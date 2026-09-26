import test from "node:test";
import assert from "node:assert/strict";
import {
  HERMES_FAILURE_CODES,
  HERMES_RECOVERY_HINTS,
  MAX_DETAIL_CHARS,
  MAX_MESSAGE_CHARS,
  backendStartHint,
  classifyHermesFailure,
  describeSessionHolder,
  failureBlock,
  firstLine,
  sanitizeFailureText,
} from "../electron/hermesFailure.mjs";

// The real refusal Hermes produced on 2026-09-16, copied from
// ~/.hermes/hermes-agent/hermes_cli/active_sessions.py.
const SESSION_IN_USE =
  "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n" +
  "Details: session 20260916_174926_797a3b opened by desktop 1h36m ago.";

// The log tail from the crash-loop: a broken MCP server (Strava OAuth) made
// `hermes serve` hang past its startup allowance.
const STRAVA_LOG_TAIL = [
  "[gateway] loading MCP servers from ~/.hermes/config.yaml",
  "[mcp] MCP server 'strava' failed to authenticate: OAuth token expired (401)",
  "[mcp] retrying strava in 5s",
  "[gateway] still waiting for MCP servers to settle",
].join("\n");

test("every code and recovery hint is a stable snake_case token", () => {
  for (const code of HERMES_FAILURE_CODES) assert.match(code, /^[a-z][a-z_]*$/);
  for (const hint of HERMES_RECOVERY_HINTS) assert.match(hint, /^[a-z][a-z_]*$/);
});

test("the session-in-use refusal is named, attributed, and offers a new chat", () => {
  const failure = classifyHermesFailure(SESSION_IN_USE);
  assert.equal(failure.code, "session_in_use");
  // The exact wording agreed for the phone.
  assert.equal(
    failure.message,
    "That chat is open in Hermes Desktop. Close it there, or I can start a new chat.",
  );
  assert.equal(failure.recovery, "start_new_chat");
  assert.equal(failure.holder, "Hermes Desktop");
  assert.equal(failure.surface, "desktop");
  assert.equal(failure.age, "1h36m");
  assert.equal(failure.sessionId, "20260916_174926_797a3b");
  // The original is never dropped on the floor.
  assert.match(failure.detail, /This chat is open in another Hermes window\/terminal\./);
});

test("the holder is named from Hermes' own surface, and never guessed", () => {
  assert.equal(describeSessionHolder("desktop"), "Hermes Desktop");
  assert.equal(describeSessionHolder("cli"), "a Hermes terminal");
  assert.equal(describeSessionHolder("tui"), "the Hermes terminal app");
  assert.equal(describeSessionHolder("something-new"), "another Hermes window");

  const fromCli = classifyHermesFailure(
    "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n" +
      "Details: session 20260920_161059_28930d opened by cli 12m ago.",
  );
  assert.equal(fromCli.code, "session_in_use");
  assert.equal(
    fromCli.message,
    "That chat is open in a Hermes terminal. Close it there, or I can start a new chat.",
  );
  assert.equal(fromCli.age, "12m");
});

test("a session-in-use refusal with no Details line still classifies", () => {
  const failure = classifyHermesFailure(
    "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.",
  );
  assert.equal(failure.code, "session_in_use");
  assert.equal(failure.recovery, "start_new_chat");
  assert.equal(failure.holder, "another Hermes window");
  assert.equal(failure.age, undefined);
});

test("a backend that would not start names the MCP server from the log tail", () => {
  const failure = classifyHermesFailure({
    message: "Timed out starting Hermes interactive backend.",
    logTail: STRAVA_LOG_TAIL,
  });
  assert.equal(failure.code, "backend_start_failed");
  assert.equal(
    failure.message,
    "Hermes' backend would not start (MCP server 'strava' failed to authenticate).",
  );
  assert.equal(failure.recovery, "check_mac");
  assert.equal(failure.hint, "MCP server 'strava' failed to authenticate");
});

test("a backend start failure with no nameable cause says so plainly", () => {
  const failure = classifyHermesFailure(
    new Error("Hermes interactive backend exited before ready (1). goodbye"),
  );
  assert.equal(failure.code, "backend_start_failed");
  assert.equal(failure.message, "Hermes' backend would not start on your Mac, so nothing ran.");
  assert.equal(failure.hint, undefined);
});

test("a missing runtime is a backend start failure, not an unreachable gateway", () => {
  const failure = classifyHermesFailure(
    "No usable Hermes runtime could start the interactive gateway.",
  );
  assert.equal(failure.code, "backend_start_failed");
  assert.match(failure.message, /no usable Hermes runtime was found/);
});

test("backendStartHint lifts only a short named cause", () => {
  assert.equal(backendStartHint(STRAVA_LOG_TAIL), "MCP server 'strava' failed to authenticate");
  assert.equal(
    backendStartHint("[mcp] MCP server 'github' crashed on startup"),
    "MCP server 'github' would not start",
  );
  assert.equal(backendStartHint("nothing useful here"), "");
});

