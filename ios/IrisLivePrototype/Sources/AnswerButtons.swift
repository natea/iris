//
//  AnswerButtons.swift
//  IrisLivePrototype
//
//  The big thumb-reach buttons the user answers with, and the one setting that
//  decides which side the "yes" lives on.
//
//  WHY THESE ARE NOT GLASS. Everything else that floats over the aurora is
//  control-layer material. These are not decoration over content: they are the
//  content at that moment — an irreversible answer about work that will run on
//  the user's machine. Apple's own guidance keeps glass off the thing being
//  acted on, and a faint translucent "Yes" over a moving gradient is exactly
//  the button somebody mis-hits. So they are solid, high-contrast fills.
//
//  WHY COLOR IS NEVER THE ONLY SIGNAL. Green/red/yellow is what was asked for
//  and it is what a glance reads fastest, but every button also carries its
//  own glyph and its own word, so the meaning survives any form of color
//  blindness and Reduce Transparency.
//
//  SAFETY. This file draws buttons; it never decides anything. Each action is
//  a closure supplied by the screen that owns the decision, and those closures
//  are the only callers of the confirm / decline / approve paths.
//

import SwiftUI
import UIKit

// MARK: - Handedness

/// Which side of the screen the affirmative button sits on.
///
/// A phone is held in one hand and answered with that hand's thumb, which
/// sweeps a short arc up from the bottom corner it is anchored at. The
/// affirmative answer is the one that should land inside that arc.
enum Handedness: String, CaseIterable, Identifiable {
    case right
    case left

    static let storageKey = "iris.answerButtons.handedness"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: return "Right-handed"
        case .left: return "Left-handed"
        }
    }

    /// Reorders a left-to-right list so the LAST element is nearest the thumb.
    /// Callers build the list right-handed and this mirrors it.
    func arrange<T>(_ rightHanded: [T]) -> [T] {
        self == .right ? rightHanded : rightHanded.reversed()
    }
}

// MARK: - Haptics

/// Three feelings, one per outcome. Deliberately coarse: a phone in a pocket
/// or a hand should be able to tell "sent" from "not sent" without looking.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// The lighter one, for an answer that changed nothing irreversible.
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - One button

/// What a single big button is and does. The screen that owns the decision
/// supplies `action`; nothing in this file ever calls it on its own.
struct AnswerAction: Identifiable {
    enum Role {
        /// Go ahead — green.
        case affirmative
        /// Don't — red.
        case negative
        /// The rarer third way out — yellow, and visibly quieter than the
        /// other two so it is not competing for the same thumb.
        case tertiary
    }

    let id: String
    let title: String
    let symbol: String
    let role: Role
    let accessibilityLabel: String
    var accessibilityHint: String = ""
    /// Shows a spinner in place of the glyph and blocks the tap.
    var isBusy: Bool = false
    let action: () -> Void

    var fill: Color {
        switch role {
        // Chosen against the aurora rather than from the system palette:
        // `Color.green` over that gradient is bright but thin, and these have
        // to read as buttons in sunlight.
        case .affirmative: return Color(red: 0.11, green: 0.60, blue: 0.29)
        case .negative: return Color(red: 0.81, green: 0.20, blue: 0.19)
        case .tertiary: return Color(red: 0.97, green: 0.79, blue: 0.24)
        }
    }

    /// Yellow takes dark text: white on yellow is the one combination here
    /// that fails contrast outright.
    var ink: Color {
        role == .tertiary ? Color.black.opacity(0.86) : .white
    }
}

// MARK: - The bar

