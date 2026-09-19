//
//  SessionCoordinator.swift
//  IrisLivePrototype
//
//  The non-UI half of a paired session: it turns Live events into gate
//  transitions, runs tool calls off the audio path, polls the runs this phone
//  dispatched, and injects the contract's system events (LINK_API.md §7–§9).
//
//  It is deliberately Foundation-only and free of SwiftUI and AVFoundation, so
//  the macOS CLI probe in Tools/ConversationProbe drives the exact same code
//  the phone runs.
//

import Foundation

// MARK: - What the UI is told

public enum CoordinatorEvent: Sendable {
    /// A human-readable line for the debug log.
    case log(String)
    /// The staged brief while the gate waits for confirmation, or nil.
    case pendingProposal(String?)
    /// The run list changed (dispatched, polled, or refreshed).
    case runs([LinkTask])
    /// A tool call finished. `json` is the exact `response` object sent back
    /// to the model, which is what the contract fixes.
    case toolCompleted(name: String, json: String)
    /// A completion was injected into the Live session for this run.
    case announcing(runId: String, status: String)
    /// The announcement turn completed and `announced` was acknowledged.
    case announced(runId: String)
    /// Iris Link refused or could not be reached. `clearsPairing` decides
    /// whether the UI must return to pairing.
    case linkError(LinkError)
}

// MARK: - Coordinator

