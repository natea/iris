//
//  ReconnectPolicy.swift
//  IrisLivePrototype
//
//  The Live API does not let a conversation run forever on one socket. Two
//  different server-side deadlines end it, and both were measured against the
//  real API rather than assumed (see the notes on each case below):
//
//    1. A top-level `goAway` with a `timeLeft`, followed by a hang-up. This is
//       the ~10-minute connection rotation the desktop already rides out.
//    2. The ephemeral token's own `expireTime` (30 minutes for a paired
//       phone). Observed: the server closes a perfectly healthy session with
//       close code 1011 and the reason "auth token has expired", exactly at
//       expireTime.
//
//  Neither is a failure, and neither may end the conversation. This type owns
//  the decision of what to do about a closed socket, and owns nothing else: no
//  clock, no sockets, no I/O. Everything it needs is passed in, so the whole
//  state machine is unit-tested with a fake transport and a fake clock.
//
//  The numbers mirror electron/main.mjs so the phone and the Mac behave the
//  same way: backoff 0.5 s, 2 s, 8 s, 32 s then give up; a connection that
//  lived longer than a minute was healthy, so its close refills the budget; a
//  RESUMED connection that dies within seconds means the server rejected the
//  handle.
//

import Foundation

// MARK: - Why a connection ended

public enum LiveCloseCause: Sendable, Equatable {
    /// The server refused the credential before the session was ever usable.
    /// Retrying the same token loops forever, so this never schedules one.
    case authorizationRefused(code: Int, reason: String?)
    /// A session that was working ran past its token's `expireTime`. Verified
    /// against the real API: close 1011, reason "auth token has expired". The
    /// cure is a freshly minted token, not a fresh conversation.
    case credentialExpired(reason: String?)
    /// A network blip, a server reset, or the hang-up that follows `goAway`.
    case transportDropped(code: Int, reason: String?)
    /// The app or the user closed it.
    case intentional
}

// MARK: - What to do about it

public enum ReconnectDecision: Sendable, Equatable {
    /// Reconnect after this delay. `dropResumeHandle` is set when the evidence
    /// says the handle we just used was rejected, so the next attempt starts a
    /// fresh conversation instead of failing the same way again.
    case reconnect(after: TimeInterval, dropResumeHandle: Bool)
    /// The backoff budget is spent. The user has to be told.
    case giveUp(message: String)
    /// A refused credential. Never retried automatically.
    case stopAuthorizationFailed(code: Int, reason: String?)
    /// Nothing to do.
    case stopIntentional
}

// MARK: - Proactive reconnect after goAway

/// When to swap sockets after the server announced it is going away.
///
/// `fireAt` is when we would *like* to reconnect — comfortably before the
/// server hangs up, while the line is quiet. `hardDeadline` is the last moment
/// it is still worth doing: past that the server closes it for us anyway. The
/// gap between them is the slack a mid-sentence turn is allowed to use.
public struct GoAwaySchedule: Sendable, Equatable {
    public let fireAt: Date
    public let hardDeadline: Date

    public init(fireAt: Date, hardDeadline: Date) {
        self.fireAt = fireAt
        self.hardDeadline = hardDeadline
    }

    public func delay(from now: Date) -> TimeInterval {
        max(0, fireAt.timeIntervalSince(now))
    }
}

// MARK: - Policy

public struct ReconnectPolicy: Sendable, Equatable {

    /// electron/main.mjs: "Reconnect with backoff (0.5s, 2s, 8s, 32s)".
    public static let backoffSteps: [TimeInterval] = [0.5, 2, 8, 32]
    /// A connection that survived this long was healthy; its close is a
    /// routine reset rather than a failure streak, so the budget refills.
    public static let healthyLifetime: TimeInterval = 60
    /// A *resumed* connection that dies this fast means the handle was refused.
    public static let resumeRejectedLifetime: TimeInterval = 15
    /// Reconnect this long before the server's own deadline.
    public static let goAwayLead: TimeInterval = 8
    /// Never schedule a proactive reconnect sooner than this: a `goAway` that
    /// arrives with almost no time left should still let the current phrase land.
    public static let goAwayMinDelay: TimeInterval = 0.5
    /// Stop waiting for the line to go quiet this long before the hang-up.
    public static let goAwayGuardBand: TimeInterval = 1.0
    /// With no `timeLeft` at all, assume the server means "very soon".
    public static let goAwayFallback: TimeInterval = 10

