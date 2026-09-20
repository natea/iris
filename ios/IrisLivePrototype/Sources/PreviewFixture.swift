//
//  PreviewFixture.swift
//  IrisLivePrototype
//
//  Fake state for looking at the UI — in Xcode previews and, with
//  `-uiPreviewState <name>`, in the simulator.
//
//  It is deliberately a *view* input: `MainView` and `RunsScreen` take an
//  optional fixture and prefer it over their controllers when one is present.
//  No controller, client, gate or engine is touched, and the launch argument
//  is only ever read in a DEBUG build, so a release build has no path that can
//  produce one.
//

import Foundation

struct PreviewFixture {
    var state: VoiceState = .listening
    var lines: [LiveSessionController.TranscriptLine] = []
    var runs: [LinkTask] = []
    var pendingProposal: String?
    var errorText: String?
    /// Only used to dress the Settings screen while nothing is really paired.
    var pairedName: String?
    /// Dresses the Settings screen's Voice section (LINK_API.md §13.3) without
    /// a Mac to ask. DEBUG only, like everything else here.
    var voices: [LinkVoice] = []
    var defaultVoice: String = ""
    var accent: String = ""
    var pushConfigured: Bool = false

    /// nil in release, and nil in debug unless `-uiPreviewState <name>` was
    /// passed on launch.
    static func fromLaunchArguments() -> PreviewFixture? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiPreviewState"),
              index + 1 < args.count else { return nil }
        return named(args[index + 1])
        #else
        return nil
        #endif
    }

    /// `-uiPreviewScreen settings|runs` opens that sheet on launch, so a
    /// screenshot can be taken without tapping. DEBUG only.
    static func screenFromLaunchArguments() -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiPreviewScreen"),
              index + 1 < args.count else { return nil }
        return args[index + 1]
        #else
        return nil
        #endif
    }

    static func named(_ name: String) -> PreviewFixture? {
        switch name {
        case "unpaired":  return nil
        case "listening": return .listening
        case "speaking":  return .speaking
        case "working":   return .working
        case "proposal":  return .proposal
        case "error":     return .errored
        case "reconnecting": return .reconnecting
        case "voices":    return .voices
        #if DEBUG
        case "progress":  return .progress
        case "approval":  return .approval
        #endif
        default:          return nil
        }
    }

    // MARK: Canned states

    private static let conversation: [LiveSessionController.TranscriptLine] = [
        .init(speaker: "You", text: "Morning. What's on today?"),
        .init(speaker: "Iris", text: "Two things. The pairing spec review at eleven, and Hermes still owes you the dependency audit."),
        .init(speaker: "You", text: "Can you have Hermes finish that audit and write it up?"),
        .init(speaker: "Iris", text: "I can. I'd ask it to re-run the audit across the workspace and summarise anything pinned more than two majors behind.")
    ]

    static let listening = PreviewFixture(state: .listening, lines: conversation)

    /// The socket is being swapped under a conversation that is still going.
    /// No banner: the point of this state is that nothing has gone wrong yet.
    static let reconnecting = PreviewFixture(state: .reconnecting, lines: conversation)

    static let speaking = PreviewFixture(
        state: .speaking,
        lines: conversation + [.init(speaker: "Iris", text: "Sending that over now — I'll read the result back when it lands.")]
    )

    static let working = PreviewFixture(
        state: .working(2),
        lines: conversation,
        runs: [
            LinkTask(runId: "r-1", task: "Audit workspace dependencies and summarise anything pinned two majors behind",
                     status: "running", origin: "device:abc", createdAt: Date().addingTimeInterval(-240).timeIntervalSince1970,
                     updatedAt: Date().addingTimeInterval(-40).timeIntervalSince1970),
            LinkTask(runId: "r-2", task: "Rebuild the release notes draft for 0.4",
                     status: "running", origin: "desktop", createdAt: Date().addingTimeInterval(-900).timeIntervalSince1970,
                     updatedAt: Date().addingTimeInterval(-120).timeIntervalSince1970),
            LinkTask(runId: "r-3", task: "Summarise yesterday's Link API changes",
                     status: "completed", origin: "desktop", createdAt: Date().addingTimeInterval(-5400).timeIntervalSince1970,
                     updatedAt: Date().addingTimeInterval(-4800).timeIntervalSince1970),
            LinkTask(runId: "r-4", task: "Check whether the token mint path leaks the key",
                     status: "failed", origin: "device:abc", createdAt: Date().addingTimeInterval(-9000).timeIntervalSince1970,
                     updatedAt: Date().addingTimeInterval(-8700).timeIntervalSince1970),
            LinkTask(runId: "r-5", task: "Draft the pairing QR copy",
                     status: "cancelled", origin: "desktop", createdAt: Date().addingTimeInterval(-90000).timeIntervalSince1970,
                     updatedAt: Date().addingTimeInterval(-89000).timeIntervalSince1970)
        ],
        pairedName: "Nate's MacBook Pro"
    )

    static let proposal = PreviewFixture(
        state: .awaitingAnswer,
        lines: conversation,
        pendingProposal: "Ask Hermes to re-run the dependency audit across the workspace and write up anything pinned more than two majors behind.",
        pairedName: "Nate's MacBook Pro"
    )

    #if DEBUG
    /// Runs that carry a §12 live-progress block, for the run-detail screen.
    /// See RunProgressFixtures.swift — the whole thing is DEBUG-only.
    static let progress = PreviewFixture(
        state: .working(3),
        lines: conversation,
        runs: RunProgressFixtures.runs,
        pairedName: "Nate's MacBook Pro"
    )
    #endif

    /// Enough of the catalogue to see the picker, with the styles the real
    /// one carries. Not the whole thirty: a screenshot of a scrolling list
    /// proves nothing the first six do not.
    static let voices = PreviewFixture(
        state: .idle,
        lines: [],
        pairedName: "Nate's MacBook Pro",
        voices: [
            LinkVoice(name: "Zephyr", style: "Bright"),
            LinkVoice(name: "Puck", style: "Upbeat"),
            LinkVoice(name: "Charon", style: "Informative"),
            LinkVoice(name: "Kore", style: "Firm"),
            LinkVoice(name: "Algenib", style: "Gravelly"),
            LinkVoice(name: "Iapetus", style: "Clear")
        ],
        defaultVoice: "Zephyr",
        accent: "British (RP, London)",
        pushConfigured: true
    )

    #if DEBUG
    /// A run Hermes is waiting on, for the approval card (§11.5).
    static let approval = PreviewFixture(
        state: .working(1),
        lines: conversation,
        runs: RunProgressFixtures.runs,
        pairedName: "Nate's MacBook Pro"
    )
    #endif

    static let errored = PreviewFixture(
        state: .idle,
        lines: conversation,
        errorText: "Socket receive ended: Socket is not connected",
        pairedName: "Nate's MacBook Pro"
    )
}
