//
//  TranscriptView.swift
//  IrisLivePrototype
//
//  The content layer. Apple's guidance is that Liquid Glass belongs to the
//  floating control layer and content sits *under* it — so nothing here is in
//  glass. What it gets instead is contrast: a speaker label, a generous line
//  height, and a soft scrim behind the text block so it stays readable over
//  the aurora without turning into another pane of material.
//

import SwiftUI

struct TranscriptView: View {
    let lines: [LiveSessionController.TranscriptLine]
    /// Shown instead of the list while the transcript is empty.
    var placeholder: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if lines.isEmpty {
                        Text(placeholder)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(lines) { line in
                        TranscriptLineView(line: line).id(line.id)
                    }
                    // Keeps the last line clear of the floating control bar.
                    Color.clear.frame(height: 96).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            // Content passing under the orb and the control bar fades out
            // rather than being sliced mid-glyph.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.045),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: lines.count) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "transcript-bottom"
}

private struct TranscriptLineView: View {
    let line: LiveSessionController.TranscriptLine

    var body: some View {
        if isSystemNote {
            Text(cleanedNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(cleanedNote)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.speaker == "You" ? "You" : "Iris")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(line.speaker == "You" ? Color.secondary : accent)
                    .textCase(.uppercase)
                    .kerning(0.6)
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(line.speaker == "You" ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var accent: Color { Color(red: 0.66, green: 0.62, blue: 0.99) }

    private var isSystemNote: Bool { line.speaker == "—" }

    /// The controller writes bracketed markers; soften them for reading and
    /// leave the exact text in the Debug section.
    private var cleanedNote: String {
        switch line.text {
        case "[interrupted]": return "you interrupted"
        case "[turn complete]": return "— · —"
        default:
            return line.text
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        }
    }
}
