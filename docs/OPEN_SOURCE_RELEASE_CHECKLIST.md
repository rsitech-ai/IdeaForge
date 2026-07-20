# Open-source release checklist

Use this as the owner-sealed gate for the first official IdeaForge release.
Evidence must refer to the exact source commit and tag.

## Owner and legal decisions

- [ ] Confirm the 36 entries in `ASSET_PROVENANCE.md` were created by or for the
      owner and may be redistributed under Apache-2.0.
- [ ] Confirm `NOTICE`, Apache-2.0 licensing, and `TRADEMARKS.md` express the
      intended public grant and mark restrictions.
- [ ] Confirm GitHub private vulnerability reporting is an acceptable
      confidential Code of Conduct enforcement channel, or provide another
      maintained private contact.
- [x] Use `rsitech-ai/IdeaForge` as the canonical public repository and release
      feed owner.
- [x] Start the canonical repository from the audited source snapshot with no
      inherited personal-repository objects or legacy metadata exceptions.

## Repository-host controls

- [ ] Apply and verify the `main` and `v*` rulesets in
      `docs/REPOSITORY_SETTINGS.md`.
- [ ] Add an effective required DCO status check or revise the documented policy.
- [ ] Verify Sparkle appears in GitHub's dependency graph at the pinned revision.
- [ ] Complete code-scanning analysis for the exact release commit.
- [ ] Confirm all seven release-environment secrets exist and remain scoped to
      the protected environment.

## Exact source and artifacts

- [ ] CI is green on the exact release commit.
- [ ] `python3 script/audit_public_git_metadata.py --strict` passes.
- [ ] The exact `v<version>` tag points at current `main`.
- [ ] The versioned release notes and changelog match the tag.
- [ ] The protected workflow produces Developer ID signed artifacts with secure
      timestamps, accepted notarization results, stapled tickets, checksums,
      SPDX SBOM, Sparkle signature, appcast, and GitHub attestations.
- [ ] The app and DMG pass `codesign`, `spctl`, and `stapler` verification.
- [ ] A prior installed build completes N-to-N+1 update on a clean Mac or clean
      macOS user account.
- [ ] The draft GitHub release, appcast, checksums, version, and bytes agree.

Publication remains prohibited while any required item is unchecked.