public actor SessionCoordinator {

    /// LINK_API.md §9 — the desktop's own polling interval for an active run.
    public static let activePollInterval: TimeInterval = 2.0
    /// 1 s, 2 s, 4 s … capped at 30 s.
    public static let maxBackoff: TimeInterval = 30.0

    /// The desktop's `MIN_AUDIBLE_READBACK_CHARS`. A barge-in after this much
    /// of the read-back was already spoken is treated as a completed turn;
    /// a genuinely early interruption still invalidates the proposal.
    public static let minAudibleReadbackChars = 48

    private let link: LinkTaskService
    private let transport: LiveTransport
    private let router: ToolRouter
    private let notify: @Sendable (CoordinatorEvent) -> Void

    private var userName: String
    private let sessionId: String
    /// A resumed session keeps its conversation, so it must not be greeted
    /// again (LINK_API.md §7.1).
    private let isResumedSession: Bool

    // Turn bookkeeping
    private var modelTranscriptChars = 0
    private var userTranscriptBuffer = ""
    private var modelTurnActive = false
    private var userHasSpoken = false
    private var sessionStartInjected = false

    // Announcements
    private var announcementQueue: [(runId: String, text: String, status: String)] = []
    private var pendingAnnouncement: String?
    private var announcedRuns: Set<String> = []

    // Run tracking
    private var trackedRuns: Set<String> = []
    private var cyclesSinceUndeliveredCheck = 0
    /// With a 2 s poll this asks the Mac for unannounced completions every ~6 s.
    static let undeliveredCheckEveryCycles = 3
    private var pollTask: Task<Void, Never>?
    private var toolTasks: [Task<Void, Never>] = []
    private var closed = false

    public init(
        link: LinkTaskService,
        transport: LiveTransport,
        userName: String = "the user",
        sessionId: String = UUID().uuidString,
        isResumedSession: Bool = false,
        settleInterval: TimeInterval = 0.04,
        settleTimeout: TimeInterval = 1.6,
        notify: @escaping @Sendable (CoordinatorEvent) -> Void = { _ in }
    ) {
        self.link = link
        self.transport = transport
        self.userName = userName
        self.sessionId = sessionId
        self.isResumedSession = isResumedSession
        self.notify = notify
        self.router = ToolRouter(
            link: link,
            userName: userName,
            sessionId: sessionId,
            settleInterval: settleInterval,
            settleTimeout: settleTimeout
        )
    }

    public var toolRouter: ToolRouter { router }

    // MARK: Lifecycle

    /// Called once `setupComplete` arrives. Everything here is best-effort:
    /// a failure must degrade the session, never end it.
    public func sessionReady() async {
        await router.resetSession(sessionId: sessionId)
        let coordinator = self
        await router.setOnDispatch { result, task in
            Task { await coordinator.track(runId: result.runId, note: task) }
        }

        if let status = try? await link.status() {
            if !status.userName.isEmpty {
                userName = status.userName
                await router.setUserName(status.userName)
            }
        }

        await injectSessionStart()
        await refreshRuns()
        await loadUndelivered()
        startPolling()
    }

    private func injectSessionStart() async {
        guard !sessionStartInjected, !userHasSpoken, !isResumedSession else { return }
        sessionStartInjected = true
        modelTurnActive = true
        notify(.log("→ SYSTEM_EVENT_SESSION_START"))
        await transport.sendTextTurn(SystemEvent.sessionStart(userName: userName), turnComplete: true)
    }

    public func close() {
        closed = true
        pollTask?.cancel()
        pollTask = nil
        for task in toolTasks { task.cancel() }
        toolTasks.removeAll()
        // A pending announcement is deliberately NOT acknowledged: the desktop
        // will offer it again as undelivered on the next session.
        pendingAnnouncement = nil
    }

    // MARK: Live events

    private var queue: [LiveEvent] = []
    private var draining = false

    /// Ordered, non-blocking hand-off. The caller (a serial `for await` over
    /// the socket's event stream) returns immediately; the coordinator works
    /// through the events in the order they arrived, which the gate depends
    /// on. Awaiting `handle` directly from the audio pump would stall playback
    /// on a network call.
    public func submit(_ event: LiveEvent) {
        queue.append(event)
        guard !draining else { return }
        draining = true
        let coordinator = self
        Task { await coordinator.drainQueue() }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let event = queue.removeFirst()
            await handle(event)
        }
        draining = false
    }

    public func handle(_ event: LiveEvent) async {
        switch event {
        case .setupComplete:
            await sessionReady()

        case .inputTranscript(let text):
            userHasSpoken = true
            userTranscriptBuffer += text
            let trimmed = userTranscriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            await router.userTurnObserved(
                trimmed,
                allowDuringReadback: modelTranscriptChars >= Self.minAudibleReadbackChars
            )
            await publishPendingProposal()

        case .outputTranscript(let text):
            modelTurnActive = true
            modelTranscriptChars += text.count

        case .text:
            modelTurnActive = true

        case .audio:
            modelTurnActive = true

        case .turnComplete:
            await endModelTurn(interrupted: false)

        case .interrupted:
            await endModelTurn(interrupted: true)

        case .toolCall(let calls):
            // Never on the audio path: a tool call that takes seconds must not
            // stall playback or capture.
            let coordinator = self
            let task = Task.detached { await coordinator.run(calls: calls) }
            toolTasks.append(task)

        case .toolCallCancellation(let ids):
            await router.cancel(ids: ids)
            notify(.log("tool calls cancelled: \(ids.count)"))

        case .closed, .authorizationFailed:
            close()

        default:
            break
        }
    }

    private func endModelTurn(interrupted: Bool) async {
        let audible = modelTranscriptChars >= Self.minAudibleReadbackChars
        if interrupted && !audible {
            await router.modelTurnInterrupted()
        } else {
            await router.modelTurnComplete()
        }

        // LINK_API.md §8 step 3/4: acknowledge ONLY a completed announcement.
        if let runId = pendingAnnouncement {
            pendingAnnouncement = nil
            if interrupted {
                notify(.log("announcement for \(runId) was interrupted — not acknowledged"))
            } else {
                await acknowledge(runId: runId)
            }
        }

        modelTurnActive = false
        modelTranscriptChars = 0
        userTranscriptBuffer = ""
        await publishPendingProposal()
        await drainAnnouncements()
    }

    private func publishPendingProposal() async {
        notify(.pendingProposal(await router.pendingProposal()?.task))
    }

    // MARK: Tool calls

    private func run(calls: [LiveToolCall]) async {
        var responses: [LiveFunctionResponse] = []
        for call in calls {
            guard let response = await router.handle(call) else {
                notify(.log("tool \(call.name) cancelled before its result was sent"))
                continue
            }
            notify(.toolCompleted(name: call.name, json: Self.pretty(response)))
            responses.append(.init(id: call.id, name: call.name, response: response))
        }
        await publishPendingProposal()
        guard !responses.isEmpty, !closed else { return }
        await transport.sendToolResponses(responses)
    }

    static func pretty(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "\(object)" }
        return text
    }

    /// A typed user turn. The phone's users speak, and the gate observes them
    /// through `inputTranscription`; the CLI probe types, and a typed answer
    /// is just as much a turn of the user's own. Recorded before it is sent so
    /// the ordering the gate checks is the real one.
    public func sendUserText(_ text: String) async {
        userHasSpoken = true
        await router.userTurnObserved(text)
        await publishPendingProposal()
        modelTurnActive = true
        modelTranscriptChars = 0
        await transport.sendTextTurn(text, turnComplete: true)
    }

    // MARK: Run tracking

    public func track(runId: String, note: String = "") {
        guard !runId.isEmpty else { return }
        trackedRuns.insert(runId)
        notify(.log("tracking run \(runId)\(note.isEmpty ? "" : " — \(note.prefix(60))")"))
        startPolling()
    }

    public func refreshRuns() async {
        do {
            notify(.runs(try await link.listTasks(undelivered: false)))
        } catch let error as LinkError {
            notify(.linkError(error))
        } catch {
            notify(.log("could not list runs"))
        }
    }

    /// LINK_API.md §8 step 1: on connect, foreground and reconnect.
    public func loadUndelivered() async {
        do {
            let pending = try await link.listTasks(undelivered: true)
            // Oldest first.
            for entry in pending.sorted(by: { $0.updatedAt < $1.updatedAt }) {
                await enqueueAnnouncement(for: entry.runId, status: entry.status)
            }
            await drainAnnouncements()
        } catch let error as LinkError {
            notify(.linkError(error))
        } catch {
            notify(.log("could not fetch undelivered completions"))
        }
    }

    private func startPolling() {
        guard pollTask == nil, !closed else { return }
        let coordinator = self
        pollTask = Task { await coordinator.pollLoop() }
    }

    private func pollLoop() async {
        var backoff: TimeInterval = 0
        while !closed && !Task.isCancelled {
            let wait = backoff > 0 ? backoff : Self.activePollInterval
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if closed || Task.isCancelled { return }
            // Runs this session did not dispatch — queued in an earlier session,
            // still working when this one began — are in nobody's tracked set.
            // The desktop's undelivered list is the durable source of truth, so
            // ask it throughout the session, not only at the start. (Observed on
            // device: a run finished mid-conversation and was never announced.)
            cyclesSinceUndeliveredCheck += 1
            if cyclesSinceUndeliveredCheck >= Self.undeliveredCheckEveryCycles {
                cyclesSinceUndeliveredCheck = 0
                await loadUndelivered()
            }
            guard !trackedRuns.isEmpty else { continue }
            var failed = false
            for runId in trackedRuns {
                do {
                    let status = try await link.taskStatus(runId: runId)
                    // A polling failure must never downgrade a run: only a real
                    // terminal status from the Mac stops the tracking.
                    if let failure = status.error, !failure.isEmpty { continue }
                    if status.isTerminal {
                        trackedRuns.remove(runId)
                        await enqueueAnnouncement(for: runId, status: status.status)
                    }
                } catch LinkError.notPaired {
                    notify(.linkError(.notPaired))
                    close()
                    return
                } catch {
                    failed = true
                }
            }
            backoff = failed ? min(max(backoff * 2, 1), Self.maxBackoff) : 0
            await refreshRuns()
            await drainAnnouncements()
        }
    }

    // MARK: Announcements

    private func enqueueAnnouncement(for runId: String, status: String) async {
        guard !announcedRuns.contains(runId) else { return }
        // Being spoken right now: the periodic undelivered check still lists it
        // until the turn completes, and it must not be queued a second time.
        guard pendingAnnouncement != runId else { return }
        guard !announcementQueue.contains(where: { $0.runId == runId }) else { return }
        // The result is fetched before the turn is injected: the model must
        // never be asked to summarize something the phone has not read.
        var output = ""
        var finalStatus = status
        do {
            let result = try await link.taskResult(runId: runId)
            output = result.output
            if !result.status.isEmpty { finalStatus = result.status }
        } catch LinkError.taskNotFinished {
            return
        } catch {
            // The status line carries the failure; do not dress it up.
            output = "(The stored result could not be read from the Mac.)"
        }
        announcementQueue.append((
            runId: runId,
            text: SystemEvent.hermesComplete(
                runId: runId,
                status: finalStatus,
                output: output,
                userName: userName
            ),
            status: finalStatus
        ))
    }

    private func drainAnnouncements() async {
        guard !closed, pendingAnnouncement == nil, !modelTurnActive else { return }
        guard !announcementQueue.isEmpty else { return }
        let next = announcementQueue.removeFirst()
        pendingAnnouncement = next.runId
        modelTurnActive = true
        notify(.announcing(runId: next.runId, status: next.status))
        notify(.log("→ SYSTEM_EVENT_HERMES_COMPLETE \(next.runId) (\(next.status))"))
        await transport.sendTextTurn(next.text, turnComplete: true)
    }

    private func acknowledge(runId: String) async {
        do {
            try await link.markAnnounced(runId: runId)
            announcedRuns.insert(runId)
            notify(.announced(runId: runId))
        } catch LinkError.taskUnknown {
            // Safe to ignore per LINK_API.md §8.
            announcedRuns.insert(runId)
        } catch {
            notify(.log("could not acknowledge \(runId); it will be offered again"))
        }
    }
}
