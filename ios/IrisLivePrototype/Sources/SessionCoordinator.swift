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

/// The staged brief as the screen shows it. The id is what a tap answers for.
public struct StagedProposal: Sendable, Equatable, Identifiable {
    public let id: String
    public let task: String
    public let urgency: String

    public init(id: String, task: String, urgency: String = "normal") {
        self.id = id
        self.task = task
        self.urgency = urgency
    }
}

/// Which on-screen control the user tapped.
public enum ProposalAnswer: String, Sendable, Equatable {
    case yes
    case no
    case explain
}

/// What the tap actually did. Never a guess: `sent` is only returned after the
/// Mac answered with a run id, and every other case means nothing was sent.
public enum ProposalAnswerOutcome: Sendable, Equatable {
    case sent(runId: String)
    /// The same proposal had already been sent — a second tap, or the model's
    /// own submit winning the race. Same run, no second dispatch.
    case alreadySent(runId: String)
    case declined
    case explaining
    /// The brief that button belonged to is not the staged one any more.
    case stale
    /// Nothing was sent; the proposal is still staged. Plain-language reason.
    case failed(message: String)
}

public enum CoordinatorEvent: Sendable {
    /// A human-readable line for the debug log.
    case log(String)
    /// The staged proposal while the gate waits for an answer, or nil.
    ///
    /// It carries the ID as well as the brief because the on-screen answer
    /// buttons act on ONE proposal: the one whose complete brief is on the
    /// card. Without the id a tap could only mean "whatever is staged now",
    /// which is exactly the confusion the spec forbids.
    case pendingProposal(StagedProposal?)
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
    /// Swapped, not replaced, on a reconnect: the coordinator outlives any one
    /// socket so run tracking, the announcement queue and the acknowledged
    /// ledger carry over.
    private var transport: LiveTransport
    private let router: ToolRouter
    private let notify: @Sendable (CoordinatorEvent) -> Void

    private var userName: String
    private var sessionId: String
    /// A resumed session keeps its conversation, so it must not be greeted
    /// again (LINK_API.md §7.1).
    private let isResumedSession: Bool

    // MARK: Connection identity
    //
    // One coordinator, many sockets. Everything that can outlive a socket —
    // a tool call in flight, a queued announcement — is tagged with the
    // connection it belongs to, so a dead socket's work can never be
    // delivered on a live one.

    /// Bumped by every `setupComplete`. Connection 1 is the original session.
    private var connectionEpoch = 0
    /// Whether the connection now open continued the previous conversation.
    private var connectionResumed = false

    // Turn bookkeeping
    private var modelTranscriptChars = 0
    private var userTranscriptBuffer = ""
    private var modelTurnActive = false
    private var userHasSpoken = false
    private var sessionStartInjected = false

    // Announcements
    typealias Announcement = (runId: String, text: String, status: String)
    private var announcementQueue: [Announcement] = []
    /// The announcement currently being spoken. Held whole rather than by id
    /// so a connection reset can put it back at the front of the queue —
    /// LINK_API.md §8 step 4: an interrupted announcement is retried, never
    /// acknowledged.
    private var inFlightAnnouncement: Announcement?
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

    /// Points the coordinator at a new socket after a reconnect, WITHOUT
    /// losing what the conversation has accumulated.
    ///
    /// `resumed` is the desktop's answer about the resumption handle, not a
    /// guess: true only when the Mac minted a token that carried it.
    public func reattach(transport: LiveTransport, resumed: Bool) {
        self.transport = transport
        connectionResumed = resumed
        closed = false
        // Nothing from the dead socket is still in flight, whatever the last
        // frame on it claimed.
        modelTurnActive = false
        modelTranscriptChars = 0
        userTranscriptBuffer = ""
        for task in toolTasks { task.cancel() }
        toolTasks.removeAll()
        // §8 step 4: an announcement the reset cut off was never delivered, so
        // it goes back to the front of the queue instead of being acknowledged.
        if let announcement = inFlightAnnouncement {
            inFlightAnnouncement = nil
            announcementQueue.insert(announcement, at: 0)
            notify(.log("announcement for \(announcement.runId) was cut off by the reset — it will be retried"))
        }
    }

