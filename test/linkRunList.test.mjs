import test from "node:test";
import assert from "node:assert/strict";
import {
  LINK_EARLIER_RUN_LIMIT,
  LINK_TASK_LIMIT,
  earlierRuns,
  isRestoredRunId,
  mergeSessionRuns,
  orderTaskList,
  restoredTaskSummary,
  sessionOfRestoredRunId,
} from "../electron/linkRunList.mjs";
import { snapshotFromHistory } from "../electron/runSteps.mjs";

const PINNED = "20260920_200302_c7caaf";
const OLD = "20260916_174926_797a3b";

function registryEntry(overrides = {}) {
  return {
    runId: "iris_1",
    task: "Summarise yesterday's commits",
    sessionId: PINNED,
    status: "completed",
    origin: "desktop",
    createdAt: 1_000,
    updatedAt: 2_000,
    announcedAt: 0,
    ...overrides,
  };
}

function transcriptRun(overrides = {}) {
  return {
    id: `history:${PINNED}:msg_1`,
    sessionId: PINNED,
    task: "Draft the release notes",
    status: "completed",
    output: "Done.",
    updatedAt: 1_500,
    steps: [],
    ...overrides,
  };
}

test("the merged list is the registry plus the transcript runs it does not already hold", () => {
  const registry = [registryEntry(), registryEntry({ runId: "iris_2", task: "Tidy the inbox" })];
  const restored = [
    transcriptRun(),
    transcriptRun({ id: `history:${PINNED}:msg_9`, task: "Check the build" }),
  ];
  const merged = mergeSessionRuns(registry, restored);
  assert.equal(merged.registry.length, 2);
  assert.deepEqual(merged.restored.map((run) => run.task), [
    "Draft the release notes",
    "Check the build",
  ]);
});

test("a transcript run whose brief a registry run already holds is dropped", () => {
  // The same rule fetchHermesHistory() uses: one brief is one run, whichever
  // list it came from, and case and surrounding space do not make it two.
  const registry = [registryEntry({ task: "Draft the release notes" })];
  const restored = [
    transcriptRun({ task: "  DRAFT THE Release Notes  " }),
    transcriptRun({ id: `history:${PINNED}:msg_9`, task: "Something else" }),
  ];
  const merged = mergeSessionRuns(registry, restored);
  assert.deepEqual(merged.restored.map((run) => run.task), ["Something else"]);
});

test("a transcript run whose id a registry run already holds is dropped", () => {
  const id = `history:${PINNED}:msg_1`;
  const merged = mergeSessionRuns(
    [registryEntry({ runId: id, task: "Different brief entirely" })],
    [transcriptRun({ id })],
  );
  assert.deepEqual(merged.restored, []);
});

test("an empty or missing transcript leaves the registry untouched", () => {
  // A transcript read that failed degrades to registry-only, never to an error.
  const registry = [registryEntry()];
  for (const restored of [[], null, undefined]) {
    const merged = mergeSessionRuns(registry, restored);
    assert.equal(merged.registry.length, 1);
    assert.deepEqual(merged.restored, []);
  }
});

test("the list is newest first and capped", () => {
  const tasks = Array.from({ length: 60 }, (_, index) => ({
    run_id: `r${index}`,
    updated_at: index,
  }));
  const ordered = orderTaskList(tasks);
  assert.equal(ordered.length, LINK_TASK_LIMIT);
  assert.equal(ordered[0].run_id, "r59");
  assert.equal(ordered[1].run_id, "r58");
  // A run with no timestamp sorts last rather than being dropped.
  const mixed = orderTaskList([{ run_id: "a" }, { run_id: "b", updated_at: 5 }]);
  assert.deepEqual(mixed.map((task) => task.run_id), ["b", "a"]);
});

test("a restored run is read-only history with milliseconds and no output", () => {
  const run = transcriptRun({
    updatedAt: 1_789_947_620_033,
    steps: [
      { tool: "read_file", preview: "CHANGELOG.md", ts: 1_789_947_600_000 },
      { tool: "Terminal", preview: "git log --oneline", ts: 1_789_947_610_000 },
    ],
  });
  const summary = restoredTaskSummary(run, snapshotFromHistory(run.steps));
  assert.equal(summary.origin, "history");
  assert.equal(summary.restored, true);
  assert.equal(summary.read_only, true);
  assert.equal(summary.session_id, PINNED);
  assert.equal(summary.status, "completed");
  // Epoch MILLISECONDS, like every other Link timestamp.
  assert.equal(summary.updated_at, 1_789_947_620_033);
  assert.equal(summary.step_count, 2);
  assert.equal(summary.pending_approval, null);
  assert.equal(summary.failure, null);
  // List-sized: no step array, no output text.
  assert.equal(summary.steps, undefined);
  assert.equal(summary.output, undefined);
  assert.ok(!JSON.stringify(summary).includes("Done."));
});

test("restored run ids are recognised and carry their session", () => {
  assert.equal(isRestoredRunId(`history:${PINNED}:msg_1`), true);
  assert.equal(isRestoredRunId("iris_9c1a"), false);
  assert.equal(isRestoredRunId(""), false);
  assert.equal(sessionOfRestoredRunId(`history:${PINNED}:msg_1`), PINNED);
  assert.equal(sessionOfRestoredRunId("iris_9c1a"), "");
  assert.equal(sessionOfRestoredRunId("history:"), "");
});

test("earlier chats are the OTHER sessions' runs, read-only and capped", () => {
  const summarize = (entry) => ({
    run_id: entry.runId,
    task: entry.task,
    status: entry.status,
    origin: entry.origin,
    updated_at: entry.updatedAt,
    read_only: false,
    restored: false,
  });
  const entries = [
    registryEntry({ runId: "iris_now", sessionId: PINNED }),
    registryEntry({ runId: "iris_old_1", sessionId: OLD }),
    registryEntry({ runId: "iris_old_2", sessionId: OLD }),
    registryEntry({ runId: "iris_nosession", sessionId: "" }),
  ];
  const earlier = earlierRuns(entries, PINNED, summarize);
  assert.deepEqual(earlier.map((run) => run.run_id), ["iris_old_1", "iris_old_2"]);
  for (const run of earlier) {
    assert.equal(run.session_id, OLD);
    // Read-only, but not "restored": these are real registry runs, just from
    // a chat that is no longer pinned.
    assert.equal(run.read_only, true);
    assert.equal(run.restored, false);
  }

  const many = Array.from({ length: 150 }, (_, index) =>
    registryEntry({ runId: `old_${index}`, sessionId: OLD }),
  );
  assert.equal(earlierRuns(many, PINNED, summarize).length, LINK_EARLIER_RUN_LIMIT);
});

test("with no other sessions there are no earlier chats", () => {
  const earlier = earlierRuns([registryEntry()], PINNED, (entry) => ({ run_id: entry.runId }));
  assert.deepEqual(earlier, []);
});
