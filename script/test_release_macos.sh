#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/script/release_macos.sh"
EXPECTED_TEAM="2NY8A789TN"
EXPECTED_IDENTITY="325BE7BDA73543F37311F400F231DC751E87FB77"
SECRET_SENTINEL="task3-secret-must-not-leak"

if [[ ! -x "$RELEASE_SCRIPT" ]]; then
  echo "Missing executable release script: $RELEASE_SCRIPT" >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "test_release_macos.sh: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq "$needle" "$file" || fail "expected '$needle' in $file"
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq "$needle" "$file"; then
    fail "unexpected '$needle' in $file"
  fi
}

assert_before() {
  local first="$1"
  local second="$2"
  local file="$3"
  local first_line second_line
  first_line="$(grep -n -m1 -F "$first" "$file" | cut -d: -f1)"
  second_line="$(grep -n -m1 -F "$second" "$file" | cut -d: -f1)"
  [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] \
    || fail "expected '$first' before '$second' in $file"
}

assert_same_line_contains() {
  local first="$1"
  local second="$2"
  local file="$3"
  if ! grep -F "$first" "$file" | grep -Fq "$second"; then
    fail "expected one line containing '$first' and '$second' in $file"
  fi
}

assert_count() {
  local expected="$1"
  local needle="$2"
  local file="$3"
  local actual
  actual="$(grep -F -c "$needle" "$file" || true)"
  [[ "$actual" == "$expected" ]] \
    || fail "expected $expected occurrences of '$needle' in $file, found $actual"
}

write_fake_tools() {
  local fixture="$1"
  local fakebin="$fixture/fakebin"
  mkdir -p "$fakebin"

  while IFS= read -r tool; do
    ln -s "$fixture/fake-tool" "$fakebin/$tool"
  done <<'EOF'
codesign
file
git
hdiutil
security
xcodebuild
xcrun
EOF
}

new_fixture() {
  local name="$1"
  local fixture="$TEST_ROOT/$name"
  mkdir -p "$fixture/script" "$fixture/Config" "$fixture/IdeaForge.xcodeproj"
  cp "$RELEASE_SCRIPT" "$fixture/script/release_macos.sh"
  cp "$ROOT_DIR/Config/DeveloperIDExportOptions.plist" "$fixture/Config/DeveloperIDExportOptions.plist"
  mkdir -p "$fixture/ThirdPartyLicenses"
  cp "$ROOT_DIR/LICENSE" "$fixture/LICENSE"
  cp "$ROOT_DIR/NOTICE" "$fixture/NOTICE"
  cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$fixture/THIRD_PARTY_NOTICES.md"
  cp "$ROOT_DIR/ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt" \
    "$fixture/ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt"
  chmod +x "$fixture/script/release_macos.sh"
  printf '%s\n' \
    'settings:' \
    '  base:' \
    '    MARKETING_VERSION: "0.1.0"' \
    '    CURRENT_PROJECT_VERSION: "1"' > "$fixture/project.yml"

  cp "$TEST_ROOT/fake-tool-template" "$fixture/fake-tool"
  chmod +x "$fixture/fake-tool"
  write_fake_tools "$fixture"
  printf '%s\n' "$fixture"
}

run_release() {
  local fixture="$1"
  local output="$2"
  shift 2
  # Bash 3.2 treats an empty array expansion as unbound under `set -u`.
  local env_args=("TASK3_RELEASE_SELF_TEST=1")
  while [[ "$#" -gt 0 && "$1" == *=* ]]; do
    env_args+=("$1")
    shift
  done
  set +e
  env \
    PATH="$fixture/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    FAKE_STATE_DIR="$fixture/fake-state" \
    FAKE_COMMAND_LOG="$fixture/commands.log" \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM" \
    DEVELOPER_ID_APPLICATION="$EXPECTED_IDENTITY" \
    RELEASE_VERSION="0.1.0" \
    "${env_args[@]}" \
    "$fixture/script/release_macos.sh" "$@" > "$output" 2>&1
  local status=$?
  set -e
  return "$status"
}

cat > "$TEST_ROOT/fake-tool-template" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

tool="$(basename "$0")"
mkdir -p "$FAKE_STATE_DIR"
printf '%s' "$tool" >> "$FAKE_COMMAND_LOG"
printf ' %q' "$@" >> "$FAKE_COMMAND_LOG"
printf '\n' >> "$FAKE_COMMAND_LOG"

