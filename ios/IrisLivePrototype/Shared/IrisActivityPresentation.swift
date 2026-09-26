//
//  IrisActivityPresentation.swift
//  Shared by the app and the IrisWidgets extension.
//
//  How a Hermes state is named, coloured and iconed. Pure: no SwiftUI view, no
//  ActivityKit, so the whole of it is unit-tested and the Live Activity, the
//  home-screen widget and Settings cannot drift apart.
//
//  Colour is never the only signal. Every state has a distinct SF Symbol as
//  well, because a Live Activity is read at a glance, in a tinted rendering
//  mode that may drop colour entirely, and by people who cannot tell orange
//  from green.
//

import Foundation

enum IrisActivityLook {

    /// A state's icon, in the order a glance reads it: shape first.
    /// `waiting` is deliberately the exclamation, not a pause: a person is
    /// being asked for something, which is not the same as idling.
    static func symbol(for phase: IrisRunActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .running: return "gearshape.2.fill"
        case .waiting: return "exclamationmark.bubble.fill"
        case .idle:    return "moon.zzz.fill"
        case .done:    return "checkmark.circle.fill"
        case .failed:  return "xmark.octagon.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    /// The word for the state, in the app's voice. `failed` is not "finished".
    static func label(for phase: IrisRunActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .running: return "Working"
        case .waiting: return "Needs you"
        case .idle:    return "Idle"
        case .done:    return "Done"
        case .failed:  return "Couldn't finish"
        case .stopped: return "Stopped"
        }
    }

    /// The orb's state colours, reused so the activity and the app read as one
    /// product. Expressed as RGB triples here so this file stays SwiftUI-free.
    static func rgb(for phase: IrisRunActivityAttributes.ContentState.Phase) -> (Double, Double, Double) {
        switch phase {
        // The orb's "working" amber.
        case .running: return (0.98, 0.60, 0.29)
        // The orb's "awaiting answer" gold, pushed brighter for a lock screen.
        case .waiting: return (0.99, 0.78, 0.35)
        // The orb's idle indigo.
        case .idle:    return (0.45, 0.47, 0.75)
        case .done:    return (0.36, 0.82, 0.60)
        case .failed:  return (0.95, 0.42, 0.45)
        case .stopped: return (0.66, 0.68, 0.78)
        }
    }

    /// The violet the app's aurora is built from — the activity's own accent.
    static let accentRGB: (Double, Double, Double) = (0.66, 0.62, 0.95)
}

// MARK: - Relative time, said the same way everywhere

enum IrisRelativeTime {

    /// "just now" · "3 min ago" · "2 h ago" · "4 d ago". Deliberately short:
    /// this text shares a line with a title on a 200-point-wide widget.
    ///
    /// A date in the future is not extrapolated into a countdown — clocks
    /// disagree, and "in 4 s" on a lock screen reads as a bug.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    /// The same value phrased as a duration, for "no update for 4 min".
    /// Rounded, not truncated. A `Date` round-tripped through a `Double`
    /// comes back a hair short, so an age of exactly twelve minutes arrives
    /// here as 719.9999 seconds — and truncation would print "11 min", which
    /// is both wrong and the kind of wrong nobody would ever reproduce.
    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 60 { return "under a minute" }
        let minutes = Int((value / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = Int((value / 3600).rounded())
        if hours < 24 { return "\(hours) h" }
        return "\(Int((value / 86_400).rounded())) d"
    }
}
