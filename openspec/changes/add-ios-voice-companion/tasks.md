## 1. Prototypes that can invalidate the design

- [x] 1.1 Prove a Swift `URLSessionWebSocketTask` client can open a Gemini Live session, stream 16 kHz PCM up, and play 24 kHz PCM back — verify by holding a 30-second spoken exchange from a throwaway iOS app
- [x] 1.2 Mint an ephemeral token (`AuthTokenService.CreateToken`) from a script and connect the prototype with it instead of an API key — verify the session opens with the token and is refused after expiry
- [x] 1.3 Reach a stub service bound to the Mac's Tailscale address from the iPhone — verify it answers over the tailnet, is refused without a credential, and is unreachable from a non-tailnet network
- [ ] 1.4 Prototype `StartIrisSessionIntent` with `openAppWhenRun = true` and time "Hey Siri" → microphone live — verify capture starts and record whether the launch feels like an assistant or an app launch
- [ ] 1.5 Prototype a question-shaped Siri phrase ("ask Iris to research X") and verify whether the string reaches the intent or Siri answers it itself; if intercepted, settle on imperative phrasing before any UI work

## 2. Desktop: pairing and token service

- [x] 2.1 Add the Iris Link service to the Electron app, bound to the Tailscale address only, with a token endpoint that mints Gemini ephemeral tokens for a paired device — verify a paired client receives a token, an unpaired request is refused, and the port does not listen on other interfaces
- [x] 2.2 Implement per-device credential issuance and storage on the desktop — verify two paired devices receive distinct credentials
- [x] 2.3 Add the "Pair a device" panel with a QR code carrying a one-time, short-lived payload — verify the payload expires unused and cannot pair a second device
- [x] 2.4 Add the paired-device list with names, last-seen times, and revoke — verify a revoked credential is refused on its next request
- [x] 2.5 Write unit tests for pairing issue/expire/revoke in `test/` alongside the existing suites — verify `npm test` covers the refusal paths
- [ ] 2.6 Rate-limit authenticated Iris Link routes per device (token minting and run creation especially) and keep a per-device audit log of dispatched runs — verify a burst beyond the limit is refused with a distinct error and that a dispatched run appears in the log with its device id
- [ ] 2.7 Serve Iris Link over HTTPS on the Mac's MagicDNS name with a `tailscale cert` certificate, put that hostname in the pairing QR, and have the phone accept only `*.ts.net` hosts — verify the iOS app pairs and fetches a token with no App Transport Security exception in its Info.plist

## 3. Hermes reachability

- [x] 3.1 Add the Hermes proxy to Iris Link: forward only the allowlisted routes (runs, status, events stream, stored results, interaction responses, sessions) to loopback Hermes with the shared key attached server-side — verify an allowlisted call succeeds, a non-allowlisted path is refused, and the shared key never appears in any response
- [ ] 3.2 Document a Tailscale ACL restricting the Iris Link port to the user's own devices — verify a tailnet node outside the ACL is refused
- [ ] 3.3 Add a preflight check to the iOS app that distinguishes "tailnet down", "host asleep", and "service not running" — verify each produces its own message

## 4. iOS: session core

- [ ] 4.1 Create the SwiftUI app target with microphone and notification permission flows — verify a refused permission shows the explanation path, not a broken session
- [x] 4.2 Implement pairing on the phone: register the `iris-link://` scheme, redeem a scanned offer with Iris Link, show the 6-digit code for comparison, and store the device credential in the Keychain — verify scanning the desktop QR opens the app, the device appears in the desktop list, and a revoked device returns to the pairing screen
- [x] 4.3 Connect with an ephemeral token fetched from Iris Link instead of an API key — verify a full spoken session with no Gemini API key on the phone, and that an early 1011 close is reported as not authorized
- [ ] 4.4 Implement the Live WebSocket client (setup, realtime input, server content, transcripts, tool calls, session resumption) — verify against the prototype's recorded message flow
- [ ] 4.5 Implement capture and playback with `.playAndRecord`, echo cancellation, and barge-in flush — verify playback stops within a perceptibly immediate interval when the user speaks over it
- [ ] 4.6 Handle route changes and interruptions — verify a headset connect mid-session and an incoming call each behave as `ios-voice-companion` specifies
- [ ] 4.7 Add `UIBackgroundModes: audio`, lock-screen controls, and idle auto-end — verify a session survives locking and ends itself when idle
- [ ] 4.8 Implement reconnect with session resumption, and an explicit "started a fresh conversation" message when resumption fails — verify by killing the network mid-session

