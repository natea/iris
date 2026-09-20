//
//  PushService.swift
//  IrisLivePrototype
//
//  Real push (LINK_API.md §11): the UIKit half, the registration half, and the
//  one place a tapped notification turns into "open that run".
//
//  Three objects, each with one job:
//
//    · `IrisAppDelegate` — the only reason UIKit is here at all. SwiftUI has
//      no hook for `didRegisterForRemoteNotificationsWithDeviceToken`, so the
//      app adopts a delegate through `UIApplicationDelegateAdaptor` and
//      forwards the two callbacks. It also installs the notification-centre
//      delegate *at launch*, which is what makes a tap from a cold start
//      arrive at all.
//    · `PushRegistrar` — permission, `registerForRemoteNotifications`, and
//      `PUT`/`DELETE /link/push-token`. It re-registers on every launch,
//      whenever iOS issues a new token, and whenever the phone re-pairs.
//    · `NotificationRouter` — the `UNUserNotificationCenterDelegate`. It
//      decides whether a banner is shown in the foreground and turns a tap
//      into a run to open, for local and remote notifications alike, so the
//      two can be de-duplicated against each other.
//
//  A device token is never logged in full; only `PushDeviceToken.redacted`
//  ever reaches a string.
//

import Foundation
import SwiftUI
import UIKit
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - App delegate

/// Adopted by `IrisLivePrototypeApp` through `UIApplicationDelegateAdaptor`.
final class IrisAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must happen before the app finishes launching, or the response to a
        // notification that launched the app is never delivered.
        MainActor.assumeIsolated { NotificationRouter.shared.install() }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = PushDeviceToken.hex(deviceToken)
        Task { @MainActor in await PushRegistrar.shared.received(tokenHex: hex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor in PushRegistrar.shared.registrationFailed(message) }
    }
}

// MARK: - Registrar

@MainActor
public final class PushRegistrar: ObservableObject {

    public static let shared = PushRegistrar()

    public enum State: Equatable {
        case notRegistered
        case registering
        case registered(PushEnvironment)
        case failed(String)
    }

    @Published public private(set) var state: State = .notRegistered
    /// Whether the Mac can push at all (§11 — `pushConfigured` on status).
    /// nil until a status has actually been read; never guessed.
    @Published public private(set) var macPushConfigured: Bool?
    /// Redacted, for the Settings readout. Never the whole token.
    @Published public private(set) var tokenSummary: String = ""

    /// The build's APNs environment. Derived, not configurable.
    public let environment: PushEnvironment = .current

