//
//  DispatchGateTests.swift
//
//  Every case in test/hermesGate.test.mjs, ported, plus the extra orderings
//  the dispatch contract names: a same-turn submit, a decline, an amendment
//  that has to be confirmed again, an interrupted read-back, and a session
//  change.
//

import XCTest
@testable import IrisLivePrototype

final class DispatchGateTests: XCTestCase {

    private func staged(_ gate: inout DispatchGate, task: String = "Task", urgency: String = "normal", session: String = "s") -> DispatchGate.Proposal {
        guard case .success(let proposal) = gate.propose(task: task, urgency: urgency, sessionId: session) else {
            XCTFail("propose should succeed")
            fatalError("unreachable")
        }
        return proposal
    }

    // MARK: Ports of test/hermesGate.test.mjs

    func testRecordsARealUserTurnWithoutHardCodingItsWording() {
        for response in ["Okay, yes, yes, yes.", "That sounds good to me.", "हाँ, भेज दो"] {
            var gate = DispatchGate()
            let proposal = staged(&gate)
            gate.markModelTurnComplete()
            guard case .success = gate.recordUserResponse(response) else {
                return XCTFail("\(response) should be recorded")
            }
            XCTAssertEqual(gate.pendingProposal()?.userTurnObserved, true, response)
            guard case .success = gate.claim(proposalId: proposal.id, sessionId: "s") else {
                return XCTFail("\(response) should unlock the claim")
            }
        }
    }

