//
//  IrisActivityViews.swift
//  Shared by the app and the IrisWidgets extension.
//
//  Every pixel of the Live Activity. The WidgetKit plumbing that places these
//  (ActivityConfiguration, the Dynamic Island regions) lives in the extension;
//  the views themselves live here so the app can render them to PNGs in a
//  DEBUG test and a person can actually look at them before a phone is
//  involved.
//
//  The rules these views exist to keep (§14.2, truthfulness):
//
//    · No percentage, no progress fraction, no ETA, ever. Hermes reports
//      none. The only progress indicator used anywhere here is an
//      INDETERMINATE one.
//    · `headline == ""` shows the status, not a guess.
//    · `stepsKnown == false` shows nothing about steps — never "0 steps".
//    · `failed` is drawn as failed, with its own icon, not as "finished".
//    · `.stale` dims the whole thing and says the Mac stopped reporting,
//      instead of leaving a spinner that implies work is continuing.
//
//  Colour is never the only carrier: every state has its own SF Symbol, and
//  the views read correctly in the system's `.accented` and `.vibrant`
//  rendering modes, where colour is thrown away entirely.
//

import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Colour

extension IrisActivityLook {
    static func color(for phase: IrisRunActivityAttributes.ContentState.Phase) -> Color {
        let (r, g, b) = rgb(for: phase)
        return Color(red: r, green: g, blue: b)
    }

    static var accent: Color {
        let (r, g, b) = accentRGB
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Small parts

/// The status dot: symbol first, colour second. In `.accented` rendering the
/// colour is dropped by the system and the symbol still carries the meaning.
struct IrisStatusBadge: View {
    let phase: IrisRunActivityAttributes.ContentState.Phase
    var isStale: Bool = false
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: isStale ? "wifi.exclamationmark" : IrisActivityLook.symbol(for: phase))
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isStale ? Color.secondary : IrisActivityLook.color(for: phase))
            .accessibilityLabel(isStale ? "Iris has not checked in" : IrisActivityLook.label(for: phase))
    }
}

/// The only motion allowed. `ProgressView()` with no value is indeterminate by
/// construction — there is no number it could be showing, which is exactly
/// right, because Hermes reports none.
struct IrisWorkingIndicator: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .accessibilityLabel("Working")
    }
}

// MARK: - The lock screen / banner presentation

struct IrisActivityLockScreenView: View {
    let state: IrisRunActivityAttributes.ContentState
    let macName: String
    /// True when iOS has marked the activity `.stale` — the Mac has not
    /// reported inside its 120 s window (§14.5).
    var isStale: Bool = false
    /// Always-On display: the screen is dimmed and must draw less.
    var isLuminanceReduced: Bool = false
    var now: Date = Date()

