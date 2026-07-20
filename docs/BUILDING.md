# Building IdeaForge

## Verified toolchain

The release branch is verified with:

| Component | Version or target |
| --- | --- |
| Xcode | 26.6, build 17F113 |
| Swift language mode | 6 |
| XcodeGen | 2.45.4 |
| macOS deployment target | 14.0 |
| iOS deployment target | 17.0 |
| watchOS deployment target | 10.0 |
| Sparkle | 2.9.4, exact package pin |

Newer compatible tools may work, but they do not replace verification on this matrix.

Install Xcode from Apple and select it with `xcode-select`. Install XcodeGen 2.45.4, then confirm the tools:

```bash
xcodebuild -version
xcodegen --version
swift --version
```

## Generate the project

`project.yml` is the source of truth for targets, settings, package pins, bundle identifiers, and deployment versions.

```bash
xcodegen generate
test -f IdeaForge.xcodeproj/project.pbxproj
```

The generated project is ignored by Git. Review target, package, bundle, and version changes in `project.yml`; CI generates a new project from that file for every run.

## Test the shared core

```bash
swift build
swift test
```

Swift Package Manager builds `IdeaForgeCore`. App targets use the generated Xcode project.

## Build the apps

Build an unsigned Mac community app:

```bash
xcodebuild \
  -project IdeaForge.xcodeproj \
  -scheme IdeaForgeMac \
  -configuration Debug \
  -derivedDataPath DerivedData-mac \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build iPhone and Watch targets for generic simulators:

```bash
xcodebuild \
  -project IdeaForge.xcodeproj \
  -scheme IdeaForgeiOS \
  -configuration Debug \
  -derivedDataPath DerivedData-ios \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project IdeaForge.xcodeproj \
  -scheme IdeaForgeWatch \
  -configuration Debug \
  -derivedDataPath DerivedData-watch \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Use a named simulator or a registered device for runtime tests. Device builds require your Apple development team and provisioning profiles.

## Run the Mac app

```bash
./script/build_and_run.sh --verify
```

This helper builds and launches the local app. A successful local launch does not prove Developer ID signing, notarization, update delivery, microphone permission, or Watch transfer.

## Test the community backend

```bash
python3 script/mock_backend.py --self-test
script/run_local_sync_e2e.py
python3 script/review_privacy_logs.py --self-test
```

The first two commands exercise a local single-workspace contract. They do not prove a hosted service.

## Public-source checks

The auditor requires new report paths inside the audited tree. Use a disposable clean snapshot for strict public-profile checks:

```bash
destination="$(mktemp -d)/IdeaForge"
./script/create_public_source_snapshot.sh --destination "$destination"
(
  cd "$destination"
  swift test
  python3 script/mock_backend.py --self-test
)
```

The snapshot builder requires a clean committed source tree, removes private release history, audits the exported files, and creates one new `main` commit without the source Git objects.

## Distributing a fork

An unsigned or self-signed build is a community build. Before distributing a fork, replace the product name, icons, bundle identifiers, Sparkle feed URL, Sparkle public key, signing identity, and download links. Publish your source changes under Apache-2.0 and keep the required notices. Follow [TRADEMARKS.md](../TRADEMARKS.md).
