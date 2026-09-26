//
//  WidgetBridge.swift
//  IrisLivePrototype
//
//  How the home-screen widget gets data without ever seeing the pairing
//  credential (LINK_API.md §14.6 / §14.7).
//
//  The widget extension runs in its own process with its own Keychain access
//  group. It could be given the credential through a Keychain Sharing group
//  and fetch `/link/summary` itself — and that would put a credential in a
//  second place, readable by a target that draws pictures. Instead:
//
//      app → GET /link/summary → small non-secret snapshot → App Group file
//          → WidgetCenter.reloadAllTimelines() → widget reads the file
//
//  The widget therefore cannot talk to the Mac at all, which is the point. The
//  cost is honesty work: the snapshot carries `generatedAt`, and every widget
//  view says how old it is (§14.6 rule 3).
//
//  There is no reliable way to push a widget reload — a silent push is
//  best-effort and throttled hard — so the refresh points are all moments the
//  APP is already running: launch, foreground, after a runs poll that changed
//  something, a push arriving in the foreground, a Live Activity update, and a
//  BGAppRefreshTask that iOS will honour on its own budget and often not at
//  all. Nothing here promises the user a refresh that iOS has not agreed to.
//

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@MainActor
final class WidgetBridge: ObservableObject {

    static let shared = WidgetBridge()

    /// Declared in Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
    /// A task scheduled under an identifier iOS has not been told about
    /// traps at submit time, so the two must stay in step.
    static let refreshTaskIdentifier = "app.iris.liveprototype.widget-refresh"

    /// The last snapshot written, for the Settings readout. Never a promise
    /// that the widget has drawn it — only that the app wrote it.
    @Published private(set) var lastWritten: IrisWidgetSnapshot?
    /// Set when the App Group container is not reachable, which on a device
    /// means the capability is missing from the provisioning profile. Said out
    /// loud, because the symptom otherwise is a widget that is simply empty.
    @Published private(set) var containerUnavailable = false

    private let store: IrisWidgetStore
    private var paired: PairedDesktop?
    private var service: (any LinkTaskService)?
    private var inFlight = false
    /// `501 tasks_unavailable` means this desktop build has no summary
    /// handler. Asking again every 15 seconds would be rude and pointless.
    private var routeUnavailable = false
    private var lastFetchAttempt: Date?
    /// One summary a minute is plenty for a surface iOS redraws every 5–15.
    private static let minimumInterval: TimeInterval = 60

    init(store: IrisWidgetStore = IrisWidgetStore()) {
        self.store = store
        self.containerUnavailable = !store.isAvailable
        self.lastWritten = store.load()
    }

    func configure(paired: PairedDesktop?) {
        let usable = (paired?.credential.isEmpty == false) ? paired : nil
        let changed = usable?.deviceId != self.paired?.deviceId
        self.paired = usable
        self.service = usable.map { LinkClient(paired: $0) }
        if changed { routeUnavailable = false; lastFetchAttempt = nil }
        if usable == nil {
            // An unpaired phone must not leave last week's counts on the home
            // screen: the widget says "Open Iris to pair" instead.
            store.save(.unpaired)
            lastWritten = .unpaired
            reloadTimelines()
        }
    }

    /// True when the App Group container is reachable. False on a device
    /// whose provisioning profile has no App Group capability — a real thing
    /// that happens before the group is registered for the team — and Settings
    /// says so, because the symptom is otherwise a widget that is just empty.
    var isSharedStorageAvailable: Bool { store.isAvailable }

    /// What the widget would draw right now, for the Settings readout.
    func currentSnapshot() -> IrisWidgetSnapshot? { lastWritten ?? store.load() }

    /// Fetch `/link/summary` and write the snapshot.
    ///
    /// Safe to call often. The unforced form is rate-limited, because the
    /// caller is a run-list change and Hermes can change the list several
    /// times a minute — while the widget will not be redrawn faster than iOS
    /// feels like, so the extra requests would buy nothing. `force: true` is
    /// for the moments that genuinely mean "the data just changed under us":
    /// launch, foreground, and a push arriving.
    func refresh(force: Bool = false, now: Date = Date()) async {
        guard let service, !inFlight, !routeUnavailable else { return }
        if !force, let last = lastFetchAttempt, now.timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        lastFetchAttempt = now
        inFlight = true
        defer { inFlight = false }
        do {
            let summary = try await service.summary()
            let snapshot = summary.snapshot(macName: paired?.desktopName ?? "", now: now)
            write(snapshot)
        } catch LinkError.tasksUnavailable {
            routeUnavailable = true
        } catch {
            // The Mac is unreachable or refused. The old snapshot stays, and
            // its age is what tells the user — overwriting it with zeroes
            // would read as "Hermes has nothing to do", which is a lie.
        }
    }

    private func write(_ snapshot: IrisWidgetSnapshot) {
        let ok = store.save(snapshot)
        containerUnavailable = !store.isAvailable
        guard ok else { return }
        lastWritten = snapshot
        reloadTimelines()
    }

    func reloadTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Background refresh

    /// Registered at launch. iOS decides whether this ever runs — it is
    /// budgeted per app, per device, and a phone that is not plugged in and
    /// not being used may go a whole day without granting one. Treated as a
    /// bonus, never as the mechanism.
    func registerBackgroundRefresh() {
        #if canImport(BackgroundTasks)
        // `.main`, not nil: with nil the handler runs on a background queue
        // and `assumeIsolated` traps the first time iOS grants a refresh.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                WidgetBridge.shared.handle(task: task)
            }
        }
        #endif
    }

    func scheduleBackgroundRefresh() {
        #if canImport(BackgroundTasks)
        guard paired != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // A refusal here is ordinary (the identifier is not permitted, too
        // many requests, the user disabled Background App Refresh) and is not
        // worth a message: nothing the user can see depends on it.
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if canImport(BackgroundTasks)
    private func handle(task: BGTask) {
        // Ask for the next one first: if this run is killed, the chain
        // continues.
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            await refresh()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
    #endif
}