    /// A close this soon after opening, before the session was ever usable, is
    /// a refused credential dressed up as a connection.
    public static let authorizationWindow: TimeInterval = 2.0

    public static let giveUpMessage =
        "Iris could not get back to Gemini. Tap the orb to start a new conversation."

    /// How many failures in a row we have counted. Reset by a healthy session.
    public private(set) var attempts = 0
    /// Whether the connection that is currently open was opened with a handle.
    public private(set) var usedResumeHandle = false

    public init() {}

    // MARK: Connection lifecycle

    public mutating func connectionOpened(resuming: Bool) {
        usedResumeHandle = resuming
    }

    /// A completed model turn proves the session works. Same signal the
    /// desktop uses to refill its own reconnect budget.
    public mutating func connectionHealthy() {
        attempts = 0
    }

    // MARK: The decision

    public mutating func decide(cause: LiveCloseCause, lived: TimeInterval) -> ReconnectDecision {
        switch cause {
        case .intentional:
            return .stopIntentional
        case .authorizationRefused(let code, let reason):
            return .stopAuthorizationFailed(code: code, reason: reason)
        case .credentialExpired, .transportDropped:
            break
        }

        // A long-lived connection was healthy — do not count its close against
        // the budget, and do not blame the resume handle for it.
        if lived > Self.healthyLifetime { attempts = 0 }

        // A resumed connection that died in seconds: the handle was expired or
        // invalidated. A fresh conversation beats a dead assistant.
        let dropHandle = usedResumeHandle && lived < Self.resumeRejectedLifetime

        guard attempts < Self.backoffSteps.count else {
            return .giveUp(message: Self.giveUpMessage)
        }
        let delay = Self.backoffSteps[attempts]
        attempts += 1
        return .reconnect(after: delay, dropResumeHandle: dropHandle)
    }

    // MARK: Classification

    /// Turns what the socket reported into one of the four causes.
    ///
    /// The 1011 rule is the subtle one and it is empirical. An ephemeral token
    /// that is expired, already spent, or outside its start window is refused
    /// with 1011 *before* `setupComplete` ("Token has been used too many
    /// times"). But 1011 is ALSO how a healthy session ends when the token's
    /// `expireTime` arrives ("auth token has expired") — every 30-minute
    /// paired session ends that way. Treating both as an authorization failure
    /// is what makes a working session die on the half hour.
    public static func classify(
        code: Int,
        reason: String?,
        sawSetupComplete: Bool,
        lived: TimeInterval
    ) -> LiveCloseCause {
        if code == 1011 {
            if !sawSetupComplete || lived <= authorizationWindow {
                return .authorizationRefused(code: code, reason: reason)
            }
            return .credentialExpired(reason: reason)
        }
        if !sawSetupComplete && lived <= authorizationWindow {
            return .authorizationRefused(code: code, reason: reason)
        }
        return .transportDropped(code: code, reason: reason)
    }

    // MARK: goAway

    public static func schedule(goAwayTimeLeft timeLeft: TimeInterval?, now: Date) -> GoAwaySchedule {
        let left = max(0, timeLeft ?? goAwayFallback)
        let hardDeadline = now.addingTimeInterval(max(0, left - goAwayGuardBand))
        let preferred = now.addingTimeInterval(max(goAwayMinDelay, left - goAwayLead))
        return GoAwaySchedule(fireAt: min(preferred, hardDeadline), hardDeadline: hardDeadline)
    }

    /// True while it is still worth waiting for the line to go quiet: the model
    /// is mid-turn (or the user is mid-utterance) and the server has not run
    /// out of patience yet. Past the hard deadline the swap happens regardless,
    /// because the alternative is the server cutting the socket itself.
    public static func shouldWaitForQuiet(busy: Bool, now: Date, hardDeadline: Date) -> Bool {
        busy && now < hardDeadline
    }
}

// MARK: - protobuf Duration

public enum LiveDuration {
    /// `goAway.timeLeft` is a protobuf Duration in its JSON form: a decimal
    /// number of seconds with a trailing "s" ("600s", "9.999s"). Returns nil
    /// for anything else rather than guessing a deadline.
    public static func seconds(_ text: String?) -> TimeInterval? {
        guard var value = text?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasSuffix("s") { value.removeLast() }
        guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}
