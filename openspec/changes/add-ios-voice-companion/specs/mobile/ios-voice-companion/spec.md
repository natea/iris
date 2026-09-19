## Purpose

Defines the behavior of the iOS Iris app: how a voice conversation starts, survives interruption and backgrounding, dispatches agent work, and delivers results on a phone that is frequently locked, moving between audio routes, and away from the desktop.

## ADDED Requirements

### Requirement: User-initiated voice sessions

The app SHALL start a voice session only on a deliberate user action, and SHALL end it on a deliberate user action, on prolonged silence, or on an unrecoverable error. It SHALL NOT listen continuously in the background.

#### Scenario: Start and stop

- **WHEN** the user starts a session
- **THEN** the app captures microphone audio, streams it to the AI session, and plays the spoken response
- **WHEN** the user ends the session
- **THEN** capture stops, playback stops, and the microphone indicator clears

#### Scenario: Idle session ends itself

- **WHEN** a session sits idle beyond the configured limit with no work in flight
- **THEN** the app ends the session and says nothing further

#### Scenario: Microphone permission refused

- **WHEN** the user has not granted microphone access
- **THEN** the app explains what is needed and offers to open Settings, and does not present a session as running

### Requirement: Barge-in

The user SHALL be able to interrupt the assistant by speaking. On interruption, queued playback SHALL be discarded immediately so the assistant does not continue talking over the user.

#### Scenario: User speaks over the response

- **WHEN** the user begins speaking while the assistant is talking
- **THEN** playback stops within a perceptibly immediate interval and the new utterance is treated as the current turn

### Requirement: Audio routing and interruptions

The app SHALL follow the system audio route, including Bluetooth headsets, speaker, and receiver, and SHALL survive route changes mid-session. It SHALL yield to system interruptions such as phone calls and resume or end cleanly afterwards.

#### Scenario: Headphones connected mid-session

- **WHEN** the audio route changes during a session
- **THEN** capture and playback follow the new route without ending the session or losing the conversation

#### Scenario: Incoming call

- **WHEN** a phone call or other system interruption begins
- **THEN** the session suspends without losing conversation state, and on return the app either resumes it or tells the user it ended

### Requirement: Background and locked-screen continuity

A session that is running SHALL continue while the app is backgrounded or the screen is locked, for as long as the platform permits, and the user SHALL be able to end it from the system playback controls.

#### Scenario: Screen locks during a run

- **WHEN** the user locks the phone while a dispatched run is in flight
- **THEN** the session continues and the completion is still delivered

#### Scenario: Platform terminates the session

- **WHEN** the system reclaims the audio session or terminates the app
- **THEN** on next launch the app reports that the session ended, and any undelivered completion is still shown

### Requirement: Conversation continuity across reconnects

Brief network loss or a transport reset SHALL NOT discard the conversation. The app SHALL restore the same conversation when it can, and SHALL tell the user when it has had to start a fresh one.

#### Scenario: Network drops briefly

- **WHEN** connectivity is lost for a short interval and returns
- **THEN** the app restores the session and the user can continue without repeating context

#### Scenario: Conversation cannot be restored

- **WHEN** the previous conversation can no longer be resumed
- **THEN** the app starts a fresh session and says so, rather than silently losing context

### Requirement: Agent work from the phone

The app SHALL implement the dispatch behavior defined in `agent-dispatch-contract`, including the two-step confirmation, non-blocking dispatch, and honest run reporting.

#### Scenario: Task dispatched by voice

- **WHEN** the user asks for agent work and confirms the read-back brief
- **THEN** the app dispatches it, reports that it started, and keeps the conversation responsive

### Requirement: Run visibility and result reading

The app SHALL show dispatched runs with their current state, and SHALL let the user open a completed run and have its result read aloud or displayed. The view SHALL include runs dispatched from other paired clients in the same pinned session.

#### Scenario: Run list

- **WHEN** the user opens the app with runs in flight or recently finished
- **THEN** each run is listed with its state, and a finished run can be opened to read its result

#### Scenario: Run started elsewhere completes

- **WHEN** a run dispatched from the desktop finishes while the phone is the active client
- **THEN** the phone can show and read that result

### Requirement: Completion notifications

When a run completes while no session is active, the app SHALL notify the user, and opening the notification SHALL take them to that run's result. Notifications SHALL state the real outcome, including failure.

#### Scenario: Run completes with the app closed

- **WHEN** a dispatched run finishes while the app is not in the foreground
- **THEN** the user receives a notification naming the task and its outcome, and opening it shows the result

#### Scenario: Notifications not permitted

- **WHEN** notification permission has been refused
- **THEN** the app still shows the completed run on next launch and does not claim to have notified the user

### Requirement: Agent unreachable is stated plainly

When the agent cannot be reached — the desktop is asleep, the private network is down, or the service is not running — the app SHALL say which condition it detected and what would restore it, and SHALL NOT present the failure as an empty or successful result.

#### Scenario: Desktop asleep

- **WHEN** the agent cannot be reached because its host is unavailable
- **THEN** the app says the agent is unreachable and names the likely cause, and any attempted dispatch is reported as not sent

#### Scenario: Conversation without the agent

- **WHEN** the agent is unreachable but the AI session is available
- **THEN** the user can still converse and get direct answers, while dispatch is refused with the reason

### Requirement: Privacy of capture

The app SHALL make it unambiguous when the microphone is live, SHALL NOT retain raw audio beyond what an active session requires, and SHALL NOT transmit audio when no session is running.

#### Scenario: Session ends

- **WHEN** a session ends by any path
- **THEN** capture stops, no further audio is transmitted, and retained audio buffers are released
