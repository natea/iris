//
//  IrisLiveActivityWidget.swift
//  IrisWidgets
//
//  Placement only: the views are in Shared/IrisActivityViews.swift so the app
//  can render them to PNGs and a person can look at them.
//
//  `context.isStale` is ActivityKit telling us the `stale-date` in the last
//  push has passed — the Mac has not reported for two minutes (§14.5). Every
//  presentation below takes it and changes what it says, because the
//  alternative is a spinner that implies Hermes is still working when nobody
//  knows whether it is.
//

import SwiftUI
import WidgetKit
import ActivityKit

struct IrisLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IrisRunActivityAttributes.self) { context in
            LockScreenContainer(
                state: context.state,
                macName: context.attributes.macName,
                isStale: context.isStale
            )
            .widgetURL(Self.link(for: context.state))
            // Deep blue-violet, the app's own background, so the activity
            // reads as Iris and not as a generic notification.
            .activityBackgroundTint(Color(red: 0.07, green: 0.06, blue: 0.16))
            .activitySystemActionForegroundColor(IrisActivityLook.accent)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IrisIslandLeadingView(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IrisIslandTrailingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    IrisIslandCenterView(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IrisIslandBottomView(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                IrisIslandCompactLeadingView(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                IrisIslandCompactTrailingView(state: context.state, isStale: context.isStale)
            } minimal: {
                IrisIslandMinimalView(state: context.state, isStale: context.isStale)
            }
            .widgetURL(Self.link(for: context.state))
            .keylineTint(IrisActivityLook.color(
                for: context.isStale ? .idle : context.state.phase))
        }
    }

    /// Tapping opens the run the activity is about (§14.8). `IrisRunLink`
    /// validates the id, so a payload with a hostile run id opens nothing
    /// rather than something else.
    static func link(for state: IrisRunActivityAttributes.ContentState) -> URL {
        guard let id = state.runs.first?.id, let url = IrisRunLink.run(id) else {
            return IrisRunLink.runs
        }
        return url
    }
}

/// Reads the Always-On environment, which is only available inside a view.
private struct LockScreenContainer: View {
    let state: IrisRunActivityAttributes.ContentState
    let macName: String
    let isStale: Bool

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        IrisActivityLockScreenView(
            state: state,
            macName: macName,
            isStale: isStale,
            isLuminanceReduced: isLuminanceReduced
        )
    }
}
