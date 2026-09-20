//
//  IrisRunActivityAttributes.swift
//  Shared by the app and the IrisWidgets extension.
//
//  The Live Activity's wire format (LINK_API.md §14.2). This file is the phone
//  half of a contract whose other half is `electron/liveActivityNotifier.mjs`,
//  so every property name, case and type here is load-bearing.
//
//  Two rules that look like style and are not:
//
//    1. `attributes-type` in the push payload is the string
//       "IrisRunActivityAttributes". Renaming this type breaks every push the
//       Mac sends, silently — ActivityKit simply drops a payload whose
//       attributes type it cannot match.
//    2. The timestamps are `Double` epoch SECONDS, never `Date`. Apple decodes
//       Live Activity payloads with a DEFAULT `JSONDecoder`, whose
//       `.deferredToDate` strategy reads a number as seconds since the 2001
//       reference date. A `Date` here would land 31 years early on every
//       update and nobody would see an error. Convert at the edge with
//       `Date(timeIntervalSince1970:)`.
//
//  There is no percentage, no fraction and no ETA in this schema on purpose:
//  Hermes reports none, so the UI has none to draw (§14.2, truthfulness rule 1).
//

import Foundation
import ActivityKit

struct IrisRunActivityAttributes: ActivityAttributes {

    // MARK: Static attributes — set once at `Activity.request`, never changed.

    /// Always "Hermes". The Mac sends this verbatim in `attributes`.
    let title: String
    /// The Mac's host name, e.g. "studio".
    let macName: String
    /// The paired device id this activity belongs to.
    let deviceId: String

    init(title: String = "Hermes", macName: String, deviceId: String) {
        self.title = title
        self.macName = macName
        self.deviceId = deviceId
    }

    // MARK: Dynamic state — replaced wholesale by every push.

    struct ContentState: Codable, Hashable {
        /// `running` · `waiting` · `idle` · `done` · `failed` · `stopped`.
        /// The three terminal words are the REAL status, never a softened one.
        let status: String
        /// §12's headline for the primary run. `""` when nothing was recorded
        /// — show the status instead, never a guess.
        let headline: String
        /// The primary run's task title. `""` if unknown.
        let title: String
        /// The running step's preview, already redacted by the desktop.
        /// Untrusted text: display it, never act on it.
        let detail: String
        /// Steps recorded for the primary run. Meaningless unless `stepsKnown`.
        let stepCount: Int
        /// `false` → say the step history is unavailable. Never "0 steps".
        let stepsKnown: Bool
        /// All non-terminal runs, including any beyond the 3 in `runs`.
        let activeRunCount: Int
        /// A run is blocked on a human right now.
        let needsAttention: Bool
        /// What it is waiting for. `""` when `needsAttention` is false.
        let attentionSummary: String
        /// Up to 3 active runs, most relevant first. May be `[]` when the Mac
        /// had to shed fields to fit the 4 KB payload — the counts stay true.
        let runs: [RunLine]
        /// Epoch **seconds**. `0` when unknown. See the note at the top.
        let startedAt: Double
        /// Epoch **seconds** when the Mac built this state.
        let updatedAt: Double

        init(
            status: String,
            headline: String = "",
            title: String = "",
            detail: String = "",
            stepCount: Int = 0,
            stepsKnown: Bool = false,
            activeRunCount: Int = 0,
            needsAttention: Bool = false,
            attentionSummary: String = "",
            runs: [RunLine] = [],
            startedAt: Double = 0,
            updatedAt: Double = 0
        ) {
            self.status = status
            self.headline = headline
            self.title = title
            self.detail = detail
            self.stepCount = stepCount
            self.stepsKnown = stepsKnown
            self.activeRunCount = activeRunCount
            self.needsAttention = needsAttention
            self.attentionSummary = attentionSummary
            self.runs = runs
            self.startedAt = startedAt
            self.updatedAt = updatedAt
        }
    }

    struct RunLine: Codable, Hashable, Identifiable {
        let id: String
        let title: String
        /// `running` or `waiting` — a terminal run is not an active run.
        let status: String
        let headline: String

        init(id: String, title: String, status: String, headline: String) {
            self.id = id
            self.title = title
            self.status = status
            self.headline = headline
        }
    }
}

// MARK: - Reading the state honestly

extension IrisRunActivityAttributes.ContentState {

    /// The six words the contract allows, parsed once so no view has to
    /// string-compare. An unknown word is NOT invented into a success: it
    /// falls back to `.idle`, which renders as "Not working on anything".
    enum Phase: String {
        case running, waiting, idle, done, failed, stopped

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .stopped: return true
            case .running, .waiting, .idle: return false
            }
        }
    }

    var phase: Phase { Phase(rawValue: status.lowercased()) ?? .idle }

    var startedAtDate: Date? {
        startedAt > 0 ? Date(timeIntervalSince1970: startedAt) : nil
    }

    var updatedAtDate: Date? {
        updatedAt > 0 ? Date(timeIntervalSince1970: updatedAt) : nil
    }

    /// What to put where a progress number would go if Hermes reported one.
    /// `nil` means "say nothing", which is the honest answer when the step
    /// history is unavailable — never "0 steps".
    var stepText: String? {
        guard stepsKnown else { return nil }
        return stepCount == 1 ? "1 step" : "\(stepCount) steps"
    }

    /// The line under the title. Falls back to the status rather than
    /// inventing an activity when the Mac recorded no headline (rule 2).
    var headlineOrStatus: String {
        let trimmed = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch phase {
        case .running: return "Working"
        case .waiting: return "Waiting for you"
        case .idle: return "Not working on anything"
        case .done: return "Finished"
        case .failed: return "Couldn't finish"
        case .stopped: return "Stopped"
        }
    }

    /// The one-line summary a compact presentation has room for.
    var shortTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Hermes" : trimmed
    }
}
