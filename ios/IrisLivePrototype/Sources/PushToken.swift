//
//  PushToken.swift
//  IrisLivePrototype
//
//  The pure half of push (LINK_API.md §11): how a device token is encoded,
//  which APNs environment this build belongs to, and what the two payloads
//  mean. No UIKit and no UserNotifications here, so all of it is unit-tested
//  and the same file compiles for the macOS probe.
//
//  A device token is not a secret in the way a credential is, but it is a
//  unique handle to this phone, so nothing here ever puts a whole one in a
//  string a log could take.
//

import Foundation

// MARK: - Environment

/// §11.2 — derived from the build, never from a setting. A token minted under
/// the development entitlement only works against Apple's sandbox host and
/// vice versa; the wrong one comes back `BadDeviceToken` and the Mac drops the
/// token, which looks exactly like "push is broken".
public enum PushEnvironment: String, Sendable, Equatable {
    case sandbox
    case production

    /// The conventional derivation, spelled out so it can be tested without a
    /// build configuration:
    ///
    ///   - a DEBUG build is always run from Xcode → the development
    ///     entitlement → `sandbox`;
    ///   - a release build **with** a receipt was installed by TestFlight
    ///     (`sandboxReceipt`) or the App Store (`receipt`). Both use the
    ///     production APNs host → `production`;
    ///   - a release build with **no** receipt was run from Xcode or installed
    ///     ad hoc, so it still carries the development entitlement →
    ///     `sandbox`. Guessing `production` here is what silently breaks push
    ///     for anyone testing a Release configuration on their own phone.
    public static func derive(isDebugBuild: Bool, receiptURL: URL?) -> PushEnvironment {
        if isDebugBuild { return .sandbox }
        guard let receiptURL, !receiptURL.lastPathComponent.isEmpty else { return .sandbox }
        return .production
    }

    /// What this build really is, for the Settings readout and the `PUT`.
    public static var current: PushEnvironment {
        #if DEBUG
        return derive(isDebugBuild: true, receiptURL: nil)
        #elseif os(iOS)
        return derive(isDebugBuild: false, receiptURL: Bundle.main.appStoreReceiptURL)
        #else
        // The macOS probe has no APNs entitlement and never registers; it only
        // links this file because LinkClient's push routes name the type.
        return .sandbox
        #endif
    }

    public var label: String {
        switch self {
        case .sandbox: return "sandbox (development build)"
        case .production: return "production"
        }
    }
}

// MARK: - Device token

public enum PushDeviceToken {

    /// §11.1 — the APNs device token as lowercase hex, which is the only form
    /// the desktop accepts. `Data.description` is NOT this: on newer OSes it
    /// is `<Data 32 bytes>`, which is how a registration silently becomes
    /// `400 invalid_token`.
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The only form a token is ever allowed to appear in outside the request
    /// body: enough to tell two tokens apart, not enough to be one.
    public static func redacted(_ hex: String) -> String {
        guard hex.count > 12 else { return "…" }
        return "\(hex.prefix(6))…\(hex.suffix(4)) (\(hex.count / 2) bytes)"
    }
}

// MARK: - Payloads

/// §11.4 — the two notifications the Mac sends, and nothing else. Anything
/// that does not parse is dropped rather than guessed at: a malformed payload
/// must never open the wrong run.
public struct PushNotice: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        /// A run this phone dispatched reached a terminal status.
        case runComplete = "run_complete"
        /// A run this phone dispatched is waiting on the user.
        case needsAttention = "needs_attention"
    }

    public let runId: String
    public let kind: Kind
    /// Only on `needs_attention`: the pending request this push is about, so a
    /// push and a poll of §11.5's `pending_approval` can be reconciled.
    public let requestId: String
    /// Only on `needs_attention`. `false` means it is a Hermes interaction
    /// Link cannot carry — say it needs the Mac, never offer to approve it.
    public let canApproveFromPhone: Bool

    public init(runId: String, kind: Kind, requestId: String = "", canApproveFromPhone: Bool = false) {
        self.runId = runId
        self.kind = kind
        self.requestId = requestId
        self.canApproveFromPhone = canApproveFromPhone
    }

    /// Parses a notification's `userInfo`. Returns nil for anything that is
    /// not one of the two documented payloads — a missing run id, an unknown
    /// `kind`, or a value of the wrong type.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let runId = (userInfo["run_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !runId.isEmpty
        else { return nil }
        guard let rawKind = userInfo["kind"] as? String,
              let kind = Kind(rawValue: rawKind)
        else { return nil }
        self.runId = runId
        self.kind = kind
        self.requestId = (userInfo["request_id"] as? String) ?? ""
        // Absent means "do not offer the buttons", which is the safe reading.
        self.canApproveFromPhone = kind == .needsAttention
            && (userInfo["can_approve_from_phone"] as? Bool) == true
    }

    /// The identity a duplicate is measured against. A completion is one per
    /// run; an attention notice is one per distinct pending request, because a
    /// *different* request on the same run is a genuinely new thing to say.
    public var dedupeKey: String {
        switch kind {
        case .runComplete: return "run:\(runId)"
        case .needsAttention: return requestId.isEmpty ? "attention:\(runId)" : "attention:\(requestId)"
        }
    }
}