make_app() {
  local app="$1"
  local fixture="${FAKE_STATE_DIR%/fake-state}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/Sparkle.framework/Versions/B" \
    "$app/Contents/Resources/ThirdPartyLicenses"
  printf '#!/bin/sh\n' > "$app/Contents/MacOS/IdeaForge"
  printf 'fake Mach-O\n' > "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
  cp "$fixture/LICENSE" "$app/Contents/Resources/LICENSE"
  cp "$fixture/NOTICE" "$app/Contents/Resources/NOTICE"
  cp "$fixture/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
  cp "$fixture/ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt" \
    "$app/Contents/Resources/ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt"
  chmod +x "$app/Contents/MacOS/IdeaForge" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
}

case "$tool" in
  git)
    if [[ " $* " == *" rev-parse --is-inside-work-tree "* ]]; then
      if [[ "${FAKE_GIT_NOT_WORKTREE:-0}" == "1" ]]; then
        printf 'false\n'
      else
        printf 'true\n'
      fi
    elif [[ " $* " == *" status --porcelain --untracked-files=all "* ]]; then
      [[ "${FAKE_GIT_STATUS_FAIL:-0}" != "1" ]] || exit 128
      [[ "${FAKE_GIT_DIRTY:-0}" != "1" ]] || printf '?? fixture-dirty\n'
    elif [[ " $* " == *" describe --tags --exact-match HEAD "* ]]; then
      [[ "${FAKE_GIT_TAG_MISSING:-0}" != "1" ]] || exit 128
      printf '%s\n' "${FAKE_GIT_TAG:-v0.1.0}"
    else
      echo "Unexpected fake git invocation" >&2
      exit 89
    fi
    ;;
  security)
    if [[ "${FAKE_IDENTITY_MISSING:-0}" == "1" ]]; then
      echo '  1) BADBADBADBADBADBADBADBADBADBADBADBADBADB "Developer ID Application: Wrong Person (BADTEAM123)"'
    else
      echo '  1) 325BE7BDA73543F37311F400F231DC751E87FB77 "Developer ID Application: Rafal Sikora (2NY8A789TN)"'
    fi
    ;;
  xcodebuild)
    previous=""
    archive_path=""
    export_path=""
    for argument in "$@"; do
      if [[ "$previous" == "-archivePath" ]]; then archive_path="$argument"; fi
      if [[ "$previous" == "-exportPath" ]]; then export_path="$argument"; fi
      previous="$argument"
    done
    if [[ " $* " == *" archive "* ]]; then
      make_app "$archive_path/Products/Applications/IdeaForge.app"
    elif [[ " $* " == *" -exportArchive "* ]]; then
      make_app "$export_path/IdeaForge.app"
    else
      echo "Unexpected fake xcodebuild invocation" >&2
      exit 90
    fi
    ;;
  codesign)
    if [[ " $* " == *" --entitlements "* ]]; then
      cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
    elif [[ " $* " == *" -d "* || " $* " == *" -dv "* || " $* " == *" --display "* ]]; then
      cat >&2 <<'DETAILS'
Executable=/fixture/IdeaForge
Identifier=com.s1kor.ideaforge.mac
Authority=Developer ID Application: Rafal Sikora (2NY8A789TN)
TeamIdentifier=2NY8A789TN
Runtime Version=26.0.0
Timestamp=Jul 15, 2026 at 12:00:00
flags=0x10000(runtime)
DETAILS
    fi
    ;;
  file)
    echo 'Mach-O 64-bit executable arm64'
    ;;
  xcrun)
    if [[ -n "${APPLE_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -n "${NOTARY_PASSWORD:-}" ]]; then
      printf 'LEAKED:%s:%s:%s\n' "${APPLE_ID:-}" "${APPLE_APP_SPECIFIC_PASSWORD:-}" "${NOTARY_PASSWORD:-}" >> "$FAKE_COMMAND_LOG"
    fi
    if [[ "${1:-}" == "notarytool" && "${2:-}" == "submit" ]]; then
      counter_file="$FAKE_STATE_DIR/notary-submit-count"
      count=0
      [[ ! -f "$counter_file" ]] || count="$(cat "$counter_file")"
      count=$((count + 1))
      printf '%s\n' "$count" > "$counter_file"
      case "${FAKE_NOTARY_RESULT:-accepted}" in
        malformed) printf '{not-json\n' ;;
        rejected) printf '{"id":"fixture-rejected","status":"Rejected","message":"Invalid signature"}\n' ;;
        accepted) printf '{"id":"fixture-%s","status":"Accepted","message":"Processing complete"}\n' "$count" ;;
        *) exit 91 ;;
      esac
    elif [[ "${1:-}" == "notarytool" && "${2:-}" == "log" ]]; then
      if [[ "${FAKE_NOTARY_LOG_FAIL:-0}" == "1" ]]; then
        echo 'task3-secret-must-not-leak raw notarytool stderr' >&2
        exit 94
      fi
      printf '{"jobId":"fixture-rejected","status":"Rejected","statusSummary":"Archive contains critical validation errors","issues":[{"severity":"error","code":4000,"path":"IdeaForge.app","message":"Invalid signature"}]}\n'
    elif [[ "${1:-}" == "stapler" && "${2:-}" == "staple" ]]; then
      [[ "${FAKE_STAPLER_FAIL:-0}" != "1" ]] || exit 92
    elif [[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]]; then
      :
    else
      echo "Unexpected fake xcrun invocation" >&2
      exit 93
    fi
    ;;
  hdiutil)
    stage="${@: -5:1}"
    for legal_file in LICENSE NOTICE THIRD_PARTY_NOTICES.md ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt; do
      [[ -f "$stage/IdeaForge.app/Contents/Resources/$legal_file" ]] || exit 95
    done
    output="${!#}"
    : > "$output"
    ;;
