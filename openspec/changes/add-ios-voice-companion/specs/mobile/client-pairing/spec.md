## Purpose

Defines how a mobile Iris client earns the right to talk to the user's agent and AI session, what secrets end up on the phone, and how that trust is inspected and revoked. Pairing is the security boundary of the whole mobile surface.

## ADDED Requirements

### Requirement: Explicit pairing before any agent access

A mobile client SHALL NOT reach the user's agent or AI session until it has been paired through an action the user takes on an already-trusted surface. An unpaired client SHALL be able to do nothing beyond starting the pairing flow.

#### Scenario: First launch

- **WHEN** the app is launched before pairing
- **THEN** it presents the pairing flow only, and no conversation can be started and no agent request is issued

#### Scenario: Pairing approved

- **WHEN** the user approves the pairing on the trusted surface
- **THEN** the client stores its credential and can start sessions and dispatch work under the contract in `agent-dispatch-contract`

### Requirement: No manual secret entry

Pairing SHALL NOT require the user to type or paste API keys into the mobile device. The flow SHALL transfer whatever the client needs automatically once the user approves, using a channel the user can see and confirm (such as a scanned code or a short verification string shown on both surfaces).

#### Scenario: Codes are confirmed on both ends

- **WHEN** pairing is in progress
- **THEN** the user can compare an identifying code shown by both the mobile client and the trusted surface before approving

#### Scenario: Pairing material expires

- **WHEN** an offered pairing is not completed within a short bounded window
- **THEN** the offer expires, and the same material cannot be reused to pair a later client

### Requirement: Per-client credentials

Each paired client SHALL hold its own credential, distinct from the desktop's and from any other device's. The credential SHALL identify the client so that its activity can be attributed and it can be revoked alone.

#### Scenario: Two devices paired

- **WHEN** a phone and a second device are both paired
- **THEN** each holds a distinct credential, and revoking one leaves the other working

### Requirement: Credential storage and lifetime

Credentials on a mobile device SHALL be stored in the platform's protected credential store, SHALL be available only while the device is unlocked, and SHALL NOT be written to logs, analytics, backups outside the protected store, or crash reports.

#### Scenario: Device locked

- **WHEN** the device is locked
- **THEN** stored credentials are not readable by the app or any other process

#### Scenario: App uninstalled

- **WHEN** the app is removed from the device
- **THEN** its stored credential no longer grants access, either because it is destroyed with the app or because the user can revoke it from the trusted surface

### Requirement: Visible and revocable pairings

The trusted surface SHALL list every paired client with an identifying name and the time it was last active, and SHALL allow revoking any of them. Revocation SHALL take effect without needing the revoked device present.

#### Scenario: Lost phone revoked

- **WHEN** the user revokes a paired client
- **THEN** subsequent requests carrying that client's credential are refused, and the client reports that it is no longer paired and returns to the pairing flow

### Requirement: Refusal is explicit and non-silent

When a request is refused for authorization reasons, the client SHALL tell the user that it is not authorized and SHALL NOT present the refusal as an agent failure, a network problem, or an empty result.

#### Scenario: Credential rejected mid-session

- **WHEN** a request is refused because the credential is invalid or revoked
- **THEN** the client ends the session, states that the device is no longer paired, and offers to pair again

### Requirement: Transport confidentiality

All traffic between a mobile client and the agent or AI session SHALL be confidential in transit and SHALL NOT traverse the public internet unencrypted. Where the transport is a private network, the client SHALL detect its absence and report it rather than silently falling back to an unprotected path.

#### Scenario: Private network unavailable

- **WHEN** the required private network is not connected
- **THEN** the client says the agent is unreachable and how to restore the connection, and does not attempt an unprotected connection
