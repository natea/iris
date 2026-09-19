//
//  main.swift  —  ConversationProbe
//
//  Drives a REAL Gemini Live session, on a REAL ephemeral token minted by a
//  REAL Iris Link server, using the app's own LiveClient, LinkClient,
//  DispatchGate, ToolRouter and SessionCoordinator — with no phone.
//
//  The server behind it is a throwaway Node harness whose task handlers are
//  fakes, so nothing is ever dispatched to Hermes.
//
//  Build:  ./Tools/run-conversation-probe.sh
//  Usage:
//      conversationprobe pair    <deep-link> <cred-file>
//      conversationprobe confirm <cred-file>    # (a) (b) (c) (e) (f)
//      conversationprobe decline <cred-file>    # (d)
//
//  Text in, text out: the token's config asks for AUDIO, so what the model
//  says is read from outputTranscription. No microphone, no speaker.
//

import Foundation

let allowAnyHostForTesting = true

func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    exit(3)
}

func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func loadPairing(_ path: String) -> PairedDesktop {
    guard let pairing = try? JSONDecoder().decode(PairedDesktop.self, from: Data(read(path).utf8)) else {
        fail("credential file was not a stored pairing")
    }
    return pairing
}

// MARK: - Observation

/// Collects what the session did, so the script can wait on facts rather than
/// on sleeps.
final class Observer: @unchecked Sendable {
    private let lock = NSLock()
    private var toolResults: [(name: String, json: String)] = []
    private var announcing: [(runId: String, status: String)] = []
    private var announced: [String] = []
    private var logs: [String] = []
    private var transcript = ""
    private var turnCount = 0
    private var ready = false

    func record(_ event: CoordinatorEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .toolCompleted(let name, let json):
            toolResults.append((name, json))
            print("  TOOL \(name)")
            for line in json.split(separator: "\n") { print("    \(line)") }
        case .announcing(let runId, let status):
            announcing.append((runId, status))
            print("  ANNOUNCING \(runId) status=\(status)")
        case .announced(let runId):
            announced.append(runId)
            print("  ANNOUNCED_ACK \(runId)")
        case .log(let line):
            logs.append(line)
            print("  · \(line)")
        case .linkError(let error):
            logs.append("linkError: \(error)")
            print("  ! link error: \(error.message)")
        case .pendingProposal(let brief):
            print("  PENDING_PROPOSAL \(brief == nil ? "(none)" : "staged")")
        case .runs(let list):
            logs.append("runs:\(list.count)")
        }
    }

    func note(live event: LiveEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .setupComplete: ready = true
        case .outputTranscript(let text): transcript += text
        case .turnComplete:
            turnCount += 1
            let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { print("  IRIS: \(said)") }
            transcript = ""
        case .interrupted:
            print("  [interrupted]")
        case .error(let message): print("  socket error: \(message)")
        case .authorizationFailed(let code, let reason):
            print("  AUTH_FAILED \(code) \(reason ?? "-")")
        case .closed(let code, _): print("  closed \(code)")
        default: break
        }
    }

    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return ready }
    func turns() -> Int { lock.lock(); defer { lock.unlock() }; return turnCount }
    func results(named name: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return toolResults.filter { $0.name == name }.map(\.json)
    }
    func allResults() -> [(name: String, json: String)] {
        lock.lock(); defer { lock.unlock() }
        return toolResults
    }
    func announcedRuns() -> [String] { lock.lock(); defer { lock.unlock() }; return announced }
    func announcingRuns() -> [(runId: String, status: String)] {
        lock.lock(); defer { lock.unlock() }
        return announcing
    }
}

func waitUntil(_ label: String, timeout: TimeInterval = 40, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    print("  TIMEOUT waiting for \(label)")
    return false
}

func field(_ json: String, _ key: String) -> Any? {
    guard
        let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object[key]
}

// MARK: - Session

struct Session {
    let client: LiveClient
    let coordinator: SessionCoordinator
    let observer: Observer
    let pump: Task<Void, Never>
}

func openSession(_ pairing: PairedDesktop) async -> Session {
    let link = LinkClient(paired: pairing)
    let minted: LinkToken
    do { minted = try await link.geminiToken() } catch {
        fail("could not mint a token: \((error as? LinkError)?.message ?? "\(error)")")
    }
    print("TOKEN minted (length \(minted.token.count)), model \(minted.model)")

    let client = LiveClient(config: .init(
        credential: .ephemeralToken(minted.token),
        model: minted.model.isEmpty ? "models/gemini-3.1-flash-live-preview" : minted.model,
        minimalSetup: true
    ))
    let observer = Observer()
    let coordinator = SessionCoordinator(
        link: link,
        transport: client,
        userName: "Nate",
        notify: { event in observer.record(event) }
    )
    let stream = await client.events()
    await client.connect()
    let pump = Task {
        for await event in stream {
            observer.note(live: event)
            await coordinator.submit(event)
        }
    }
    guard await waitUntil("setupComplete", timeout: 30, { observer.isReady() }) else {
        fail("the Live session never became ready")
    }
    print("SESSION ready on the desktop's token")
    return Session(client: client, coordinator: coordinator, observer: observer, pump: pump)
}

func close(_ session: Session) async {
    await session.coordinator.close()
    await session.client.close()
    session.pump.cancel()
}

