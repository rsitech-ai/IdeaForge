# Premium Capture Relay

## Experience brief

The wrist question is: **Can I capture this thought now, and is it safely moving to my iPhone?** The primary Watch action is record/stop. History, target, tag, and markers remain available, but they cannot compete with capture in the first viewport.

Personality: **precise, calm, kinetic**.

Truth contract:

- Watch may show recording, saved locally, queued for iPhone, acknowledged by iPhone, or failed. It must not claim Mac/backend receipt.
- iPhone and Mac may show only states derived from their local store and sync snapshots.
- The visualization uses the current microphone meter while recording. Idle and historical visuals never pretend to be measured audio.
- Text and symbols carry every state; color is reinforcement only.

## Audit

- Blocker: on the 40 mm baseline the record guidance and status are below the first viewport; 42 mm partially clips the guidance.
- High: a fixed 108-point ring dominates the small screen and makes capture state slower to parse.
- High: Sync, saved recordings, options, and questions use equal-weight glass panels, obscuring the task hierarchy.
- Medium: rotating traces, pulsing symbols, glowing panels, and ambient movement repeat without a state transition or new information.
- Medium: the iPhone Inbox uses a generic oversized capsule and empty state; the Mac Inbox summarizes counts but does not express the Watch-to-iPhone-to-workspace handoff as one product story.

## Directions considered

### 1. Capture Focus

A restrained native record control, one status line, and conventional detail destinations. It is highly legible but too generic to become an IdeaForge signature.

### 2. Signal Aperture

An asymmetric precision instrument with a narrow live trace and denser technical labeling. It is distinctive but risks making a simple capture action feel analytical.

### 3. Forge Relay — selected

A voice “filament” begins at the microphone, contracts into a durable node after save, and advances only when a real handoff state changes. The motif is compact on Watch and can continue naturally on iPhone and Mac. It explains the product rather than decorating it.

Originality check: the direction avoids the previous card stack, giant centered ring, constellation overlay, dashboard grid, and generic neon-glass treatment. Its identity comes from the data journey, not ornamental chrome.

## Motion storyboard

1. Touch: immediate press-scale and brightness response.
2. Recording begins: a semantic start haptic; live bars respond only to the recorder's normalized power level.
3. Stop: the live filament settles immediately. No success state appears yet.
4. Durable save: a one-shot contraction resolves into the “On Watch” node and a success haptic.
5. Transfer queued: the next node and connecting segment become active.
6. iPhone acknowledgement: the iPhone node resolves with one semantic success transition.
7. Failure: motion stops; orange text and symbol explain that the audio remains on Watch and expose retry.

Reduce Motion replaces travel/scale transitions with immediate opacity, symbol, and text changes. Inactive scenes do not run decorative animation.

## Capability decisions

| Capability | Decision | Reason / fallback |
|---|---|---|
| Digital Crown | Native scrolling only | Recording is binary, not a bounded value; Crown control would add error risk. |
| Haptics | Use for start, durable save/acknowledgement, and failure | Feedback follows real state transitions; text remains the accessible fallback. |
| Always On | Defer specialized behavior | This is not a workout/live-session surface; inactive UI settles with no continuous animation. |
| Complications / Smart Stack / App Intents | Defer | Out of scope for the core capture reliability path. |
| iPhone connectivity | Use with offline degradation | Capture remains local and retryable when the phone is unavailable. |
| Sensors / workouts | Reject | No product requirement justifies the privacy and energy cost. |
| Notifications | Defer | Current in-app acknowledgement is sufficient for this slice. |

## Validation matrix

- Watch: 40, 42, 44, 46, and 49 mm on watchOS 26.5.
- Accessibility: large content size, Reduce Motion, color-independent labels, VoiceOver naming, and primary hit target.
- iPhone: compact/current/large layouts where installed, including an empty and queued Inbox.
- Mac: Inbox at the supported deployment target, including queued/failure provenance.
- Evidence: before/after screenshots plus fresh core tests and warning-as-error builds. Simulator evidence is not physical-device proof.

## Implemented result

- Watch: capture, real meter visualization, relay state, retry, marker, setup, history, tags, and append targeting are preserved. The first viewport now prioritizes capture and the Watch-to-iPhone relay; secondary controls live in “Saved & Setup.”
- Motion: all repeating decorative pulses, rotations, constellation traces, and ambient loops were removed from the active flow. Remaining animation is microphone-meter driven while recording or a short state transition, with Reduce Motion support.
- Haptics: start follows a successful recorder start; success follows durable persistence or a real iPhone import acknowledgement; failure follows an actual recording/transfer failure.
- iPhone: the local-first capture surface precedes queue/status information and adapts at accessibility text sizes so the action remains visible.
- Mac: the Inbox names observed Watch/iPhone source counts separately and points them into the recordings actually present on this Mac. It does not infer a device receipt.

## Verification evidence

- `swift test`: 335 tests passed, 0 failures.
- Warning-as-error Debug builds: watchOS, iOS, and macOS passed.
- Focused iPhone UI test `testTaskFirstInboxHierarchy`: passed after the accessibility refactor.
- Five watchOS 26.5 sizes: 40, 42, 44, 46, and 49 mm launch the real Watch app with the primary action and truthful relay status reachable. Deterministic Watch UI tests cover ready, queued, iPhone-received, and failed durable states on 40 and 49 mm, with screenshot attachments retained as rendered evidence.
- iPhone Accessibility XXXL plus Increase Contrast: rendered with the action glyph in the first portion of the capture surface and expandable copy in the scroll view.
- Mac: signed app launch and fixture render passed. The focused XCUITest discovers the real queued-upload control, then the macOS 27 runner falsely classifies a non-overlapping Notification Center desktop widget as an interruption and fails inside its built-in banner handler before the click reaches IdeaForge.
- An app-isolated accessibility fixture rendered the real Watch view at accessibility XXXL on 40 and 49 mm. The 40 mm composition removes decorative density so the complete “Record idea” action and relay state remain visible; the secondary setup surface remains crown-scrollable. Physical Watch haptics, microphone capture, and post-redesign WatchConnectivity transfer remain explicit hardware gates.

Rendered artifacts are retained in the maintainer's private verification archive;
they are not included in the public source snapshot.
