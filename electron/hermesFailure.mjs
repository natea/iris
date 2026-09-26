// Why a Hermes run did not happen, in words a person can act on.
//
// Every failure that reaches a phone used to arrive as the same sentence —
// "Hermes is not reachable from your Mac. Nothing was sent." — or as a bare
// FAILED. That sentence was often a lie: the gateway's HTTP health check was
// green while the interactive backend crash-looped, and it was flatly wrong
// when Hermes had simply refused because the chat was already open somewhere
// else.
//
// This module is the one place that turns Hermes' own text (or a transport
// error, or a log tail) into a stable code, one plain sentence, and a machine
// hint for what would fix it. It is pure: no I/O, no Electron, no clock. The
// codes are part of the Iris Link contract (LINK_API.md, "Failure reasons and
// recovery") and must not be renamed.
//
// Two rules it never bends:
//   · the original text is never dropped on the floor — a sanitized, capped
//     copy always comes back as `detail`, so the phone can show it behind a
//     disclosure and a bug report still has something to quote;
//   · nothing that looks like a secret survives sanitization, and no path is
//     invented that Hermes' own message did not already contain.

export const HERMES_FAILURE_CODES = Object.freeze([
  "session_in_use",
  "backend_start_failed",
  "model_unreachable",
  "auth_failed",
  "gateway_unreachable",
  "run_limit",
  "stopped_by_user",
  "unknown",
]);

export const HERMES_RECOVERY_HINTS = Object.freeze([
  "start_new_chat",
  "retry",
  "check_mac",
  "none",
]);

// Bounds. A failure reason is a sentence on a phone screen, not a log file.
export const MAX_MESSAGE_CHARS = 240;
export const MAX_DETAIL_CHARS = 400;
const MAX_INPUT_CHARS = 40_000;
const MAX_HINT_CHARS = 80;

const REDACTED = "[redacted]";

// Anything that looks like a credential is replaced BEFORE any matching or
// extraction, so a secret cannot reach a message, a hint, or `detail`.
const SECRET_PATTERNS = [
  // Authorization headers and bearer tokens.
  [/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, `$1 ${REDACTED}`],
  // key=value / "key": "value" shapes for anything named like a credential.
  // `auth` on its own is deliberately NOT in this list: it would swallow
  // "failed to authenticate: …", which is exactly the sentence that names why
  // a backend would not start.
  [
    /\b([\w-]*(?:api[_-]?key|api[_-]?secret|secret|token|passw(?:or)?d|pwd|credential|access[_-]?key|client[_-]?secret|refresh[_-]?token|session[_-]?key|auth[_-]?(?:key|token)|key)[\w-]*)\s*[:=]\s*["']?[^\s"',;)]{4,}["']?/gi,
    `$1=${REDACTED}`,
  ],
  // Common vendor key shapes, matched on their own.
  [/\b(?:sk|pk|rk|ghp|gho|ghs|ghu|xox[abprs])[-_][A-Za-z0-9._-]{12,}/g, REDACTED],
  [/\bAIza[0-9A-Za-z_-]{20,}/g, REDACTED],
  [/\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}/g, REDACTED],
  // A long unbroken high-entropy run is a key far more often than it is prose.
  [/\b[A-Fa-f0-9]{40,}\b/g, REDACTED],
  [/\b[A-Za-z0-9+/]{48,}={0,2}\b/g, REDACTED],
];

/**
 * Strip control characters and redact anything secret-shaped, KEEPING line
 * breaks. Used for the bulk text that classification matches against, so that
 * "first line" still means something afterwards.
 */
function redact(value) {
  let text = String(value ?? "").slice(0, MAX_INPUT_CHARS);
  // Control characters first: a terminal escape in a notification body is both
  // ugly and a way to hide the rest of the sentence. `\n` survives.
  text = text.replace(/[\u0000-\u0009\u000b\u000c\u000e-\u001f\u007f]/g, " ");
  for (const [pattern, replacement] of SECRET_PATTERNS) {
    text = text.replace(pattern, replacement);
  }
  return text;
}

/** Redacted, flattened to one line, and capped — the display form. */
export function sanitizeFailureText(value, max = MAX_DETAIL_CHARS) {
  const text = redact(value).replace(/\s+/g, " ").trim();
  if (text.length > max) return `${text.slice(0, max - 1).trimEnd()}…`;
  return text;
}

/** The first meaningful line, sanitized — what a person would read first. */
export function firstLine(value, max = MAX_DETAIL_CHARS) {
  const line = redact(value)
    .split(/\r?\n/)
    .map((part) => part.trim())
    .find(Boolean) || "";
  return sanitizeFailureText(line, max);
}

// ----- Input shaping -------------------------------------------------------

