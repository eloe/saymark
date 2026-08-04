#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const checker = path.join(scriptDirectory, "check-daily-driver-diagnostics.mjs");
const fixture = path.join(scriptDirectory, "fixtures", "daily-driver-pass.jsonl");
const baseEvents = fs.readFileSync(fixture, "utf8")
  .split(/\r?\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "saymark-diagnostic-contract-"));

try {
  expect("valid linked lifecycle", baseEvents, true);
  expect(
    "missing joined HUD latency",
    baseEvents.map((event) => event.event === "dictation.ui_started"
      ? without(event, "hud_latency_ms")
      : event),
    false
  );
  expect(
    "missing capture",
    baseEvents.filter((event) => event.event !== "microphone.capture_first_buffer"),
    false
  );
  expect(
    "duplicate capture",
    [...baseEvents, structuredClone(baseEvents.find((event) => event.event === "microphone.capture_first_buffer"))],
    false
  );
  expect(
    "mismatched capture session",
    baseEvents.map((event) => event.event === "microphone.capture_first_buffer"
      ? { ...event, session_id: "00000000-0000-4000-8000-000000000002" }
      : event),
    false
  );
  expect(
    "missing insert mode",
    baseEvents.map((event) => event.event === "dictation.ui_completed"
      ? without(event, "insert_mode")
      : event),
    false
  );
  expect(
    "unconfirmed insertion",
    baseEvents.map((event) => event.event === "dictation.insert_completed"
      ? { ...event, outcome: "delivery_unconfirmed" }
      : event),
    false
  );
  expect(
    "all HUD-only sessions cannot certify insertion",
    baseEvents
      .filter((event) => event.event !== "dictation.insert_completed")
      .map((event) => (event.event === "dictation.ui_started" || event.event === "dictation.ui_completed")
        ? { ...event, insert_mode: "hudOnly" }
        : event),
    false
  );
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}

console.log("daily-driver diagnostic contract: PASS");

function expect(name, events, shouldPass) {
  const input = path.join(temporaryDirectory, `${name.replaceAll(" ", "-")}.jsonl`);
  fs.writeFileSync(input, `${events.map((event) => JSON.stringify(event)).join("\n")}\n`, {
    mode: 0o600,
  });
  const result = spawnSync(process.execPath, [checker, input, "--min-sessions", "1"], {
    encoding: "utf8",
  });
  const passed = result.status === 0;
  if (passed !== shouldPass) {
    process.stderr.write(result.stdout);
    process.stderr.write(result.stderr);
    throw new Error(`${name}: expected ${shouldPass ? "pass" : "failure"}, exit=${result.status}`);
  }
}

function without(object, key) {
  const result = { ...object };
  delete result[key];
  return result;
}
