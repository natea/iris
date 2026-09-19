## Purpose

Defines the rules every Iris client must honor when it turns a spoken conversation into agent work: how a task is confirmed before dispatch, how run state is reported without invention, and how finished work reaches the user. Clients differ in interface; this behavior does not.

## ADDED Requirements

### Requirement: Two-step dispatch confirmation

A client SHALL NOT dispatch work to the agent without an explicit user confirmation given in a turn of its own. The assistant SHALL first stage a proposal containing the complete task brief, read that brief back, and end its turn. Only after the user responds SHALL the client dispatch the staged proposal. A dispatch attempt that does not satisfy this sequence SHALL be rejected by the client, not merely discouraged by instructions to the model.

#### Scenario: Confirmed dispatch

- **WHEN** the assistant stages a proposal, reads it back, ends its turn, and the user then replies with clear authorization
- **THEN** the client dispatches that exact staged proposal to the agent and reports that it has started

#### Scenario: Dispatch without a user turn

- **WHEN** the assistant attempts to dispatch in the same turn as the proposal, or before the user has responded
- **THEN** the client refuses the dispatch, tells the assistant it is blocked, and no work reaches the agent

#### Scenario: User declines or amends

- **WHEN** the user declines the staged proposal
- **THEN** the client discards it and dispatches nothing
- **WHEN** the user changes a detail instead
- **THEN** the client replaces the staged proposal with the amended brief and requires confirmation again

### Requirement: Self-contained task briefs

A dispatched brief SHALL stand alone without the conversation that produced it. The client SHALL transmit the brief as staged, preserving every concrete detail the user supplied — names, numbers, dates, URLs, file paths, budgets, constraints, and the expected output format.

#### Scenario: Shorthand request is expanded before dispatch

- **WHEN** the user makes a request that relies on earlier conversation or on stored personal context
- **THEN** the brief that reaches the agent restates the goal and the relevant details explicitly, rather than referring back to the conversation

### Requirement: No invented run state

A client SHALL report agent progress, results, and completion only from an actual agent response or run event. When no terminal state has been received, the only permitted answer about a run is that it is still in progress.

#### Scenario: Asked about a run in flight

- **WHEN** the user asks how a dispatched task is going and no terminal status has been received
- **THEN** the client reports that the task is still running and does not describe partial findings, progress percentages, or expected completion times

#### Scenario: Result is reported only after retrieval

- **WHEN** the user asks what a completed run produced
- **THEN** the client retrieves the stored result and answers from its content, and never infers the result from the task title or the brief

### Requirement: Non-blocking dispatch

Dispatch SHALL return control to the conversation immediately. The client SHALL obtain a run identifier without waiting for the work to finish, and the user SHALL be able to keep talking, interrupt, ask unrelated questions, or dispatch further work while a run is in flight.

#### Scenario: Conversation continues during a long run

- **WHEN** a dispatched run takes minutes to complete
- **THEN** the assistant remains responsive throughout, and the voice session is never blocked waiting on the run

### Requirement: Proactive completion announcement

When a run reaches a terminal state, the client SHALL surface it without the user having to ask. The announcement SHALL state the real outcome, including failure, and SHALL offer to go through the result.

#### Scenario: Run completes mid-conversation

- **WHEN** a run finishes while the user is talking about something else
- **THEN** the client announces the completion at the next opportunity and offers the result, without discarding the user's current topic

#### Scenario: Announcement interrupted

- **WHEN** the announcement is interrupted or the session drops before it is delivered
- **THEN** the pending announcement is retained and delivered on the next session, and is never silently dropped

#### Scenario: Run fails

- **WHEN** a run ends in failure or is stopped
- **THEN** the client says so plainly and does not present the outcome as a success

### Requirement: Single pinned agent session

All work from one user SHALL be dispatched into one configured agent session so that history and context accumulate in a single thread. The assistant SHALL NOT choose or create session identifiers on its own.

#### Scenario: Work from a second client

- **WHEN** the user dispatches work from a different client than the one that dispatched earlier work
- **THEN** the run joins the same pinned agent session, and the earlier history is visible to both clients

### Requirement: Secure handling of agent interaction requests

When a run asks for input mid-flight, the client SHALL relay the question and return the user's answer to the run. Credentials, passwords, and other secrets SHALL NOT be requested, spoken, or repeated through the voice channel; they SHALL be collected only through a trusted input surface.

#### Scenario: Run requests a choice

- **WHEN** a run asks a non-sensitive question with options
- **THEN** the client presents the question, ends the turn, and returns the user's answer with the exact identifiers the run expects

#### Scenario: Run requests a secret

- **WHEN** a run asks for a password or other credential
- **THEN** the client collects it through a trusted input surface and never reads it aloud, logs it, or sends it through the conversation transcript
