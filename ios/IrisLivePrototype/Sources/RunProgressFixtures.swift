//
//  RunProgressFixtures.swift
//  IrisLivePrototype
//
//  Canned §12 blocks, so the progress screen can be looked at — in Xcode
//  previews, and in the simulator with `-uiPreviewState progress`.
//
//  The whole file is inside `#if DEBUG`: a release build has no symbol here,
//  so there is no path by which a fixture can reach production logic. The
//  screen reads them only when `RunsScreen` was already handed injected runs,
//  which itself only happens under a DEBUG launch argument.
//

#if DEBUG
import Foundation

enum RunProgressFixtures {

    private static func ms(_ secondsAgo: Double) -> Double {
        Date().addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000
    }

    // MARK: Runs

    static let activeRun = LinkTask(
        runId: "run-8f21a0c4d9", task: briefText, status: "running", origin: "device:abc",
        createdAt: ms(320), updatedAt: ms(4), headline: "Running code", stepCount: 5
    )

    static let failingRun = LinkTask(
        runId: "run-3b77e1f0aa", task: "Goal: Check whether the token mint path leaks the key.\nLook at LinkClient and the desktop's token route.",
        status: "running", origin: "desktop",
        createdAt: ms(640), updatedAt: ms(9), headline: "Searching example.com", stepCount: 4
    )

    static let finishedRun = LinkTask(
        runId: "run-12ce77b481", task: "Goal: Summarise yesterday's Link API changes.",
        status: "completed", origin: "desktop",
        createdAt: ms(5400), updatedAt: ms(4800), headline: "", stepCount: 3
    )

    static let blindRun = LinkTask(
        runId: "run-55aa10d2ef", task: "Goal: Rebuild the release notes draft for 0.4.",
        status: "running", origin: "desktop",
        createdAt: ms(900), updatedAt: ms(30), headline: "", stepCount: 0
    )

    /// §11.5 — a run stopped on an approval Hermes actually asked for.
    static let waitingRun = LinkTask(
        runId: "run-6d04bb92c1",
        task: "Goal: Clear the stale build output before the release build.",
        status: "running", origin: "device:abc",
        createdAt: ms(210), updatedAt: ms(6), headline: "Waiting for you", stepCount: 2,
        pendingApproval: PendingApproval(
            requestId: "approval:9f3c41",
            summary: "Hermes wants to run: rm -rf build",
            canApproveFromPhone: true
        )
    )

    /// The other half of §11.5: something Link cannot carry, so there are no
    /// buttons — only "answer it on the Mac".
    static let macOnlyRun = LinkTask(
        runId: "run-7c15da3b02",
        task: "Goal: Install the updated signing certificate.",
        status: "running", origin: "device:abc",
        createdAt: ms(400), updatedAt: ms(11), headline: "Waiting for you", stepCount: 1,
        pendingApproval: PendingApproval(
            requestId: "approval:2ab7e0",
            summary: "Hermes needs a credential entered on the Mac before it can carry on.",
            canApproveFromPhone: false
        )
    )

    // MARK: §15 — a run that failed for the reason that actually bit
    //
    // The Hermes Desktop app had Iris's pinned chat open, so Hermes refused.
    // The phone used to show "Hermes is not reachable from your Mac. Nothing
    // was sent." — which was untrue in every word that mattered.

    static let sessionInUseFailure = LinkFailure(
        code: .sessionInUse,
        message: "That chat is open in Hermes Desktop. Close it there, or I can start a new chat.",
        recovery: .startNewChat,
        detail:
            "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here. "
            + "Details: session 20260916_174926_797a3b opened by desktop 1h36m ago."
    )

    static let backendFailure = LinkFailure(
        code: .backendStartFailed,
        message: "Hermes' backend would not start (MCP server 'strava' failed to authenticate).",
        recovery: .checkMac,
        detail: "Timed out starting Hermes interactive backend."
    )

    static let lockedRun = LinkTask(
        runId: "run-4e19bb70c3",
        task: "Goal: Summarise yesterday's commits across electron/ and ios/.",
        status: "failed", origin: "device:abc",
        createdAt: ms(180), updatedAt: ms(174), headline: "", stepCount: 0,
        failure: sessionInUseFailure
    )

    static let brokenBackendRun = LinkTask(
        runId: "run-91f0ac4d22",
        task: "Goal: Pull this week's Strava activities into the weekly note.",
        status: "failed", origin: "device:abc",
        createdAt: ms(2600), updatedAt: ms(2580), headline: "", stepCount: 0,
        failure: backendFailure
    )

