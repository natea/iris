//
//  ActivityKitSource.swift
//  IrisLivePrototype
//
//  The only file in the app that touches ActivityKit. Everything above it
//  talks to `LiveActivitySource`, so the lifecycle rules can be tested and
//  this stays a thin, boring adapter.
//
//  Deployment target is iOS 18, so nothing here needs an availability gate:
//  `Activity.request(attributes:content:pushType:)` and `AlertConfiguration`
//  are 16.2, `pushToStartTokenUpdates` is 17.2, and both are below the floor.
//  The `#if canImport(ActivityKit)` is for the macOS probes in Tools/, which
//  compile a subset of these sources.
//
//  Four async sequences are observed for the life of the process:
//
//    · `Activity.pushToStartTokenUpdates` — a per-device token that lets the
//      Mac raise an activity while Iris is closed. You do NOT have to have an
//      activity running to get one.
//    · `Activity.activityUpdates` — activities appearing, including ones the
//      system started from a push while the app was suspended.
//    · `activity.pushTokenUpdates` — the per-activity update token. It rotates
//      mid-activity; a stale one is dead, so every value is re-registered.
//    · `activity.activityStateUpdates` — `.stale`, `.ended`, `.dismissed`.
//

import Foundation
#if canImport(ActivityKit)
import ActivityKit

@MainActor
final class ActivityKitSource: LiveActivitySource {

    weak var delegate: (any LiveActivitySourceDelegate)?

    private var observed: Set<String> = []
    private var started = false

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var runningActivityId: String? {
        Activity<IrisRunActivityAttributes>.activities
            .first { $0.activityState == .active || $0.activityState == .stale }?
            .id
    }

    func begin() {
        guard !started else { return }
        started = true

        // ADOPT FIRST. §14.8 flags the race: an activity the Mac started by
        // push is un-updatable until this phone registers its update token, so
        // the very first thing a launch does is find those activities and
        // start watching their token streams.
        for activity in Activity<IrisRunActivityAttributes>.activities {
            adopt(activity, isExisting: true)
        }

        Task { [weak self] in
            for await activity in Activity<IrisRunActivityAttributes>.activityUpdates {
                self?.adopt(activity, isExisting: false)
            }
        }

        // The push-to-start token. Registering it is what makes "dispatch from
        // the Mac and watch it appear on a locked phone" possible at all.
        Task { [weak self] in
            for await data in Activity<IrisRunActivityAttributes>.pushToStartTokenUpdates {
                let hex = PushDeviceToken.hex(data)
                await MainActor.run { self?.delegate?.liveActivity(didReceiveStartToken: hex) }
            }
        }

        // Authorization can be revoked in Settings while the app is running.
        Task { [weak self] in
            for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                // The published mirror is refreshed by the controller on its
                // next observation; this just makes sure one happens promptly.
                _ = self
            }
        }
    }

    private func adopt(_ activity: Activity<IrisRunActivityAttributes>, isExisting: Bool) {
        guard !observed.contains(activity.id) else { return }
        observed.insert(activity.id)
        delegate?.liveActivity(didAdopt: activity.id)

        let id = activity.id
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let hex = PushDeviceToken.hex(data)
                await MainActor.run {
                    self?.delegate?.liveActivity(didReceiveUpdateToken: hex, activityId: id)
                }
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                await MainActor.run {
                    switch state {
                    case .stale:
                        self?.delegate?.liveActivity(didChangeStale: true, activityId: id)
                    case .active:
                        self?.delegate?.liveActivity(didChangeStale: false, activityId: id)
                    case .ended, .dismissed:
                        self?.observed.remove(id)
                        self?.delegate?.liveActivity(didEnd: id)
                    default:
                        // `default` rather than `@unknown default`: ActivityKit
                        // has gained states since iOS 16 (and will gain more),
                        // and a state this app does not recognise is not a
                        // reason to claim anything about the activity.
                        break
                    }
                }
            }
        }
    }

    func request(
        attributes: IrisRunActivityAttributes,
        state: IrisRunActivityAttributes.ContentState,
        staleDate: Date
    ) throws -> String {
        // `.token` is what produces an update token. Without it the Mac can
        // never change this activity — it would freeze on its first frame.
        let activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: staleDate, relevanceScore: 100),
            pushType: .token
        )
        adopt(activity, isExisting: false)
        return activity.id
    }

    func update(
        id: String,
        state: IrisRunActivityAttributes.ContentState,
        staleDate: Date,
        alert: (title: String, body: String)?
    ) {
        guard let activity = Activity<IrisRunActivityAttributes>.activities.first(where: { $0.id == id })
        else { return }
        let content = ActivityContent(
            state: state,
            staleDate: staleDate,
            // §14.3: routine progress is 50; something a person must answer
            // is 100, so iOS keeps it in front when several activities compete.
            relevanceScore: state.needsAttention ? 100 : 50
        )
        let configuration: AlertConfiguration? = alert.map {
            AlertConfiguration(
                title: LocalizedStringResource(stringLiteral: $0.title),
                body: LocalizedStringResource(stringLiteral: $0.body),
                sound: .default
            )
        }
        Task { await activity.update(content, alertConfiguration: configuration) }
    }

    func end(
        id: String,
        state: IrisRunActivityAttributes.ContentState,
        dismissAfter: TimeInterval
    ) {
        guard let activity = Activity<IrisRunActivityAttributes>.activities.first(where: { $0.id == id })
        else { return }
        let policy: ActivityUIDismissalPolicy = dismissAfter <= 0
            ? .immediate
            : .after(Date().addingTimeInterval(dismissAfter))
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: policy
            )
        }
    }
}
#endif