test("Hermes' own model-service outage is not reported as unreachable", () => {
  const failure = classifyHermesFailure(
    "⚠️ The AI model service isn't reachable right now — the configured model endpoint is not running or is unreachable. Wait a moment and use /retry.",
  );
  assert.equal(failure.code, "model_unreachable");
  assert.equal(failure.recovery, "retry");
  assert.match(failure.message, /couldn't reach its AI model service/);
  assert.doesNotMatch(failure.message, /not reachable from your Mac/);
});

test("a wrong shared key between Iris and Hermes is auth_failed", () => {
  const byStatus = classifyHermesFailure({ message: "Hermes rejected the request", status: 401 });
  assert.equal(byStatus.code, "auth_failed");
  assert.equal(byStatus.recovery, "check_mac");

  const byText = classifyHermesFailure("Hermes returned 401: invalid api key");
  assert.equal(byText.code, "auth_failed");
  assert.match(byText.message, /shared API key doesn't match/);
});

test("a refused connection to the gateway stays gateway_unreachable", () => {
  const failure = classifyHermesFailure(new Error("connect ECONNREFUSED 127.0.0.1:8642"));
  assert.equal(failure.code, "gateway_unreachable");
  assert.equal(failure.recovery, "check_mac");
  assert.match(failure.message, /isn't answering on your Mac/);
});

test("the iteration budget and a user stop are their own reasons", () => {
  const limit = classifyHermesFailure("⚠️  Reached maximum iterations (150). Requesting summary...");
  assert.equal(limit.code, "run_limit");
  assert.equal(limit.recovery, "retry");

  const stopped = classifyHermesFailure("Run was stopped by the user.");
  assert.equal(stopped.code, "stopped_by_user");
  assert.equal(stopped.recovery, "none");
});

test("an unrecognised failure keeps the original text rather than inventing one", () => {
  const failure = classifyHermesFailure("Widget frobnicator exploded\nsecond line of detail");
  assert.equal(failure.code, "unknown");
  assert.equal(failure.detail, "Widget frobnicator exploded");
  assert.match(failure.message, /Widget frobnicator exploded/);
  assert.equal(failure.recovery, "retry");
});

test("an empty or absent failure never fabricates a cause", () => {
  for (const input of [null, undefined, "", "   ", {}]) {
    const failure = classifyHermesFailure(input);
    assert.equal(failure.code, "unknown");
    assert.equal(failure.detail, "");
    assert.equal(failure.message, "Hermes couldn't run that, and it didn't say why.");
  }
});

test("anything secret-shaped is redacted before it can reach a phone", () => {
  const leaky = [
    "Hermes refused: Authorization: Bearer sk-live-0123456789abcdefghijklmnop",
    "API_SERVER_KEY=hunter2-not-a-real-key-at-all",
    "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
    // Built, not written: a literal in this shape trips GitHub secret scanning.
    "google key " + "AIza" + "Sy" + "FAKE-not-a-real-google-key-0000000".padEnd(33, "0"),
    "sha 0123456789abcdef0123456789abcdef01234567",
  ].join("\n");
  const cleaned = sanitizeFailureText(leaky, 4000);
  assert.doesNotMatch(cleaned, /sk-live-0123456789/);
  assert.doesNotMatch(cleaned, /hunter2-not-a-real-key/);
  assert.doesNotMatch(cleaned, /ghp_ABCDEFGHIJ/);
  assert.doesNotMatch(cleaned, /AIzaSyFAKE/);
  assert.doesNotMatch(cleaned, /0123456789abcdef0123456789abcdef01234567/);
  assert.match(cleaned, /\[redacted\]/);

  // …and through the classifier, in both the message and the detail.
  const failure = classifyHermesFailure(leaky);
  assert.doesNotMatch(failure.message, /sk-live/);
  assert.doesNotMatch(JSON.stringify(failure), /hunter2-not-a-real-key/);
});

test("control characters are stripped and lengths are capped", () => {
  const noisy = `\u001b[31mred\u0007\u0000 text\u001b[0m ${"x".repeat(900)}`;
  const cleaned = sanitizeFailureText(noisy);
  assert.doesNotMatch(cleaned, /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/);
  assert.ok(cleaned.length <= MAX_DETAIL_CHARS);

  const failure = classifyHermesFailure("y".repeat(5000));
  assert.ok(failure.message.length <= MAX_MESSAGE_CHARS);
  assert.ok(failure.detail.length <= MAX_DETAIL_CHARS);
});

test("firstLine takes the first meaningful line only", () => {
  assert.equal(firstLine("\n\n  hello there \nsecond"), "hello there");
  assert.equal(firstLine(""), "");
});

test("no classification ever leaks a filesystem path Hermes did not print", () => {
  const failure = classifyHermesFailure({
    message: "Timed out starting Hermes interactive backend.",
    logTail: "[mcp] MCP server 'strava' failed to authenticate reading /Users/nate/.hermes/auth.json",
  });
  // The hint names the server, not where its credentials live.
  assert.doesNotMatch(failure.message, /\/Users\//);
  assert.equal(failure.hint, "MCP server 'strava' failed to authenticate");
});

test("failureBlock is the wire shape and nothing more", () => {
  const block = failureBlock(SESSION_IN_USE);
  assert.deepEqual(Object.keys(block).sort(), ["code", "detail", "message", "recovery"]);
  assert.equal(block.code, "session_in_use");
  assert.equal(block.recovery, "start_new_chat");
});

test("a stale line in the shared log tail never classifies this run's failure", () => {
  // The gateway's log tail is long-lived and shared across runs. What it
  // said an hour ago about some MCP server is not why this dispatch failed.
  const staleTail = [
    "12:01:03 mcp[weather]: connect ECONNREFUSED 127.0.0.1:9911",
    "12:01:04 run 8f2 cancelled by user",
    "12:01:05 session abc is already in use by Hermes Desktop",
  ].join("\n");
  const unknown = classifyHermesFailure({ message: "Tool 'fetch' raised: boom", logTail: staleTail });
  assert.equal(unknown.code, "unknown");
  assert.match(unknown.message, /boom/);
  // The one rule that legitimately reads the tail still does.
  const start = classifyHermesFailure({
    message: "Timed out starting Hermes interactive backend.",
    logTail: "MCP server 'weather' failed to authenticate",
  });
  assert.equal(start.code, "backend_start_failed");
  assert.equal(start.hint, "MCP server 'weather' failed to authenticate");
});

