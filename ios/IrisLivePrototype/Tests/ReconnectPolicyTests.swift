//
//  ReconnectPolicyTests.swift
//
//  The reconnect state machine, driven by a fake clock and made-up close
//  codes. No sockets, no network, no waiting: every deadline in here is a
//  `Date` the test chose.
//

import XCTest
@testable import IrisLivePrototype

final class ReconnectPolicyTests: XCTestCase {

    // MARK: Backoff

    func testUnexpectedCloseFollowsTheDesktopBackoffSequence() {
        var policy = ReconnectPolicy()
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            let decision = policy.decide(
                cause: .transportDropped(code: 1006, reason: "abnormal"),
                lived: 3
            )
            guard case .reconnect(let after, _) = decision else {
                return XCTFail("expected a reconnect, got \(decision)")
            }
            delays.append(after)
        }
        XCTAssertEqual(delays, [0.5, 2, 8, 32])
    }

    func testTheFifthFailureInARowGivesUpWithAMessage() {
        var policy = ReconnectPolicy()
        for _ in 0..<4 {
            _ = policy.decide(cause: .transportDropped(code: 1006, reason: nil), lived: 3)
        }
        let decision = policy.decide(cause: .transportDropped(code: 1006, reason: nil), lived: 3)
        guard case .giveUp(let message) = decision else {
            return XCTFail("expected giveUp, got \(decision)")
        }
        XCTAssertEqual(message, ReconnectPolicy.giveUpMessage)
        XCTAssertFalse(message.isEmpty)
    }

    func testAHealthyConnectionRefillsTheBudget() {
        var policy = ReconnectPolicy()
        for _ in 0..<3 {
            _ = policy.decide(cause: .transportDropped(code: 1006, reason: nil), lived: 2)
        }
        // This one lived well past the healthy mark, so its close is a routine
        // reset and the sequence starts over rather than continuing to climb.
        let decision = policy.decide(
            cause: .transportDropped(code: 1006, reason: nil),
            lived: ReconnectPolicy.healthyLifetime + 1
        )
        XCTAssertEqual(decision, .reconnect(after: 0.5, dropResumeHandle: false))
    }

    func testACompletedTurnAlsoRefillsTheBudget() {
        var policy = ReconnectPolicy()
        for _ in 0..<3 {
            _ = policy.decide(cause: .transportDropped(code: 1006, reason: nil), lived: 2)
        }
        policy.connectionHealthy()
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertEqual(
            policy.decide(cause: .transportDropped(code: 1006, reason: nil), lived: 2),
            .reconnect(after: 0.5, dropResumeHandle: false)
        )
    }

    // MARK: The resume handle

    func testAResumedConnectionThatDiesFastDropsTheHandle() {
        var policy = ReconnectPolicy()
        policy.connectionOpened(resuming: true)
        let decision = policy.decide(cause: .transportDropped(code: 1006, reason: nil), lived: 1.2)
        XCTAssertEqual(decision, .reconnect(after: 0.5, dropResumeHandle: true))
    }

    func testAResumedConnectionThatLivedKeepsTheHandle() {
        var policy = ReconnectPolicy()
        policy.connectionOpened(resuming: true)
        let decision = policy.decide(
            cause: .transportDropped(code: 1006, reason: nil),
            lived: ReconnectPolicy.resumeRejectedLifetime + 1
        )
        XCTAssertEqual(decision, .reconnect(after: 0.5, dropResumeHandle: false))
    }

    func testAFreshConnectionNeverBlamesAHandleItDidNotUse() {
        var policy = ReconnectPolicy()
        policy.connectionOpened(resuming: false)
        let decision = policy.decide(cause: .transportDropped(code: 1006, reason: nil), lived: 0.2)
        XCTAssertEqual(decision, .reconnect(after: 0.5, dropResumeHandle: false))
    }

    // MARK: Authorization

    func testARefusedCredentialNeverSchedulesARetry() {
        var policy = ReconnectPolicy()
        // Ten times over: a refused token must not loop, however often it is
        // offered back to the policy.
        for _ in 0..<10 {
            let decision = policy.decide(
                cause: .authorizationRefused(code: 1011, reason: "Token has been used too many times"),
                lived: 0.1
            )
            XCTAssertEqual(
                decision,
                .stopAuthorizationFailed(code: 1011, reason: "Token has been used too many times")
            )
        }
        XCTAssertEqual(policy.attempts, 0, "a refusal must not even consume the backoff budget")
    }

    func testAnIntentionalCloseStops() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.decide(cause: .intentional, lived: 120), .stopIntentional)
    }

    // MARK: Classification
    //
    // The 1011 split is the correction this build carries, and both halves
    // were observed against the real API.

    func testSpentTokenBeforeSetupIsAnAuthorizationFailure() {
        let cause = ReconnectPolicy.classify(
            code: 1011,
            reason: "Token has been used too many times",
            sawSetupComplete: false,
            lived: 0.1
        )
        XCTAssertEqual(
            cause,
            .authorizationRefused(code: 1011, reason: "Token has been used too many times")
        )
    }

    func testExpiredTokenUnderAHealthySessionIsNotAnAuthorizationFailure() {
        // Observed: a working session is closed with 1011 "auth token has
        // expired" the moment the token's expireTime arrives. Treating that as
        // a refusal is what killed the conversation on the half hour.
        let cause = ReconnectPolicy.classify(
            code: 1011,
            reason: "auth token has expired",
            sawSetupComplete: true,
            lived: 1800
        )
        XCTAssertEqual(cause, .credentialExpired(reason: "auth token has expired"))

        var policy = ReconnectPolicy()
        guard case .reconnect = policy.decide(cause: cause, lived: 1800) else {
            return XCTFail("an expired token must reconnect on a fresh one")
        }
    }

    func testAnEarlyCloseWithoutSetupIsAnAuthorizationFailure() {
        let cause = ReconnectPolicy.classify(
            code: 1006, reason: nil, sawSetupComplete: false, lived: 0.4
        )
        XCTAssertEqual(cause, .authorizationRefused(code: 1006, reason: nil))
    }

    func testTheGoAwayHangUpIsJustADroppedTransport() {
        let cause = ReconnectPolicy.classify(
            code: 1000, reason: "server reset", sawSetupComplete: true, lived: 600
        )
        XCTAssertEqual(cause, .transportDropped(code: 1000, reason: "server reset"))
    }

    // MARK: goAway

    func testGoAwaySchedulesAProactiveSwapBeforeTheDeadline() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = ReconnectPolicy.schedule(goAwayTimeLeft: 60, now: now)
        XCTAssertEqual(schedule.delay(from: now), 60 - ReconnectPolicy.goAwayLead, accuracy: 0.001)
        XCTAssertEqual(
            schedule.hardDeadline.timeIntervalSince(now),
            60 - ReconnectPolicy.goAwayGuardBand,
            accuracy: 0.001
        )
        XCTAssertLessThan(schedule.fireAt, schedule.hardDeadline)
    }

    func testAGoAwayWithAlmostNoTimeLeftStillLetsThePhraseLand() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = ReconnectPolicy.schedule(goAwayTimeLeft: 0.2, now: now)
        // Never negative, never instant, and never after the server's own
        // hang-up.
        XCTAssertGreaterThanOrEqual(schedule.delay(from: now), 0)
        XCTAssertLessThanOrEqual(schedule.fireAt, schedule.hardDeadline)
    }

    func testAGoAwayWithNoTimeLeftFieldAssumesSoon() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let schedule = ReconnectPolicy.schedule(goAwayTimeLeft: nil, now: now)
        XCTAssertEqual(
            schedule.hardDeadline.timeIntervalSince(now),
            ReconnectPolicy.goAwayFallback - ReconnectPolicy.goAwayGuardBand,
            accuracy: 0.001
        )
    }

    func testTheSwapWaitsForAMidTurnButNotPastTheDeadline() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let deadline = now.addingTimeInterval(5)
        // Iris is mid-sentence and there is still slack: wait.
        XCTAssertTrue(ReconnectPolicy.shouldWaitForQuiet(busy: true, now: now, hardDeadline: deadline))
        // Quiet line: go now.
        XCTAssertFalse(ReconnectPolicy.shouldWaitForQuiet(busy: false, now: now, hardDeadline: deadline))
        // Still mid-sentence, but the server is about to hang up anyway.
        XCTAssertFalse(ReconnectPolicy.shouldWaitForQuiet(
            busy: true, now: deadline.addingTimeInterval(0.1), hardDeadline: deadline
        ))
    }

    // MARK: Duration parsing

    func testTimeLeftIsParsedAsAProtobufDuration() {
        XCTAssertEqual(LiveDuration.seconds("600s"), 600)
        XCTAssertEqual(LiveDuration.seconds("9.5s") ?? .nan, 9.5, accuracy: 0.0001)
        XCTAssertEqual(LiveDuration.seconds("0s"), 0)
        XCTAssertNil(LiveDuration.seconds(nil))
        XCTAssertNil(LiveDuration.seconds(""))
        XCTAssertNil(LiveDuration.seconds("soon"))
        XCTAssertNil(LiveDuration.seconds("-5s"))
    }
}