    func testRequiresCompletedReadbackRealUserTurnExactIdAndSession() {
        var gate = DispatchGate()
        let proposal = staged(&gate, task: "Goal:\nPrepare the report", urgency: "high", session: "session-a")
        XCTAssertEqual(proposal.urgency, "high")
        XCTAssertEqual(proposal.stage, .awaitingReadback)

        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "session-a").failureReason, .noUserTurn)

        gate.markModelTurnComplete()
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "session-a").failureReason, .noUserTurn)

        gate.recordUserResponse("Okay, yes, yes, yes.")
        XCTAssertEqual(gate.claim(proposalId: "different", sessionId: "session-a").failureReason, .proposalMismatch)
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "session-b").failureReason, .sessionMismatch)

        guard case .success(let claimed) = gate.claim(proposalId: proposal.id, sessionId: "session-a") else {
            return XCTFail("the claim should succeed")
        }
        XCTAssertEqual(claimed.task, "Goal:\nPrepare the report")
        XCTAssertNil(gate.pendingProposal())
    }

    func testDiscardsTheExactStagedProposal() {
        var gate = DispatchGate()
        let proposal = staged(&gate, task: "Task A")
        gate.markModelTurnComplete()
        gate.recordUserResponse("No, let's leave it.")
        XCTAssertEqual(gate.discard(proposalId: "different", sessionId: "s").failureReason, .proposalMismatch)
        XCTAssertEqual(gate.discard(proposalId: proposal.id, sessionId: "other").failureReason, .sessionMismatch)
        guard case .success(let discarded) = gate.discard(proposalId: proposal.id, sessionId: "s") else {
            return XCTFail("the discard should succeed")
        }
        XCTAssertEqual(discarded.task, "Task A")
        XCTAssertNil(gate.pendingProposal())
    }

    func testAnInterruptedReadbackNeverUnlocksSubmission() {
        var gate = DispatchGate()
        let proposal = staged(&gate)
        gate.markModelTurnInterrupted()
        XCTAssertEqual(gate.recordUserResponse("yes").failureReason, .notAwaitingUser)
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "s").failureReason, .readbackInterrupted)
    }

    func testCapturesAQuickResponseArrivingJustBeforeReadbackCompletion() {
        var gate = DispatchGate()
        let proposal = staged(&gate)
        guard case .success = gate.recordUserResponse("Mm-hmm, go ahead.", allowDuringReadback: true) else {
            return XCTFail("an audible read-back should accept the early reply")
        }
        gate.markModelTurnComplete()
        guard case .success = gate.claim(proposalId: proposal.id, sessionId: "s") else {
            return XCTFail("the claim should succeed")
        }
    }

    func testDoesNotMistakeAPreReadbackTranscriptTailForConfirmation() {
        var gate = DispatchGate()
        let proposal = staged(&gate)
        XCTAssertEqual(gate.recordUserResponse("yes").failureReason, .readbackInProgress)
        gate.markModelTurnComplete()
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "s").failureReason, .noUserTurn)
    }

    func testExpiredProposalsAreDiscarded() {
        var gate = DispatchGate()
        let proposedAt = Date(timeIntervalSince1970: 1_000)
        guard case .success(let proposal) = gate.propose(task: "Task", sessionId: "s", now: proposedAt) else {
            return XCTFail("propose should succeed")
        }
        gate.markModelTurnComplete()
        gate.recordUserResponse("yes")
        let later = proposedAt.addingTimeInterval(DispatchGate.proposalTTL + 1)
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "s", now: later).failureReason, .noProposal)
    }

    // MARK: The contract's extra orderings

    /// agent-dispatch-contract, "Dispatch without a user turn".
    func testSubmitInTheSameModelTurnIsRejected() {
        var gate = DispatchGate()
        let proposal = staged(&gate)
        // No turnComplete, no user transcript: the model called submit inside
        // its own proposal turn.
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "s").failureReason, .noUserTurn)
        XCTAssertNotNil(gate.pendingProposal(), "a rejected claim must leave the proposal staged")
        XCTAssertTrue(gate.isSettling(), "the settle window should still be open")
    }

    /// "User declines" — nothing is dispatchable afterwards.
    func testDeclineLeavesNothingToClaim() {
        var gate = DispatchGate()
        let proposal = staged(&gate)
        gate.markModelTurnComplete()
        gate.recordUserResponse("No, don't send that.")
        XCTAssertNotNil(gate.discard(proposalId: proposal.id, sessionId: "s").success)
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "s").failureReason, .noProposal)
        XCTAssertFalse(gate.hasPendingProposal())
    }

    /// "User amends" — the replacement needs its own confirmation, and the
    /// superseded id can never be claimed.
    func testAmendmentRequiresConfirmationAgain() {
        var gate = DispatchGate()
        let first = staged(&gate, task: "Goal:\nBook a flight")
        gate.markModelTurnComplete()
        gate.recordUserResponse("Actually make it Tuesday.")

        let second = staged(&gate, task: "Goal:\nBook a flight on Tuesday")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(gate.claim(proposalId: first.id, sessionId: "s").failureReason, .proposalMismatch)
        XCTAssertEqual(gate.claim(proposalId: second.id, sessionId: "s").failureReason, .noUserTurn,
                       "the amended brief must be read back and confirmed on its own")

        gate.markModelTurnComplete()
        gate.recordUserResponse("Yes, that's right.")
        guard case .success(let claimed) = gate.claim(proposalId: second.id, sessionId: "s") else {
            return XCTFail("the confirmed amendment should claim")
        }
        XCTAssertEqual(claimed.task, "Goal:\nBook a flight on Tuesday")
    }

    /// A barge-in during the read-back cannot be rescued by a later turn.
    func testInterruptedReadbackCannotBeRecoveredByALaterTurn() {
        var gate = DispatchGate()
        let proposal = staged(&gate)
        gate.markModelTurnInterrupted()
        gate.markModelTurnComplete()   // a later turn must not re-open it
        XCTAssertEqual(gate.recordUserResponse("go ahead").failureReason, .notAwaitingUser)
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "s").failureReason, .readbackInterrupted)
    }

    /// A fresh Live session clears anything staged (LINK_API.md §6.2).
    func testSessionResetClearsTheProposal() {
        var gate = DispatchGate()
        let proposal = staged(&gate)
        gate.markModelTurnComplete()
        gate.recordUserResponse("yes")
        gate.reset()
        XCTAssertEqual(gate.claim(proposalId: proposal.id, sessionId: "s").failureReason, .noProposal)
    }

    func testAnEmptyBriefIsRefusedAndLeavesTheStagedProposalAlone() {
        var gate = DispatchGate()
        let proposal = staged(&gate, task: "Keep me")
        XCTAssertEqual(gate.propose(task: "   ", sessionId: "s").failureReason, .emptyTask)
        XCTAssertEqual(gate.pendingProposal()?.id, proposal.id)
    }

    func testUrgencyIsNormalized() {
        var gate = DispatchGate()
        XCTAssertEqual(staged(&gate, urgency: "URGENT").urgency, "normal")
        XCTAssertEqual(staged(&gate, urgency: "low").urgency, "low")
    }

    func testEmptyUserResponseIsNotATurn() {
        var gate = DispatchGate()
        _ = staged(&gate)
        gate.markModelTurnComplete()
        XCTAssertEqual(gate.recordUserResponse("   ").failureReason, .emptyResponse)
    }

    // MARK: Contract wording

    func testRejectionWordingMatchesTheContract() {
        XCTAssertEqual(
            DispatchGate.errorText(for: .noProposal, userName: "Nate"),
            "REJECTED: no active proposal. Stage and read back a complete brief first."
        )
        XCTAssertEqual(
            DispatchGate.errorText(for: .noUserTurn, userName: "Nate"),
            "REJECTED: no distinct response from Nate was observed after the proposal read-back."
        )
        XCTAssertEqual(
            DispatchGate.instructions(for: .proposalMismatch, activeProposalId: "abc"),
            "Do not restage or repeat the readback. Retry submit_hermes_task using active_proposal_id if this is the proposal the user just confirmed."
        )
        XCTAssertEqual(
            DispatchGate.instructions(for: .proposalMismatch, activeProposalId: nil),
            "Do not claim the task was sent."
        )
        XCTAssertEqual(
            DispatchGate.instructions(for: .readbackInterrupted, activeProposalId: nil),
            "Call propose_hermes_task with the corrected brief."
        )
    }

    // MARK: Approval gate

    func testApprovalGateRefusesTheSameTurnAndAcceptsAnAnsweredTurn() {
        var gate = ApprovalGate()
        XCTAssertFalse(gate.userAnsweredInOwnTurn, "no answer before the model even asked")
        gate.recordUserResponse("once")     // before the question ended: ignored
        XCTAssertFalse(gate.userAnsweredInOwnTurn)

        gate.markModelTurnComplete()
        XCTAssertFalse(gate.userAnsweredInOwnTurn, "ending the turn is not an answer")
        gate.recordUserResponse("Allow it once.")
        XCTAssertTrue(gate.userAnsweredInOwnTurn)
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim(), "one spoken answer authorizes exactly one approval")
    }

    func testApprovalGateClosesOnBargeIn() {
        var gate = ApprovalGate()
        gate.markModelTurnComplete()
        gate.markModelTurnInterrupted()
        gate.recordUserResponse("yes")
        XCTAssertFalse(gate.userAnsweredInOwnTurn)
    }
}

// MARK: - Result helpers

extension Result where Failure == DispatchGate.Reason {
    var failureReason: DispatchGate.Reason? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
    var success: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
