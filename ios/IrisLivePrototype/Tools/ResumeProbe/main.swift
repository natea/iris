//
//  main.swift  —  ResumeProbe
//
//  Task 4.8, end to end, against the REAL Gemini Live API with the app's own
//  LiveClient, LinkClient, DispatchGate, ToolRouter, SessionCoordinator and
//  ReconnectPolicy — no phone, no microphone.
//
//  It establishes a fact, kills the socket itself (no waiting ten minutes for
//  a real goAway), reconnects, and asks for the fact back. Then it makes the
//  Mac refuse the handle and checks that the app starts a fresh session AND
//  says so out loud.
//
//  Build:  ./Tools/run-resume-probe.sh
//  Usage:
//      resumeprobe pair   <deep-link> <cred-file>
//      resumeprobe resume <cred-file>
//

import Foundation

let allowAnyHostForTesting = true
let SECRET_WORD = "PINEAPPLE"
let ASK_FOR_WORD = "Without any preamble, tell me the single fruit word I asked you to remember earlier in this conversation. If you do not know it, say exactly: I DO NOT KNOW."

func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    exit(3)
}

func loadPairing(_ path: String) -> PairedDesktop {
    guard
        let text = try? String(contentsOfFile: path, encoding: .utf8),
        let pairing = try? JSONDecoder().decode(
            PairedDesktop.self,
            from: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        )
    else { fail("cannot read a stored pairing from \(path)") }
    return pairing
}

// MARK: - Observation

/// Watches one connection at a time and keeps what each one said separately,
/// so "did the reconnect re-greet?" is a question with an answer.
final class Observer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    private(set) var connectionTurns: [[String]] = []
    private(set) var handle: String?
    private var ready = false
    /// -1 until the first connection opens, so connection 1 is index 0.
    private var connection = -1

    func beginConnection() {
        lock.lock(); defer { lock.unlock() }
        connection += 1
        while connectionTurns.count <= connection { connectionTurns.append([]) }
        partial = ""
        ready = false
    }

    func note(_ event: LiveEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .setupComplete:
            ready = true
        case .outputTranscript(let text):
            partial += text
        case .turnComplete:
            let said = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            partial = ""
            guard !said.isEmpty else { break }
            connectionTurns[connection].append(said)
            print("  IRIS[c\(connection + 1)]: \(said)")
        case .sessionResumption(let newHandle, let resumable):
            guard resumable, let newHandle, !newHandle.isEmpty else { break }
            // Never print a handle: it is a key to the conversation.
            if handle == nil { print("  (captured a resumable session handle)") }
            handle = newHandle
        case .goAway(let timeLeft):
            print("  goAway timeLeft=\(timeLeft ?? "-")")
        case .authorizationFailed(let code, let reason):
            print("  AUTH_FAILED \(code) \(reason ?? "-")")
        case .closed(let code, let reason):
            print("  closed \(code) \(reason ?? "")")
        case .error(let message):
            print("  socket: \(message)")
        default:
            break
        }
    }

    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return ready }
    func turns(on index: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return index < connectionTurns.count ? connectionTurns[index] : []
    }
    func currentHandle() -> String? { lock.lock(); defer { lock.unlock() }; return handle }
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

// MARK: - Connections

final class ConnectCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    func total() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
let connects = ConnectCounter()

/// Holds the coordinator so a pump started before it exists can still deliver
/// to it. The app has the same arrangement, with the controller as the box.
final class CoordinatorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SessionCoordinator?
    func set(_ coordinator: SessionCoordinator) { lock.lock(); value = coordinator; lock.unlock() }
    func get() -> SessionCoordinator? { lock.lock(); defer { lock.unlock() }; return value }
}
let box = CoordinatorBox()

/// Opens one connection exactly the way `LiveSessionController` does: a fresh
/// single-use token from the Mac, carrying the resume handle when we have one.
func openConnection(
    link: LinkClient,
    observer: Observer,
    resumeHandle: String?
) async -> (client: LiveClient, pump: Task<Void, Never>, resumed: Bool) {
    let minted: LinkToken
    do {
        minted = try await link.geminiToken(resumeHandle: resumeHandle)
    } catch {
        fail("could not mint a token: \((error as? LinkError)?.message ?? "\(error)")")
    }
    _ = connects.bump()
    print("  TOKEN minted (resume requested: \(resumeHandle != nil), desktop resumed: \(minted.resumed))")
    let client = LiveClient(config: .init(
        credential: .ephemeralToken(minted.token),
        model: minted.model.isEmpty ? "models/gemini-3.1-flash-live-preview" : minted.model,
        minimalSetup: true
    ))
    observer.beginConnection()
    let stream = await client.events()
    await client.connect()
    let pump = Task {
        for await event in stream {
            observer.note(event)
            // Everything the socket says reaches the coordinator, exactly as
            // it does in the app. `setupComplete` is delivered by the caller
            // instead, so the probe can order it deterministically.
            if case .setupComplete = event { continue }
            if let coordinator = box.get() { await coordinator.submit(event) }
        }
    }
    return (client, pump, minted.resumed)
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
            deviceName: "ResumeProbe (macOS)")
        let record = PairedDesktop(
            host: offer.host, port: offer.port, deviceId: result.deviceId,
            credential: result.credential, desktopName: offer.desktopName)
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: args[2]))
        print("PAIR_OK deviceId=\(result.deviceId)")
    } catch {
        fail("pairing failed: \((error as? LinkError)?.message ?? "\(error)")")
    }

