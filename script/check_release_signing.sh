#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/IdeaForge.xcodeproj"
ARCHIVE_DIR="$ROOT_DIR/build/archives"
TEAM_ID="${DEVELOPMENT_TEAM:-}"

cd "$ROOT_DIR"

if [[ ! -d "$PROJECT" ]]; then
  xcodegen generate
fi

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(xcodebuild -project "$PROJECT" -scheme IdeaForgeiOS -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/DEVELOPMENT_TEAM =/ { print $2; exit }' \
    | tr -d '[:space:]')"
fi

if [[ -z "$TEAM_ID" ]]; then
  cat >&2 <<'EOF'
Release signing is not configured.

Set DEVELOPMENT_TEAM in project.yml or export DEVELOPMENT_TEAM=<team-id>, then run:
  xcodegen generate
  ./script/check_release_signing.sh

This check is fail-closed because App Store/TestFlight archives need a real Apple Developer team,
certificates, profiles, and entitlements. Debug ad-hoc signing is not release proof.
EOF
  exit 2
fi

echo "==> Development-signed Release archive check (not distribution-ready)"
echo "==> Using DEVELOPMENT_TEAM=$TEAM_ID"
echo "==> Available code signing identities"
security find-identity -p codesigning -v || true

mkdir -p "$ARCHIVE_DIR"

echo "==> Archiving macOS Release"
xcodebuild \
  -project "$PROJECT" \
  -scheme IdeaForgeMac \
  -configuration Release \
  -archivePath "$ARCHIVE_DIR/IdeaForgeMac.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

echo "==> Archiving iOS Release"
xcodebuild \
  -project "$PROJECT" \
  -scheme IdeaForgeiOS \
  -configuration Release \
  -archivePath "$ARCHIVE_DIR/IdeaForgeiOS.xcarchive" \
  -destination "generic/platform=iOS" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

echo "==> Development-signed Release archives created under $ARCHIVE_DIR"
echo "==> Readiness: development_archive_verified (not Developer ID export, notarization, or distribution readiness)"
