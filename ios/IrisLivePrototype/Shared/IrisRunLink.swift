//
//  IrisRunLink.swift
//  Shared by the app and the IrisWidgets extension.
//
//  The `iris://` scheme, which exists for exactly one reason: a Live Activity
//  or a widget cannot call into the app, it can only hand iOS a URL. A tap on
//  a run opens THAT run (§14.8).
//
//  This is a separate scheme from `iris-link://`, which carries pairing
//  secrets from a QR code. Keeping them apart means a widget URL can never be
//  mistaken for a pairing offer, and the pairing parser never has to consider
//  a URL that came from a lock screen.
//
//  Everything arriving here is parsed strictly. A run id that is not plainly a
//  run id opens nothing: the ids come from a payload the phone did not author,
//  and "open whatever this string says" is how a deep link becomes a hole.
//

import Foundation

enum IrisRunLink {

    static let scheme = "iris"

    /// The desktop's own rule for a run id (§14.7 `invalid_activity_id` uses
    /// the same alphabet). Anything else is refused rather than sanitised —
    /// a "cleaned up" id would open some other run.
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")

    static func isValidRunId(_ id: String) -> Bool {
        !id.isEmpty
            && id.count <= 128
            && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `iris://run/<id>` — open this run's detail.
    static func run(_ id: String) -> URL? {
        guard isValidRunId(id) else { return nil }
        return URL(string: "\(scheme)://run/\(id)")
    }

    /// `iris://runs` — open the run list, for a widget with nothing specific
    /// to point at.
    static var runs: URL { URL(string: "\(scheme)://runs")! }

    /// `iris://open` — just bring the app forward (the unpaired widget).
    static var open: URL { URL(string: "\(scheme)://open")! }

    enum Destination: Equatable {
        case run(String)
        case runs
        case app
    }

    /// Parses a URL the system handed the app. Returns nil for anything that
    /// is not one of the three forms above, including `iris-link://` pairing
    /// URLs, which belong to `IrisLinkDeepLink` and are not touched here.
    static func parse(_ url: URL) -> Destination? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // A custom-scheme URL puts the first path element in `host`.
        let head = (url.host ?? "").lowercased()
        switch head {
        case "run":
            let id = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let decoded = id.removingPercentEncoding ?? id
            guard isValidRunId(decoded) else { return nil }
            return .run(decoded)
        case "runs":
            return .runs
        case "open", "":
            return .app
        default:
            return nil
        }
    }
}
