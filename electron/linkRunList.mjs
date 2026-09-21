// What the phone's run list is allowed to contain, and in what order.
//
// The desktop's Work Stream shows the run registry MERGED with runs rebuilt
// from the pinned session's Hermes transcript. `GET /link/tasks` showed the
// registry alone, so the moment the pinned session changed the phone showed
// one run where the Mac showed thirteen — the registry held eighty runs under
// the previous chat and one under the new one.
//
// This module is the merge rule, pure and testable: same de-duplication and
// same ordering as main.mjs' `fetchHermesHistory()`. It does no I/O and knows
// nothing about Electron; main.mjs hands it the two lists.
//
// LINK_API.md §16.

export const LINK_TASK_LIMIT = 50;
export const LINK_EARLIER_RUN_LIMIT = 100;

/** True for an id rebuilt from a transcript rather than issued by Hermes. */
export function isRestoredRunId(runId) {
  return String(runId || "").startsWith("history:");
}

/** The session a `history:<session>:<message>` id belongs to, or "". */
export function sessionOfRestoredRunId(runId) {
  if (!isRestoredRunId(runId)) return "";
  return String(runId).split(":")[1] || "";
}

function taskKey(value) {
  return String(value || "").toLowerCase().trim();
}

/**
 * The desktop's merge rule, exactly.
 *
 * Registry runs for the pinned session first, then transcript runs whose id is
 * not already present AND whose task text does not match a registry run's —
 * the same pair of checks `fetchHermesHistory()` makes, because the same brief
 * appearing in both lists is one run, not two.
 *
 * @param registry   Registry entries for the pinned session (already filtered).
 * @param restored   Transcript-rebuilt runs for the same session.
 * @returns {{registry: Array, restored: Array}} — `restored` is what survived.
 */
export function mergeSessionRuns(registry = [], restored = []) {
  const live = Array.isArray(registry) ? registry : [];
  const seenIds = new Set(live.map((entry) => entry.runId));
  const seenTasks = new Set(live.map((entry) => taskKey(entry.task)));
  const kept = (Array.isArray(restored) ? restored : []).filter(
    (run) => !seenIds.has(run.id) && !seenTasks.has(taskKey(run.task)),
  );
  return { registry: live, restored: kept };
}

/**
 * Newest first, capped. `updated_at` is epoch MILLISECONDS on both sides — a
 * restored run read as seconds would sort to 1970 and sink out of view.
 */
export function orderTaskList(tasks, limit = LINK_TASK_LIMIT) {
  return [...(Array.isArray(tasks) ? tasks : [])]
    .sort((a, b) => (Number(b.updated_at) || 0) - (Number(a.updated_at) || 0))
    .slice(0, limit);
}

/**
 * The list-sized shape for a transcript-restored run: no step array, no output
 * text. `origin: "history"` is a new, additive value in the §4 vocabulary —
 * nothing here dispatched it, so claiming "from the Mac" would be untrue.
 *
 * @param progress  The result of `snapshotFromHistory(run.steps)`, injected so
 *                  this module stays free of runSteps' own dependencies.
 */
export function restoredTaskSummary(run, progress = {}) {
  return {
    run_id: run.id,
    task: String(run.task || ""),
    status: String(run.status || "completed"),
    origin: "history",
    session_id: run.sessionId || "",
    restored: true,
    // Nothing on a restored run can be stopped, approved, announced or
    // retried: it is a reconstruction of a finished conversation.
    read_only: true,
    created_at: Number(run.updatedAt) || 0,
    updated_at: Number(run.updatedAt) || 0,
    announced_at: 0,
    pending_approval: null,
    failure: null,
    headline: progress.headline || "",
    step_count: Number(progress.step_count) || 0,
  };
}

/**
 * Registry runs from chats that are no longer pinned — the work that becomes
 * invisible in BOTH apps the moment the pinned session changes. Read-only,
 * newest first, capped, each carrying its `session_id` so the phone can group
 * them under "Earlier chats".
 *
 * @param summarize  (entry) => the same list shape a pinned run gets.
 */
export function earlierRuns(entries, currentSessionId, summarize, limit = LINK_EARLIER_RUN_LIMIT) {
  const current = String(currentSessionId || "");
  return (Array.isArray(entries) ? entries : [])
    .filter((entry) => entry.sessionId && entry.sessionId !== current)
    .slice(0, limit)
    .map((entry) => ({
      ...summarize(entry),
      session_id: entry.sessionId,
      restored: false,
      read_only: true,
    }));
}
