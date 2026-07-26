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

const hud = values("dictation.hud_presented", "latency_ms");
const completed = select("dictation.ui_completed");
const pipelines = select("dictation.pipeline_completed");
const pasted = select("dictation.insert_completed")
  .filter((event) => event.outcome === "pasted");

if (completed.length < minimumSessions || pipelines.length < minimumSessions) {
  fail(`Need ${minimumSessions} completed sessions; found UI=${completed.length}, pipeline=${pipelines.length}`);
}
if (hud.length < minimumSessions) {
  fail(`Need ${minimumSessions} HUD latency samples; found ${hud.length}`);
}

const failures = [];
gate("HUD p95", percentile(hud, 0.95), 100, "ms", failures);
gate("HUD max", Math.max(...hud), 200, "ms", failures);

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

const inField = completed.filter((event) => event.insert_mode === "inField");
if (inField.length > 0 && pasted.length !== inField.length) {
  failures.push(`Insertion success: ${pasted.length}/${inField.length} (expected 100%)`);
}

console.log(`Saymark daily-driver acceptance: ${path}`);
console.log(`sessions: ${completed.length}; HUD samples: ${hud.length}; successful pastes: ${pasted.length}/${inField.length}`);
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

function number(value, field) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    fail(`Missing or invalid numeric field "${field}"`);
  }
  return value;
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
