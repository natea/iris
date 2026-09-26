//
//  IrisWidgetViews.swift
//  Shared by the app and the IrisWidgets extension.
//
//  The home-screen widget's faces. A widget is NOT the Live Activity: iOS
//  refreshes it on its own budget, so the one thing these views must never do
//  is look live. Every one of them can say how old its data is, and after
//  `IrisWidgetSnapshot.staleAfter` they stop asserting a state at all and ask
//  for the app instead (§14.6 rule 3).
//
//  Three states that are genuinely different and are drawn differently:
//  unpaired (there is no Mac), no data yet (paired, never fetched), and stale
//  (we had data, it is too old to stand behind).
//

import SwiftUI

// MARK: - Shared pieces

private struct WidgetHeader: View {
    let snapshot: IrisWidgetSnapshot
    var now: Date = Date()

    var body: some View {
        HStack(spacing: 5) {
            IrisStatusBadge(
                phase: snapshot.phase,
                isStale: snapshot.isStale(now: now),
                size: 13
            )
            Text("HERMES")
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(IrisActivityLook.accent)
            Spacer(minLength: 0)
            if !snapshot.hermesReachable && !snapshot.isStale(now: now) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Hermes not responding")
            }
        }
    }
}

/// The "as of" line. Absent while the data is current — there is nothing worth
/// saying about a two-minute-old count — and insistent once it is not.
private struct WidgetAgeLine: View {
    let snapshot: IrisWidgetSnapshot
    var now: Date = Date()

    var body: some View {
        if let line = snapshot.ageLine(now: now) {
            Text(line)
                .font(.system(size: 10, weight: snapshot.isStale(now: now) ? .semibold : .regular))
                .foregroundStyle(snapshot.isStale(now: now) ? .secondary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private struct WidgetEmptyState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "iphone.badge.exclamationmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IrisActivityLook.accent)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - systemSmall

struct IrisSmallWidgetView: View {
    let snapshot: IrisWidgetSnapshot
    var now: Date = Date()

    var body: some View {
        if !snapshot.paired {
            WidgetEmptyState(
                title: "Not paired",
                detail: "Open Iris and scan the code on your Mac."
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(snapshot: snapshot, now: now)
                Spacer(minLength: 0)
                countLine
                headlineLine
                WidgetAgeLine(snapshot: snapshot, now: now)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var countLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // Greyed once the data is too old to stand behind: a big orange
            // number reads as "happening now", which is exactly what a stale
            // snapshot cannot promise.
            Text("\(snapshot.activeCount)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(snapshot.isStale(now: now)
                                 ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(IrisActivityLook.color(for: snapshot.phase)))
            Text(snapshot.activeCount == 1 ? "run" : "runs")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(snapshot.activeCount) active runs")
    }

    @ViewBuilder
    private var headlineLine: some View {
        if snapshot.isStale(now: now) {
            Text("Not up to date")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        } else if snapshot.waitingCount > 0 {
            Label("Needs you", systemImage: "exclamationmark.bubble.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IrisActivityLook.color(for: .waiting))
                .lineLimit(1)
        } else if let run = snapshot.activeRun, !run.headline.isEmpty {
            Text(run.headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if snapshot.activeCount == 0 {
            Text("Nothing running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            Text("Working")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - systemMedium

struct IrisMediumWidgetView: View {
    let snapshot: IrisWidgetSnapshot
    var now: Date = Date()

    var body: some View {
        if !snapshot.paired {
            WidgetEmptyState(
                title: "Iris is not paired",
                detail: "Open Iris on this iPhone and scan the pairing code shown on your Mac to watch Hermes from here."
            )
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        WidgetHeader(snapshot: snapshot, now: now)
                        activeBlock
                    }
                    Spacer(minLength: 6)
                    countsColumn
                }
                Divider().opacity(0.4)
                footerRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var activeBlock: some View {
        if snapshot.isStale(now: now) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not up to date")
                    .font(.system(size: 14, weight: .semibold))
                Text("Open Iris to refresh")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if let run = snapshot.activeRun {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title.isEmpty ? "Hermes" : run.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    if run.needsAttention {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(IrisActivityLook.color(for: .waiting))
                    }
                    Text(run.needsAttention
                         ? "Waiting for your answer"
                         : (run.headline.isEmpty ? "Working" : run.headline))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(run.needsAttention
                                         ? IrisActivityLook.color(for: .waiting)
                                         : .secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing running")
                    .font(.system(size: 14, weight: .semibold))
                Text(snapshot.hermesReachable ? "Hermes is idle" : "Hermes is not responding")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var countsColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(snapshot.activeCount)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(snapshot.isStale(now: now)
                                     ? AnyShapeStyle(.secondary)
                                     : AnyShapeStyle(IrisActivityLook.color(for: snapshot.phase)))
                Text("active")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if snapshot.waitingCount > 0 {
                Text("\(snapshot.waitingCount) waiting on you")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(IrisActivityLook.color(for: .waiting))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(IrisActivityLook.color(for: .waiting).opacity(0.2))
                    )
            }
        }
        .fixedSize()
    }

    private var footerRow: some View {
        HStack(spacing: 6) {
            if let finished = snapshot.lastFinished {
                let phase = IrisWidgetSnapshot.terminalPhase(finished.status)
                Image(systemName: IrisActivityLook.symbol(for: phase))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IrisActivityLook.color(for: phase))
                Text(finished.title.isEmpty ? "Last run" : finished.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(IrisActivityLook.label(for: phase))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if finished.finishedAt > 0 {
                    Text("· \(IrisRelativeTime.ago(Date(timeIntervalSince1970: finished.finishedAt), now: now))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text("No finished runs yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            // Only while the data is merely ageing: once it is stale the
            // headline above already says "Open Iris to refresh", and saying
            // it twice on one card reads as a bug rather than as emphasis.
            if !snapshot.isStale(now: now) {
                WidgetAgeLine(snapshot: snapshot, now: now)
            }
        }
    }
}

// MARK: - Lock Screen accessories

struct IrisAccessoryRectangularView: View {
    let snapshot: IrisWidgetSnapshot
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: snapshot.isStale(now: now)
                      ? "wifi.exclamationmark"
                      : IrisActivityLook.symbol(for: snapshot.phase))
                    .font(.system(size: 11, weight: .semibold))
                Text("Hermes")
                    .font(.system(size: 12, weight: .semibold))
            }
            if !snapshot.paired {
                Text("Not paired").font(.system(size: 12))
            } else if snapshot.isStale(now: now) {
                Text("Open Iris to refresh").font(.system(size: 12)).lineLimit(1)
            } else if snapshot.waitingCount > 0 {
                Text("\(snapshot.waitingCount) waiting on you").font(.system(size: 12)).lineLimit(1)
            } else if let run = snapshot.activeRun {
                Text(run.headline.isEmpty ? run.title : run.headline)
                    .font(.system(size: 12))
                    .lineLimit(1)
            } else {
                Text("Nothing running").font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IrisAccessoryCircularView: View {
    let snapshot: IrisWidgetSnapshot
    var now: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: snapshot.isStale(now: now)
                  ? "wifi.exclamationmark"
                  : IrisActivityLook.symbol(for: snapshot.phase))
                .font(.system(size: 13, weight: .semibold))
            if snapshot.paired && !snapshot.isStale(now: now) {
                Text("\(snapshot.activeCount)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
        }
        .accessibilityLabel(snapshot.paired
                            ? "\(snapshot.activeCount) active Hermes runs"
                            : "Iris is not paired")
    }
}
