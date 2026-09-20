//
//  RunNotifier.swift
//  IrisLivePrototype
//
//  Local notifications for runs this phone dispatched that finish while no
//  Live session is running.
//
//  There is now real push as well (LINK_API.md §11, PushService.swift), and
//  the two overlap deliberately rather than by accident:
//
//    - the Mac pushes six seconds after a phone-dispatched run finishes, and
//      skips the push entirely if the phone acked the announcement first;
//    - this file still raises a local banner for a completion the app sees
//      itself — which is what covers a Mac with no APNs key configured, and a
//      run that finished while the app was open and quiet.
//
//  So every completion has two possible sources, and exactly one banner is
//  allowed to reach the user. `notified` is the ledger that guarantees it: a
//  push claims the run through `markHandled` before this ever runs, and a run
//  that already has a delivered notification is skipped below.
//
//  If the phone is locked with the app suspended and the Mac cannot push, the
//  completion is still not delivered at that moment; it is delivered the next
//  time the app runs. That is a real limitation, not a bug to hide behind a
//  cheerful message.
//
//  If the user refuses notification permission, nothing here pretends
//  otherwise: `permission` becomes `.denied`, the run still appears in the run
//  list, and the UI says it could not notify.
//

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
public final class RunNotifier: NSObject, ObservableObject {

    public enum Permission: Equatable {
        case unknown, granted, denied, unavailable
    }

    @Published public private(set) var permission: Permission = .unknown

    /// Runs this phone has already raised a notification for. Kept locally,
    /// separate from the desktop's `announced` ledger: that one belongs to the
    /// spoken announcement and must not be spent by a banner.
    private var notified: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.storageKey) }
    }
    private static let storageKey = "iris.notifiedRunIds"

    #if canImport(UserNotifications)
    private let center = UNUserNotificationCenter.current()
    #endif

    public override init() {
        super.init()
        // The delegate is installed once at launch by `IrisAppDelegate`, which
        // is what lets a tap from a cold start arrive. This object just lends
        // the router its ledger.
        NotificationRouter.shared.notifier = self
    }

    /// Whether a banner has already been raised — or claimed by a push — for
    /// this run.
    public func hasNotified(_ runId: String) -> Bool { notified.contains(runId) }

    /// Asked for at the moment it first means something: the user has just
    /// sent real work to Hermes from this phone, so a completion banner is
    /// about to become useful. Never at launch.
    public func requestPermissionIfNeeded() async {
        #if canImport(UserNotifications)
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permission = .granted
            return
        case .denied:
            permission = .denied
            return
        default:
            break
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        permission = granted ? .granted : .denied
        #else
        permission = .unavailable
        #endif
    }

    public func refreshPermission() async {
        #if canImport(UserNotifications)
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = .granted
        case .denied: permission = .denied
        default: permission = .unknown
        }
        #else
        permission = .unavailable
        #endif
    }

    /// Raises one banner per finished run. Returns the runs it actually
    /// notified about, so the caller never claims more than happened.
    @discardableResult
    public func notifyIfNeeded(_ runs: [LinkTask]) async -> [String] {
        guard !Self.candidates(from: runs, notified: notified).isEmpty else { return [] }
        guard permission == .granted else {
            // Refused or not yet asked: the run still shows in the list and we
            // record nothing, so a later grant can still deliver it.
            return []
        }
        var delivered: [String] = []
        #if canImport(UserNotifications)
        // A push that arrived while the app was suspended is already on the
        // user's screen. Same run, same banner: never a second one.
        let onScreen = Self.runIds(ofDelivered: await center.deliveredNotifications())
        let candidates = Self.candidates(from: runs, notified: notified, alreadyOnScreen: onScreen)
        // Runs skipped because a push already covered them are recorded, not
        // delivered: the ledger is what stops them being reconsidered on every
        // poll, and the caller must not be told they buzzed.
        let covered = Self.candidates(from: runs, notified: notified)
            .map(\.runId)
            .filter { onScreen.contains($0) }
        for run in candidates {
            let content = UNMutableNotificationContent()
            content.title = Self.title(for: run.status)
            content.body = Self.body(for: run)
            content.sound = .default
            // The same identity a push carries (§11.4 sets `thread-id` and
            // `apns-collapse-id` to the run id), so a later push for this run
            // replaces this banner instead of stacking on it.
            content.threadIdentifier = run.runId
            content.userInfo = ["run_id": run.runId, "kind": PushNotice.Kind.runComplete.rawValue]
            let request = UNNotificationRequest(
                identifier: "iris.run.\(run.runId)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
                delivered.append(run.runId)
            } catch {
                // Say nothing rather than claim a delivery that failed.
                continue
            }
        }
        if !covered.isEmpty { notified.formUnion(covered) }
        #endif
        if !delivered.isEmpty { notified.formUnion(delivered) }
        return delivered
    }

    // MARK: De-duplication (pure, so it can be tested without iOS)

    /// The runs a local banner is owed: terminal, dispatched by this phone,
    /// not already in the ledger, and not already on screen from a push.
    nonisolated static func candidates(
        from runs: [LinkTask],
        notified: Set<String>,
        alreadyOnScreen: Set<String> = []
    ) -> [LinkTask] {
        runs.filter {
            $0.isTerminal
                && $0.isFromThisPhone
                && !notified.contains($0.runId)
                && !alreadyOnScreen.contains($0.runId)
        }
    }

    /// A run already spoken aloud in a live session should not also buzz.
    public func markHandled(_ runId: String) {
        var current = notified
        current.insert(runId)
        notified = current
    }

    #if canImport(UserNotifications)
    /// The run ids already showing in Notification Centre, from a push or from
    /// an earlier local banner. Both carry the run id as the thread id.
    nonisolated static func runIds(ofDelivered delivered: [UNNotification]) -> Set<String> {
        Set(delivered.compactMap { item -> String? in
            if let notice = PushNotice(userInfo: item.request.content.userInfo),
               notice.kind == .runComplete {
                return notice.runId
            }
            let thread = item.request.content.threadIdentifier
            return thread.isEmpty ? nil : thread
        })
    }
    #endif

    nonisolated static func title(for status: String) -> String {
        switch status.lowercased() {
        case "completed": return "Hermes finished"
        case "failed", "error": return "Hermes failed"
        case "cancelled", "canceled": return "Hermes run stopped"
        default: return "Hermes run ended (\(status))"
        }
    }

    nonisolated static func body(for run: LinkTask) -> String {
        let firstLine = run.task
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "Goal:" })
            ?? run.task
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 120 ? String(trimmed.prefix(117)) + "…" : trimmed
    }
}