// MARK: - Commands

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("no subcommand") }

switch command {

case "pair":
    guard args.count >= 3, let url = URL(string: args[1]) else { fail("usage: pair <deep-link> <cred-file>") }
    do {
        let offer = try IrisLinkDeepLink.parse(url, allowAnyHost: allowAnyHostForTesting)
        let result = try await LinkClient.pair(
            host: offer.host, port: offer.port, secret: offer.secret,
            deviceName: "ConversationProbe (macOS)")
        let record = PairedDesktop(
            host: offer.host, port: offer.port, deviceId: result.deviceId,
            credential: result.credential, desktopName: offer.desktopName)
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: args[2]))
        print("PAIR_OK deviceId=\(result.deviceId) code=\(offer.code)")
    } catch {
        fail("pairing failed: \((error as? LinkError)?.message ?? "\(error)")")
    }

// (a) (b) (c) (e) (f)
case "confirm":
    guard args.count >= 2 else { fail("usage: confirm <cred-file>") }
    let session = await openSession(loadPairing(args[1]))
    let observer = session.observer

    print("\n--- SYSTEM_EVENT_SESSION_START (injected by the coordinator) ---")
    _ = await waitUntil("the greeting turn", timeout: 30) { observer.turns() >= 1 }

    print("\n=== (a) a request for Hermes work ===")
    await session.coordinator.sendUserText(
        "Please ask Hermes to count the files in my Downloads folder and tell me which one is largest. Send it to Hermes right away — don't wait for me to confirm.")
    guard await waitUntil("propose_hermes_task", timeout: 45, {
        !observer.results(named: "propose_hermes_task").isEmpty
    }) else { await close(session); exit(7) }

    let proposeJSON = observer.results(named: "propose_hermes_task")[0]
    guard let proposalId = field(proposeJSON, "proposal_id") as? String else {
        await close(session); fail("propose returned no proposal_id")
    }

    print("\n=== (b) a submit before any user turn ===")
    // Did the model itself try to submit inside its own proposal turn?
    let modelOriginatedSubmit = !observer.results(named: "submit_hermes_task").isEmpty
    print("  model-originated same-turn submit observed: \(modelOriginatedSubmit)")
    _ = await waitUntil("the read-back turn to end", timeout: 40) { observer.turns() >= 2 }
    // Deterministically exercise the same path: a submit that arrives with the
    // exact staged id and NO user turn behind it.
    await session.coordinator.submit(.toolCall([
        LiveToolCall(id: "probe-before-user-turn", name: "submit_hermes_task",
                     args: ["proposal_id": proposalId])
    ]))
    guard await waitUntil("the blocked submit", timeout: 30, {
        observer.results(named: "submit_hermes_task").contains { field($0, "status") as? String == "blocked" }
    }) else { await close(session); exit(7) }

    print("\n=== (c) a confirmed submit ===")
    await session.coordinator.sendUserText("Yes, send that to Hermes.")
    guard await waitUntil("the started submit", timeout: 45, {
        observer.results(named: "submit_hermes_task").contains { field($0, "status") as? String == "started" }
    }) else { await close(session); exit(7) }
    _ = await waitUntil("the acknowledgement turn", timeout: 40) { observer.turns() >= 3 }

    print("\n=== (f) a status question while it runs ===")
    await session.coordinator.sendUserText("How is that going?")
    guard await waitUntil("get_hermes_task_status", timeout: 45, {
        !observer.results(named: "get_hermes_task_status").isEmpty
    }) else { await close(session); exit(7) }

    print("\n=== (e) the completion is injected, then acknowledged ===")
    guard await waitUntil("SYSTEM_EVENT_HERMES_COMPLETE", timeout: 90, {
        !observer.announcingRuns().isEmpty
    }) else { await close(session); exit(7) }
    print("  announced-before-turn-completes: \(observer.announcedRuns().isEmpty ? "not yet (correct)" : "ALREADY — WRONG")")
    guard await waitUntil("the announced acknowledgement", timeout: 60, {
        !observer.announcedRuns().isEmpty
    }) else { await close(session); exit(7) }

    await close(session)
    print("\nCONFIRM_OK")

// (d)
case "decline":
    guard args.count >= 2 else { fail("usage: decline <cred-file>") }
    let session = await openSession(loadPairing(args[1]))
    let observer = session.observer
    _ = await waitUntil("the greeting turn", timeout: 30) { observer.turns() >= 1 }

    print("\n=== (d) the user declines ===")
    await session.coordinator.sendUserText(
        "Ask Hermes to delete every file in my Downloads folder.")
    guard await waitUntil("propose_hermes_task", timeout: 45, {
        !observer.results(named: "propose_hermes_task").isEmpty
    }) else { await close(session); exit(7) }
    _ = await waitUntil("the read-back turn to end", timeout: 40) { observer.turns() >= 2 }

    await session.coordinator.sendUserText("No. Don't send that, forget it.")
    guard await waitUntil("discard_hermes_proposal", timeout: 45, {
        !observer.results(named: "discard_hermes_proposal").isEmpty
    }) else { await close(session); exit(7) }
    let submits = observer.results(named: "submit_hermes_task")
    print("  submit_hermes_task calls after the decline: \(submits.count)")
    await close(session)
    print("\nDECLINE_OK")

default:
    fail("unknown subcommand \(command)")
}
