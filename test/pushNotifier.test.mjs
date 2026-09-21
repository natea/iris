import test from "node:test";
import assert from "node:assert/strict";
import {
  COMPLETION_PUSH_GRACE_MS,
  buildAttentionPayload,
  buildCompletionPayload,
  completionTitle,
  createPushNotifier,
  deviceIdFromOrigin,
  shortenForPush,
} from "../electron/pushNotifier.mjs";
import { pendingApprovalFor, approvalRequestId } from "../electron/runRegistry.mjs";

// A notifier with a hand-cranked clock: nothing is scheduled for real, so the
// grace window is exercised by firing the pending timer explicitly.
function makeNotifier(overrides = {}) {
  const sent = [];
  const dropped = [];
  const logs = [];
  const pending = [];
  const apns = {
    send: async (request) => {
      sent.push(request);
      return overrides.result || { ok: true, status: 200, reason: "", unregistered: false };
    },
  };
  const notifier = createPushNotifier({
    getClient: overrides.getClient || (() => apns),
    getTarget:
      overrides.getTarget ||
      ((deviceId) => ({ token: "a".repeat(64), environment: "sandbox", deviceId })),
    isAnnounced: overrides.isAnnounced || (() => false),
    dropToken: (deviceId) => dropped.push(deviceId),
    log: (message, level) => logs.push({ message, level }),
    schedule: (fn) => {
      const entry = { fn, fired: false };
      pending.push(entry);
      return entry;
    },
    clear: (entry) => {
      if (entry) entry.cancelled = true;
    },
    ...overrides.inject,
  });
  return {
    notifier,
    sent,
    dropped,
    logs,
    // Fire every scheduled grace timer that has not been cancelled.
    async flush() {
      for (const entry of pending) {
        if (entry.fired || entry.cancelled) continue;
        entry.fired = true;
        entry.fn();
      }
      await new Promise((resolve) => setImmediate(resolve));
    },
    pending,
  };
}

test("the completion title is the real terminal status, never an optimistic one", () => {
  assert.equal(completionTitle("completed"), "Hermes finished");
  assert.equal(completionTitle("failed"), "Hermes couldn't finish");
  assert.equal(completionTitle("error"), "Hermes couldn't finish");
  assert.equal(completionTitle("cancelled"), "Hermes was stopped");
  assert.equal(completionTitle("canceled"), "Hermes was stopped");
  assert.equal(completionTitle(""), "Hermes couldn't finish");
});

test("a completion payload carries the task title and no result text", () => {
  const payload = buildCompletionPayload({
    runId: "run-9",
    task: "Goal:\n  Summarize the quarterly numbers   ",
    status: "completed",
  });
  assert.equal(payload.aps.alert.title, "Hermes finished");
  assert.equal(payload.aps.alert.body, "Goal: Summarize the quarterly numbers");
  assert.equal(payload.aps["thread-id"], "run-9");
  assert.equal(payload.aps["interruption-level"], "active");
  assert.equal(payload.aps.sound, "default");
  assert.equal(payload.run_id, "run-9");
  assert.equal(payload.kind, "run_complete");
  assert.equal("output" in payload, false);

  const long = buildCompletionPayload({ runId: "r", task: "x".repeat(400), status: "failed" });
  assert.ok(long.aps.alert.body.length <= 110);
  assert.equal(shortenForPush("", 10), "");
});

test("a needs-attention payload says where it can be answered", () => {
  const phone = buildAttentionPayload({
    runId: "run-1",
    task: "Deploy the site",
    requestId: "approval:abc",
    canApproveFromPhone: true,
  });
  assert.equal(phone.aps.alert.title, "Hermes needs you");
  assert.match(phone.aps.alert.body, /approve or deny it/);
  assert.equal(phone.aps["interruption-level"], "time-sensitive");
  assert.equal(phone.kind, "needs_attention");
  assert.equal(phone.request_id, "approval:abc");
  assert.equal(phone.can_approve_from_phone, true);

  const mac = buildAttentionPayload({ runId: "run-1", task: "Deploy", requestId: "interaction:7" });
  assert.match(mac.aps.alert.body, /on the Mac/);
  assert.equal(mac.can_approve_from_phone, false);
});

test("only a device-origin run pushes, and only to the device that dispatched it", async () => {
  const h = makeNotifier();
  const desktop = await h.notifier.notifyRunTerminal({
    runId: "run-desktop",
    task: "Local task",
    status: "completed",
    origin: "desktop",
  });
  assert.deepEqual(desktop, { skipped: "not_device_origin" });
  assert.equal(h.pending.length, 0, "a desktop run never even schedules a push");

  const promise = h.notifier.notifyRunTerminal({
    runId: "run-phone",
    task: "Phone task",
    status: "failed",
    origin: "device:abc123",
  });
  assert.equal(h.sent.length, 0, "nothing is sent before the grace window elapses");
  await h.flush();
  await promise;
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].environment, "sandbox");
  assert.equal(h.sent[0].collapseId, "run-phone");
  assert.equal(h.sent[0].payload.aps.alert.title, "Hermes couldn't finish");
  assert.equal(deviceIdFromOrigin("device:abc123"), "abc123");
  assert.equal(deviceIdFromOrigin("desktop"), "");
});

