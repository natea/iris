//
//  main.swift  —  ButtonProbe
//
//  Proves the ANSWER BUTTONS end to end, from macOS, with no phone: a real
//  Gemini Live session on a real ephemeral token minted by a real Iris Link
//  server, driving the app's own LiveClient, LinkClient, DispatchGate,
//  ToolRouter and SessionCoordinator.
//
//  The one thing it fakes is the phone's finger. `SessionCoordinator
//  .answerStagedProposal(_:proposalId:)` is the exact method the SwiftUI
//  button closure calls — the probe calls it directly, so what is measured
//  here is the same path a tap takes on the device.
//
//  The Link server behind it is the throwaway Node harness, whose dispatch
//  handler is a fake, so nothing ever reaches Hermes.
//
//  Build:  ./Tools/run-button-probe.sh
//  Usage:
//      buttonprobe pair <deep-link> <cred-file>
//      buttonprobe yes  <cred-file>   # tap Yes: exactly one dispatch
//      buttonprobe no   <cred-file>   # tap No: zero dispatches
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

func field(_ json: String, _ key: String) -> Any? {
    guard
        let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object[key]
}

// MARK: - Observation

final class Observer: @unchecked Sendable {
    private let lock = NSLock()
    private var toolResults: [(name: String, json: String)] = []
    private var transcript = ""
    private var turns: [String] = []
    private var ready = false

    func record(_ event: CoordinatorEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .toolCompleted(let name, let json):
            toolResults.append((name, json))
            print("  TOOL \(name)")
            for line in json.split(separator: "\n") { print("    \(line)") }
        case .log(let line):
            print("  · \(line)")
        case .pendingProposal(let staged):
            print("  PENDING_PROPOSAL \(staged.map { "staged id=\($0.id)" } ?? "(none)")")
        case .linkError(let error):
            print("  ! link error: \(error.message)")
        default:
            break
        }
    }

    func note(live event: LiveEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .setupComplete: ready = true
        case .outputTranscript(let text): transcript += text
        case .turnComplete:
            let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = ""
            guard !said.isEmpty else { return }
            turns.append(said)
            print("  IRIS: \(said)")
        case .interrupted: print("  [interrupted]")
        case .error(let message): print("  socket error: \(message)")
        case .closed(let code, _): print("  closed \(code)")
        default: break
        }
    }

    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return ready }
    func turnCount() -> Int { lock.lock(); defer { lock.unlock() }; return turns.count }
    func spoken() -> [String] { lock.lock(); defer { lock.unlock() }; return turns }
    func results(named name: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return toolResults.filter { $0.name == name }.map(\.json)
    }
}

func waitUntil(_ label: String, timeout: TimeInterval = 45, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    print("  TIMEOUT waiting for \(label)")
    return false
}

// MARK: - Session

struct Session {
    let client: LiveClient
    let link: LinkClient
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
        link: link, transport: client, userName: "Nate",
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
    return Session(client: client, link: link, coordinator: coordinator, observer: observer, pump: pump)
}

func close(_ session: Session) async {
    await session.coordinator.close()
    await session.client.close()
    session.pump.cancel()
}

/// Runs this device has dispatched, straight from the Link server. The
/// authority on "how many times did this actually get sent".
func dispatchedRuns(_ session: Session) async -> [LinkTask] {
    (try? await session.link.listTasks(undelivered: false)) ?? []
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
            deviceName: "ButtonProbe (macOS)")
        let record = PairedDesktop(
            host: offer.host, port: offer.port, deviceId: result.deviceId,
            credential: result.credential, desktopName: offer.desktopName)
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: args[2]))
        print("PAIR_OK deviceId=\(result.deviceId) code=\(offer.code)")
    } catch {
        fail("pairing failed: \((error as? LinkError)?.message ?? "\(error)")")
    }

