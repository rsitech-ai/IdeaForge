# IdeaForge

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![CI](https://github.com/rsitech-ai/IdeaForge/actions/workflows/ci.yml/badge.svg)](https://github.com/rsitech-ai/IdeaForge/actions/workflows/ci.yml)

IdeaForge is a native Mac, iPhone, and Apple Watch workspace for turning spoken ideas into transcripts, plans, validation work, and reviewable engineering packets. The repository contains the Apple clients, shared Swift core, tests, release tooling, a development mock backend, and a production-local backend for one operator on a private LAN.

Public maintainer: [RSI Tech](https://rsitech.ai). Copyright owner: Rafal
Sikora. Public and confidential project contact: [info@rsitech.ai](mailto:info@rsitech.ai).

**Project status:** pre-1.0 and under active development. The source tree is
public, but no official binary release has been published. APIs, backend
contracts, and persisted formats may change before 1.0; versioned changes are
tracked in [CHANGELOG.md](CHANGELOG.md).

The project does not include a hosted production service. The production-local backend can synchronize one workspace between paired devices without S3, PostgreSQL, Redis, Docker, a public tunnel, or OpenAI. Hosted account plans and web account management still require a separate service.

## Download for Mac

Official Mac builds are distributed outside the Mac App Store through the [GitHub Releases page](https://github.com/rsitech-ai/IdeaForge/releases). An official binary must carry the maintainer's Developer ID signature, an Apple notarization ticket, a stapled ticket on the app and DMG, and the release workflow's provenance. If the Releases page has no DMG with that evidence, build from source.

IdeaForge checks for Mac updates with Sparkle 2.9.6. The app verifies update metadata with its embedded EdDSA public key. A GitHub signature, a Developer ID signature, an Apple notarization ticket, and a Sparkle signature prove different parts of the release chain; see [docs/RELEASING.md](docs/RELEASING.md).

## Build from source

The verified toolchain is Xcode 26.6, Swift 6, and XcodeGen 2.45.4. The deployment targets are macOS 14, iOS 17, and watchOS 10.

```bash
xcodegen generate
swift test
xcodebuild \
  -project IdeaForge.xcodeproj \
  -scheme IdeaForgeMac \
  -configuration Debug \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

A source build is a community build. Distributors must use their own bundle identifiers, product name, artwork, signing identity, and update feed. The [trademark policy](TRADEMARKS.md) explains how to describe forks.

[docs/BUILDING.md](docs/BUILDING.md) covers every platform and the test commands.

`Package.swift` exposes `IdeaForgeCore` so the shared logic can be built and
tested without Xcode. It is an internal, pre-stable project surface rather than
a supported third-party library API.

## What works without a backend

- Local recording, workspace persistence, transcript and project review, and packet export.
- Encrypted local object storage with keys held in Keychain.
- Watch-to-iPhone recording handoff on paired devices.
- On supported iPhone and Mac configurations, local enrichment: on-device Apple Speech transcription of audio already on that device, followed by an optional Foundation Models title proposal.
- Deterministic local workflow and test implementations.

Backend upload and shared workspace sync stay unavailable until you configure either the production-local backend or another backend session with the required capability. Provider-backed transcription, cloud workflow execution, account usage, and web account management are not supplied by the production-local backend.

### Local enrichment and sync privacy

Local enrichment is intentionally split. Apple Speech transcribes the original audio file held by the iPhone or Mac and requires on-device recognition; if authorization, local audio, or on-device recognition is unavailable, the action fails without a cloud-speech fallback. Foundation Models can then propose a title from a completed transcript, but it is not used for transcription. A transcript still saves when the title model is unavailable, and a user-authored title is preserved.

Foundation Models title generation is available only where the framework, operating system, device eligibility, Apple Intelligence setting, model readiness, and transcript locale permit it; the Watch has no Foundation Models enrichment path. A bounded physical Watch-to-iPhone-to-Mac recording and enriched return to iPhone have been observed. This is not an endurance, transcription-accuracy, or universal device-eligibility guarantee. See [local backend behavior and limits](docs/LOCAL_BACKEND.md#return-synchronization-and-current-limits).

If configured, authorized backend sync is used, it transfers the enriched project data (including transcript, title, and revision time) but excludes device-local audio paths and upload queues. A receiving device only restores audio state that it already owns. Private Local mode keeps automatic backend sync off; the Local Backend connection uses authenticated HTTPS on the private LAN and ordinary files on the operator's Mac.

The direct-download Mac app does not use StoreKit. It opens HTTPS plan-management or account-deletion URLs supplied by a validated backend session. The iPhone app retains its App Store purchase and restore path.

## Community backend

For a durable one-operator private-LAN deployment, use the production-local
backend documented in [docs/LOCAL_BACKEND.md](docs/LOCAL_BACKEND.md). It uses
SQLite WAL and ordinary local recording files, pairs each device separately,
supports revocation, rate limits requests durably, and provides verified local
backup/restore tooling. It does not call OpenAI or upload data to object
storage.

For protocol development only, run the dependency-free mock backend on
localhost:

```bash
python3 script/mock_backend.py \
  --host 127.0.0.1 \
  --port 8765 \
  --token dev-token \
  --workspace-id local-dev-workspace \
  --state-dir .local/backend
```

This server uses one process, one configured bearer token, one workspace scope, local files, and SQLite. It has no TLS termination, tenant isolation, operator authentication, managed secrets, durable queue, or production availability design. Do not expose it to the public internet.

[docs/SELF_HOSTING.md](docs/SELF_HOSTING.md) documents storage, backups, optional provider credentials, and the boundary between this community server and a production service. [docs/backend-contract.md](docs/backend-contract.md) defines the client protocol.

## Project map

- `Sources/IdeaForgeCore`: shared models, persistence, workflow logic, backend clients, privacy gates, and tests.
- `Sources/IdeaForgeMac`: Mac studio, account portal handoff, and Sparkle updater.
- `Sources/IdeaForgeiOS`: iPhone capture, review, sync, and App Store account flow.
- `Sources/IdeaForgeWatch`: Watch capture and transfer.
- `script/local_backend.py`: production-local private-LAN service and operator CLI.
- `script/mock_backend.py`: community development server.
- `script/release_macos.sh`: maintainer-only Developer ID and notarization pipeline.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the trust boundaries and data paths.

## Contributing and security

Contributions use Apache License 2.0 and require a Developer Certificate of Origin sign-off. Read [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Report vulnerabilities through GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md). Do not put recordings, transcripts, credentials, private URLs, local paths, or exploit details in a public issue.

## License

Source and the assets listed in [ASSET_PROVENANCE.md](ASSET_PROVENANCE.md) are offered under Apache License 2.0. Product identity remains subject to [TRADEMARKS.md](TRADEMARKS.md).