test("a phone that already announced the result inside the grace window wins", async () => {
  let announced = false;
  const h = makeNotifier({ isAnnounced: () => announced });
  const promise = h.notifier.notifyRunTerminal({
    runId: "run-1",
    task: "Task",
    status: "completed",
    origin: "device:abc",
  });
  // The ack lands while the push is still waiting out the grace delay.
  announced = true;
  await h.flush();
  assert.deepEqual(await promise, { skipped: "announced" });
  assert.equal(h.sent.length, 0);
  assert.ok(COMPLETION_PUSH_GRACE_MS >= 3000, "the grace window must be long enough to lose the race");
});

test("a needs-attention push is sent once per distinct pending request", async () => {
  const h = makeNotifier();
  const args = {
    runId: "run-1",
    task: "Task",
    origin: "device:abc",
    requestId: "approval:deadbeef",
    canApproveFromPhone: true,
  };
  await h.notifier.notifyNeedsAttention(args);
  await h.notifier.notifyNeedsAttention(args);
  await h.notifier.notifyNeedsAttention(args);
  assert.equal(h.sent.length, 1, "a poll that re-reports the same request must not re-push");

  // A different request on the same run is a different notification.
  await h.notifier.notifyNeedsAttention({ ...args, requestId: "interaction:2" });
  assert.equal(h.sent.length, 2);

  // Once it is resolved, a later identical request may push again.
  h.notifier.clearAttention("run-1");
  await h.notifier.notifyNeedsAttention(args);
  assert.equal(h.sent.length, 3);

  const desktop = await h.notifier.notifyNeedsAttention({ ...args, origin: "desktop" });
  assert.deepEqual(desktop, { skipped: "not_device_origin" });
});

test("push does nothing, loudly once, when it is not configured", async () => {
  const h = makeNotifier({ getClient: () => null });
  const promise = h.notifier.notifyRunTerminal({
    runId: "run-1",
    task: "Task",
    status: "completed",
    origin: "device:abc",
  });
  await h.flush();
  assert.deepEqual(await promise, { skipped: "not_configured" });
  await h.notifier.notifyNeedsAttention({
    runId: "run-1",
    task: "Task",
    origin: "device:abc",
    requestId: "x",
  });
  assert.equal(h.sent.length, 0);
  assert.equal(h.logs.filter((line) => line.message.includes("not configured")).length, 1);
});

test("a device with no registered token is skipped", async () => {
  const h = makeNotifier({ getTarget: () => null });
  const promise = h.notifier.notifyRunTerminal({
    runId: "run-1",
    task: "Task",
    status: "completed",
    origin: "device:abc",
  });
  await h.flush();
  assert.deepEqual(await promise, { skipped: "no_token" });
});

test("a token Apple reports as unregistered is dropped", async () => {
  const h = makeNotifier({
    result: { ok: false, status: 410, reason: "Unregistered", unregistered: true },
  });
  const promise = h.notifier.notifyRunTerminal({
    runId: "run-1",
    task: "Task",
    status: "completed",
    origin: "device:abc",
  });
  await h.flush();
  await promise;
  assert.deepEqual(h.dropped, ["abc"]);
});

test("pending approvals are derived from real run state only", () => {
  assert.equal(pendingApprovalFor(null), null);
  assert.equal(pendingApprovalFor({ approval: null, interaction: null }), null);

  const approval = { command: "rm -rf build", reason: "Deletes files", requestedAt: 5 };
  const pending = pendingApprovalFor({ approval });
  assert.equal(pending.can_approve_from_phone, true);
  assert.match(pending.summary, /rm -rf build/);
  assert.equal(pending.request_id, approvalRequestId(approval));
  // The id is content-derived, so the same request seen twice is one request.
  assert.equal(approvalRequestId({ ...approval, requestedAt: 99 }), pending.request_id);
  assert.notEqual(approvalRequestId({ command: "ls", reason: "" }), pending.request_id);

  const interaction = pendingApprovalFor({
    interaction: { id: "i-1", type: "question", question: "Which branch?" },
  });
  assert.deepEqual(interaction, {
    request_id: "interaction:i-1",
    summary: "Which branch?",
    can_approve_from_phone: false,
  });

  const secret = pendingApprovalFor({
    interaction: { id: "i-2", type: "password", question: "sudo password for nate", secret: true },
  });
  assert.equal(secret.can_approve_from_phone, false);
  assert.equal(secret.summary.includes("sudo password for nate"), false, "a secret prompt is never echoed");
});

test("a failed run's push says why, and carries no result text or secret", () => {
  const payload = buildCompletionPayload({
    runId: "run-9",
    task: "Summarise yesterday's commits",
    status: "failed",
    failure: {
      code: "session_in_use",
      message: "That chat is open in Hermes Desktop. Close it there, or I can start a new chat.",
      recovery: "start_new_chat",
      detail: "This chat is open in another Hermes window/terminal.",
    },
  });
  assert.equal(payload.aps.alert.title, "Hermes couldn't finish");
  // The reason, not the task title: a title tells the user nothing to act on.
  assert.equal(
    payload.aps.alert.body,
    "That chat is open in Hermes Desktop. Close it there, or I can start a new chat.",
  );
  assert.equal(payload.failure_code, "session_in_use");
  assert.equal(payload.recovery, "start_new_chat");
  // `detail` is for a debugging disclosure on the phone, never a lock screen.
  assert.doesNotMatch(JSON.stringify(payload), /window\/terminal/);
});

test("a completion with no failure is unchanged", () => {
  const payload = buildCompletionPayload({ runId: "run-1", task: "Tidy the inbox", status: "completed" });
  assert.equal(payload.aps.alert.body, "Tidy the inbox");
  assert.equal(payload.failure_code, undefined);
  assert.equal(payload.recovery, undefined);
});