## 5. iOS: agent work

- [x] 5.1 Implement the dispatch gate as a Swift value type mirroring `hermesGate.mjs` — verify unit tests reject same-turn dispatch, allow confirmed dispatch, and handle decline and amend
- [x] 5.2 Implement the Hermes client (dispatch, run status, stored results, interaction responses) against the pinned session — verify a task dispatched from the phone appears in the same session as desktop runs
- [x] 5.3 Wire the Live tool declarations to the gate and Hermes client — verify a full voice round trip: request, read-back, confirmation, dispatch, "it started"
- [x] 5.4 Implement run list and result reading, including runs dispatched elsewhere — verify a desktop-dispatched result can be opened and read on the phone
- [ ] 5.5 Implement local completion notifications raised on reconnect — verify a run finishing with the app closed produces a notification that deep-links to the result
- [ ] 5.6 Implement the secure input surface for credential requests from a run — verify a secret prompt never appears in the transcript or is spoken
- [ ] 5.7 Reconcile `LINK_API.md` with the desktop where the phone implementer found them disagreeing: the barge-in rule (desktop accepts a read-back interrupted after 48 audible characters; the contract says any interruption invalidates it) and the missing `allowDuringReadback` equivalent — verify the contract, the desktop, and the Swift gate state one rule and share test cases for it
- [ ] 5.8 Expose pending approvals to the phone (a field on task status or an undelivered-style list) so an approval can be surfaced rather than only answered — verify a run awaiting approval shows as such on the phone and that approving still requires a user turn
- [ ] 5.9 Send push notifications from the desktop through APNs (token-based auth with the team's .p8 key, no third-party relay): the phone registers its device token and environment with Iris Link; the desktop pushes when a phone-dispatched run finishes and when a run is waiting on the user — verify a notification arrives with the app closed and the phone locked, that opening it shows that run, and that a revoked device stops receiving pushes

## 6. Siri entry points

- [ ] 6.1 Ship `StartIrisSessionIntent` and `SendTaskToIrisIntent` with an `AppShortcutsProvider` — verify both appear in Shortcuts with no user setup and that phrases include the app name token
- [ ] 6.2 Add free-text handling with `requestValue` for a task with no inline parameter — verify the spoken string reaches the intent unchanged
- [ ] 6.3 Register the `iris://` URL scheme in the Electron app's `Info.plist` with wake and task actions — verify a macOS Shortcut using "Open URL" wakes the desktop app and dispatches a task
- [ ] 6.4 Document the macOS Swift helper app option and decide for or against it based on task 1.4's result — verify the decision is recorded in design.md before any helper code is written

## 7. Contract conformance

- [ ] 7.1 Turn `agent-dispatch-contract` scenarios into a shared checklist and run it against the desktop app — verify each scenario passes or is filed as a desktop follow-up
- [ ] 7.2 Run the same checklist against the iOS app — verify every scenario passes before the app is used for real work
- [ ] 7.3 Exercise the unreachable-agent paths end to end (Mac asleep, tailnet off, Hermes stopped) — verify no failure is ever reported as an empty or successful result

## 8. Distribution and follow-on

- [ ] 8.1 Set up Apple Developer provisioning and a TestFlight build — verify an install on the user's own devices from TestFlight
- [ ] 8.2 Write the setup guide (pairing, Tailscale, Siri phrases, what to do when the Mac is asleep) — verify a clean install can be set up following it alone
- [ ] 8.3 Open the watchOS change proposal informed by what phases 1–7 learned — verify it names its transport and what it does when the phone is out of range
