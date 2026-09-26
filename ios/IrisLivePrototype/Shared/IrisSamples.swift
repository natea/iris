//
//  IrisSamples.swift
//  Shared by the app and the IrisWidgets extension.
//
//  Fixed, obviously-fake states. Three callers need them and all three are
//  legitimate: the widget gallery's placeholder (which the system redacts
//  anyway, but which must have a plausible shape), SwiftUI previews, and the
//  DEBUG test that renders every presentation to a PNG so a person can look at
//  it before a phone is involved.
//
//  They are NOT compiled out of release, because the widget placeholder is a
//  release path. Nothing here is ever shown as if it were real: the
//  placeholder is redacted by WidgetKit, and the renderer runs only in tests.
//

import Foundation

extension IrisWidgetSnapshot {

    enum Sample {
        case active
        case waiting
        case idle
        /// Real data, too old to stand behind.
        case stale
    }

    static func preview(_ sample: Sample, now: Date = Date()) -> IrisWidgetSnapshot {
        let generated: Double
        switch sample {
        case .stale: generated = now.timeIntervalSince1970 - (IrisWidgetSnapshot.staleAfter + 600)
        default: generated = now.timeIntervalSince1970 - 20
        }
        switch sample {
        case .idle:
            return IrisWidgetSnapshot(
                paired: true, activeCount: 0, waitingCount: 0, finishedTodayCount: 4,
                activeRun: nil,
                lastFinished: .init(runId: "run-7c10", title: "Book a table",
                                    status: "completed",
                                    finishedAt: now.timeIntervalSince1970 - 2_400),
                hermesReachable: true, generatedAt: generated,
                fetchedAt: now.timeIntervalSince1970, macName: "studio")
        case .waiting:
            return IrisWidgetSnapshot(
                paired: true, activeCount: 2, waitingCount: 1, finishedTodayCount: 3,
                activeRun: .init(runId: "run-9a02", title: "Deploy the site",
                                 headline: "Running code", needsAttention: true),
                lastFinished: .init(runId: "run-7c10", title: "Book a table",
                                    status: "failed",
                                    finishedAt: now.timeIntervalSince1970 - 900),
                hermesReachable: true, generatedAt: generated,
                fetchedAt: now.timeIntervalSince1970, macName: "studio")
        case .active, .stale:
            return IrisWidgetSnapshot(
                paired: true, activeCount: 2, waitingCount: 0, finishedTodayCount: 4,
                activeRun: .init(runId: "run-8f21", title: "Summarize the quarterly numbers",
                                 headline: "Running code", needsAttention: false),
                lastFinished: .init(runId: "run-7c10", title: "Book a table",
                                    status: "completed",
                                    finishedAt: now.timeIntervalSince1970 - 1_800),
                hermesReachable: true, generatedAt: generated,
                fetchedAt: now.timeIntervalSince1970, macName: "studio")
        }
    }
}

extension IrisRunActivityAttributes.ContentState {

    enum Sample {
        case running
        case needsAttention
        case finishedFailed
        case finishedDone
        /// Running, but the step history is not available — the case that
        /// must never render as "0 steps".
        case stepsUnknown
    }

    static func preview(_ sample: Sample, now: Date = Date()) -> Self {
        let started = now.timeIntervalSince1970 - 320
        let updated = now.timeIntervalSince1970 - 12
        switch sample {
        case .running:
            return .init(
                status: "running", headline: "Running code",
                title: "Summarize the quarterly numbers", detail: "python analyze.py",
                stepCount: 7, stepsKnown: true, activeRunCount: 2,
                needsAttention: false, attentionSummary: "",
                runs: [
                    .init(id: "run-8f21", title: "Summarize the quarterly numbers",
                          status: "running", headline: "Running code"),
                    .init(id: "run-9a02", title: "Deploy the site",
                          status: "running", headline: "Searching example.com"),
                ],
                startedAt: started, updatedAt: updated)
        case .needsAttention:
            return .init(
                status: "waiting", headline: "Running code",
                title: "Deploy the site", detail: "rm -rf build",
                stepCount: 12, stepsKnown: true, activeRunCount: 2,
                needsAttention: true, attentionSummary: "Hermes wants to run: rm -rf build",
                runs: [
                    .init(id: "run-9a02", title: "Deploy the site",
                          status: "waiting", headline: "Running code"),
                    .init(id: "run-8f21", title: "Summarize the quarterly numbers",
                          status: "running", headline: "Searching example.com"),
                ],
                startedAt: started, updatedAt: updated)
        case .finishedFailed:
            return .init(
                status: "failed", headline: "", title: "Deploy the site", detail: "",
                stepCount: 0, stepsKnown: false, activeRunCount: 0,
                needsAttention: false, attentionSummary: "", runs: [],
                startedAt: started, updatedAt: updated)
        case .finishedDone:
            return .init(
                status: "done", headline: "", title: "Summarize the quarterly numbers",
                detail: "", stepCount: 0, stepsKnown: false, activeRunCount: 0,
                needsAttention: false, attentionSummary: "", runs: [],
                startedAt: started, updatedAt: updated)
        case .stepsUnknown:
            return .init(
                status: "running", headline: "",
                title: "Restore the nightly backup", detail: "",
                stepCount: 0, stepsKnown: false, activeRunCount: 1,
                needsAttention: false, attentionSummary: "",
                runs: [.init(id: "run-4d77", title: "Restore the nightly backup",
                             status: "running", headline: "")],
                startedAt: started, updatedAt: now.timeIntervalSince1970 - 400)
        }
    }
}
