//
//  VoiceChoice.swift
//  IrisLivePrototype
//
//  Which voice this phone asks for (LINK_API.md §13.4).
//
//  There is no server-side per-device voice preference: a phone that sends no
//  `voice` gets the Mac's `default_voice`. So the choice lives here, in
//  UserDefaults — it is a preference, not a secret, and putting it in the
//  Keychain would only make it harder to clear.
//
//  Two rules this type exists to hold:
//
//    · the stored name is sent on EVERY `purpose:"session"` mint, the resume
//      ones included, so a reconnect mid-conversation cannot change how Iris
//      sounds halfway through;
//    · when the Mac answers `400 invalid_voice` the stored name is dropped
//      rather than retried. The catalogue is the Mac's, and the phone has just
//      been told its copy is stale.
//

import Foundation

/// The phone's voice preference. `nil` means "whatever the Mac's default is",
/// which is a real choice the picker offers, not an absence of one.
@MainActor
public final class VoiceChoiceStore: ObservableObject {

    private static let key = "iris.voice.selected"

    private let defaults: UserDefaults

    /// The chosen catalogue name, or nil for the Mac's default.
    @Published public private(set) var selected: String?

    /// Set when a mint was refused with `invalid_voice`, so the UI can say
    /// plainly what happened instead of quietly sounding different.
    @Published public var fallbackNotice: String = ""

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.key)?.trimmingCharacters(in: .whitespaces)
        self.selected = (stored?.isEmpty ?? true) ? nil : stored
    }

    /// The value to put in a token request body: nil when the Mac should pick.
    public var requestedVoice: String? { selected }

    public func select(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            selected = trimmed
            defaults.set(trimmed, forKey: Self.key)
        } else {
            selected = nil
            defaults.removeObject(forKey: Self.key)
        }
        fallbackNotice = ""
    }

    /// §13.1's refusal. The choice is cleared — the next session uses the Mac's
    /// default — and the user is told, because the voice really did change.
    public func fallBackToMacDefault(macDefault: String) {
        let lost = selected
        selected = nil
        defaults.removeObject(forKey: Self.key)
        let named = lost.map { "“\($0)”" } ?? "The voice this phone had chosen"
        let fallback = macDefault.isEmpty ? "your Mac's default voice" : "\(macDefault), your Mac's default"
        fallbackNotice = "\(named) is not in your Mac's voice list any more, so Iris will use \(fallback)."
    }

    /// True when the stored name is not in the catalogue the Mac just sent.
    /// An empty catalogue proves nothing (an older desktop sends none), so it
    /// is never treated as a refusal.
    public func isStale(against catalogue: [LinkVoice]) -> Bool {
        guard let selected, !catalogue.isEmpty else { return false }
        return !catalogue.contains { $0.name.caseInsensitiveCompare(selected) == .orderedSame }
    }

    /// What the picker shows as ticked: the stored name, else the Mac default.
    public func effectiveName(macDefault: String) -> String {
        selected ?? macDefault
    }
}