// The green button.
case "yes":
    guard args.count >= 2 else { fail("usage: yes <cred-file>") }
    let session = await openSession(loadPairing(args[1]))
    let observer = session.observer
    _ = await waitUntil("the greeting turn", timeout: 30) { observer.turnCount() >= 1 }

    print("\n=== a real model turn stages a proposal ===")
    await session.coordinator.sendUserText(
        "Please ask Hermes to count the files in my Downloads folder and tell me which one is largest.")
    guard await waitUntil("propose_hermes_task", timeout: 45, {
        !observer.results(named: "propose_hermes_task").isEmpty
    }) else { await close(session); exit(7) }
    let proposeJSON = observer.results(named: "propose_hermes_task")[0]
    guard let proposalId = field(proposeJSON, "proposal_id") as? String,
          let stagedBrief = field(proposeJSON, "task") as? String else {
        await close(session); fail("propose returned no proposal")
    }
    print("STAGED_BRIEF:")
    for line in stagedBrief.split(separator: "\n") { print("  | \(line)") }

    let before = await dispatchedRuns(session).count

    print("\n=== THE YES BUTTON — the same call the SwiftUI closure makes ===")
    // Deliberately WITHOUT a spoken answer: the voice path would refuse this,
    // and the point of the button is that the brief on screen is the proof.
    let outcome = await session.coordinator.answerStagedProposal(.yes, proposalId: proposalId)
    print("OUTCOME \(outcome)")
    guard case .sent(let runId) = outcome else { await close(session); fail("the tap did not send") }

    print("\n=== a second tap on the same brief (double tap) ===")
    let again = await session.coordinator.answerStagedProposal(.yes, proposalId: proposalId)
    print("OUTCOME_AGAIN \(again)")

    // What the Mac actually received.
    let after = await dispatchedRuns(session)
    let mine = after.filter { $0.runId == runId }
    print("\nDISPATCHES_FOR_THIS_PROPOSAL \(mine.count) (runs before: \(before), after: \(after.count))")
    if let run = mine.first {
        print("DISPATCHED_TASK_MATCHES_STAGED_BRIEF \(run.task == stagedBrief)")
    }
    guard mine.count == 1, after.count == before + 1 else {
        await close(session); fail("expected exactly one new run, got \(after.count - before)")
    }

    print("\n=== Iris acknowledges, without sending it again ===")
    _ = await waitUntil("the acknowledgement turn", timeout: 40) { observer.turnCount() >= 3 }
    let submits = observer.results(named: "submit_hermes_task")
    print("submit_hermes_task calls after the tap: \(submits.count)")
    for json in submits { print("  \(json.replacingOccurrences(of: "\n", with: " "))") }
    print("ACKNOWLEDGEMENT: \(observer.spoken().last ?? "(nothing)")")

    await close(session)
    print("\nYES_OK run_id=\(runId)")

// The red button.
case "no":
    guard args.count >= 2 else { fail("usage: no <cred-file>") }
    let session = await openSession(loadPairing(args[1]))
    let observer = session.observer
    _ = await waitUntil("the greeting turn", timeout: 30) { observer.turnCount() >= 1 }

    print("\n=== a real model turn stages a proposal ===")
    await session.coordinator.sendUserText(
        "Ask Hermes to delete every file in my Downloads folder.")
    guard await waitUntil("propose_hermes_task", timeout: 45, {
        !observer.results(named: "propose_hermes_task").isEmpty
    }) else { await close(session); exit(7) }
    guard let proposalId = field(observer.results(named: "propose_hermes_task")[0], "proposal_id") as? String else {
        await close(session); fail("propose returned no proposal_id")
    }
    let before = await dispatchedRuns(session).count

    print("\n=== THE NO BUTTON ===")
    let outcome = await session.coordinator.answerStagedProposal(.no, proposalId: proposalId)
    print("OUTCOME \(outcome)")

    print("\n=== and the model cannot send it afterwards ===")
    await session.coordinator.submit(.toolCall([
        LiveToolCall(id: "probe-after-decline", name: "submit_hermes_task",
                     args: ["proposal_id": proposalId])
    ]))
    _ = await waitUntil("the blocked submit", timeout: 30, {
        observer.results(named: "submit_hermes_task").contains { field($0, "status") as? String == "blocked" }
    })

    _ = await waitUntil("Iris's acknowledgement", timeout: 40) { observer.turnCount() >= 3 }
    let after = await dispatchedRuns(session).count
    print("\nRUNS_BEFORE \(before) RUNS_AFTER \(after)")
    print("ACKNOWLEDGEMENT: \(observer.spoken().last ?? "(nothing)")")
    guard after == before else { await close(session); fail("something was dispatched after a decline") }

    await close(session)
    print("\nNO_OK (zero dispatches)")

default:
    fail("unknown subcommand \(command)")
}
