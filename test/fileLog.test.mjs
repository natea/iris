import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  createFileLog,
  eventLogEntry,
  formatLogLine,
  redactSecrets,
} from "../electron/fileLog.mjs";

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "iris-filelog-"));
}

test("credentials are scrubbed before a line is written", () => {
  const text = redactSecrets(
    "key AIzaSyA1234567890abcdefghijklmnop, Authorization: Bearer abcdef123456, " +
      "API_SERVER_KEY=supersecretvalue https://x/y?key=abc123&ok=1 " +
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
  );
  assert.doesNotMatch(text, /AIzaSy|abcdef123456|supersecretvalue|abc123|eyJhbGci/);
  assert.match(text, /ok=1/);
});

test("only diagnostic events are logged; conversation content never is", () => {
  assert.deepEqual(eventLogEntry({ type: "log", level: "warn", message: "Hermes slow" }), {
    level: "warn",
    message: "Hermes slow",
  });
  assert.equal(eventLogEntry({ type: "fatal", message: "Gemini Live error", error: "boom" }).message, "Gemini Live error: boom");
  assert.equal(eventLogEntry({ type: "hermes_status", status: "error", error: "ECONNREFUSED" }).level, "warn");
  assert.equal(eventLogEntry({ type: "sidecar_status", status: { running: false }, reason: "closed" }).message, "Live session stopped (closed)");
  assert.equal(eventLogEntry({ type: "transcript", text: "my bank password is hunter2" }), null);
  assert.equal(eventLogEntry({ type: "tool_call", args: { brief: "private" } }), null);
  assert.equal(eventLogEntry(null), null);
});

test("a line is one line, timestamped and levelled", () => {
  const line = formatLogLine({ level: "warn", message: "first\nsecond", time: new Date("2026-09-22T10:00:00Z") });
  assert.equal(line, "2026-09-22T10:00:00.000Z WARN  first ⏎ second\n");
});

test("events are appended to iris.log", () => {
  const dir = tempDir();
  const log = createFileLog({ dir, now: () => new Date("2026-09-22T10:00:00Z") });
  log.event({ type: "log", level: "info", message: "Iris Link listening" });
  log.event({ type: "transcript", text: "not this" });
  log.error("crashed");
  const text = fs.readFileSync(path.join(dir, "iris.log"), "utf8");
  assert.match(text, /INFO  Iris Link listening/);
  assert.match(text, /ERROR crashed/);
  assert.doesNotMatch(text, /not this/);
  assert.equal(fs.statSync(path.join(dir, "iris.log")).mode & 0o777, 0o600);
});

test("the log rotates by size and keeps a bounded number of files", () => {
  const dir = tempDir();
  const log = createFileLog({ dir, maxBytes: 200, maxFiles: 3 });
  for (let i = 0; i < 40; i += 1) log.info(`line ${i} ${"x".repeat(40)}`);
  const files = fs.readdirSync(dir).sort();
  assert.deepEqual(files, ["iris.1.log", "iris.2.log", "iris.log"]);
  for (const file of files) assert.ok(fs.statSync(path.join(dir, file)).size <= 200);
  // The newest line is in the live file, and the oldest was dropped.
  assert.match(fs.readFileSync(path.join(dir, "iris.log"), "utf8"), /line 39 /);
  assert.doesNotMatch(files.map((f) => fs.readFileSync(path.join(dir, f), "utf8")).join(""), /line 0 /);
});

test("an unwritable log directory never throws into the app", () => {
  const dir = tempDir();
  const blocker = path.join(dir, "not-a-dir");
  fs.writeFileSync(blocker, "");
  const log = createFileLog({ dir: path.join(blocker, "logs") });
  assert.doesNotThrow(() => log.warn("first"));
  assert.doesNotThrow(() => log.warn("second"));
});
