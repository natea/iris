## MODIFIED Requirements

### Requirement: User-initiated voice sessions

A voice session SHALL start only from a deliberate user action — a control in the app, a lock-screen control, or a Siri or Shortcuts request — and SHALL end when the user ends it, when the platform ends it, or when it has been idle for the standby interval. The microphone SHALL never be open outside a session.

#### Scenario: Start and stop

- **WHEN** the user starts a session
- **THEN** capture begins and the assistant is audible within a short, perceptible interval, and a single control ends the session and releases the microphone

#### Scenario: Idle session enters standby

- **WHEN** a session has had no recognized user speech, no assistant speech, and no local speech onset for the standby interval
- **THEN** the session ends itself: the connection is closed, the microphone is released, and the app shows that the assistant is asleep rather than stopped

#### Scenario: Standby waits for a question

- **WHEN** a proposal is waiting for the user's answer
- **THEN** the standby interval is extended so the user can read and answer it, and standby does not discard the proposal when it does fire

#### Scenario: Standby never cuts a turn

- **WHEN** the assistant is mid-response, or a completion announcement is queued or being spoken
- **THEN** standby does not fire until that turn has finished, subject to a bounded maximum wait after which a stalled response no longer holds the session open

#### Scenario: Standby interval is a setting

- **WHEN** the user changes the standby interval in Settings
- **THEN** the new interval applies to the next idle period, and the setting can disable standby entirely with a plain statement of what that costs

#### Scenario: Microphone permission refused

- **WHEN** microphone permission is denied
- **THEN** the app explains what is needed and how to grant it, and does not present a broken session

## ADDED Requirements

### Requirement: Conversation resumes after standby

A session that entered standby SHALL be resumable: a wake within the assistant service's resumption window continues the same conversation, and a wake after it starts a new conversation and says so. The app SHALL NOT claim continuity it did not get.

#### Scenario: Wake within the window

- **WHEN** the user wakes the assistant less than the resumption window after standby
- **THEN** the conversation continues where it left off and the assistant does not re-greet as if meeting the user for the first time

#### Scenario: Wake after the window

- **WHEN** the user wakes the assistant after the resumption window has passed
- **THEN** a new conversation starts and the assistant says it could not pick up the earlier one

#### Scenario: The phone cannot extend the window

- **WHEN** the app is suspended during standby
- **THEN** it does not attempt to reconnect in the background to extend the window, and the stated window is the service's own, not a longer one the app cannot honor

### Requirement: Asleep is visible and wakeable

While the assistant is asleep the app, the lock screen and any Live Activity SHALL show that it is asleep and how to wake it, distinct from a stopped session, and completed runs SHALL still reach the user.

#### Scenario: Asleep on the lock screen

- **WHEN** the assistant is in standby and the phone is locked
- **THEN** no live-microphone control is shown, and any run activity on the lock screen says the assistant is asleep rather than listening

#### Scenario: Run completes while asleep

- **WHEN** a run finishes while the assistant is in standby
- **THEN** the user is notified as they would be for a stopped session, and the completion is spoken on the next wake only if it has not already been announced

#### Scenario: Waking

- **WHEN** the user taps the wake control, or asks Siri to start the assistant
- **THEN** a session starts under the resume rules above

### Requirement: Siri and Shortcuts entry points

The app SHALL offer two actions with no user setup: start a session, and send a task. Neither SHALL give the assistant a microphone from the background; a task sent this way SHALL be treated as a proposal, not a dispatch.

#### Scenario: Start by voice

- **WHEN** the user asks Siri to start the assistant
- **THEN** the app comes to the foreground and a session starts, resuming if a resumable conversation exists

#### Scenario: Send a task by voice

- **WHEN** the user asks Siri to send a task and the phrase carries the task text
- **THEN** the text reaches the app unchanged and is staged as a proposal for the user to confirm, with the two-step dispatch rule unchanged

#### Scenario: Task phrase without text

- **WHEN** the user asks Siri to send a task without saying what it is
- **THEN** Siri asks for the task and the answer reaches the app unchanged

#### Scenario: Phrase intercepted

- **WHEN** Siri answers a request itself instead of passing it to the app
- **THEN** the app's published phrases avoid that shape, and the setup guide says which phrasing works
