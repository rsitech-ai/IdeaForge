# IdeaForge

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![CI](https://github.com/rsitech-ai/IdeaForge/actions/workflows/ci.yml/badge.svg)](https://github.com/rsitech-ai/IdeaForge/actions/workflows/ci.yml)

IdeaForge is a native Mac, iPhone, and Apple Watch workspace for turning spoken ideas into transcripts, plans, validation work, and reviewable engineering packets. The repository contains the Apple clients, shared Swift core, tests, release tooling, and a single-node community backend for development and personal evaluation.

Public maintainer: [RSI Tech](https://rsitech.ai). Copyright owner: Rafal
Sikora. Public and confidential project contact: [info@rsitech.ai](mailto:info@rsitech.ai).

**Project status:** pre-1.0 and under active development. The source tree is
public, but no official binary release has been published. APIs, backend
contracts, and persisted formats may change before 1.0; versioned changes are
tracked in [CHANGELOG.md](CHANGELOG.md).

The project does not include a deployed production service. Cloud AI, cross-device backend sync, account plans, and web account management require a backend that implements the documented contract.

## Download for Mac

Official Mac builds are distributed outside the Mac App Store through the [GitHub Releases page](https://github.com/rsitech-ai/IdeaForge/releases). An official binary must carry the maintainer's Developer ID signature, an Apple notarization ticket, a stapled ticket on the app and DMG, and the release workflow's provenance. If the Releases page has no DMG with that evidence, build from source.

IdeaForge checks for Mac updates with Sparkle 2.9.4. The app verifies update metadata with its embedded EdDSA public key. A GitHub signature, a Developer ID signature, an Apple notarization ticket, and a Sparkle signature prove different parts of the release chain; see [docs/RELEASING.md](docs/RELEASING.md).

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
- Deterministic local workflow and test implementations.

Backend upload, shared workspace sync, provider-backed transcription, cloud workflow execution, account usage, and web account management stay unavailable until you configure a backend session with the required capability.

The direct-download Mac app does not use StoreKit. It opens HTTPS plan-management or account-deletion URLs supplied by a validated backend session. The iPhone app retains its App Store purchase and restore path.

## Community backend

Run the dependency-free backend on localhost:

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
- `script/mock_backend.py`: community development server.
- `script/release_macos.sh`: maintainer-only Developer ID and notarization pipeline.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the trust boundaries and data paths.

## Contributing and security

Contributions use Apache License 2.0 and require a Developer Certificate of Origin sign-off. Read [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Report vulnerabilities through GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md). Do not put recordings, transcripts, credentials, private URLs, local paths, or exploit details in a public issue.

## License

Source and the assets listed in [ASSET_PROVENANCE.md](ASSET_PROVENANCE.md) are offered under Apache License 2.0. Product identity remains subject to [TRADEMARKS.md](TRADEMARKS.md).
