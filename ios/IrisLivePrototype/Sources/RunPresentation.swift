//
//  RunPresentation.swift
//  IrisLivePrototype
//
//  How a run is named and shown to a person: a readable title instead of an
//  id, and a status icon that moves while Hermes is working.
//

import SwiftUI

enum RunTitle {
    /// A short human title from a Hermes brief. Briefs are multi-line
    /// ("Goal:\n<sentence>\nContext: …"), so take the goal sentence, drop the
    /// label, and keep it to one line. Never invents wording: it only trims.
    static func summary(of task: String, limit: Int = 60) -> String {
        let lines = task
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "Run" }

        var text = lines[0]
        let lowered = text.lowercased()
        if lowered == "goal:" || lowered == "goal" {
            text = lines.count > 1 ? lines[1] : "Run"
        } else if lowered.hasPrefix("goal:") {
            text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if text.isEmpty, lines.count > 1 { text = lines[1] }
        }
        // First sentence only, when there is a clear one.
        if let end = text.firstIndex(where: { ".!?".contains($0) }),
           text.distance(from: text.startIndex, to: end) >= 12 {
            text = String(text[..<end])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .:;,"))
        guard text.count > limit else { return text.isEmpty ? "Run" : text }
        let cut = text.prefix(limit)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }
}

/// The run's status symbol. While the run is active the arrows turn, so a
/// glance says "Hermes is working" without reading. Reduce Motion gets a
/// gentle pulse instead of rotation.
struct RunStatusIcon: View {
    let symbol: String
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        Image(systemName: symbol)
            .rotationEffect(.degrees(isActive && !reduceMotion && turning ? 360 : 0))
            .opacity(isActive && reduceMotion && turning ? 0.45 : 1)
            .animation(
                isActive
                    ? (reduceMotion
                        ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                        : .linear(duration: 1.6).repeatForever(autoreverses: false))
                    : .default,
                value: turning
            )
            .onAppear { turning = isActive }
            .onChange(of: isActive) { _, active in turning = active }
    }
}
