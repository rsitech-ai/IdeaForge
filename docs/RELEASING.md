# Releasing the Mac app

This document describes the maintainer's direct-download release. Community distributors need their own identity, bundle identifiers, artwork, update feed, and Sparkle key pair.

## Trust chain

| Evidence | What it proves | What it does not prove |
| --- | --- | --- |
| Source commit and tag | Which public source revision the maintainer selected | Binary contents or Apple review |
| GitHub artifact attestation | Which protected workflow produced an artifact | Apple notarization or update authorization |
| Developer ID signature and secure timestamp | Apple issued the signing certificate to the named team and the signed code has not changed | Apple malware scan acceptance |
| Apple notarization ticket and staple | Apple accepted that submitted artifact and Gatekeeper can verify it offline | Source-to-binary reproducibility |
| Sparkle EdDSA signature | The holder of the update private key authorized the update archive | Apple identity, notarization, or source provenance |
| SHA-256 file | Download integrity against the published digest | Publisher identity on its own |

Treat an artifact as official only when the GitHub release, Apple evidence, and Sparkle metadata agree on version and bytes.

## Maintainer prerequisites

- A clean public repository at the exact release commit.
- An annotated tag named `v<MARKETING_VERSION>` on that commit.
- Xcode 26.6 and XcodeGen 2.45.4.
- The exact Developer ID Application identity and private key required by `script/release_macos.sh`.
- A Keychain notarytool profile. Create it through Apple's interactive credential flow, for example `xcrun notarytool store-credentials IdeaForgeNotary`. Do not export the password or API private key into shell history.
- The Sparkle EdDSA private key in the release secret store. The repository contains only the public key.
- A protected GitHub `release` environment with reviewers and scoped release secrets.

The release script rejects a different team or signing identity. That restriction prevents a community build from being mislabeled as an official build.

The GitHub `release` environment supplies these secrets:

| Secret | Content |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID certificate and private key export |
| `DEVELOPER_ID_P12_PASSWORD` | Password for that PKCS#12 export |
| `SIGNING_KEYCHAIN_PASSWORD` | Random password for the workflow's temporary Keychain |
| `NOTARY_API_KEY_P8_BASE64` | Base64-encoded App Store Connect notary API private key |
| `NOTARY_API_KEY_ID` | App Store Connect API key identifier |
| `NOTARY_API_ISSUER_ID` | App Store Connect team API issuer UUID |
| `SPARKLE_ED25519_PRIVATE_KEY` | Exact private key exported by Sparkle `generate_keys -x` |

Limit the environment to release tags and require owner review. The workflow checks that the tag points at the current `main` commit before it exposes secrets. CODEOWNERS covers the workflow, release script, appcast, SBOM generator, and embedded Sparkle public key.

The workflow creates a temporary Keychain, imports the certificate, validates and stores the notary profile, imports the Sparkle key, and compares its public key with `SUPublicEDKey`. Its final step deletes temporary credential files and the Keychain. GitHub must never store unencoded raw files in the repository or workflow artifacts. Base64 is transport encoding, not encryption; GitHub environment access controls protect these values.

## Prepare a version

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Generate `IdeaForge.xcodeproj` with XcodeGen 2.45.4.
3. Update `CHANGELOG.md` and `docs/releases/<version>.md`. The protected
   workflow generates the signed appcast entry from the verified archive.
4. Run the full test and public-source audit matrix.
5. Commit all release inputs. Confirm `git status --porcelain --untracked-files=all` is empty.
6. Create and push the exact `v<version>` tag only after reviewing the commit.

## Local Developer ID proof

The local mode makes no notarization request and omits the secure-timestamp requirement. It cannot produce a distribution-ready label.

```bash
export DEVELOPMENT_TEAM=2NY8A789TN
export DEVELOPER_ID_APPLICATION=8E28D5C9EE3B03AB145B4827B534DA9D765CA8D2
export RELEASE_VERSION=0.1.0
./script/release_macos.sh --package-only
```

Success creates `dist/release/local-export/IdeaForge-<version>/` with readiness `local_export_verified`. A Keychain error such as `errSecInternalComponent` blocks this gate even when `security find-identity` lists the certificate; fix private-key access before continuing.

## Notarized release

Run this only from the clean, tagged public commit:

```bash
export DEVELOPMENT_TEAM=2NY8A789TN
export DEVELOPER_ID_APPLICATION=8E28D5C9EE3B03AB145B4827B534DA9D765CA8D2
export RELEASE_VERSION=0.1.0
export NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary
./script/release_macos.sh --notarize
```

The script archives with hardened runtime, exports with Developer ID, audits the app and nested Mach-O signatures, rejects `get-task-allow`, requires App Sandbox on the app, submits the app to Apple, staples it, creates and signs a DMG with an Applications link, submits and staples the DMG, and writes:

```text
dist/release/IdeaForge-<version>.dmg
dist/release/IdeaForge-<version>.zip
dist/release/SHA256SUMS
dist/release/manifest.json
dist/release/notary/
```

The script stores sanitized notary results. It discards raw response output and never accepts raw Apple credential environment variables.

The app embedded in both the DMG and update ZIP contains `LICENSE`, `NOTICE`,
`THIRD_PARTY_NOTICES.md`, and Sparkle's complete upstream license inventory in
its resources. Treat omission of any of these files as a packaging failure.

## Independent verification

Before publishing, verify both the extracted app and mounted DMG:

```bash
codesign --verify --strict --verbose=2 /path/to/IdeaForge.app
codesign --display --verbose=4 /path/to/IdeaForge.app
spctl --assess --type execute --verbose=4 /path/to/IdeaForge.app
xcrun stapler validate /path/to/IdeaForge.app
xcrun stapler validate dist/release/IdeaForge-<version>.dmg
shasum -a 256 -c dist/release/SHA256SUMS
```

Test first launch and update installation on a second clean Mac or clean macOS user account. A build-host launch does not replace that check.

## Publish

The protected release workflow must upload the DMG, ZIP, checksums, manifest, sanitized notary reports, SBOM, and GitHub artifact attestations. It must sign the ZIP with Sparkle's EdDSA key and publish an appcast entry that matches the ZIP length, version, download URL, and signature. The workflow creates the GitHub release as a draft from the reviewed versioned notes, updates and verifies the appcast, and only then publishes the release.

Do not publish a release when any required signature, notary status, staple validation, Gatekeeper assessment, checksum, attestation, or appcast field is missing. Keep a failed tag unpublished or mark the GitHub release as a draft until the exact commit passes.

The Mac appcast URL is `https://raw.githubusercontent.com/rsitech-ai/IdeaForge/main/updates/appcast.xml`. A release is incomplete until that URL serves the signed entry and an installed prior version completes an N-to-N+1 update.
