#!/usr/bin/env node

import fs from "node:fs";

const path = process.argv[2] ??
  `${process.env.HOME}/Library/Logs/com.eloe.saymark.local/saymark.jsonl`;
const minimumIndex = process.argv.indexOf("--min-sessions");
const minimumSessions = minimumIndex >= 0
  ? Number(process.argv[minimumIndex + 1])
  : 1;

if (!Number.isInteger(minimumSessions) || minimumSessions < 1) {
  fail("--min-sessions must be a positive integer");
}
if (!fs.existsSync(path) || fs.statSync(path).size === 0) {
  fail(`No diagnostic events found at ${path}`);
}

const events = fs.readFileSync(path, "utf8")
  .split(/\r?\n/)
  .filter(Boolean)
  .map((line, index) => {
    try {
      return JSON.parse(line);
    } catch {
      fail(`Invalid JSON on line ${index + 1}`);
    }
  });

const forbiddenKeys = /^(audio|audio_data|audio_samples|transcript|transcript_text|clipboard|clipboard_contents|selected_text|focused_text)$/i;
for (const event of events) {
  const forbidden = Object.keys(event).find((key) => forbiddenKeys.test(key));
  if (forbidden) fail(`Privacy gate: forbidden diagnostic field "${forbidden}"`);
}

const completedBySession = uniqueSessionEvents("dictation.ui_completed");
const startedBySession = uniqueSessionEvents("dictation.ui_started");
const captureBySession = uniqueSessionEvents("microphone.capture_first_buffer");
const pipelineBySession = uniqueSessionEvents("dictation.pipeline_completed");
const insertionBySession = uniqueSessionEvents("dictation.insert_completed");
if (completedBySession.size < minimumSessions) {
  fail(`Need ${minimumSessions} completed sessions; found ${completedBySession.size}`);
}

const completed = [];
const pipelines = [];
const captureStart = [];
const hud = [];
let inFieldCount = 0;
let pastedCount = 0;
for (const [sessionID, completion] of completedBySession) {
  const started = requireSessionEvent(startedBySession, sessionID, "dictation.ui_started");
  const capture = requireSessionEvent(captureBySession, sessionID, "microphone.capture_first_buffer");
  const pipeline = requireSessionEvent(pipelineBySession, sessionID, "dictation.pipeline_completed");
  if (started.insert_mode !== completion.insert_mode) {
    fail(`Session ${sessionID} changed insert_mode between start and completion`);
  }
  if (started.model_mode !== completion.model_mode || pipeline.mode !== completion.model_mode) {
    fail(`Session ${sessionID} changed model mode across its lifecycle`);
  }
  completed.push(completion);
  pipelines.push(pipeline);
  captureStart.push(nonnegativeNumber(capture.capture_start_ms, "capture_start_ms"));
  hud.push(nonnegativeNumber(started.hud_latency_ms, "hud_latency_ms"));

  if (completion.insert_mode === "inField") {
    inFieldCount += 1;
    const insertion = requireSessionEvent(insertionBySession, sessionID, "dictation.insert_completed");
    if (insertion.outcome === "pasted") pastedCount += 1;
  } else if (completion.insert_mode === "hudOnly") {
    if (insertionBySession.has(sessionID)) {
      fail(`HUD-only session ${sessionID} unexpectedly crossed the insertion boundary`);
    }
  } else {
    fail(`Session ${sessionID} has missing or invalid insert_mode`);
  }
}

const failures = [];
gate("HUD p95", percentile(hud, 0.95), 100, "ms", failures);
gate("HUD max", Math.max(...hud), 200, "ms", failures);
gate("Capture-start p95", percentile(captureStart, 0.95), 250, "ms", failures);

const stop = completed.map((event) => number(event.stop_to_complete_ms, "stop_to_complete_ms"));
gate("Stop-to-final median", percentile(stop, 0.5), 2_000, "ms", failures);
gate("Stop-to-final p95", percentile(stop, 0.95), 3_000, "ms", failures);

for (const [mode, limits] of Object.entries({
  accurate: { rtf: 0.08, p95: 100, max: 250 },
  hybrid: { rtf: 0.50, p95: 250, max: 450 },
})) {
  const modeEvents = pipelines.filter((event) => event.mode === mode);
  if (modeEvents.length === 0) continue;
  gate(`${mode} median RTF`, percentile(modeEvents.map((e) => number(e.compute_rtf, "compute_rtf")), 0.5), limits.rtf, "", failures);
  gate(`${mode} step p95`, percentile(modeEvents.map((e) => number(e.asr_step_p95_ms, "asr_step_p95_ms")), 0.95), limits.p95, "ms", failures);
  gate(`${mode} step max`, Math.max(...modeEvents.map((e) => number(e.asr_step_max_ms, "asr_step_max_ms"))), limits.max, "ms", failures);
}

const peakGB = Math.max(...pipelines.map((event) => number(event.mlx_peak_bytes, "mlx_peak_bytes"))) / 1_000_000_000;
gate("MLX peak", peakGB, 6, "GB", failures);

if (pastedCount !== inFieldCount) {
  failures.push(`Insertion success: ${pastedCount}/${inFieldCount} (expected 100%)`);
}
if (inFieldCount < minimumSessions) {
  failures.push(`Insertion evidence: need ${minimumSessions} completed in-field sessions; found ${inFieldCount}`);
}

console.log(`Saymark daily-driver acceptance: ${path}`);
console.log(`sessions: ${completed.length}; HUD samples: ${hud.length}; capture-start samples: ${captureStart.length}; successful pastes: ${pastedCount}/${inFieldCount}`);
if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL ${failure}`);
  process.exit(1);
}
console.log("PASS all observed daily-driver gates");

function select(name) {
  return events.filter((event) => event.event === name);
}

function values(name, field) {
  return select(name).map((event) => number(event[field], field));
}

function uniqueSessionEvents(name) {
  const result = new Map();
  for (const event of select(name)) {
    const sessionID = event.session_id;
    if (typeof sessionID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sessionID)) {
      fail(`${name} has a missing or invalid opaque session_id`);
    }
    if (result.has(sessionID)) fail(`${name} is duplicated for session ${sessionID}`);
    result.set(sessionID, event);
  }
  return result;
}

function requireSessionEvent(eventsBySession, sessionID, name) {
  const event = eventsBySession.get(sessionID);
  if (!event) fail(`Completed session ${sessionID} is missing ${name}`);
  return event;
}

function number(value, field) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    fail(`Missing or invalid numeric field "${field}"`);
  }
  return value;
}

function nonnegativeNumber(value, field) {
  const result = number(value, field);
  if (result < 0) fail(`Numeric field "${field}" must be nonnegative`);
  return result;
}

function percentile(items, fraction) {
  const sorted = [...items].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
}

function gate(label, actual, limit, unit, failures) {
  const formatted = Number(actual.toFixed(3));
  if (actual > limit) failures.push(`${label}: ${formatted}${unit} > ${limit}${unit}`);
  else console.log(`PASS ${label}: ${formatted}${unit} <= ${limit}${unit}`);
}

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}