    private var paired: PairedDesktop?
    private var tokenHex: String = ""
    /// True once the user has turned push on in this app. Kept so a relaunch
    /// re-registers without asking again, and so "off" really means off.
    private var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }
    private static let enabledKey = "iris.push.enabled"

    public var isEnabled: Bool { enabled }

    private init() {}

    // MARK: Wiring

    /// Called whenever the pairing changes. A phone that re-pairs is a new
    /// device to the Mac, so whatever token it holds has to be sent again.
    public func configure(paired: PairedDesktop?) {
        // Same rule as RunsController: no credential, nothing to register with.
        let paired = (paired?.credential.isEmpty == false) ? paired : nil
        let changed = paired?.deviceId != self.paired?.deviceId
        self.paired = paired
        guard paired != nil else {
            state = .notRegistered
            return
        }
        if enabled && (changed || !tokenHex.isEmpty) {
            Task { await registerWithAPNs() }
        }
    }

    public func noteStatus(_ status: LinkStatus?) {
        macPushConfigured = status.map(\.pushConfigured)
    }

    // MARK: Turning it on and off

    /// The user asked for notifications — from the Settings row, or right
    /// after pairing succeeded. Never at cold first launch.
    public func enable(notifier: RunNotifier) async {
        // Nothing to enable without a Mac to register with — and asking for
        // notification permission with nowhere to send them would be a prompt
        // the user cannot make sense of.
        guard paired != nil else { return }
        await notifier.requestPermissionIfNeeded()
        guard notifier.permission == .granted else {
            enabled = false
            state = .notRegistered
            return
        }
        enabled = true
        await registerWithAPNs()
    }

    /// Re-run on every launch and every foreground: `PUT` is idempotent and
    /// costs one request, and iOS can hand out a new token after a restore, a
    /// reinstall or an OS update.
    public func refreshOnLaunch(notifier: RunNotifier) async {
        await notifier.refreshPermission()
        guard enabled, notifier.permission == .granted, paired != nil else { return }
        await registerWithAPNs()
    }

    /// The user turned notifications off in Iris. §11.2: tell the Mac, so it
    /// stops pushing, and stop APNs handing us tokens.
    public func disable() async {
        enabled = false
        tokenHex = ""
        tokenSummary = ""
        state = .notRegistered
        UIApplication.shared.unregisterForRemoteNotifications()
        await deletePushToken()
    }

    /// Unpairing: the credential is about to go, so unregister while it still
    /// works. Failure is not surfaced — the desktop deletes the token with the
    /// device anyway (§11.6).
    public func unpairing() async {
        await deletePushToken()
        enabled = false
        tokenHex = ""
        tokenSummary = ""
        state = .notRegistered
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    // MARK: APNs

    private func registerWithAPNs() async {
        state = .registering
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// `didRegisterForRemoteNotificationsWithDeviceToken`, hex-encoded.
    func received(tokenHex hex: String) async {
        tokenHex = hex
        tokenSummary = PushDeviceToken.redacted(hex)
        await putPushToken()
    }

    func registrationFailed(_ message: String) {
        state = .failed("iOS would not register this phone for push notifications. (\(message))")
    }

    private func putPushToken() async {
        guard let paired, !tokenHex.isEmpty else { return }
        do {
            _ = try await LinkClient(paired: paired).registerPushToken(tokenHex, environment: environment)
            state = .registered(environment)
        } catch let error as LinkError {
            state = .failed(error.message)
        } catch {
            state = .failed("Could not tell your Mac where to send notifications.")
        }
    }

    private func deletePushToken() async {
        guard let paired else { return }
        try? await LinkClient(paired: paired).unregisterPushToken()
    }

    // MARK: Readouts

    public var stateLabel: String {
        switch state {
        case .notRegistered: return enabled ? "Waiting for iOS" : "Off"
        case .registering: return "Registering…"
        case .registered(let environment): return "Registered · \(environment.label)"
        case .failed: return "Not registered"
        }
    }

    public var problem: String? {
        if case .failed(let message) = state { return message }
        if enabled, macPushConfigured == false {
            return "Your Mac is not set up to send push notifications, so nothing will arrive while Iris is closed. Runs still appear in the Runs list, and Iris still notifies you while it is open."
        }
        return nil
    }
}

// MARK: - Router

/// The single `UNUserNotificationCenterDelegate`. Local notifications
/// (`RunNotifier`) and pushes from the Mac both land here, which is the only
/// way the two can be told apart and de-duplicated.
@MainActor
public final class NotificationRouter: NSObject, ObservableObject {

    public static let shared = NotificationRouter()

    /// Set when a notification is tapped: the run to open, and what for.
    @Published public var opened: PushNotice?

    /// The notifier that owns the local ledger, so a push can mark a run as
    /// already announced and vice versa. Weak: the app owns it, not this.
    weak var notifier: RunNotifier?

    /// The run a live session is reading out right now. §11.5: a run the user
    /// is already hearing about must not also banner.
    var announcingRunId: String?

    private override init() { super.init() }

    func install() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().delegate = self
        #endif
    }
}

#if canImport(UserNotifications)
extension NotificationRouter: UNUserNotificationCenterDelegate {

    // Both methods use the COMPLETION-HANDLER form on purpose. The `async`
    // variants look equivalent but are not: when Swift resumes them, the
    // bridged completion is called on a concurrency thread, and UIKit then
    // throws NSInternalInconsistencyException "Call must be made on main
    // thread" — seen on device, killing the app whenever a push arrived while
    // it was open. Here the handler is always called on the main thread.

    /// Foreground presentation: banner and sound, unless this run is already
    /// being spoken aloud or has already been raised locally.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Parsed here: `userInfo` is not Sendable, so only the decoded value
        // crosses onto the main actor.
        let notice = PushNotice(userInfo: notification.request.content.userInfo)
        let isRemote = notification.request.trigger is UNPushNotificationTrigger
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                completionHandler(self.presentation(for: notice, isRemote: isRemote))
            }
        }
    }

    /// A tap, from a cold launch, the background, or the foreground.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let notice = PushNotice(userInfo: info)
        // Same reason: take the one string out of the dictionary here.
        let localRunId = (info["run_id"] as? String) ?? ""
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.handleTap(notice: notice, localRunId: localRunId)
                completionHandler()
            }
        }
    }
}

extension NotificationRouter {
    /// The presentation decision, separated so it can be unit-tested.
    func presentation(for notice: PushNotice?, isRemote: Bool) -> UNNotificationPresentationOptions {
        guard let notice else {
            // A local notification: RunNotifier only ever raises one per run,
            // so there is nothing more to suppress.
            return [.banner, .sound]
        }
        if announcingRunId == notice.runId { return [] }
        if notice.kind == .runComplete, notifier?.hasNotified(notice.runId) == true {
            // The local banner for this completion is already on screen.
            return []
        }
        if isRemote, notice.kind == .runComplete {
            // Claim it, so the local notifier does not add a second one.
            notifier?.markHandled(notice.runId)
        }
        return [.banner, .sound]
    }

    func handleTap(notice: PushNotice?, localRunId: String) {
        if let notice {
            if notice.kind == .runComplete { notifier?.markHandled(notice.runId) }
            opened = notice
            return
        }
        // A local notification from an older build carries only a run id.
        guard !localRunId.isEmpty else { return }
        notifier?.markHandled(localRunId)
        opened = PushNotice(runId: localRunId, kind: .runComplete)
    }
}
#endif