    /// Called once `setupComplete` arrives — on the first connection and on
    /// every reconnect.
    ///
    /// Everything here is best-effort: a failure must degrade the session,
    /// never end it.
    public func sessionReady() async {
        connectionEpoch += 1
        let isReconnect = connectionEpoch > 1

        // WHAT HAPPENS TO THE DISPATCH GATE ACROSS A RECONNECT
        //
        // The staged proposal does NOT survive, on a resumed session either.
        // A resumed session restores the MODEL's view of the conversation; it
        // restores nothing about what this phone observed. The gate's whole
        // job is to prove an ordering — the complete brief was read back, and
        // then the user answered in a turn of their own — and a socket that
        // died somewhere inside that sequence leaves it unprovable. The
        // failure mode of guessing is the one failure this app must never
        // have: a reconnect turning an unconfirmed proposal into a confirmed
        // one. So it is invalidated and Iris has to stage and re-read it.
        //
        // The model is told this in the contract's own words. On a resumed
        // session the stale proposal_id now matches nothing, so a submit is
        // rejected with `no_proposal` ("Stage and read back a complete brief
        // first"). On a fresh session the session id is rotated too, so it is
        // rejected with `session_mismatch` ("Stage and confirm the brief
        // again"). Either way the model re-reads the brief and waits for a
        // real answer.
        if isReconnect && !connectionResumed { sessionId = UUID().uuidString }
        await router.resetSession(sessionId: sessionId)
        if isReconnect {
            notify(.pendingProposal(nil))
            notify(.log("reconnected (\(connectionResumed ? "same conversation" : "new conversation")) — any staged proposal was invalidated"))
        }

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

        if isReconnect {
            // Do NOT re-greet a conversation that is still going. Say
            // something only when the thread was actually lost.
            if !connectionResumed { await injectFreshSessionNotice() }
        } else {
            await injectSessionStart()
        }
        await refreshRuns()
        // §8 step 1 names reconnect explicitly: ask again every time.
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

    /// The spec's "start a fresh session AND say so". Uses §7.1's mechanism —
    /// a client text turn the model already knows how to handle — so the
    /// notice arrives in Iris's own voice rather than as a silent context loss.
    private func injectFreshSessionNotice() async {
        modelTurnActive = true
        notify(.log("→ SYSTEM_EVENT_SESSION_START (conversation could not be restored)"))
        await transport.sendTextTurn(SystemEvent.sessionRestarted(userName: userName), turnComplete: true)
    }

    /// The socket died but the session has not. Stops everything bound to the
    /// dead connection and keeps everything bound to the conversation.
    public func suspend() {
        closed = true
        pollTask?.cancel()
        pollTask = nil
        for task in toolTasks { task.cancel() }
        toolTasks.removeAll()
    }

    public func close() {
        suspend()
        // A pending announcement is deliberately NOT acknowledged: the desktop
        // will offer it again as undelivered on the next session.
        inFlightAnnouncement = nil
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
            // stall playback or capture. Tagged with the connection that asked
            // for it — a result cannot be answered onto a different socket.
            let coordinator = self
            let epoch = connectionEpoch
            let task = Task.detached { await coordinator.run(calls: calls, epoch: epoch) }
            toolTasks.append(task)

        case .toolCallCancellation(let ids):
            await router.cancel(ids: ids)
            notify(.log("tool calls cancelled: \(ids.count)"))

        case .closed, .authorizationFailed:
            // Only the socket is finished. Whether the session is finished is
            // the reconnect manager's call, so this stops short of close().
            suspend()

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
        if let announcement = inFlightAnnouncement {
            inFlightAnnouncement = nil
            if interrupted {
                notify(.log("announcement for \(announcement.runId) was interrupted — not acknowledged"))
            } else {
                await acknowledge(runId: announcement.runId)
            }
        }

        modelTurnActive = false
        modelTranscriptChars = 0
        userTranscriptBuffer = ""
        await publishPendingProposal()
        await drainAnnouncements()
    }

    /// True while cutting the socket would talk over somebody: Iris is
    /// mid-turn, an announcement is being delivered, or the user is partway
    /// through an utterance the server has not closed off yet. The proactive
    /// `goAway` reconnect waits on this, up to the server's own deadline.
    public func isMidTurn() -> Bool {
        modelTurnActive
            || inFlightAnnouncement != nil
            || !userTranscriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func publishPendingProposal() async {
        guard let staged = await router.pendingProposal() else {
            notify(.pendingProposal(nil))
            return
        }
        notify(.pendingProposal(StagedProposal(id: staged.id, task: staged.task, urgency: staged.urgency)))
    }

    // MARK: Answers given by tapping
    //
    // SECURITY INVARIANT: `answerStagedProposal` is called from exactly one
    // place — the SwiftUI action closures of the answer buttons, by way of
    // `LiveSessionController.answerPendingProposal`. Nothing the model emits
    // reaches it: `handle(_:)` above routes model output to the router's tool
    // dispatch and to the gates' turn observers, never here.

    /// Acts on the proposal whose complete brief is on screen, then tells Iris
    /// what happened so she acknowledges instead of dispatching again.
    ///
    /// The system event is injected only AFTER the outcome is known, because
    /// its text asserts what the phone has already done. Telling Iris the task
    /// was sent and only then trying to send it is the one ordering that could
    /// make her lie.
    public func answerStagedProposal(
        _ answer: ProposalAnswer,
        proposalId: String
    ) async -> ProposalAnswerOutcome {
        switch answer {
        case .yes:
            let outcome = await router.confirmByUserControl(proposalId: proposalId)
            await publishPendingProposal()
            switch outcome {
            case .dispatched(let runId, let task):
                track(runId: runId, note: task)
                notify(.log("Yes button → dispatched \(runId)"))
                await inject(SystemEvent.userConfirmedByButton(
                    proposalId: proposalId, runId: runId, userName: userName))
                return .sent(runId: runId)
            case .alreadyDispatched(let runId):
                // Iris was already told by the `started` result she got, or by
                // the first tap's event. A second notice would make her
                // acknowledge the same task twice.
                track(runId: runId)
                notify(.log("Yes button → \(runId) was already sent; no second dispatch"))
                return .alreadySent(runId: runId)
            case .stale:
                notify(.log("Yes button → that brief is no longer staged; nothing sent"))
                return .stale
            case .failed(let message):
                notify(.log("Yes button → dispatch failed; the brief is still staged"))
                return .failed(message: message)
            }

        case .no:
            guard await router.declineByUserControl(proposalId: proposalId) else {
                await publishPendingProposal()
                return .stale
            }
            await publishPendingProposal()
            notify(.log("No button → proposal discarded; nothing sent"))
            await inject(SystemEvent.userDeclinedByButton(
                proposalId: proposalId, userName: userName))
            return .declined

        case .explain:
            guard await router.isStagedByUserControl(proposalId: proposalId) else { return .stale }
            // Deliberately no gate change: the proposal stays staged, unsent
            // and still confirmable, and any amended brief will have to be
            // staged and confirmed again like every other one.
            notify(.log("Let me explain → still staged, nothing sent"))
            await inject(SystemEvent.userWantsToExplainByButton(
                proposalId: proposalId, userName: userName))
            return .explaining
        }
    }

    /// Tells Iris that a Hermes approval was answered by tapping, so she stops
    /// asking about it and never calls `approve_hermes_action` for it.
    /// Called only from the approval buttons' action closures.
    public func announceApprovalAnswer(
        runId: String,
        requestId: String,
        decision: String,
        summary: String
    ) async {
        notify(.log("approval \(decision) by button → \(runId)"))
        await inject(SystemEvent.userAnsweredApprovalByButton(
            runId: runId, requestId: requestId, decision: decision,
            summary: summary, userName: userName))
    }

    /// §7's mechanism: a client text turn, role user, `turnComplete: true`.
    /// The same one every other system event rides on.
    private func inject(_ text: String) async {
        guard !closed else { return }
        modelTurnActive = true
        modelTranscriptChars = 0
        notify(.log("→ \(text.prefix(40))"))
        await transport.sendTextTurn(text, turnComplete: true)
    }

    // MARK: Tool calls

    private func run(calls: [LiveToolCall], epoch: Int) async {
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
        // The socket that asked is gone. Its call ids mean nothing to the new
        // connection, and the model there is not waiting for them, so these
        // results are dropped rather than answered onto the wrong session.
        guard epoch == connectionEpoch else {
            notify(.log("dropped \(responses.count) tool result(s) belonging to a closed connection"))
            return
        }
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
        guard inFlightAnnouncement?.runId != runId else { return }
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
        guard !closed, inFlightAnnouncement == nil, !modelTurnActive else { return }
        guard !announcementQueue.isEmpty else { return }
        let next = announcementQueue.removeFirst()
        inFlightAnnouncement = next
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