esac
EOF

fixture="$(new_fixture wrong-identity)"
if run_release "$fixture" "$fixture/output.log" DEVELOPER_ID_APPLICATION=BAD --package-only --allow-dirty; then
  fail "wrong identity unexpectedly passed"
fi
assert_contains "DEVELOPER_ID_APPLICATION must equal $EXPECTED_IDENTITY" "$fixture/output.log"

fixture="$(new_fixture missing-installed-identity)"
if run_release "$fixture" "$fixture/output.log" FAKE_IDENTITY_MISSING=1 --package-only --allow-dirty; then
  fail "missing installed identity unexpectedly passed"
fi
assert_contains "exact Developer ID Application identity is not installed" "$fixture/output.log"

fixture="$(new_fixture missing-version)"
if env -u RELEASE_VERSION \
  PATH="$fixture/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
  FAKE_STATE_DIR="$fixture/fake-state" FAKE_COMMAND_LOG="$fixture/commands.log" \
  FAKE_GIT_TAG_MISSING=1 \
  DEVELOPMENT_TEAM="$EXPECTED_TEAM" DEVELOPER_ID_APPLICATION="$EXPECTED_IDENTITY" \
  "$fixture/script/release_macos.sh" --package-only --allow-dirty > "$fixture/output.log" 2>&1; then
  fail "missing version unexpectedly passed"
fi
assert_contains "RELEASE_VERSION is required" "$fixture/output.log"

fixture="$(new_fixture output-collision)"
mkdir -p "$fixture/dist/release"
: > "$fixture/dist/release/IdeaForge-0.1.0.dmg"
if run_release "$fixture" "$fixture/output.log" NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary --notarize; then
  fail "output collision unexpectedly passed"
fi
assert_contains "Refusing to overwrite existing release output" "$fixture/output.log"
[[ ! -f "$fixture/commands.log" ]] || fail "output collision invoked external tooling"

fixture="$(new_fixture non-git-notarization)"
if run_release "$fixture" "$fixture/output.log" \
  NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary \
  FAKE_GIT_NOT_WORKTREE=1 \
  --notarize; then
  fail "non-worktree notarization unexpectedly passed"
fi
assert_contains "real notarization requires a valid Git worktree" "$fixture/output.log"
assert_not_contains "security find-identity" "$fixture/commands.log"
assert_not_contains "xcodebuild" "$fixture/commands.log"

fixture="$(new_fixture git-status-failure)"
if run_release "$fixture" "$fixture/output.log" \
  NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary \
  FAKE_GIT_STATUS_FAIL=1 \
  --notarize; then
  fail "notarization with unavailable Git status unexpectedly passed"
fi
assert_contains "unable to verify clean Git worktree: git status failed" "$fixture/output.log"
assert_not_contains "security find-identity" "$fixture/commands.log"
assert_not_contains "xcodebuild" "$fixture/commands.log"

fixture="$(new_fixture malformed-json)"
if run_release "$fixture" "$fixture/output.log" NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary FAKE_NOTARY_RESULT=malformed --notarize; then
  fail "malformed notarization JSON unexpectedly passed"
fi
assert_contains "Malformed notarization JSON" "$fixture/output.log"
assert_not_contains "hdiutil" "$fixture/commands.log"

fixture="$(new_fixture rejected-notarization)"
if run_release "$fixture" "$fixture/output.log" NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary FAKE_NOTARY_RESULT=rejected --notarize; then
  fail "rejected notarization unexpectedly passed"
