//
//  RunProgress.swift
//  IrisLivePrototype
//
//  The step list a run detail screen shows, kept as a plain value so the
//  merge rules of LINK_API.md §12.3 can be tested without a server, a view or
//  a clock.
//
//  Everything here is deliberately incapable of inventing progress. The store
//  holds what the Mac sent and nothing else; when the Mac says it cannot
//  vouch for the list, the store says so too rather than quietly showing a
//  shorter one.
//

import Foundation

// MARK: - Timestamps

enum IrisEpoch {
    /// The desktop reports JavaScript timestamps (milliseconds). Read as
    /// seconds they land tens of thousands of years in the future — a bug this
    /// app shipped once already.
    static func seconds(_ stamp: Double) -> Double {
        stamp > 100_000_000_000 ? stamp / 1000 : stamp
    }
}

// MARK: - Formatting

enum RunStepFormat {

    /// The desktop prints `1.2s`. Longer steps are unreadable that way, so
    /// they round to whole seconds and then to minutes: `1.2s`, `48s`,
    /// `2m 05s`.
    static func duration(seconds: Double) -> String {
        let value = max(0, seconds)
        if value < 10 { return String(format: "%.1fs", value) }
        if value < 60 { return "\(Int(value.rounded()))s" }
        let total = Int(value.rounded())
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }

    /// VoiceOver reads "12 seconds", not "12s".
    static func spokenDuration(seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total) second\(total == 1 ? "" : "s")" }
        let minutes = total / 60
        let rest = total % 60
        let head = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        return rest == 0 ? head : "\(head) \(rest) second\(rest == 1 ? "" : "s")"
    }
}

// MARK: - Store

/// Accumulates `steps_since` deltas into one ordered list.
struct RunProgressStore: Equatable {

    private(set) var steps: [RunStep] = []
    /// `steps_cursor` from the last good response, to send next (§12.3).
    private(set) var cursor: Int?
    private(set) var headline = ""
    /// The run's whole-run step count, as reported. Not `steps.count`: a
    /// delta response describes the whole run in its counts.
    private(set) var stepCount = 0
    private(set) var stepsComplete = false
    private(set) var stepsTruncated = false
    private(set) var hasLoaded = false

    /// Set when the server's cursor moved backwards (Iris restarted, or the
    /// run's steps were evicted). The next poll must be a full fetch.
    private(set) var needsFullResync = false

    /// What to pass as `steps_since`. `nil` means "fetch everything" — first
    /// load, after an error, after a resync, and on resume from background.
    var nextStepsSince: Int? {
        guard hasLoaded, !needsFullResync, let cursor else { return nil }
        return cursor
    }

    /// §12.6: after a failed poll or a return from the background, resynchronize
    /// with one full `GET` rather than trusting a cursor we may have outrun.
    mutating func requireFullResync() {
        needsFullResync = true
    }

    mutating func apply(_ detail: LinkTaskDetail) {
        // A cursor that moved backwards means the run's counter was reset:
        // whatever we hold may belong to a previous life of this run.
        let rewound = detail.isDelta && cursor.map { detail.stepsCursor < $0 } == true

        if !detail.isDelta || rewound {
            steps = detail.steps.sorted { $0.index < $1.index }
        } else {
            var byId: [String: RunStep] = [:]
            var order: [String] = []
            for step in steps where byId[step.id] == nil {
                byId[step.id] = step
                order.append(step.id)
            }
            for step in detail.steps {
                // "A step that merely finished comes back again, with its new
                // status and duration_ms. Merge by id." (§12.3)
                if byId[step.id] == nil { order.append(step.id) }
                byId[step.id] = step
            }
            steps = order.compactMap { byId[$0] }.sorted { $0.index < $1.index }
        }

        headline = detail.headline
        stepCount = detail.stepCount
        stepsComplete = detail.stepsComplete
        stepsTruncated = detail.stepsTruncated
        cursor = detail.stepsCursor
        hasLoaded = true
        // A rewind is repaired by the full list we just took, so the next poll
        // can go back to being a delta.
        needsFullResync = false
    }

    /// True when the Mac has told us the list is not the whole story.
    var isKnownIncomplete: Bool { hasLoaded && !stepsComplete }

    /// Plain language for that, in §12.4's own wording where it gives one.
    /// `nil` when there is nothing to admit.
    func incompleteNotice(isActive: Bool) -> String? {
        guard hasLoaded else { return nil }
        if stepsTruncated {
            return "Older steps were dropped on the Mac — this is the most recent \(steps.count)."
        }
        guard !stepsComplete else { return nil }
        if steps.isEmpty {
            return isActive
                ? "Iris doesn't have the step history for this run — it's still working."
                : "Iris doesn't have the step history for this run."
        }
        return "This may not be the full step history — Iris can't vouch for what came before."
    }

    /// The collapsible header the desktop shows: "7 steps".
    var stepCountText: String {
        let count = max(stepCount, steps.count)
        return "\(count) step\(count == 1 ? "" : "s")"
    }
}