    private var phase: IrisRunActivityAttributes.ContentState.Phase { state.phase }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            title
            if isStale {
                staleLine
            } else {
                detailLine
            }
            if state.needsAttention, !isStale {
                attentionCard
            } else if state.runs.count > 1, !isStale {
                // Suppressed while stale: each line here is a claim about what
                // a run is doing RIGHT NOW, and when the Mac has stopped
                // reporting nobody knows that. The header's run count is the
                // last true thing left, and it stays.
                runList
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isStale ? 0.62 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            IrisStatusBadge(phase: phase, isStale: isStale)
            Text("HERMES")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(IrisActivityLook.accent)
            if !macName.isEmpty {
                Text("· \(macName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if state.activeRunCount > 1 {
                Text("\(state.activeRunCount) runs")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if phase == .running, !isStale, !isLuminanceReduced {
                IrisWorkingIndicator()
            }
        }
    }

    private var title: some View {
        Text(state.shortTitle)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The headline, then the step count — but only when the step history is
    /// actually known. A missing history says so; it never becomes "0 steps".
    private var detailLine: some View {
        HStack(spacing: 6) {
            Text(state.headlineOrStatus)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IrisActivityLook.color(for: phase))
                .lineLimit(1)
            if let steps = state.stepText {
                Text("·").font(.system(size: 13)).foregroundStyle(.tertiary)
                Text(steps)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if !phase.isTerminal {
                Text("·").font(.system(size: 13)).foregroundStyle(.tertiary)
                Text("step history unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// §14.5 / truthfulness rule 5. No spinner, no confident status — the only
    /// honest claim left is "we stopped hearing from the Mac", with when.
    private var staleLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text("Iris hasn't checked in")
                    .font(.system(size: 13, weight: .semibold))
                if let updated = state.updatedAtDate {
                    Text("No update since \(IrisRelativeTime.ago(updated, now: now))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private var attentionCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IrisActivityLook.color(for: .waiting))
            VStack(alignment: .leading, spacing: 2) {
                Text("Hermes needs you")
                    .font(.system(size: 13, weight: .bold))
                if !state.attentionSummary.isEmpty {
                    // Untrusted text from Hermes: displayed, never acted on.
                    Text(state.attentionSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(IrisActivityLook.color(for: .waiting).opacity(0.18))
        )
    }

    /// The up-to-3 `runs` the payload carries, minus the primary, which the
    /// title already showed.
    private var runList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(state.runs.dropFirst(), id: \.id) { run in
                HStack(spacing: 5) {
                    Image(systemName: IrisActivityLook.symbol(
                        for: run.status == "waiting" ? .waiting : .running))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(IrisActivityLook.color(
                            for: run.status == "waiting" ? .waiting : .running))
                    Text(run.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if !run.headline.isEmpty {
                        Text("· \(run.headline)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Dynamic Island regions

/// Expanded leading: who and what state.
struct IrisIslandLeadingView: View {
    let state: IrisRunActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            IrisStatusBadge(phase: state.phase, isStale: isStale, size: 17)
            Text(isStale ? "No update" : IrisActivityLook.label(for: state.phase))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 2)
    }
}

/// Expanded trailing: how much, never how far along.
struct IrisIslandTrailingView: View {
    let state: IrisRunActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if state.activeRunCount > 1 {
                Text("\(state.activeRunCount) runs")
                    .font(.system(size: 13, weight: .semibold))
            }
            if let steps = state.stepText {
                Text(steps)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !state.phase.isTerminal {
                Text("steps n/a")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.trailing, 2)
    }
}

/// Expanded centre: the run's name.
struct IrisIslandCenterView: View {
    let state: IrisRunActivityAttributes.ContentState

    var body: some View {
        Text(state.shortTitle)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

/// Expanded bottom: the live line, or the thing to answer.
struct IrisIslandBottomView: View {
    let state: IrisRunActivityAttributes.ContentState
    var isStale: Bool = false
    var now: Date = Date()

    var body: some View {
        if isStale {
            Label {
                Text(state.updatedAtDate.map { "Iris hasn't checked in · \(IrisRelativeTime.ago($0, now: now))" }
                     ?? "Iris hasn't checked in")
                    .font(.system(size: 12, weight: .medium))
            } icon: {
                Image(systemName: "wifi.exclamationmark")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.needsAttention {
            Label {
                Text(state.attentionSummary.isEmpty ? "Hermes needs you" : state.attentionSummary)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
            } icon: {
                Image(systemName: "exclamationmark.bubble.fill")
            }
            .foregroundStyle(IrisActivityLook.color(for: .waiting))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 6) {
                Text(state.headlineOrStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if state.phase == .running { IrisWorkingIndicator() }
            }
        }
    }
}

/// Compact leading — one glyph's worth of room.
struct IrisIslandCompactLeadingView: View {
    let state: IrisRunActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        IrisStatusBadge(phase: state.phase, isStale: isStale, size: 14)
    }
}

/// Compact trailing. A count when there is more than one run, otherwise the
/// indeterminate spinner — and nothing at all when the activity is stale,
/// because animation there would be a claim that work continues.
struct IrisIslandCompactTrailingView: View {
    let state: IrisRunActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        if isStale {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
        } else if state.needsAttention {
            Image(systemName: "exclamationmark")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(IrisActivityLook.color(for: .waiting))
        } else if state.activeRunCount > 1 {
            Text("\(state.activeRunCount)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(IrisActivityLook.color(for: state.phase))
        } else if state.phase == .running {
            IrisWorkingIndicator()
        } else {
            Image(systemName: IrisActivityLook.symbol(for: state.phase))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IrisActivityLook.color(for: state.phase))
        }
    }
}

/// Minimal — the whole activity in one 18-point circle.
struct IrisIslandMinimalView: View {
    let state: IrisRunActivityAttributes.ContentState
    var isStale: Bool = false

    var body: some View {
        IrisStatusBadge(phase: state.phase, isStale: isStale, size: 14)
    }
}
