//
//  VoiceOrb.swift
//  IrisLivePrototype
//
//  The hero control: one large piece of glass that *is* start/stop, and that
//  says what the session is doing without a legend.
//
//  There is no audio level to drive it. `AudioEngine` publishes route and
//  buffer counters, not metering, and adding a tap for decoration would put
//  work on the audio path — so the orb animates by state only. If metering is
//  ever exposed, `VoiceOrb` is the only thing that has to change.
//

import SwiftUI

// MARK: - State

/// What the user is looking at, in the order the UI cares about.
enum VoiceState: Equatable {
    /// Unpaired with no developer key: the orb is not a button yet.
    case unavailable
    case idle
    case connecting
    /// The socket is being replaced under a conversation that is still going.
    /// Deliberately its own state and not an error: nothing has been lost yet.
    case reconnecting
    case listening
    case speaking
    /// Hermes is running work for us.
    case working(Int)
    /// The dispatch gate is holding a proposal; nothing has been sent.
    case awaitingAnswer

    var tint: Color {
        switch self {
        case .unavailable: return Color.gray
        case .idle: return Color(red: 0.45, green: 0.47, blue: 0.75)
        case .connecting, .reconnecting: return Color(red: 0.95, green: 0.72, blue: 0.30)
        case .listening: return Color(red: 0.32, green: 0.78, blue: 0.94)
        case .speaking: return Color(red: 0.66, green: 0.52, blue: 0.99)
        case .working: return Color(red: 0.98, green: 0.60, blue: 0.29)
        case .awaitingAnswer: return Color(red: 0.98, green: 0.78, blue: 0.35)
        }
    }

    var symbol: String {
        switch self {
        case .unavailable: return "link.badge.plus"
        case .idle: return "mic.fill"
        case .connecting: return "ellipsis"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .listening: return "waveform"
        case .speaking: return "waveform.badge.mic"
        case .working: return "gearshape.2.fill"
        case .awaitingAnswer: return "questionmark"
        }
    }

    /// The one line under the orb, in the words a person would use.
    var headline: String {
        switch self {
        case .unavailable: return "Not paired yet"
        case .idle: return "Tap to talk to Iris"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .listening: return "Listening"
        case .speaking: return "Iris is speaking"
        case .working(let n): return n == 1
            ? "Hermes is working on 1 task"
            : "Hermes is working on \(n) tasks"
        case .awaitingAnswer: return "Waiting for your answer"
        }
    }

    /// Spoken by VoiceOver in place of the visual state.
    var accessibilityValue: String {
        switch self {
        case .unavailable: return "Unavailable, this phone is not paired"
        case .idle: return "Stopped"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .listening: return "Listening to you"
        case .speaking: return "Iris is speaking"
        case .working(let n): return "Hermes is working on \(n) task\(n == 1 ? "" : "s")"
        case .awaitingAnswer: return "Waiting for you to say yes or no"
        }
    }

    var isLive: Bool {
        switch self {
        case .unavailable, .idle: return false
        default: return true
        }
    }

    /// Whether the orb should breathe. Connecting and speaking earn motion;
    /// a quiet listening state gets a slow breath; idle stays still.
    var pulse: (scale: CGFloat, duration: Double)? {
        switch self {
        case .unavailable, .idle: return nil
        case .connecting, .reconnecting: return (1.06, 0.9)
        case .listening: return (1.035, 2.2)
        case .speaking: return (1.075, 0.7)
        case .working: return (1.03, 1.6)
        case .awaitingAnswer: return (1.05, 1.3)
        }
    }
}

// MARK: - Orb

struct VoiceOrb: View {
    let state: VoiceState
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var pulsing = false

    /// A graphic, not text: it does not grow with Dynamic Type. It *shrinks*
    /// at accessibility sizes, so the larger status line and transcript keep
    /// their room instead of being pushed off the screen.
    private var size: CGFloat { dynamicTypeSize.isAccessibilitySize ? 150 : 210 }

    var body: some View {
        Button(action: action) {
            ZStack {
                halo
                Circle()
                    .fill(.clear)
                    .frame(width: size, height: size)
                    // A light tint only: at this size a full-strength tint
                    // stops reading as glass and becomes a painted disc.
                    .irisGlass(.interactive(state.tint.opacity(0.32)), in: Circle())
                Image(systemName: state.symbol)
                    .font(.system(size: size * 0.24, weight: .light))
                    .foregroundStyle(.white)
                    .shadow(color: state.tint.opacity(0.6), radius: 12)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size * 1.28, height: size * 1.28)
            .scaleEffect(pulsing ? (state.pulse?.scale ?? 1) : 1)
        }
        .buttonStyle(.plain)
        .disabled(state == .unavailable)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: state)
        .onAppear { restartPulse() }
        .onChange(of: state) { _, _ in restartPulse() }
        .accessibilityLabel(state.isLive ? "Stop talking to Iris" : "Start talking to Iris")
        .accessibilityValue(state.accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityRemoveTraits(.isImage)
    }

    /// Two soft rings behind the glass. They are what makes the state legible
    /// from across a room, and they are what the pulse actually moves.
    private var halo: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [state.tint.opacity(0.45), state.tint.opacity(0)],
                        center: .center,
                        startRadius: size * 0.34,
                        endRadius: size * 0.66
                    )
                )
            Circle()
                .stroke(state.tint.opacity(0.55), lineWidth: 1.5)
                .frame(width: size * 1.10, height: size * 1.10)
            Circle()
                .stroke(state.tint.opacity(0.22), lineWidth: 1)
                .frame(width: size * 1.26, height: size * 1.26)
        }
        .allowsHitTesting(false)
    }

    private func restartPulse() {
        pulsing = false
        guard !reduceMotion, let pulse = state.pulse else { return }
        withAnimation(.easeInOut(duration: pulse.duration).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

#Preview("Orb states") {
    ZStack {
        AuroraBackground()
        ScrollView {
            VStack(spacing: 28) {
                ForEach(
                    [VoiceState.idle, .connecting, .reconnecting, .listening, .speaking, .working(2), .awaitingAnswer, .unavailable],
                    id: \.self
                ) { state in
                    VStack(spacing: 8) {
                        VoiceOrb(state: state) {}
                        Text(state.headline).font(.subheadline)
                    }
                }
            }
            .padding(.vertical, 40)
        }
    }
    .preferredColorScheme(.dark)
}

extension VoiceState: Hashable {}
