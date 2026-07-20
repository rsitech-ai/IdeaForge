# Repository settings for a public release

This file records repository-host settings that cannot be enforced by source
files alone. Apply them only after owner approval, then capture screenshots or
API output in the release dossier.

## Canonical repository (2026-07-20)

- Repository: `rsitech-ai/IdeaForge`, public, default branch `main`.
- Canonical history begins with an audited standalone source snapshot and does
  not inherit objects from the earlier personal repository.
- Workflow permissions are declared read-only unless a job explicitly needs
  narrower write access; third-party workflow actions are pinned to full commit
  IDs.
- Rulesets, the protected `release` environment, security features, and release
  credentials remain repository-host controls that must be verified through
  GitHub before the first official release.

## Required `main` ruleset

Target the default branch and require:

1. Pull requests with at least one approval from an effective CODEOWNER.
2. The exact `CI / verify` required status check from the protected base SHA.
3. Conversation resolution and dismissal of stale approvals after new commits.
4. Linear history, no force pushes, and no deletion.
5. Explicit, narrow emergency bypass actors with bypass activity audited.

Do not claim the DCO policy is enforced until a required DCO status check is
also configured.

## Required `v*` tag ruleset

- Restrict tag creation, update, and deletion to release maintainers.
- Do not permit force updates.
- Keep the protected `release` environment restricted to matching tags and an
  owner approval.

## Dependency and code security

- Add an official, immutable dependency-submission path for the Xcode project's
  generated `Package.resolved`, then verify Sparkle revision
  `b6496a74a087257ef5e6da1c5b29a447a60f5bd7` appears in the dependency graph.
- Enable a supported Swift code-scanning configuration and confirm that an
  analysis for the exact release commit completes. Do not treat “no analysis”
  as “no findings.”
- Keep private vulnerability reporting, secret scanning, push protection,
  Dependabot alerts, and automated security fixes enabled.

## Repository identity

`rsitech-ai/IdeaForge` is the canonical source, issue, update, and release
location. RSI Tech is the public maintainer; Rafal Sikora is the copyright
owner and the founder account remains a CODEOWNER. Personal repository history
is not part of the canonical release history.

Use `https://rsitech.ai` as the repository homepage. Labels, social preview,
profile README, and profile pins are useful polish, but they are not
prerequisites for source correctness.