function collectText(input) {
  if (input == null) return { text: "", logTail: "", status: 0, rpcCode: 0 };
  if (typeof input === "string") return { text: input, logTail: "", status: 0, rpcCode: 0 };
  if (input instanceof Error) {
    return {
      text: `${input.message || ""}`,
      logTail: String(input.logTail || ""),
      status: Number(input.status) || 0,
      rpcCode: Number(input.code) || 0,
    };
  }
  if (typeof input === "object") {
    const parts = [input.message, input.error, input.text, input.output]
      .filter((part) => typeof part === "string" && part.trim());
    return {
      text: parts.join("\n"),
      logTail: String(input.logTail || input.log_tail || ""),
      status: Number(input.status) || 0,
      rpcCode: Number(input.code) || 0,
    };
  }
  return { text: String(input), logTail: "", status: 0, rpcCode: 0 };
}

// ----- session_in_use ------------------------------------------------------

// Hermes' own refusal, verbatim (hermes_cli/active_sessions.py):
//   "This chat is open in another Hermes window/terminal. Use it there, or
//    start a new chat here.\nDetails: session <id> opened by <surface> <age> ago."
const SESSION_IN_USE_RE = /open in another hermes (?:window|terminal)|this chat is open in another/i;
const SESSION_DETAILS_RE =
  /session\s+([\w:.-]{1,80})\s+opened by\s+([A-Za-z][\w-]{0,30})(?:\s+((?:\d+[a-z]+)+|\d+\s*(?:seconds?|minutes?|hours?|days?))\s+ago)?/i;

// What the user calls the thing that is holding the chat. Anything unknown
// stays honest rather than being guessed into a product name.
const HOLDER_NAMES = Object.freeze({
  desktop: "Hermes Desktop",
  tui: "the Hermes terminal app",
  cli: "a Hermes terminal",
  terminal: "a Hermes terminal",
  web: "the Hermes web UI",
  webui: "the Hermes web UI",
  gateway: "the Hermes gateway",
  telegram: "Hermes on Telegram",
  slack: "Hermes on Slack",
});

export function describeSessionHolder(surface) {
  const key = String(surface || "").trim().toLowerCase();
  return HOLDER_NAMES[key] || "another Hermes window";
}

// ----- backend_start_failed hints -----------------------------------------

