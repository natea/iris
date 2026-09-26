//
//  IrisSummaryWidget.swift
//  IrisWidgets
//
//  The home-screen widget. It reads ONE file out of the App Group container
//  and draws it (LINK_API.md §14.6). No credential, no network, no Keychain.
//
//  The reload policy is the contract's: 15 minutes normally, 5 while Hermes
//  has something running. iOS honours these approximately and on its own
//  budget — it will refuse to be pushed faster — which is exactly why every
//  view says how old its data is instead of implying it is live.
//

import SwiftUI
import WidgetKit

struct IrisSummaryEntry: TimelineEntry {
    let date: Date
    let snapshot: IrisWidgetSnapshot
}

struct IrisSummaryProvider: TimelineProvider {

    /// The placeholder is redacted by the system anyway; it exists to give the
    /// gallery a shape, so it shows a plausible busy state rather than zeroes.
    func placeholder(in context: Context) -> IrisSummaryEntry {
        IrisSummaryEntry(date: Date(), snapshot: IrisWidgetSnapshot.preview(.active))
    }

    func getSnapshot(in context: Context, completion: @escaping (IrisSummaryEntry) -> Void) {
        let now = Date()
        // In the widget gallery there is nothing real to show and an empty
        // card is a poor advertisement, so the gallery gets the sample. A
        // placed widget always gets the truth, including "no data yet".
        let stored = IrisWidgetStore().load()
        let snapshot = context.isPreview ? (stored ?? .preview(.active)) : (stored ?? .unpaired)
        completion(IrisSummaryEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IrisSummaryEntry>) -> Void) {
        let now = Date()
        let snapshot = IrisWidgetStore().load() ?? .unpaired
        // A second entry at the point the data crosses into "aging" means the
        // "as of" line appears on time even if iOS never reloads us.
        var entries = [IrisSummaryEntry(date: now, snapshot: snapshot)]
        if let generated = snapshot.generatedAtDate {
            let ageing = generated.addingTimeInterval(IrisWidgetSnapshot.agingAfter)
            let stale = generated.addingTimeInterval(IrisWidgetSnapshot.staleAfter)
            for boundary in [ageing, stale] where boundary > now {
                entries.append(IrisSummaryEntry(date: boundary, snapshot: snapshot))
            }
        }
        let next = snapshot.activeCount > 0 ? 5.0 * 60 : 15.0 * 60
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(next))))
    }
}

struct IrisSummaryWidget: Widget {
    static let kind = "app.iris.liveprototype.summary"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: IrisSummaryProvider()) { entry in
            IrisSummaryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.08, blue: 0.19),
                            Color(red: 0.05, green: 0.06, blue: 0.13),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .configurationDisplayName("Hermes")
        .description("What Hermes is working on, as of the last time Iris checked.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryRectangular, .accessoryCircular,
        ])
    }
}

struct IrisSummaryWidgetView: View {
    let entry: IrisSummaryEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            IrisSmallWidgetView(snapshot: entry.snapshot, now: entry.date)
                .widgetURL(link)
        case .accessoryRectangular:
            IrisAccessoryRectangularView(snapshot: entry.snapshot, now: entry.date)
                .widgetURL(link)
        case .accessoryCircular:
            IrisAccessoryCircularView(snapshot: entry.snapshot, now: entry.date)
                .widgetURL(link)
        default:
            IrisMediumWidgetView(snapshot: entry.snapshot, now: entry.date)
                .widgetURL(link)
        }
    }

    /// The active run when there is one — the thing a tap is most likely
    /// about — otherwise the run list, and the app itself when unpaired.
    private var link: URL {
        guard entry.snapshot.paired else { return IrisRunLink.open }
        if let id = entry.snapshot.activeRun?.runId, let url = IrisRunLink.run(id) { return url }
        if let id = entry.snapshot.lastFinished?.runId, let url = IrisRunLink.run(id) { return url }
        return IrisRunLink.runs
    }
}
