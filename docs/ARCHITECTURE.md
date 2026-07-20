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
Community backend or operator service
        |
        +---- object storage, workspace state, jobs, usage, account URLs
        +---- optional transcription and workflow providers
```

`IdeaForgeCore` owns shared domain models, persistence rules, privacy modes, backend request contracts, capability gates, workflow validation, local object encryption, and packet export. Swift Package Manager tests this layer without launching an app.

The Mac app supplies the project studio, review and export tools, backend settings, web account-management handoff, and Sparkle updater. The iPhone app supplies mobile capture, review, backend upload and sync, Watch bridging, and StoreKit flows. The Watch app records and transfers captures through the paired iPhone.

The Watch-to-Mac path is intentionally two-stage:

1. The Watch persists a capture locally and queues the audio file with `WatchConnectivity`.
2. The iPhone copies the transient received file into its durable inbox, persists the recording and upload job, and only then acknowledges the import to the Watch.
3. The iPhone uploads due audio work and publishes a device-neutral workspace snapshot to the configured backend.
4. iPhone and Mac synchronization pull from the last accepted remote revision before push. A newer remote revision is applied before either client publishes local changes. Independent projects are merged and published in the same synchronization pass; edits to the same project stop for review.

Queued transfers and import acknowledgements tolerate temporary reachability loss. A Watch receipt is not considered complete until its state is saved locally. Physical paired-device testing remains required because Simulator does not exercise WatchConnectivity file transfer.

## Local data boundary

Each Apple client stores its local workspace and recordings under its application container. Secrets and local object-store keys use Keychain. Packet export writes reviewable files after validating their paths. Local mode requires no backend credential.

The clients do not treat backend responses as trusted state on receipt. They require a validated session and matching workspace, check route capabilities, enforce privacy mode, validate response contracts, and apply sync conflict rules before persistence.

Workspace snapshots exclude device-local audio paths, upload jobs, Watch reachability, and local failure/activity counters. Snapshot identifiers and relationships are validated before dictionaries or persistent state are constructed. When a remote snapshot is applied, each client restores its own matching local audio and upload state. The sync receipt separately records the remote cursor and the local revision that was actually published so an edit made while a request is in flight remains eligible for the next publish.

Background URL-session completion is not acknowledged to the system until the iPhone has reconciled the durable upload receipt and run the next queue refresh. App appearance performs the same reconciliation as a recovery path.

## Backend boundary

The repository contains `script/mock_backend.py`, a single-node community server. It uses a configured bearer token, one workspace scope, local object files, and SQLite. It can exercise the protocol and optional provider adapters. It cannot isolate unrelated users or meet production availability and operations requirements.

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