// A backend that will not start usually says why somewhere in its log tail.
// The one that actually bit: an MCP server whose OAuth had expired made
// startup hang past the timeout. Only a short, named cause is lifted out —
// never a stack trace, never a path Hermes did not print itself.
const MCP_AUTH_RE =
  /MCP server\s+['"]?([\w.@/-]{1,40})['"]?[^\n]{0,160}?(?:failed to authenticate|authentication failed|auth(?:entication)? error|unauthorized|401|oauth[^\n]{0,40}?(?:failed|expired|error))/i;
const MCP_GENERIC_RE =
  /MCP server\s+['"]?([\w.@/-]{1,40})['"]?[^\n]{0,160}?(?:failed|timed out|crashed|did not start|error)/i;
const MISSING_RUNTIME_RE = /no usable hermes runtime|command not found|ENOENT/i;

/** A short, sanitized "because…" for a backend that would not start, or "". */
export function backendStartHint(text) {
  const source = String(text || "");
  const auth = MCP_AUTH_RE.exec(source);
  if (auth) return sanitizeFailureText(`MCP server '${auth[1]}' failed to authenticate`, MAX_HINT_CHARS);
  const generic = MCP_GENERIC_RE.exec(source);
  if (generic) return sanitizeFailureText(`MCP server '${generic[1]}' would not start`, MAX_HINT_CHARS);
  if (MISSING_RUNTIME_RE.test(source)) return "no usable Hermes runtime was found";
  if (/timed out starting hermes interactive backend/i.test(source)) return "";
  return "";
}

// ----- The table -----------------------------------------------------------

const MODEL_UNREACHABLE_RE =
  /AI model service isn't reachable|could not reach the AI model service|connection to the AI model service was interrupted|AI model service kept failing|APIConnectionError|provider connection (?:failed|error)/i;
// Iris ↔ Hermes, not Hermes ↔ its provider: a wrong API_SERVER_KEY.
const AUTH_FAILED_RE =
  /\b401\b|invalid api key|api key is invalid|API_SERVER_KEY|unauthorized|authentication failed between/i;
const GATEWAY_UNREACHABLE_RE =
  /ECONNREFUSED|ECONNRESET|EHOSTUNREACH|ENETUNREACH|ETIMEDOUT|connection refused|fetch failed|socket hang up|could not connect to hermes|timed out connecting to hermes|hermes interactive socket closed|hermes is not running|hermes api not reachable/i;
const BACKEND_START_RE =
  /timed out starting hermes interactive backend|exited before ready|no usable hermes runtime|hermes interactive backend exited/i;
const RUN_LIMIT_RE = /reached maximum iterations|max(?:imum)? iterations reached|iteration budget exhausted/i;
const STOPPED_RE =
  /\bstopped by (?:the )?user\b|\binterrupted by (?:the )?user\b|\bcancell?ed by\b|^cancell?ed$|user cancell?ed/i;

/**
 * Classify one Hermes failure.
 *
 * @param input  A string, an Error, or `{ message, error, logTail, status, code }`.
 *               `logTail` is only ever mined for a short named cause; it never
 *               reaches `message` or `detail` wholesale.
 * @returns {{code:string, message:string, recovery:string, detail:string,
 *            holder?:string, age?:string, sessionId?:string, hint?:string}}
 */
export function classifyHermesFailure(input) {
  const { text, logTail, status, rpcCode } = collectText(input);
  // Redact before matching: a secret that is never matched can never be
  // quoted back. Line breaks survive, so `firstLine` still means something.
  const safe = redact(text);
  const safeLog = redact(logTail);
  // The log tail is the gateway's shared, long-lived buffer, not this run's
  // output: a stale ECONNREFUSED or "cancelled" from hours ago must never
  // classify an unrelated failure. Only the backend-start rule reads it,
  // because that is the one failure whose cause is printed there and nowhere
  // else. Every other rule matches this run's own text.
  const haystack = `${safe}\n${safeLog}`;
  const detail = firstLine(safe) || firstLine(safeLog);

  // 1. The chat is held by another Hermes client. Checked first because its
  //    text is unmistakable and nothing else should ever shadow it.
  if (SESSION_IN_USE_RE.test(safe)) {
    const details = SESSION_DETAILS_RE.exec(safe);
    const sessionId = details?.[1] ? sanitizeFailureText(details[1], 80) : "";
    const surface = details?.[2] ? details[2].trim() : "";
    const age = details?.[3] ? sanitizeFailureText(details[3], 24) : "";
    const holder = describeSessionHolder(surface);
    return {
      code: "session_in_use",
      // The exact sentence agreed for the phone.
      message: cap(`That chat is open in ${holder}. Close it there, or I can start a new chat.`),
      recovery: "start_new_chat",
      detail,
      holder,
      ...(surface ? { surface: sanitizeFailureText(surface, 30) } : {}),
      ...(age ? { age } : {}),
      ...(sessionId ? { sessionId } : {}),
    };
  }

  // 2. The backend would not come up. BEFORE the auth and connection rows:
  //    its log tail is full of both (a failing MCP server's own 401, a
  //    refused connection) and those are symptoms, not the cause.
  if (BACKEND_START_RE.test(safe) || rpcCode === 4001) {
    const hint = backendStartHint(haystack);
    return {
      code: "backend_start_failed",
      message: cap(
        hint
          ? `Hermes' backend would not start (${hint}).`
          : "Hermes' backend would not start on your Mac, so nothing ran.",
      ),
      recovery: "check_mac",
      detail,
      ...(hint ? { hint } : {}),
    };
  }

  // 3. Iris could not authenticate to Hermes at all. Matched on the error
  //    itself, never on a log tail: a 401 printed by some MCP server inside
  //    Hermes says nothing about the key between Iris and Hermes.
  if (status === 401 || AUTH_FAILED_RE.test(safe)) {
    return {
      code: "auth_failed",
      message: cap(
        "Iris isn't allowed into Hermes — the shared API key doesn't match. It has to be fixed on your Mac.",
      ),
      recovery: "check_mac",
      detail,
    };
  }

  // 4. Hermes is up but its model provider is not.
  if (MODEL_UNREACHABLE_RE.test(safe)) {
    return {
      code: "model_unreachable",
      message: cap("Hermes couldn't reach its AI model service, so nothing ran. It's usually back shortly."),
      recovery: "retry",
      detail,
    };
  }

  // 5. Hermes ran out of steps rather than failing.
  if (RUN_LIMIT_RE.test(safe)) {
    return {
      code: "run_limit",
      message: cap("Hermes hit its step limit before finishing. A narrower task usually gets there."),
      recovery: "retry",
      detail,
    };
  }

  // 6. Somebody stopped it.
  if (STOPPED_RE.test(safe)) {
    return {
      code: "stopped_by_user",
      message: cap("That run was stopped before it finished."),
      recovery: "none",
      detail,
    };
  }

  // 7. Nothing answered on 127.0.0.1:8642 (or the interactive socket died).
  if (GATEWAY_UNREACHABLE_RE.test(safe)) {
    return {
      code: "gateway_unreachable",
      message: cap("Hermes isn't answering on your Mac, so nothing was sent."),
      recovery: "check_mac",
      detail,
    };
  }

  // 8. Unknown — but never silent. The original first line is carried in the
  //    sentence as well as in `detail`, because an unexplained FAILED is the
  //    exact thing this module exists to stop.
  return {
    code: "unknown",
    message: cap(
      detail
        ? `Hermes couldn't run that. It said: ${detail}`
        : "Hermes couldn't run that, and it didn't say why.",
    ),
    recovery: "retry",
    detail,
  };
}

function cap(sentence) {
  const text = String(sentence || "").trim();
  if (text.length <= MAX_MESSAGE_CHARS) return text;
  return `${text.slice(0, MAX_MESSAGE_CHARS - 1).trimEnd()}…`;
}

/**
 * The wire shape the phone decodes: `failure` on a task, or null.
 * Additive — a run that did not fail carries null, never an empty object.
 */
export function failureBlock(input) {
  const classified = classifyHermesFailure(input);
  return {
    code: classified.code,
    message: classified.message,
    recovery: classified.recovery,
    detail: classified.detail,
  };
}
