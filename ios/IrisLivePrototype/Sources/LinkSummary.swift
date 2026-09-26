//
//  LinkSummary.swift
//  IrisLivePrototype
//
//  The two routes §14 adds to Iris Link: the widget's cheap summary, and the
//  Live Activity token registrations.
//
//  Kept out of LinkClient.swift because that file is compiled on its own for
//  the macOS probes in Tools/, and these call into types that only exist in
//  the app.
//
//  A Live Activity token is not a credential, but it is a handle to this
//  phone that lets the Mac put something on its lock screen, so it is treated
//  exactly like the APNs device token: sent, never logged, never rendered
//  except through `PushDeviceToken.redacted`.
//

import Foundation

// MARK: - GET /link/summary (§14.6)

/// Deliberately small: counts, two lines, one flag. No step lists, no result
/// text, no output — a home-screen widget has no business holding any of it.
public struct LinkSummary: Sendable, Equatable {

    public struct ActiveRun: Sendable, Equatable {
        public let runId: String
        public let title: String
        /// §12's headline; `""` when the Mac recorded nothing.
        public let headline: String
        public let needsAttention: Bool
    }

    public struct FinishedRun: Sendable, Equatable {
        public let runId: String
        public let title: String
        /// The REAL status word from the desktop.
        public let status: String
        /// Epoch **milliseconds**, as sent.
        public let finishedAtMs: Double
    }

    public let activeCount: Int
    public let waitingCount: Int
    public let finishedTodayCount: Int
    public let activeRun: ActiveRun?
    public let lastFinished: FinishedRun?
    public let hermesReachable: Bool
    /// Epoch **milliseconds** on the Mac, as sent.
    public let generatedAtMs: Double

    public init(
        activeCount: Int, waitingCount: Int, finishedTodayCount: Int,
        activeRun: ActiveRun?, lastFinished: FinishedRun?,
        hermesReachable: Bool, generatedAtMs: Double
    ) {
        self.activeCount = activeCount
        self.waitingCount = waitingCount
        self.finishedTodayCount = finishedTodayCount
        self.activeRun = activeRun
        self.lastFinished = lastFinished
        self.hermesReachable = hermesReachable
        self.generatedAtMs = generatedAtMs
    }

    public init(json: [String: Any]) {
        self.activeCount = LinkTask.integer(json["active_count"]) ?? 0
        self.waitingCount = LinkTask.integer(json["waiting_count"]) ?? 0
        self.finishedTodayCount = LinkTask.integer(json["finished_today_count"]) ?? 0

        if let active = json["active_run"] as? [String: Any],
           let runId = (active["run_id"] as? String), !runId.isEmpty {
            self.activeRun = ActiveRun(
                runId: runId,
                title: (active["title"] as? String) ?? "",
                headline: (active["headline"] as? String) ?? "",
                needsAttention: (active["needs_attention"] as? Bool) ?? false
            )
        } else {
            self.activeRun = nil
        }

        if let finished = json["last_finished"] as? [String: Any],
           let runId = (finished["run_id"] as? String), !runId.isEmpty {
            self.lastFinished = FinishedRun(
                runId: runId,
                title: (finished["title"] as? String) ?? "",
                status: (finished["status"] as? String) ?? "",
                finishedAtMs: LinkTask.number(finished["finished_at"])
            )
        } else {
            self.lastFinished = nil
        }

        self.hermesReachable = (json["hermesReachable"] as? Bool) ?? false
        self.generatedAtMs = LinkTask.number(json["generated_at"])
    }

    /// The snapshot the widget reads, with the route's milliseconds converted
    /// to seconds once. `fetchedAt` is this phone's own clock, so a widget can
    /// still say something when the Mac's `generated_at` is missing.
    func snapshot(macName: String, now: Date = Date()) -> IrisWidgetSnapshot {
        IrisWidgetSnapshot(
            paired: true,
            activeCount: activeCount,
            waitingCount: waitingCount,
            finishedTodayCount: finishedTodayCount,
            activeRun: activeRun.map {
                .init(runId: $0.runId,
                      title: RunTitle.summary(of: $0.title, limit: 80),
                      headline: $0.headline,
                      needsAttention: $0.needsAttention)
            },
            lastFinished: lastFinished.map {
                .init(runId: $0.runId,
                      title: RunTitle.summary(of: $0.title, limit: 80),
                      status: $0.status,
                      finishedAt: $0.finishedAtMs > 0 ? IrisEpoch.seconds($0.finishedAtMs) : 0)
            },
            hermesReachable: hermesReachable,
            generatedAt: generatedAtMs > 0 ? IrisEpoch.seconds(generatedAtMs) : now.timeIntervalSince1970,
            fetchedAt: now.timeIntervalSince1970,
            macName: macName
        )
    }
}

// MARK: - Defaults for services that predate §14

public extension LinkTaskService {

    func summary() async throws -> LinkSummary { throw LinkError.tasksUnavailable }

    func registerLiveActivityStartToken(_ token: String, environment: PushEnvironment) async throws -> Bool {
        throw LinkError.pushUnavailable
    }

    func unregisterLiveActivityStartToken() async throws { throw LinkError.pushUnavailable }

    func registerLiveActivityToken(activityId: String, token: String, environment: PushEnvironment) async throws -> Bool {
        throw LinkError.pushUnavailable
    }

    func unregisterLiveActivity(activityId: String?) async throws { throw LinkError.pushUnavailable }
}

// MARK: - The real implementations

public extension LinkClient {

    /// `GET /link/summary` (§14.6).
    func summary() async throws -> LinkSummary {
        LinkSummary(json: try await request(path: "/link/summary", method: "GET", body: nil))
    }

    /// `PUT /link/live-activity/start-token` (§14.7). Sent on every value of
    /// `pushToStartTokenUpdates`; the token rotates and a stale one is dead.
    @discardableResult
    func registerLiveActivityStartToken(_ token: String, environment: PushEnvironment) async throws -> Bool {
        let json = try await request(
            path: "/link/live-activity/start-token",
            method: "PUT",
            body: ["token": token, "environment": environment.rawValue]
        )
        return (json["pushToStartEnabled"] as? Bool) ?? false
    }

    func unregisterLiveActivityStartToken() async throws {
        _ = try await request(path: "/link/live-activity/start-token", method: "DELETE", body: nil)
    }

    /// `PUT /link/live-activity` (§14.7). Registering the same `activity_id`
    /// again REPLACES its token, which is exactly what `pushTokenUpdates`
    /// hands you mid-activity.
    @discardableResult
    func registerLiveActivityToken(activityId: String, token: String, environment: PushEnvironment) async throws -> Bool {
        let json = try await request(
            path: "/link/live-activity",
            method: "PUT",
            body: ["activity_id": activityId, "token": token, "environment": environment.rawValue]
        )
        return (json["liveActivityEnabled"] as? Bool) ?? false
    }

    /// `DELETE /link/live-activity` — no query string clears every activity
    /// this device registered (the user turned Live Activities off);
    /// `?activity_id=` removes just the one that ended.
    func unregisterLiveActivity(activityId: String?) async throws {
        var path = "/link/live-activity"
        if let activityId, !activityId.isEmpty {
            path += "?activity_id=\(Self.segment(activityId))"
        }
        _ = try await request(path: path, method: "DELETE", body: nil)
    }
}