fi
assert_contains "Notarization status is Rejected, expected Accepted" "$fixture/output.log"
assert_contains '"status": "Rejected"' "$fixture/dist/release/notary/app-submit.json"
assert_contains '"issues"' "$fixture/dist/release/notary/app-failure-log.json"
assert_not_contains "$SECRET_SENTINEL" "$fixture/dist/release/notary/app-submit.json"

fixture="$(new_fixture rejected-log-retrieval-failure)"
if run_release "$fixture" "$fixture/output.log" \
  NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary \
  FAKE_NOTARY_RESULT=rejected \
  FAKE_NOTARY_LOG_FAIL=1 \
  --notarize; then
  fail "rejected notarization with failed log retrieval unexpectedly passed"
fi
assert_contains "notarytool log retrieval failed" "$fixture/output.log"
assert_contains '"diagnostic": "notary_log_retrieval_failed"' "$fixture/dist/release/notary/app-failure-log.json"
assert_contains '"job_id": "fixture-rejected"' "$fixture/dist/release/notary/app-failure-log.json"
assert_contains '"notarization_status": "Rejected"' "$fixture/dist/release/notary/app-failure-log.json"
assert_contains '"raw_output_disposition": "discarded"' "$fixture/dist/release/notary/app-failure-log.json"
assert_not_contains "$SECRET_SENTINEL" "$fixture/output.log"
if grep -R -Fq "$SECRET_SENTINEL" "$fixture/dist"; then
  fail "credential sentinel leaked into rejected-log retrieval diagnostics"
fi

fixture="$(new_fixture stapler-failure)"
if run_release "$fixture" "$fixture/output.log" NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary FAKE_STAPLER_FAIL=1 --notarize; then
  fail "stapler failure unexpectedly passed"
fi
assert_contains "Failed to staple exported application" "$fixture/output.log"
assert_not_contains "hdiutil" "$fixture/commands.log"

fixture="$(new_fixture package-only)"
run_release "$fixture" "$fixture/output.log" --package-only --allow-dirty
assert_contains '"readiness": "local_export_verified"' "$fixture/dist/release/local-export/IdeaForge-0.1.0/manifest.json"
assert_before "xcodebuild -quiet -project" "xcodebuild -quiet -exportArchive" "$fixture/commands.log"
assert_before "xcodebuild -quiet -exportArchive" "codesign --verify" "$fixture/commands.log"
assert_not_contains "xcrun" "$fixture/commands.log"
assert_not_contains "hdiutil" "$fixture/commands.log"

fixture="$(new_fixture credential-safety)"
run_release "$fixture" "$fixture/output.log" \
  NOTARY_KEYCHAIN_PROFILE=IdeaForgeNotary \
  APPLE_ID="$SECRET_SENTINEL" \
  APPLE_APP_SPECIFIC_PASSWORD="$SECRET_SENTINEL" \
  NOTARY_PASSWORD="$SECRET_SENTINEL" \
  --notarize
assert_not_contains "$SECRET_SENTINEL" "$fixture/output.log"
assert_not_contains "$SECRET_SENTINEL" "$fixture/commands.log"
if grep -R -Fq "$SECRET_SENTINEL" "$fixture/dist"; then
  fail "credential sentinel leaked into release artifacts"
fi
assert_before "xcodebuild -quiet -project" "xcodebuild -quiet -exportArchive" "$fixture/commands.log"
assert_before "xcodebuild -quiet -exportArchive" "xcrun notarytool submit" "$fixture/commands.log"
assert_before "xcrun stapler staple" "hdiutil create" "$fixture/commands.log"
assert_before "hdiutil create" "codesign --force --timestamp --sign" "$fixture/commands.log"
assert_count 2 "xcrun stapler validate" "$fixture/commands.log"
assert_same_line_contains "xcrun stapler validate" "/export/IdeaForge.app" "$fixture/commands.log"
assert_same_line_contains "xcrun stapler validate" "IdeaForge-0.1.0.dmg" "$fixture/commands.log"
assert_contains '"readiness": "notarized_release_ready"' "$fixture/dist/release/manifest.json"
test -f "$fixture/dist/release/IdeaForge-0.1.0.dmg"
test -f "$fixture/dist/release/IdeaForge-0.1.0.zip"
test -f "$fixture/dist/release/SHA256SUMS"
for legal_file in LICENSE NOTICE THIRD_PARTY_NOTICES.md ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt; do
  unzip -Z1 "$fixture/dist/release/IdeaForge-0.1.0.zip" \
    | grep -Fx "IdeaForge.app/Contents/Resources/$legal_file" >/dev/null \
    || fail "update ZIP omitted $legal_file"
done

if rg -n -- '--deep' "$RELEASE_SCRIPT"; then
  fail "release script must never use codesign --deep"
fi

echo "test_release_macos.sh passed"
