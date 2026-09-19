//
//  RunNotifier.swift
//  IrisLivePrototype
//
//  Local notifications for runs this phone dispatched that finish while no
//  Live session is running.
//
//  Be honest about what iOS can do here. There is no push server in this
//  prototype, so a notification can only be scheduled by code that is actually
//  executing. In practice that means:
//
//    - while the app is in the foreground, or
//    - during the short window iOS keeps it alive after backgrounding, or
//    - on the next launch/foreground, when `refresh()` sees the finished run.
//
//  If the phone is locked with the app fully suspended for an hour, the
//  completion is NOT delivered at that moment; it is delivered the next time
//  the app runs. That is a real limitation of the prototype, not a bug to hide
//  behind a cheerful message.
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
    /// Set when a notification is tapped, so the view can open that run.
    @Published public var openRunId: String?

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
        #if canImport(UserNotifications)
        center.delegate = self
        #endif
    }

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
        let candidates = runs.filter { $0.isTerminal && $0.isFromThisPhone && !notified.contains($0.runId) }
        guard !candidates.isEmpty else { return [] }
        guard permission == .granted else {
            // Refused or not yet asked: the run still shows in the list and we
            // record nothing, so a later grant can still deliver it.
            return []
        }
        var delivered: [String] = []
        #if canImport(UserNotifications)
        for run in candidates {
            let content = UNMutableNotificationContent()
            content.title = Self.title(for: run.status)
            content.body = Self.body(for: run)
            content.sound = .default
            content.userInfo = ["run_id": run.runId]
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
        #endif
        if !delivered.isEmpty { notified.formUnion(delivered) }
        return delivered
    }

    /// A run already spoken aloud in a live session should not also buzz.
    public func markHandled(_ runId: String) {
        var current = notified
        current.insert(runId)
        notified = current
    }

    static func title(for status: String) -> String {
        switch status.lowercased() {
        case "completed": return "Hermes finished"
        case "failed", "error": return "Hermes failed"
        case "cancelled", "canceled": return "Hermes run stopped"
        default: return "Hermes run ended (\(status))"
        }
    }

    static func body(for run: LinkTask) -> String {
        let firstLine = run.task
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "Goal:" })
            ?? run.task
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 120 ? String(trimmed.prefix(117)) + "…" : trimmed
    }
}

#if canImport(UserNotifications)
extension RunNotifier: UNUserNotificationCenterDelegate {

    /// Show the banner even while the app is foregrounded: the user may be
    /// looking at something else in it.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapping a completion opens that run's result.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let runId = response.notification.request.content.userInfo["run_id"] as? String
        await MainActor.run { [weak self] in
            guard let runId, !runId.isEmpty else { return }
            self?.openRunId = runId
        }
    }
}
#endif
