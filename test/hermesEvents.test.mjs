import test from "node:test";
import assert from "node:assert/strict";
import {
  approvalRequestFromRunStatus,
  formatHermesCompletionEvent,
  normalizeHermesEvent,
} from "../electron/hermesEvents.mjs";

test("normalizes the current Hermes approval.request contract", () => {
  const event = normalizeHermesEvent(
    {
      event: "approval.request",
      run_id: "run-7",
      command: "rm -rf build-cache",
      reason: "destructive command",
      choices: ["once", "session", "always", "deny", "invalid"],
      timestamp: 123,
    },
    { task: "Clean build cache" },
  );
  assert.equal(event.approvalRequested, true);
  assert.equal(event.runId, "run-7");
  assert.equal(event.command, "rm -rf build-cache");
  assert.deepEqual(event.choices, ["once", "session", "always", "deny"]);
});

test("supports legacy approval names but ignores unknown events", () => {
  assert.equal(
    normalizeHermesEvent({ event: "approval.required" }, { runId: "r" }).approvalRequested,
    true,
  );
  assert.equal(
    normalizeHermesEvent({ event: "approval.responded", choice: "deny" }, { runId: "r" })
      .approvalResolved,
    true,
  );
  assert.equal(normalizeHermesEvent({ event: "debug.noise" }, { runId: "r" }), null);
});

test("creates an actionable fallback from waiting run status", () => {
  const detailed = approvalRequestFromRunStatus({
    status: "waiting_for_approval",
    pending_approval: {
      command: "send_email --to client@example.com",
      reason: "External side effect",
      choices: ["once", "deny"],
    },
  });
  assert.equal(detailed.event, "approval.request");
  assert.match(detailed.command, /send_email/);
  assert.deepEqual(detailed.choices, ["once", "deny"]);

  const generic = approvalRequestFromRunStatus({ status: "waiting_for_approval" });
  assert.equal(generic.details_available, false);
  assert.match(generic.reason, /did not include command details/i);
  assert.equal(approvalRequestFromRunStatus({ status: "running" }), null);
});

test("completion events include the entire Hermes result", () => {
  const output = Array.from(
    { length: 5000 },
    (_, index) => `${index + 1}. Personal skill and complete description`,
  ).join("\n");
  const event = formatHermesCompletionEvent({
    runId: "run-long",
    task: "List every personal skill",
    status: "completed",
    output,
    userName: "Ashutosh",
  });
  assert.equal(
    event.slice(
      event.indexOf("authoritative_hermes_result:") +
        "authoritative_hermes_result:\n".length,
    ),
    output,
  );
  assert.match(event, /5000\. Personal skill and complete description$/);
});

test("a failed run's completion event carries the reason and forbids a result", () => {
  const text = formatHermesCompletionEvent({
    runId: "run-7",
    status: "failed",
    output: "",
    userName: "Nate",
    failure: {
      code: "session_in_use",
      message: "That chat is open in Hermes Desktop. Close it there, or I can start a new chat.",
      recovery: "start_new_chat",
      detail: "",
    },
  });
  assert.match(text, /^SYSTEM_EVENT_HERMES_COMPLETE\n/);
  assert.match(text, /failure_code: session_in_use/);
  assert.match(text, /recovery: start_new_chat/);
  assert.match(text, /The task did NOT run\./);
  assert.match(text, /That chat is open in Hermes Desktop\./);
  // Iris must not claim a result, and must not reach for a tool that does not
  // exist: starting a new chat is a tap on the phone, not a model action.
  assert.doesNotMatch(text, /authoritative_hermes_result/);
  assert.match(text, /Start a new chat and try again/);
  assert.match(text, /You CANNOT start a new chat yourself/);
});

test("a completed run's event is untouched by the failure path", () => {
  const text = formatHermesCompletionEvent({
    runId: "run-8",
    status: "completed",
    output: "42 files",
    userName: "Nate",
  });
  assert.match(text, /authoritative_hermes_result:\n42 files$/);
  assert.doesNotMatch(text, /failure_code/);
});