/// The thumb-zone row: the answer on the dominant side, the refusal on the
/// far side, and the quieter third option between them.
///
/// The caller always describes the RIGHT-HANDED arrangement; `handedness`
/// mirrors it. Nothing else about the buttons changes between the two.
struct AnswerButtonBar: View {
    let affirmative: AnswerAction
    let negative: AnswerAction
    var tertiary: AnswerAction?
    var handedness: Handedness = .right
    /// Blocks every button (a request is in flight).
    var isDisabled: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// ~64–72pt is the smallest a "do not mis-hit this" target should be on a
    /// phone; it grows with Dynamic Type rather than clipping the label.
    private var minHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 84 : 70 }

    /// Wide enough for "Let me explain" on two short lines at the larger
    /// non-accessibility sizes, narrow enough to leave Yes and No their room.
    private var tertiaryWidth: CGFloat { dynamicTypeSize >= .xxLarge ? 128 : 112 }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Two rows, not three: stacking all of them pushed the bar up
                // over the very card it was answering (seen in the simulator
                // at accessibility sizes). "Yes" and "No" are short enough to
                // stay side by side at any text size, so they keep their
                // sides — and the long third label gets a row of its own,
                // above them, out of the thumb's way.
                VStack(spacing: 10) {
                    if let tertiary { button(tertiary) }
                    HStack(spacing: 10) {
                        ForEach(handedness.arrange([negative, affirmative]), id: \.id) { entry in
                            button(entry).frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(handedness.arrange(ordered), id: \.id) { entry in
                        if entry.role == .tertiary {
                            // A fixed, narrower column rather than a flexible
                            // one: given a share of the row it collapsed to
                            // its icon and lost its word (seen in the
                            // simulator), and a button whose meaning is only
                            // a colour and a glyph is the thing this whole
                            // file exists to avoid.
                            button(entry).frame(width: tertiaryWidth)
                        } else {
                            button(entry).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .disabled(isDisabled)
    }

    /// Right-handed reading order: refuse on the left, change it in the
    /// middle, go ahead on the right.
    private var ordered: [AnswerAction] {
        var row = [negative]
        if let tertiary { row.append(tertiary) }
        row.append(affirmative)
        return row
    }

    /// Icon beside the word for the two big answers; icon ABOVE it for the
    /// narrow third option, which is the only way its label fits.
    @ViewBuilder
    private func label(_ entry: AnswerAction) -> some View {
        let glyph = Group {
            if entry.isBusy {
                ProgressView().progressViewStyle(.circular).tint(entry.ink)
            } else {
                Image(systemName: entry.symbol)
                    .font(.system(size: entry.role == .tertiary ? 17 : 22, weight: .semibold))
            }
        }
        let text = Text(entry.title)
            .font(entry.role == .tertiary
                  ? .footnote.weight(.bold)
                  : .title3.weight(.bold))
            // One line for the two big answers: at accessibility sizes
            // "Approve" wrapped into "Ap-/prove" (seen in the simulator), and
            // a hyphenated answer button is not a word anyone reads at a
            // glance. It scales down instead.
            .lineLimit(entry.role == .tertiary ? 2 : 1)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.center)

        if entry.role == .tertiary && !dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 3) { glyph; text }
        } else {
            HStack(spacing: 8) { glyph; text }
        }
    }

    private func button(_ entry: AnswerAction) -> some View {
        Button(action: entry.action) {
            label(entry)
            .foregroundStyle(entry.ink)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .padding(.horizontal, 10)
            .background(
                entry.fill.opacity(entry.role == .tertiary ? 0.92 : 1),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(entry.id)
        .accessibilityLabel(entry.accessibilityLabel)
        .accessibilityHint(entry.accessibilityHint)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Answer bars") {
    ZStack {
        AuroraBackground()
        VStack(spacing: 24) {
            ForEach(Handedness.allCases) { hand in
                VStack(alignment: .leading, spacing: 8) {
                    Text(hand.title).font(.footnote).foregroundStyle(.secondary)
                    AnswerButtonBar(
                        affirmative: AnswerAction(
                            id: "answer-yes", title: "Yes", symbol: "checkmark.circle.fill",
                            role: .affirmative, accessibilityLabel: "Yes, send this to Hermes") {},
                        negative: AnswerAction(
                            id: "answer-no", title: "No", symbol: "xmark.circle.fill",
                            role: .negative, accessibilityLabel: "No, don't send") {},
                        tertiary: AnswerAction(
                            id: "answer-explain", title: "Let me explain",
                            symbol: "text.bubble.fill",
                            role: .tertiary, accessibilityLabel: "Let me explain a change") {},
                        handedness: hand
                    )
                }
            }
            AnswerButtonBar(
                affirmative: AnswerAction(
                    id: "approve", title: "Approve", symbol: "checkmark.shield.fill",
                    role: .affirmative, accessibilityLabel: "Approve", isBusy: true) {},
                negative: AnswerAction(
                    id: "deny", title: "Deny", symbol: "xmark.shield.fill",
                    role: .negative, accessibilityLabel: "Deny") {},
                isDisabled: true
            )
        }
        .padding(20)
    }
    .preferredColorScheme(.dark)
}
