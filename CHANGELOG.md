# Changelog

All notable user-facing changes are recorded here. IdeaForge follows
[Semantic Versioning](https://semver.org/) from the first stable release. While
the major version is zero, minor releases may change source and backend APIs.

## Unreleased

### Added

- One-operator private-LAN backend with paired device credentials, TLS, Bonjour
  discovery, durable recordings/jobs, backup/restore and LaunchAgent supervision.
- Automatic Mac recording enrichment and foreground iPhone return synchronization,
  with a compact title/status projection for the Watch.
- Inbox-first iPhone presentation and consistent voice-flame branding.
- Bounded title prompts and backward-compatible generated-title provenance.

### Fixed

- Retry starvation when audio arrives before workspace metadata, expired-lease
  terminal writes, and completion without durable enrichment publication.
- Mac startup recovery after backend outages and misleading ready status.
- Stale Watch title/state updates and overbroad iPhone synchronization receipts.
- Mac Markdown export permission for user-selected destinations.

### Current limits

- This remains a source preview, not an official signed/notarized binary release.
- iOS controls background execution; immediate background return sync is not
  guaranteed. Watch title context currently covers the latest 24 updates.
- Full endurance, Watch acknowledgement inspection and universal model/device
  compatibility are not claimed. See `docs/LOCAL_BACKEND.md`.

## 0.1.0 - Unreleased

### Added

- Native Mac, iPhone, and Apple Watch clients with a shared Swift core.
- Local recording, persistence, review, packet export, and Watch-to-iPhone handoff.
- Dependency-free community backend for localhost development and personal evaluation.
- Mac update verification through Sparkle with maintainer-only signed and notarized release tooling.
- Privacy, public-source, release-contract, backend, and Apple-platform test coverage.

### Known limitations

- No production hosted backend is included.
- Provider-backed AI, production cross-device sync, subscriptions, APNs, and web account management require separately operated infrastructure.
- No official 0.1.0 binary has been published; source builds are community builds.