    /// §16.2 — rebuilt from the transcript of a chat that is no longer pinned.
    static let restoredRun = LinkTask(
        runId: "history:20260916_174926_797a3b:msg_412",
        task: "Goal: Draft the release notes for 0.4.",
        status: "completed", origin: "history",
        createdAt: ms(86_400), updatedAt: ms(86_000), headline: "", stepCount: 3,
        restored: true, readOnly: true, sessionId: "20260916_174926_797a3b"
    )

    static let locked = LinkTaskDetail(
        task: LinkTaskStatus(
            runId: lockedRun.runId, task: lockedRun.task, origin: lockedRun.origin,
            status: "failed", failure: sessionInUseFailure
        ),
        headline: "", stepCount: 0, stepsCursor: 0,
        stepsComplete: true, stepsTruncated: false, steps: []
    )

    static let brokenBackend = LinkTaskDetail(
        task: LinkTaskStatus(
            runId: brokenBackendRun.runId, task: brokenBackendRun.task,
            origin: brokenBackendRun.origin, status: "failed", failure: backendFailure
        ),
        headline: "", stepCount: 0, stepsCursor: 0,
        stepsComplete: true, stepsTruncated: false, steps: []
    )

    static let restored = LinkTaskDetail(
        task: LinkTaskStatus(
            runId: restoredRun.runId, task: restoredRun.task, origin: "history",
            status: "completed", output: resultText, restored: true, readOnly: true
        ),
        headline: "", stepCount: 3, stepsCursor: 3,
        stepsComplete: true, stepsTruncated: false,
        steps: [
            RunStep(id: "s1", index: 1, tool: "read_file", category: .file,
                    label: "CHANGELOG.md", preview: "CHANGELOG.md",
                    status: .done, startedAtMs: ms(86_300), durationMs: 500)
        ]
    )

    static let runs: [LinkTask] = [
        waitingRun, activeRun, failingRun, macOnlyRun, blindRun,
        lockedRun, brokenBackendRun, finishedRun, restoredRun,
    ]

    // MARK: Details

    static let active = LinkTaskDetail(
        task: LinkTaskStatus(runId: activeRun.runId, task: briefText, origin: activeRun.origin,
                             status: "running", instructions: "The run is STILL IN PROGRESS."),
        headline: "Running code",
        stepCount: 5, stepsCursor: 5, stepsComplete: true, stepsTruncated: false,
        steps: [
            RunStep(id: "s1", index: 1, tool: "read_file", category: .file,
                    label: "package.json", preview: "/Users/nate/code/iris/package.json",
                    status: .done, startedAtMs: ms(88), durationMs: 420),
            RunStep(id: "s2", index: 2, tool: "web_search", category: .search,
                    label: "example.com", preview: "https://www.example.com/search?q=hermes+dependency+audit",
                    status: .done, startedAtMs: ms(82), durationMs: 1200),
            RunStep(id: "s3", index: 3, tool: "Terminal", category: .code,
                    label: "osascript <<'EOF' tell applica…",
                    preview: "osascript <<'EOF' tell application \"Finder\" to get the name of every item",
                    status: .done, startedAtMs: ms(70), durationMs: 48_300),
            RunStep(id: "s4", index: 4, tool: "write_file", category: .file,
                    label: "audit.md", preview: "/Users/nate/code/iris/notes/audit.md",
                    status: .done, startedAtMs: ms(20), durationMs: 125_400),
            RunStep(id: "s5", index: 5, tool: "Terminal", category: .code,
                    label: "npm ls --depth=0", preview: "npm ls --depth=0 --json | jq '.dependencies'",
                    status: .running, startedAtMs: ms(12), durationMs: nil)
        ]
    )

    static let failing = LinkTaskDetail(
        task: LinkTaskStatus(runId: failingRun.runId, task: failingRun.task, origin: failingRun.origin,
                             status: "running"),
        headline: "Searching example.com",
        stepCount: 4, stepsCursor: 4, stepsComplete: true, stepsTruncated: false,
        steps: [
            RunStep(id: "s1", index: 1, tool: "read_file", category: .file,
                    label: "LinkClient.swift", preview: "ios/IrisLivePrototype/Sources/LinkClient.swift",
                    status: .done, startedAtMs: ms(140), durationMs: 900),
            RunStep(id: "s2", index: 2, tool: "Terminal", category: .code,
                    label: "grep -rn 'Bearer' src/", preview: "grep -rn 'Bearer' src/ electron/ | head -40",
                    status: .failed, startedAtMs: ms(120), durationMs: 2400),
            RunStep(id: "s3", index: 3, tool: "browser_navigate", category: .browser,
                    label: "developer.apple.com",
                    preview: "https://developer.apple.com/documentation/security/keychain_services",
                    status: .done, startedAtMs: ms(60), durationMs: 5600),
            RunStep(id: "s4", index: 4, tool: "web_search", category: .search,
                    label: "example.com", preview: "https://www.example.com/search?q=bearer+token+leak",
                    status: .running, startedAtMs: ms(7), durationMs: nil)
        ]
    )

