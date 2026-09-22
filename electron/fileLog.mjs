// A log file for the main process, at ~/.iris/logs/iris.log.
//
// Every "log" line used to go only to the renderer, so a warning emitted while
// the window was closed — or before a restart — was gone, and "why did Hermes
// fail at 3 am?" had no answer. This writes the same events to disk, rotated by
// size so it cannot grow without bound.
//
// Transcripts, tool arguments and other conversation content never reach it:
// only diagnostic event types are written, and every line is scrubbed of
// anything shaped like a credential before it lands.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const DEFAULT_MAX_BYTES = 2 * 1024 * 1024;
export const DEFAULT_MAX_FILES = 3;
const MAX_LINE_CHARS = 4000;

export function defaultLogDir(env = process.env) {
  return env.IRIS_LOG_DIR || path.join(os.homedir(), ".iris", "logs");
}

// Values that must never be written, however they got into a message.
const SECRET_PATTERNS = [
  [/\bAIza[0-9A-Za-z_-]{20,}/g, "[redacted-google-key]"],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, "Bearer [redacted]"],
  // KEY=value and "token": "value" alike — API_SERVER_KEY, IRIS_APNS_KEY_ID, …
  [/\b([A-Za-z0-9_-]*(?:key|token|secret|password|authorization|credential)s?)(["']?\s*[:=]\s*["']?)(?!\[redacted|Bearer\b)[^\s"',;&]+/gi, "$1$2[redacted]"],
  [/([?&](?:key|token|access_token|secret)=)[^&\s]+/gi, "$1[redacted]"],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, "[redacted-private-key]"],
  [/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "[redacted-jwt]"],
];

export function redactSecrets(text) {
  let out = String(text ?? "");
  for (const [pattern, replacement] of SECRET_PATTERNS) out = out.replace(pattern, replacement);
  return out;
}

// Which renderer events are diagnostics, and the one line each becomes.
// Anything not listed — transcripts, tool calls, audio levels — is skipped.
export function eventLogEntry(event) {
  if (!event || typeof event !== "object") return null;
  const errorText = event.error ? `: ${event.error?.message || event.error}` : "";
  switch (event.type) {
    case "log":
      return { level: event.level || "info", message: String(event.message ?? "") };
    case "fatal":
      return { level: "error", message: `${event.message || "Fatal error"}${errorText}` };
    case "gemini_status":
    case "hermes_status": {
      const name = event.type === "gemini_status" ? "Gemini" : "Hermes";
      const level = event.status === "error" ? "warn" : "info";
      return { level, message: `${name} status: ${event.status}${errorText}` };
    }
    case "sidecar_status": {
      const running = event.status?.running ? "running" : "stopped";
      const reason = event.reason ? ` (${event.reason})` : "";
      return { level: "info", message: `Live session ${running}${reason}` };
    }
    default:
      return null;
  }
}

export function formatLogLine({ level = "info", message = "", time = new Date() } = {}) {
  const flat = redactSecrets(message).replace(/\s*\n\s*/g, " ⏎ ").slice(0, MAX_LINE_CHARS);
  return `${time.toISOString()} ${String(level).toUpperCase().padEnd(5)} ${flat}\n`;
}

export function createFileLog({
  dir = defaultLogDir(),
  fileName = "iris.log",
  maxBytes = DEFAULT_MAX_BYTES,
  maxFiles = DEFAULT_MAX_FILES,
  now = () => new Date(),
} = {}) {
  const filePath = path.join(dir, fileName);
  const base = fileName.replace(/\.log$/, "");
  const rotatedPath = (n) => path.join(dir, `${base}.${n}.log`);
  let ready = false;
  let disabled = false;

  function ensureDir() {
    if (ready) return;
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    ready = true;
  }

  // iris.log → iris.1.log → iris.2.log …; the oldest beyond maxFiles is dropped.
  function rotateIfNeeded(incoming) {
    let size = 0;
    try {
      size = fs.statSync(filePath).size;
    } catch {
      return;
    }
    if (size + incoming <= maxBytes) return;
    for (let n = maxFiles - 1; n >= 1; n -= 1) {
      const from = n === 1 ? filePath : rotatedPath(n - 1);
      try {
        fs.renameSync(from, rotatedPath(n));
      } catch {
        // A missing generation is normal until the log has rotated enough times.
      }
    }
    if (maxFiles <= 1) fs.rmSync(filePath, { force: true });
  }

  function write(level, message) {
    if (disabled) return;
    try {
      ensureDir();
      const line = formatLogLine({ level, message, time: now() });
      rotateIfNeeded(Buffer.byteLength(line));
      fs.appendFileSync(filePath, line, { mode: 0o600 });
    } catch (error) {
      // Logging must never break the app; a read-only disk turns it off quietly.
      disabled = true;
      try {
        process.stderr.write(`Iris file log disabled: ${error?.message || error}\n`);
      } catch {
        // Nothing left to tell.
      }
    }
  }

  return {
    path: filePath,
    write,
    info: (message) => write("info", message),
    warn: (message) => write("warn", message),
    error: (message) => write("error", message),
    event(event) {
      const entry = eventLogEntry(event);
      if (entry) write(entry.level, entry.message);
    },
  };
}
