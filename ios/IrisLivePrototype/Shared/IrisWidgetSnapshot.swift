//
//  IrisWidgetSnapshot.swift
//  Shared by the app and the IrisWidgets extension.
//
//  What the home-screen widget is allowed to know, and how it gets there.
//
//  The widget extension is a separate process with its own Keychain access
//  group, so it cannot read the pairing credential, and it must not: a
//  credential copied into a shared container is a credential in two places.
//  So the APP fetches `GET /link/summary` (§14.6) and writes this small,
//  non-secret snapshot into the App Group container; the extension only ever
//  reads it. Nothing here is a secret — counts, two titles, a flag — and there
//  is deliberately no output, no step list and no result text.
//
//  The other half of the deal is honesty: a widget is refreshed on iOS's
//  budget, not Hermes's. `generatedAt` travels with the data so every
//  presentation can say how old it is (§14.6 rule 3). A widget that hides its
//  age is lying about being live.
//

import Foundation

struct IrisWidgetSnapshot: Codable, Equatable {

    struct ActiveRun: Codable, Equatable {
        let runId: String
        let title: String
        /// §12's headline. `""` when the Mac recorded nothing.
        let headline: String
        let needsAttention: Bool
    }

    struct FinishedRun: Codable, Equatable {
        let runId: String
        let title: String
        /// The REAL terminal status from the desktop: `completed`, `failed`,
        /// `error`, `cancelled`, `canceled`.
        let status: String
        /// Epoch **seconds** (the route sends milliseconds; converted on the
        /// way in, once, here rather than in four views).
        let finishedAt: Double
    }

    /// False when this phone is not paired at all — the widget then says so
    /// instead of drawing zeroes that look like "Hermes is idle".
    let paired: Bool
    let activeCount: Int
    let waitingCount: Int
    let finishedTodayCount: Int
    let activeRun: ActiveRun?
    let lastFinished: FinishedRun?
    /// The Mac's own fresh probe of Hermes, not a guess by the phone.
    let hermesReachable: Bool
    /// Epoch **seconds** when the MAC built the summary.
    let generatedAt: Double
    /// Epoch **seconds** when this phone last managed to fetch it. Usually the
    /// same moment; different when the phone is holding an older answer.
    let fetchedAt: Double
    let macName: String

    init(
        paired: Bool,
        activeCount: Int = 0,
        waitingCount: Int = 0,
        finishedTodayCount: Int = 0,
        activeRun: ActiveRun? = nil,
        lastFinished: FinishedRun? = nil,
        hermesReachable: Bool = false,
        generatedAt: Double = 0,
        fetchedAt: Double = 0,
        macName: String = ""
    ) {
        self.paired = paired
        self.activeCount = activeCount
        self.waitingCount = waitingCount
        self.finishedTodayCount = finishedTodayCount
        self.activeRun = activeRun
        self.lastFinished = lastFinished
        self.hermesReachable = hermesReachable
        self.generatedAt = generatedAt
        self.fetchedAt = fetchedAt
        self.macName = macName
    }

    /// The snapshot shown before anything has ever been fetched.
    static let unpaired = IrisWidgetSnapshot(paired: false)

    var generatedAtDate: Date? { generatedAt > 0 ? Date(timeIntervalSince1970: generatedAt) : nil }

    // MARK: Age

    /// How much of the snapshot the widget is allowed to assert.
    ///
    /// The thresholds are a judgement, and a conservative one: Hermes can
    /// change what it is doing several times a minute, so three minutes is
    /// already long enough that "Running code" should carry an "as of". After
    /// 45 minutes iOS has plainly not been running the timeline and the only
    /// true thing left to say is "open Iris".
    enum Freshness: Equatable {
        /// Recent enough to show as-is.
        case current
        /// Show the data, with its age next to it.
        case aging(TimeInterval)
        /// Too old to stand behind: show the age and ask for the app.
        case stale(TimeInterval)
    }

    static let agingAfter: TimeInterval = 3 * 60
    static let staleAfter: TimeInterval = 45 * 60

    func freshness(now: Date = Date()) -> Freshness {
        guard let generated = generatedAtDate else { return .stale(.infinity) }
        let age = max(0, now.timeIntervalSince(generated))
        if age >= Self.staleAfter { return .stale(age) }
        if age >= Self.agingAfter { return .aging(age) }
        return .current
    }

    /// The line the widget prints under its content. `nil` while current —
    /// there is nothing worth saying about data that is three minutes old.
    func ageLine(now: Date = Date()) -> String? {
        switch freshness(now: now) {
        case .current: return nil
        case .aging(let age): return "as of \(IrisRelativeTime.duration(age)) ago"
        case .stale: return "Open Iris to refresh"
        }
    }

    /// True when the widget must stop drawing a live-looking state.
    func isStale(now: Date = Date()) -> Bool {
        if case .stale = freshness(now: now) { return true }
        return false
    }

    // MARK: Phase

    /// The same vocabulary the Live Activity uses, derived from counts only.
    var phase: IrisRunActivityAttributes.ContentState.Phase {
        if waitingCount > 0 { return .waiting }
        if activeCount > 0 { return .running }
        return .idle
    }

    /// The real word for a finished run's status, mapped exactly as §14.2
    /// requires: `failed` is never softened into "finished".
    static func terminalPhase(_ status: String) -> IrisRunActivityAttributes.ContentState.Phase {
        switch status.lowercased() {
        case "completed": return .done
        case "cancelled", "canceled": return .stopped
        case "failed", "error": return .failed
        default: return .idle
        }
    }
}

// MARK: - The App Group container

/// Reads and writes the one file the app and the extension share.
///
/// Both sides construct this with the same group id. If the container is not
/// available — the capability is missing from a provisioning profile, which is
/// a real thing that happens on a device before the group is registered — the
/// store degrades to "no snapshot" rather than trapping, and the widget says
/// "Open Iris". A crashing widget is a worse diagnostic than an empty one.
struct IrisWidgetStore {

    static let appGroup = "group.app.iris.liveprototype"
    private static let fileName = "summary.json"

    let directory: URL?

    init(appGroup: String = IrisWidgetStore.appGroup) {
        self.directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Test seam: a plain directory stands in for the container.
    init(directory: URL?) {
        self.directory = directory
    }

    var isAvailable: Bool { directory != nil }

    private var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    func load() -> IrisWidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(IrisWidgetSnapshot.self, from: data)
    }

    @discardableResult
    func save(_ snapshot: IrisWidgetSnapshot) -> Bool {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            // The widget reads this while the phone may be locked, so it must
            // not carry the default "complete" protection class — the
            // extension would get an unreadable file on a locked screen. None
            // of it is a secret; that is the whole design.
            try data.write(to: fileURL, options: [.atomic, .noFileProtection])
            return true
        } catch {
            return false
        }
    }

    func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