    static let finished = LinkTaskDetail(
        task: LinkTaskStatus(runId: finishedRun.runId, task: finishedRun.task, origin: finishedRun.origin,
                             status: "completed", output: resultText),
        headline: "",
        stepCount: 3, stepsCursor: 3, stepsComplete: true, stepsTruncated: false,
        steps: [
            RunStep(id: "s1", index: 1, tool: "read_file", category: .file,
                    label: "LINK_API.md", preview: "ios/IrisLivePrototype/LINK_API.md",
                    status: .done, startedAtMs: ms(5000), durationMs: 700),
            RunStep(id: "s2", index: 2, tool: "Terminal", category: .code,
                    label: "git log --since=yesterday", preview: "git log --since=yesterday --stat -- electron/ src/",
                    status: .done, startedAtMs: ms(4990), durationMs: 3100),
            RunStep(id: "s3", index: 3, tool: "summarize", category: .tool,
                    label: "", preview: "", status: .done, startedAtMs: ms(4900), durationMs: 145_000)
        ]
    )

    /// §12.4's first case: nothing recorded, and the screen must say so.
    static let blind = LinkTaskDetail(
        task: LinkTaskStatus(runId: blindRun.runId, task: blindRun.task, origin: blindRun.origin,
                             status: "running"),
        headline: "", stepCount: 0, stepsCursor: 0,
        stepsComplete: false, stepsTruncated: false, steps: []
    )

    static let waiting = LinkTaskDetail(
        task: LinkTaskStatus(runId: waitingRun.runId, task: waitingRun.task, origin: waitingRun.origin,
                             status: "running", instructions: "The run is STILL IN PROGRESS.",
                             pendingApproval: waitingRun.pendingApproval),
        headline: "Waiting for you",
        stepCount: 2, stepsCursor: 2, stepsComplete: true, stepsTruncated: false,
        steps: [
            RunStep(id: "s1", index: 1, tool: "read_file", category: .file,
                    label: "build/", preview: "/Users/nate/code/iris/build",
                    status: .done, startedAtMs: ms(200), durationMs: 310),
            RunStep(id: "s2", index: 2, tool: "Terminal", category: .code,
                    label: "rm -rf build", preview: "rm -rf build",
                    status: .running, startedAtMs: ms(9), durationMs: nil)
        ]
    )

    static let macOnly = LinkTaskDetail(
        task: LinkTaskStatus(runId: macOnlyRun.runId, task: macOnlyRun.task, origin: macOnlyRun.origin,
                             status: "running", pendingApproval: macOnlyRun.pendingApproval),
        headline: "Waiting for you",
        stepCount: 1, stepsCursor: 1, stepsComplete: true, stepsTruncated: false,
        steps: [
            RunStep(id: "s1", index: 1, tool: "Terminal", category: .code,
                    label: "security import", preview: "security import cert.p12 -k login.keychain",
                    status: .running, startedAtMs: ms(10), durationMs: nil)
        ]
    )

    static func detail(for runId: String) -> LinkTaskDetail? {
        switch runId {
        case waitingRun.runId:  return waiting
        case macOnlyRun.runId:  return macOnly
        case activeRun.runId:   return active
        case failingRun.runId:  return failing
        case finishedRun.runId: return finished
        case blindRun.runId:    return blind
        case lockedRun.runId:   return locked
        case brokenBackendRun.runId: return brokenBackend
        case restoredRun.runId: return restored
        default:                return nil
        }
    }

    static func result(for runId: String) -> String? {
        switch runId {
        case finishedRun.runId, restoredRun.runId: return resultText
        // A failed run has no result. The failure card is the answer.
        default: return nil
        }
    }

    // MARK: Text

    static let briefText = """
    Goal: Audit the workspace dependencies and summarise anything pinned more than two majors behind.

    Context: the repo is a pnpm workspace with an Electron main process, a Vite renderer and an iOS prototype that is not part of the JS graph.

    Deliverable: a short table of package, pinned version, latest version, and whether the gap is a breaking one.
    """

    static let resultText = """
    ## Link API changes since yesterday

    Three things moved.

    1. `electron/runSteps.mjs` now accumulates normalized Hermes events in the
       main process, so the task API can serve a step list to the phone.
    2. `GET /link/tasks` gained `headline` and `step_count`; the step list itself
       stays out of the list response.
    3. `GET /link/tasks/:id` gained `steps`, `steps_cursor`, `steps_complete`
       and `steps_truncated`, plus a `?steps_since=` delta.

    Nothing else in §4 changed. The 60-step bound is new and is why
    `steps_truncated` exists.
    """
}
#endif