case "resume":
    guard args.count >= 2 else { fail("usage: resume <cred-file>") }
    let pairing = loadPairing(args[1])
    let link = LinkClient(paired: pairing)
    let observer = Observer()

    // ===== (1) a working conversation that establishes a fact =====
    print("\n=== (1) a fresh session, establishing a fact ===")
    var connection = await openConnection(link: link, observer: observer, resumeHandle: nil)
    let coordinator = SessionCoordinator(
        link: link,
        transport: connection.client,
        userName: "Nate",
        notify: { event in
            if case .log(let line) = event { print("  · \(line)") }
        }
    )
    box.set(coordinator)
    guard await waitUntil("setupComplete", { observer.isReady() }) else { fail("never became ready") }
    await coordinator.handle(.setupComplete)
    guard await waitUntil("the greeting turn", { !observer.turns(on: 0).isEmpty }) else {
        fail("no greeting")
    }
    await coordinator.sendUserText("Please remember this word for later: \(SECRET_WORD). Just say OK.")
    guard await waitUntil("the acknowledgement", { observer.turns(on: 0).count >= 2 }) else {
        fail("the model never acknowledged the word")
    }
    guard await waitUntil("a resumable handle", { observer.currentHandle() != nil }) else {
        fail("the server never offered a session-resumption handle")
    }

    // ===== (2) kill the socket and come back into the SAME conversation =====
    print("\n=== (2) the socket is killed, and the app reconnects ===")
    await coordinator.suspend()
    await connection.client.close()
    connection.pump.cancel()

    connection = await openConnection(link: link, observer: observer, resumeHandle: observer.currentHandle())
    guard connection.resumed else {
        fail("the desktop did not resume — it must accept resume_handle and answer resumed:true")
    }
    await coordinator.reattach(transport: connection.client, resumed: true)
    guard await waitUntil("setupComplete on the new socket", { observer.isReady() }) else {
        fail("the reconnect never became ready")
    }
    await coordinator.handle(.setupComplete)
    // Give a re-greeting the chance to appear, so its absence means something.
    try? await Task.sleep(nanoseconds: 4_000_000_000)
    let unpromptedAfterResume = observer.turns(on: 1)
    print("  unprompted turns after the resume: \(unpromptedAfterResume.count) (expected 0 — no re-greeting)")

    await coordinator.sendUserText(ASK_FOR_WORD)
    guard await waitUntil("the recall answer", {
        observer.turns(on: 1).count > unpromptedAfterResume.count
    }) else { fail("no answer after the reconnect") }
    let recalled = observer.turns(on: 1).dropFirst(unpromptedAfterResume.count).joined(separator: " ")
    let sameConversation = recalled.uppercased().contains(SECRET_WORD)
    print("  SAME CONVERSATION CONTINUED: \(sameConversation ? "YES" : "NO")")

    // ===== (3) the handle is rejected: a fresh session, and Iris says so =====
    print("\n=== (3) the handle is refused — fresh session with a spoken notice ===")
    await coordinator.suspend()
    await connection.client.close()
    connection.pump.cancel()

    connection = await openConnection(link: link, observer: observer, resumeHandle: observer.currentHandle())
    let couldNotResume = !connection.resumed
    print("  desktop could not restore the conversation: \(couldNotResume ? "YES (as arranged)" : "NO")")
    await coordinator.reattach(transport: connection.client, resumed: connection.resumed)
    guard await waitUntil("setupComplete on the fresh socket", { observer.isReady() }) else {
        fail("the fresh session never became ready")
    }
    await coordinator.handle(.setupComplete)
    guard await waitUntil("the spoken notice", { !observer.turns(on: 2).isEmpty }) else {
        fail("the fresh session said nothing — the user was never told")
    }
    let notice = observer.turns(on: 2).joined(separator: " ")

    await coordinator.sendUserText(ASK_FOR_WORD)
    _ = await waitUntil("the post-reset answer", { observer.turns(on: 2).count >= 2 })
    let afterReset = observer.turns(on: 2).dropFirst().joined(separator: " ")
    let contextLost = !afterReset.uppercased().contains(SECRET_WORD)

    await coordinator.close()
    await connection.client.close()
    connection.pump.cancel()

    print("\n--- RESULT ---")
    print("  (2) resumed conversation recalled \(SECRET_WORD): \(sameConversation)")
    print("  (2) no re-greeting on resume: \(unpromptedAfterResume.isEmpty)")
    print("  (3) fresh session announced itself: \(!notice.isEmpty)")
    print("  (3) fresh session had genuinely lost the context: \(contextLost)")
    print("  connections used: \(connects.total())")
    let ok = sameConversation && unpromptedAfterResume.isEmpty && couldNotResume && !notice.isEmpty
    print(ok ? "RESUME_OK" : "RESUME_FAILED")
    exit(ok ? 0 : 7)

default:
    fail("unknown subcommand \(command)")
}
