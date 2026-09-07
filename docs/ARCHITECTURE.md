# Architecture

## Components

```text
Apple Watch capture
        |
        | WatchConnectivity
        v
iPhone capture and review ----+
                              |
Mac studio and export --------+---- IdeaForgeCore ---- local workspace and encrypted objects
        |                     |
        | HTTPS               +---- backend clients and capability gates
        v
Production-local backend, mock backend, or operator service
        |
        +---- local recording files, workspace state, and durable jobs
        +---- optional transcription and workflow providers
```

`IdeaForgeCore` owns shared domain models, persistence rules, privacy modes, backend request contracts, capability gates, workflow validation, local object encryption, and packet export. Swift Package Manager tests this layer without launching an app.

The Mac app supplies the project studio, review and export tools, backend settings, web account-management handoff, and Sparkle updater. The iPhone app supplies mobile capture, review, backend upload and sync, Watch bridging, and StoreKit flows. The Watch app records and transfers captures through the paired iPhone.

The Watch-to-Mac path is intentionally two-stage:

1. The Watch persists a capture locally and queues the audio file with `WatchConnectivity`.
2. The iPhone copies the transient received file into its durable inbox, persists the recording and upload job, and only then acknowledges the import to the Watch.
3. The iPhone uploads due audio work and publishes a device-neutral workspace snapshot to the configured backend.
4. iPhone and Mac synchronization pull from the last accepted remote revision before push. A newer remote revision is applied before either client publishes local changes. Independent projects are merged and published in the same synchronization pass; edits to the same project stop for review.

Queued transfers and import acknowledgements tolerate temporary reachability loss. A Watch receipt is not considered complete until its state is saved locally. The Watch relay derives its post-launch presentation from durable Watch recording states, prioritizing failed and pending work before acknowledged captures so unresolved clips remain visible after relaunch. Physical paired-device testing remains required because Simulator does not exercise WatchConnectivity file transfer.

## Local data boundary

Each Apple client stores its local workspace and recordings under its application container. Secrets and local object-store keys use Keychain. Packet export writes reviewable files after validating their paths. Local mode requires no backend credential.

The clients do not treat backend responses as trusted state on receipt. They require a validated session and matching workspace, check route capabilities, enforce privacy mode, validate response contracts, and apply sync conflict rules before persistence.

Workspace snapshots exclude device-local audio paths, upload jobs, Watch reachability, and local failure/activity counters. Snapshot identifiers and relationships are validated before dictionaries or persistent state are constructed. When a remote snapshot is applied, each client restores its own matching local audio and upload state. The sync receipt separately records the remote cursor and the local revision that was actually published so an edit made while a request is in flight remains eligible for the next publish.

Background URL-session completion is not acknowledged to the system until the iPhone has reconciled the durable upload receipt and run the next queue refresh. App appearance performs the same reconciliation as a recovery path.

## Local enrichment boundary

Local enrichment has two deliberately separate Apple-system steps on iPhone and Mac. Apple Speech reads the recording that is already present in that device's local container; the request requires on-device recognition and fails explicitly when that recognizer, authorization, or local audio is unavailable. It does not fall back to a network speech-recognition request. A Watch capture must therefore complete its normal Watch-to-iPhone handoff before the iPhone can transcribe it; the Watch does not run this enrichment path.

After transcription completes, the optional title step uses Foundation Models only to propose a concise title grounded in that completed transcript. The coordinator then persists the transcript, title outcome, ready state, and revision together. Foundation Models is not a transcription provider; an unavailable or failed title proposal remains nonfatal, so the transcript is persisted and an existing non-placeholder title is preserved. Foundation Models is considered unavailable when the framework or required operating system is absent, the device is not eligible, Apple Intelligence is disabled, the model is not ready, or the transcript locale is unsupported. The model path is limited to iPhone and Mac; eligibility and actual output still require runtime verification on the target physical device.

When backend workspace sync is configured and capability-gated, its device-neutral snapshot carries the saved project transcript, title, and revision timestamps, but never a device-local audio path. A receiving device restores only audio state that it already owns for a matching recording; a new device hydrates the enriched project with no local audio path. Private Local mode keeps automatic backend sync off. Local Backend mode uses a separately paired device credential and private-LAN HTTPS endpoint; it does not imply a hosted service.

## Backend boundary

The repository contains two backend implementations with different purposes. `script/local_backend.py` is the production-local, one-operator service: SQLite WAL is canonical for workspace, device, idempotency, rate-limit, and job state; recordings are ordinary owner-only files; devices pair with single-use codes and hold distinct revocable credentials; traffic is CA-verified HTTPS restricted to configured private CIDRs. It includes local backup/restore, `_ideaforge._tcp` Bonjour advertisement, and a user LaunchAgent. With pristine settings, the Mac app discovers a private HTTPS endpoint without enabling sync or overwriting an existing configuration. When Local Backend is paired and configured, the LaunchAgent owns process start and crash recovery through `RunAtLoad` and `KeepAlive`; the sandboxed Mac app checks readiness on launch, allows one bounded recovery window for connectivity or timeout failures, checks readiness again, and synchronizes the workspace after readiness. TLS, first-time LaunchAgent installation, and pairing remain explicit setup boundaries. It has no S3-compatible store, public ingress, multi-tenant boundary, or automatic OpenAI path.

`script/mock_backend.py` is the protocol-development server. It uses one configured bearer token, one workspace scope, local files, and SQLite, but has no TLS, device pairing, or production operations design. Do not expose it to the LAN or internet.

An operator may build a separate hosted service against [backend-contract.md](backend-contract.md). That service owns authentication, authorization, durable storage, provider calls, usage decisions, account URLs, deletion, monitoring, and compliance. No hosted production service is part of this source release.

## Commerce boundary

The iPhone distribution path can use StoreKit and submit Apple transaction evidence to a backend. The backend remains the authority for cloud entitlements after verification.

The direct-download Mac app cannot use App Store in-app purchase. It reads the plan summary from the backend and opens backend-provided HTTPS plan-management or deletion pages after capability and workspace checks.

## Release and update boundary

Community builds come from source and carry the distributor's identity. Official Mac builds add four release controls:

1. The protected GitHub workflow records the selected public commit and produces artifact provenance.
2. The maintainer signs the app and nested code with Developer ID and a secure timestamp.
3. Apple notarizes the app and DMG; the release process staples both tickets.
4. Sparkle verifies the update ZIP with an EdDSA signature tied to the public key in the app.

Each control answers a different trust question. [RELEASING.md](RELEASING.md) defines the evidence and failure gates.

## External gates

Repository tests cannot prove Apple account access, certificate private-key access, notary service acceptance, a live hosted backend, provider credentials, App Store Connect configuration, physical-device permissions, Watch transfer, or a clean-Mac update. Release reports must label these as external or physical gates until someone captures the corresponding evidence.

The repository also cannot establish asset authorship through a hash alone. [ASSET_PROVENANCE.md](../ASSET_PROVENANCE.md) records the maintainer's origin and license assertion for retained assets; the owner must confirm that assertion before the first public release.
