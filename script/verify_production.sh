#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/IdeaForge.xcodeproj"
XCODEGEN_BIN="${XCODEGEN_BIN:-xcodegen}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
command -v "$XCODEGEN_BIN" >/dev/null 2>&1 || {
  echo "Missing XcodeGen executable: $XCODEGEN_BIN" >&2
  exit 2
}
command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
  echo "Missing Python executable: $PYTHON_BIN" >&2
  exit 2
}
IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.5}"
WATCH_GENERIC_DESTINATION="${WATCH_GENERIC_DESTINATION:-generic/platform=watchOS Simulator}"
WATCH_ULTRA_DESTINATION="${WATCH_ULTRA_DESTINATION:-}"
WATCH_ULTRA_NAME="${WATCH_ULTRA_NAME:-Apple Watch Ultra 3 (49mm)}"
WATCH_ULTRA_OS="${WATCH_ULTRA_OS:-26.5}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-2NY8A789TN}"

RUN_MAC_UI_TESTS="${RUN_MAC_UI_TESTS:-0}"
MAC_UI_AUTOMATION_AUTHORIZED="${MAC_UI_AUTOMATION_AUTHORIZED:-0}"
RUN_IOS_ACCESSIBILITY_MATRIX="${RUN_IOS_ACCESSIBILITY_MATRIX:-1}"
RUN_IOS_UI_SMOKE_SPLIT="${RUN_IOS_UI_SMOKE_SPLIT:-1}"
RUN_PRIVACY_LOG_REVIEW="${RUN_PRIVACY_LOG_REVIEW:-1}"
PRIVACY_LOG_REVIEW_LAST="${PRIVACY_LOG_REVIEW_LAST:-2h}"
RUN_LOCAL_SYNC_E2E="${RUN_LOCAL_SYNC_E2E:-1}"
RUN_RELEASE_SIGNING="${RUN_RELEASE_SIGNING:-auto}"
RUN_DIRECT_MAC_RELEASE="${RUN_DIRECT_MAC_RELEASE:-0}"
DIRECT_MAC_RELEASE_MODE="${DIRECT_MAC_RELEASE_MODE:-package-only}"
DIRECT_MAC_RELEASE_VERSION="${DIRECT_MAC_RELEASE_VERSION:-$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")}"
RUN_PHYSICAL_DEVICE_BUILDS="${RUN_PHYSICAL_DEVICE_BUILDS:-0}"
ALLOW_BLOCKED_PHYSICAL_DEVICE_GATE="${ALLOW_BLOCKED_PHYSICAL_DEVICE_GATE:-0}"
RUN_LIVE_DEPLOYED_BACKEND="${RUN_LIVE_DEPLOYED_BACKEND:-0}"
RUN_LIVE_AI_PROVIDER="${RUN_LIVE_AI_PROVIDER:-0}"
RUN_LIVE_APP_STORE_SERVER_API="${RUN_LIVE_APP_STORE_SERVER_API:-0}"
RUN_LIVE_APNS="${RUN_LIVE_APNS:-0}"

RUN_ID="${VERIFY_PRODUCTION_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
ARTIFACT_DIR="${VERIFY_PRODUCTION_ARTIFACT_DIR:-$ROOT_DIR/build/verification/task-first-ui-$RUN_ID}"
LOG_DIR="$ARTIFACT_DIR/logs"
RESULTS_FILE="$ARTIFACT_DIR/gates.tsv"
SUMMARY_FILE="$ARTIFACT_DIR/summary.md"
COMMANDS_FILE="$ARTIFACT_DIR/commands.log"
INPUT_MANIFEST_BEFORE="$ARTIFACT_DIR/verification-inputs-before.sha256"
INPUT_MANIFEST_AFTER="$ARTIFACT_DIR/verification-inputs-after.sha256"

MAC_DERIVED_DATA="$ROOT_DIR/DerivedData-production-mac"
IOS_DERIVED_DATA="$ROOT_DIR/DerivedData-production-ios"
IOS_GENERIC_DERIVED_DATA="$ROOT_DIR/DerivedData-production-ios-generic"
WATCH_GENERIC_DERIVED_DATA="$ROOT_DIR/DerivedData-production-watch-generic"
WATCH_ULTRA_DERIVED_DATA="$ROOT_DIR/DerivedData-production-watch-ultra"

repo_failures=0
external_blockers=0
external_failures=0
physical_status="NOT RUN"

is_exact_watch_destination() {
  [[ "$1" =~ ^platform=watchOS\ Simulator,id=[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$ ]]
}

classify_physical_result() {
  local online_status="$1"
  local preflight_status="$2"
  if [[ "$online_status" -eq 0 && "$preflight_status" -eq 0 ]]; then
    echo "PASS"
  elif [[ "$online_status" =~ ^[02]$ && "$preflight_status" =~ ^[02]$ ]]; then
    echo "BLOCKED"
  else
    echo "FAIL"
  fi
}

validate_live_prerequisite() {
  local variable="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    return 2
  fi
  case "$variable" in
    *_URL)
      [[ "$value" == https://* ]] || return 1
      ;;
    *_PATH|*_PEM)
      [[ "$value" == /* && -f "$value" && -r "$value" ]] || return 1
      ;;
    APP_STORE_SERVER_ENVIRONMENT|APNS_ENVIRONMENT)
      [[ "$value" == "production" ]] || return 1
      ;;
  esac
  return 0
}

classify_live_prerequisites() {
  local opt_in="$1"
  local missing_count="$2"
  local invalid_count="$3"
  if [[ "$missing_count" -gt 0 || "$invalid_count" -gt 0 ]]; then
    echo "BLOCKED"
  elif [[ "$opt_in" == "1" ]]; then
    echo "RUN"
  else
    echo "NOT RUN"
  fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  test "$(classify_physical_result 0 0)" = "PASS"
  test "$(classify_physical_result 2 2)" = "BLOCKED"
  test "$(classify_physical_result 1 2)" = "FAIL"
  test "$(classify_physical_result 2 1)" = "FAIL"
  test "$(classify_physical_result 0 2)" = "BLOCKED"
  is_exact_watch_destination "platform=watchOS Simulator,id=013B508D-6AF3-4C83-AB8D-D9EA3ED42ACE"
  ! is_exact_watch_destination "platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm),OS=26.5"
  validate_live_prerequisite OPENAI_API_KEY fixture-present
  set +e
  validate_live_prerequisite OPENAI_API_KEY ""
  test "$?" -eq 2
  validate_live_prerequisite IDEAFORGE_BACKEND_PUBLIC_BASE_URL http://localhost:8080
  test "$?" -eq 1
  validate_live_prerequisite APP_STORE_PRIVATE_KEY_P8_PATH /definitely/missing/private-key.p8
  test "$?" -eq 1
  validate_live_prerequisite APNS_ENVIRONMENT sandbox
  test "$?" -eq 1
  set -e
  test "$(classify_live_prerequisites 0 1 0)" = "BLOCKED"
  test "$(classify_live_prerequisites 1 0 1)" = "BLOCKED"
  test "$(classify_live_prerequisites 0 0 0)" = "NOT RUN"
  test "$(classify_live_prerequisites 1 0 0)" = "RUN"
  test "$RUN_DIRECT_MAC_RELEASE" = "0" -o "$RUN_DIRECT_MAC_RELEASE" = "1"
  test "$DIRECT_MAC_RELEASE_MODE" = "package-only" -o "$DIRECT_MAC_RELEASE_MODE" = "notarize"
  echo "verify_production.sh self-test passed"
  exit 0
fi

[[ "$RUN_DIRECT_MAC_RELEASE" == "0" || "$RUN_DIRECT_MAC_RELEASE" == "1" ]] || {
  echo "RUN_DIRECT_MAC_RELEASE must be 0 or 1." >&2
  exit 2
}
[[ "$DIRECT_MAC_RELEASE_MODE" == "package-only" || "$DIRECT_MAC_RELEASE_MODE" == "notarize" ]] || {
  echo "DIRECT_MAC_RELEASE_MODE must be package-only or notarize." >&2
  exit 2
}

mkdir -p "$LOG_DIR" "$ARTIFACT_DIR/xcresults" "$ARTIFACT_DIR/ios-ui" "$ARTIFACT_DIR/ios-accessibility"
: > "$RESULTS_FILE"
: > "$COMMANDS_FILE"
cd "$ROOT_DIR"

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

command_string() {
  local rendered=""
  printf -v rendered '%q ' "$@"
  printf '%s' "${rendered% }"
}

record_gate() {
  local category="$1"
  local name="$2"
  local status="$3"
  local started_at="$4"
  local finished_at="$5"
  local detail="$6"
  local log_path="$7"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$category" "$name" "$status" "$started_at" "$finished_at" "$detail" "$log_path" >> "$RESULTS_FILE"

  case "$category:$status" in
    repo:FAIL) repo_failures=$((repo_failures + 1)) ;;
    external:BLOCKED) external_blockers=$((external_blockers + 1)) ;;
    external:FAIL) external_failures=$((external_failures + 1)) ;;
    physical:PASS) physical_status="PASS" ;;
    physical:BLOCKED) physical_status="BLOCKED" ;;
    physical:FAIL) physical_status="FAIL" ;;
  esac
}

run_gate() {
  local category="$1"
  local slug="$2"
  local name="$3"
  shift 3

  local started_at finished_at status exit_status command log_path
  started_at="$(utc_now)"
  log_path="$LOG_DIR/$slug.log"
  command="$(command_string "$@")"
  printf '[%s] %s\n' "$started_at" "$command" >> "$COMMANDS_FILE"
  {
    printf 'Gate: %s\n' "$name"
    printf 'Category: %s\n' "$category"
    printf 'Started: %s\n' "$started_at"
    printf 'Command: %s\n\n' "$command"
  } > "$log_path"

  printf '\n==> %s\n' "$name"
  set +e
  (
    set -eEuo pipefail
    "$@"
  ) 2>&1 | tee -a "$log_path"
  exit_status=${PIPESTATUS[0]}
  set -e

  finished_at="$(utc_now)"
  if [[ "$exit_status" -eq 0 ]]; then
    status="PASS"
  else
    status="FAIL"
  fi
  printf '\nFinished: %s\nExit status: %s\nStatus: %s\n' \
    "$finished_at" "$exit_status" "$status" >> "$log_path"
  record_gate "$category" "$name" "$status" "$started_at" "$finished_at" \
    "exit $exit_status" "$log_path"
}

if [[ "${1:-}" == "--self-test-run-gate" ]]; then
  invalid_dark_screenshot="$ARTIFACT_DIR/bright-dark.png"
  PYTHONPATH="$ROOT_DIR/script" "$PYTHON_BIN" -c \
    'from pathlib import Path; from validate_ios_screenshot import write_fixture; write_fixture(Path(__import__("sys").argv[1]), "white")' \
    "$invalid_dark_screenshot"

  reject_bright_dark_screenshot() {
    "$PYTHON_BIN" "$ROOT_DIR/script/validate_ios_screenshot.py" \
      --appearance dark "$invalid_dark_screenshot"
    echo "run_gate incorrectly continued after screenshot rejection"
  }

  run_gate repo fail-closed-self-test "Fail-closed screenshot gate self-test" reject_bright_dark_screenshot
  grep -Fq $'repo\tFail-closed screenshot gate self-test\tFAIL\t' "$RESULTS_FILE"
  test "$repo_failures" -eq 1
  if grep -Fq "run_gate incorrectly continued" "$LOG_DIR/fail-closed-self-test.log"; then
    echo "run_gate did not stop the visual gate after screenshot rejection."
    exit 1
  fi
  echo "verify_production.sh run_gate self-test passed"
  exit 0
fi

record_nonrun_gate() {
  local category="$1"
  local name="$2"
  local status="$3"
  local detail="$4"
  local timestamp
  timestamp="$(utc_now)"
  printf '\n==> %s: %s\n    %s\n' "$name" "$status" "$detail"
  record_gate "$category" "$name" "$status" "$timestamp" "$timestamp" "$detail" "-"
}

run_or_record_live_gate() {
  local opt_in="$1"
  local slug="$2"
  local name="$3"
  local required_csv="$4"
  shift 4

  local timestamp log_path prerequisite_log variable validation_status readiness
  local missing=()
  local invalid=()
  local required=()
  IFS=',' read -r -a required <<< "$required_csv"
  timestamp="$(utc_now)"
  log_path="$LOG_DIR/$slug.log"
  prerequisite_log="$LOG_DIR/$slug-prerequisites.log"
  {
    echo "Gate: $name"
    echo "Category: external"
    echo "Credential/configuration presence:"
    for variable in "${required[@]}"; do
      set +e
      validate_live_prerequisite "$variable" "${!variable:-}"
      validation_status=$?
      set -e
      case "$validation_status" in
        0) echo "- $variable: present and structurally usable" ;;
        2)
          echo "- $variable: missing"
          missing+=("$variable")
          ;;
        *)
          echo "- $variable: invalid or unreadable"
          invalid+=("$variable")
          ;;
      esac
    done
  } > "$prerequisite_log"

  readiness="$(classify_live_prerequisites "$opt_in" "${#missing[@]}" "${#invalid[@]}")"

  if [[ "$readiness" == "BLOCKED" ]]; then
    echo "Live request executed: no" >> "$prerequisite_log"
    record_gate external "$name" BLOCKED "$timestamp" "$timestamp" \
      "live check not executed; missing prerequisites: ${missing[*]:-none}; invalid or unreadable prerequisites: ${invalid[*]:-none}" "$prerequisite_log"
  elif [[ "$readiness" == "NOT RUN" ]]; then
    echo "Live request executed: no" >> "$prerequisite_log"
    record_gate external "$name" "NOT RUN" "$timestamp" "$timestamp" \
      "required credential/configuration variables appear present, but the live check requires explicit opt-in" "$prerequisite_log"
  else
    echo "Live request executed: yes (explicit opt-in)" >> "$prerequisite_log"
    run_gate external "$slug" "$name" "$@"
    printf '\n' >> "$log_path"
    cat "$prerequisite_log" >> "$log_path"
  fi
}

validate_plists_and_privacy() {
  local files=(
    Sources/IdeaForgeMac/Info.plist
    Sources/IdeaForgeMac/PrivacyInfo.xcprivacy
    Sources/IdeaForgeiOS/Info.plist
    Sources/IdeaForgeiOS/PrivacyInfo.xcprivacy
    Sources/IdeaForgeWatch/Info.plist
    Sources/IdeaForgeWatch/PrivacyInfo.xcprivacy
  )
  printf 'plutil -lint'
  printf ' %q' "${files[@]}"
  printf '\n'
  plutil -lint "${files[@]}"

  plutil -extract NSMicrophoneUsageDescription raw Sources/IdeaForgeMac/Info.plist
  plutil -extract NSSpeechRecognitionUsageDescription raw Sources/IdeaForgeMac/Info.plist
  plutil -extract NSMicrophoneUsageDescription raw Sources/IdeaForgeiOS/Info.plist
  plutil -extract NSSpeechRecognitionUsageDescription raw Sources/IdeaForgeiOS/Info.plist
  plutil -extract NSMicrophoneUsageDescription raw Sources/IdeaForgeWatch/Info.plist
  plutil -extract UIBackgroundModes xml1 -o - Sources/IdeaForgeiOS/Info.plist | grep -q '<string>audio</string>'
  plutil -extract WKBackgroundModes xml1 -o - Sources/IdeaForgeWatch/Info.plist | grep -q '<string>audio</string>'

  local privacy_manifest
  for privacy_manifest in \
    Sources/IdeaForgeMac/PrivacyInfo.xcprivacy \
    Sources/IdeaForgeiOS/PrivacyInfo.xcprivacy \
    Sources/IdeaForgeWatch/PrivacyInfo.xcprivacy; do
    plutil -extract NSPrivacyAccessedAPITypes xml1 -o - "$privacy_manifest" | grep -q 'NSPrivacyAccessedAPICategoryDiskSpace'
    plutil -extract NSPrivacyAccessedAPITypes xml1 -o - "$privacy_manifest" | grep -q '<string>E174.1</string>'
    plutil -extract NSPrivacyAccessedAPITypes xml1 -o - "$privacy_manifest" | grep -q 'NSPrivacyAccessedAPICategoryUserDefaults'
    plutil -extract NSPrivacyAccessedAPITypes xml1 -o - "$privacy_manifest" | grep -q '<string>CA92.1</string>'
  done
}

prepare_ios_ui_baseline() {
  local simulator_id=""
  if [[ "$IOS_DESTINATION" =~ id=([^,[:space:]]+) ]]; then
    simulator_id="${BASH_REMATCH[1]}"
  else
    local simulator_json="$ARTIFACT_DIR/ios-ui-baseline-simulators.json"
    local resolved_destination
    xcrun simctl list devices available --json > "$simulator_json"
    resolved_destination="$(
      "$PYTHON_BIN" "$ROOT_DIR/script/resolve_ios_simulator.py" \
        --json "$simulator_json" --name "${IOS_SIMULATOR_NAME:-iPhone 17}" --os "${IOS_SIMULATOR_OS:-26.5}"
    )"
    if [[ "$resolved_destination" =~ id=([^,[:space:]]+) ]]; then
      simulator_id="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -z "$simulator_id" ]]; then
    echo "Unable to resolve an exact iOS simulator ID for the focused UI baseline."
    return 1
  fi

  xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$simulator_id" -b
  {
    echo "Simulator: $simulator_id"
    echo "Before appearance: $(xcrun simctl ui "$simulator_id" appearance)"
    echo "Before content size: $(xcrun simctl ui "$simulator_id" content_size)"
    echo "Before increased contrast: $(xcrun simctl ui "$simulator_id" increase_contrast)"
  } | tee "$ARTIFACT_DIR/ios-ui-baseline-before.txt"

  xcrun simctl ui "$simulator_id" appearance light
  xcrun simctl ui "$simulator_id" content_size large
  xcrun simctl ui "$simulator_id" increase_contrast disabled

  test "$(xcrun simctl ui "$simulator_id" appearance)" = "light"
  test "$(xcrun simctl ui "$simulator_id" content_size)" = "large"
  test "$(xcrun simctl ui "$simulator_id" increase_contrast)" = "disabled"
  echo "Focused iOS UI baseline: light, large content size, increased contrast disabled."
}

run_focused_ios_ui_test() {
  local test_name="$1"
  local test_log="$ARTIFACT_DIR/ios-ui/$test_name.log"
  local simulator_id=""
  if [[ "$IOS_DESTINATION" =~ id=([^,[:space:]]+) ]]; then
    simulator_id="${BASH_REMATCH[1]}"
    xcrun simctl terminate "$simulator_id" com.s1kor.ideaforge.ios >/dev/null 2>&1 || true
    xcrun simctl ui "$simulator_id" appearance light
    xcrun simctl ui "$simulator_id" content_size large
    xcrun simctl ui "$simulator_id" increase_contrast disabled
  fi

  env IOS_DESTINATION="$IOS_DESTINATION" \
    IOS_UI_REPORT_DIR="$ARTIFACT_DIR/ios-ui" \
    IOS_UI_LOG="$test_log" \
    IOS_UI_RESULT_BUNDLE="$ARTIFACT_DIR/ios-ui/$test_name.xcresult" \
    IOS_UI_ONLY_TESTING="IdeaForgeiOSUITests/IdeaForgeiOSUITests/$test_name" \
    "$ROOT_DIR/script/run_ios_ui_smoke.sh"

  grep -F "$test_name]' passed" "$test_log"
  if ! grep -Fq 'Executed 1 test, with 0 failures' "$test_log"; then
    echo "Focused iOS UI gate did not execute exactly one passing test: $test_name"
    return 1
  fi
}

verify_embedded_watch_app() {
  local ios_app="$IOS_DERIVED_DATA/Build/Products/Debug-iphonesimulator/IdeaForge.app"
  local watch_app="$ios_app/Watch/IdeaForge Watch.app"
  local watch_info="$watch_app/Info.plist"

  printf 'iPhone app: %s\n' "$ios_app"
  printf 'Expected embedded Watch app: %s\n' "$watch_app"
  test -d "$ios_app"
  test -d "$watch_app"
  test -f "$watch_info"
  test "$(plutil -extract CFBundleIdentifier raw "$watch_info")" = "com.s1kor.ideaforge.ios.watch"
  test "$(plutil -extract WKCompanionAppBundleIdentifier raw "$watch_info")" = "com.s1kor.ideaforge.ios"
  find "$ios_app/Watch" -maxdepth 2 -type d -name '*.app' -print
}

resolve_watch_ultra_destination() {
  local destination_file="$ARTIFACT_DIR/watch-ultra-destination.txt"
  local devices_json="$ARTIFACT_DIR/watch-ultra-simulators.json"
  local requested_udid=""

  xcrun simctl list devices available --json > "$devices_json"

  if [[ -n "$WATCH_ULTRA_DESTINATION" ]]; then
    if ! is_exact_watch_destination "$WATCH_ULTRA_DESTINATION"; then
      echo "WATCH_ULTRA_DESTINATION must be an exact watchOS Simulator UDID destination: platform=watchOS Simulator,id=<UDID>"
      return 1
    fi
    requested_udid="${WATCH_ULTRA_DESTINATION##*,id=}"
    "$PYTHON_BIN" "$ROOT_DIR/script/resolve_watch_simulator.py" \
      --json "$devices_json" --name "$WATCH_ULTRA_NAME" --os "$WATCH_ULTRA_OS" \
      --udid "$requested_udid" > "$destination_file"
  else
    "$PYTHON_BIN" "$ROOT_DIR/script/resolve_watch_simulator.py" \
      --json "$devices_json" --name "$WATCH_ULTRA_NAME" --os "$WATCH_ULTRA_OS" \
      > "$destination_file"
  fi

  local resolved
  resolved="$(cat "$destination_file")"
  if ! is_exact_watch_destination "$resolved"; then
    echo "Watch resolver did not return an exact UDID destination: $resolved"
    return 1
  fi
  echo "Resolved verified Watch Ultra destination: $resolved"
}

validate_ios_visual_scenarios() {
  local evidence="$ARTIFACT_DIR/ios-accessibility/visual-evidence.tsv"
  local marker="$ARTIFACT_DIR/ios-accessibility/visual-scenarios.pass"
  local expected=(
    clean-light
    queued-light
    failed-dark
    offline-accessibility
    conflict-contrast
    recovered-recording-reduce-motion
  )
  local scenario appearance attachment_dir screenshot

  test -s "$evidence"
  test -s "$marker"
  test "$(tail -n +2 "$evidence" | wc -l | tr -d ' ')" -eq "${#expected[@]}"
  test "$(wc -l < "$marker" | tr -d ' ')" -eq "${#expected[@]}"
  for scenario in "${expected[@]}"; do
    test "$(grep -Fxc "$scenario" "$marker")" -eq 1
    test "$(awk -F '\t' -v wanted="$scenario" '$1 == wanted { count++ } END { print count + 0 }' "$evidence")" -eq 1
    appearance="$(awk -F '\t' -v wanted="$scenario" '$1 == wanted { print $3 }' "$evidence")"
    attachment_dir="$(awk -F '\t' -v wanted="$scenario" '$1 == wanted { print $8 }' "$evidence")"
    test -d "$attachment_dir"
    test -f "$attachment_dir/manifest.json"
    grep -Fq "IdeaForge-$scenario" "$attachment_dir/manifest.json"
    test "$(find "$attachment_dir" -type f -name '*.png' | wc -l | tr -d ' ')" -eq 1
    screenshot="$(find "$attachment_dir" -type f -name '*.png' -print -quit)"
    file "$screenshot" | grep -q 'PNG image data'
    "$PYTHON_BIN" "$ROOT_DIR/script/validate_ios_screenshot.py" \
      --appearance "$appearance" "$screenshot"
  done
  echo "Validated six deterministic foreground XCTest screenshot scenarios."
}

validate_ios_reduce_motion_evidence() {
  local evidence="$ARTIFACT_DIR/ios-accessibility/visual-evidence.tsv"
  local marker="$ARTIFACT_DIR/ios-accessibility/reduce-motion-ledger.md"

  test -s "$evidence"
  test -s "$marker"
  awk -F '\t' '
    $1 == "recovered-recording-reduce-motion" && $6 == "1" { matched++ }
    END { exit matched == 1 ? 0 : 1 }
  ' "$evidence"
  grep -Fq 'Requested system value: `1` (enabled)' "$marker"
  grep -Fq 'Simulator readback after stabilization: `1`' "$marker"
  grep -Fq 'UIAccessibility.isReduceMotionEnabled == true' "$marker"
  grep -Fq 'Final status: **PASS**' "$marker"
  echo "Validated the Reduce Motion preference readback, XCTest assertion, and foreground screenshot ledger."
}

capture_verification_input_manifest() {
  local relative_path
  git -C "$ROOT_DIR" ls-files --cached --others --exclude-standard -- \
    Package.swift project.yml README.md Sources Tests script docs .github \
    | LC_ALL=C sort -u \
    | while IFS= read -r relative_path; do
        test -f "$ROOT_DIR/$relative_path"
        shasum -a 256 "$ROOT_DIR/$relative_path"
      done
}

verify_verification_inputs_unchanged() {
  capture_verification_input_manifest > "$INPUT_MANIFEST_AFTER"
  if ! cmp -s "$INPUT_MANIFEST_BEFORE" "$INPUT_MANIFEST_AFTER"; then
    echo "Verification inputs changed while the verifier was running."
    diff -u "$INPUT_MANIFEST_BEFORE" "$INPUT_MANIFEST_AFTER" || true
    return 1
  fi
  echo "Verification input hashes remained unchanged for the full run."
}

prepare_release_archive_directory() {
  if [[ -d "$ROOT_DIR/build/archives" ]]; then
    local retained="$ROOT_DIR/build/archives-before-$RUN_ID"
    printf 'Retaining previous archive directory at %s\n' "$retained"
    mv "$ROOT_DIR/build/archives" "$retained"
  fi
}

verify_release_archives() {
  local mac_app="$ROOT_DIR/build/archives/IdeaForgeMac.xcarchive/Products/Applications/IdeaForge.app"
  local ios_app="$ROOT_DIR/build/archives/IdeaForgeiOS.xcarchive/Products/Applications/IdeaForge.app"
  local watch_app="$ios_app/Watch/IdeaForge Watch.app"

  for app in "$mac_app" "$ios_app" "$watch_app"; do
    test -d "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
    codesign -dv --verbose=4 "$app" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|Signature)='
  done
}

physical_devices_are_exact_and_online() {
  local ios_id="${IDEAFORGE_IOS_DEVICE_ID:-}"
  local watch_id="${IDEAFORGE_WATCH_DEVICE_ID:-}"
  local devices_log="$ARTIFACT_DIR/physical-xctrace-devices.txt"
  local online_section="$ARTIFACT_DIR/physical-xctrace-online-devices.txt"

  local xctrace_status
  set +e
  xcrun xctrace list devices | tee "$devices_log"
  xctrace_status=${PIPESTATUS[0]}
  set -e
  if [[ "$xctrace_status" -ne 0 ]]; then
    echo "xctrace device discovery failed with exit $xctrace_status."
    return 1
  fi
  if ! grep -Fxq '== Devices ==' "$devices_log"; then
    echo "xctrace device discovery returned an unrecognized output format."
    return 1
  fi
  awk '/^== Devices ==$/{online=1; next} /^== /{online=0} online{print}' "$devices_log" > "$online_section"
  if [[ -z "$ios_id" || -z "$watch_id" ]]; then
    echo "Exact IDEAFORGE_IOS_DEVICE_ID and IDEAFORGE_WATCH_DEVICE_ID are required."
    return 2
  fi
  if ! grep -F "$ios_id" "$online_section"; then
    echo "Configured iPhone $ios_id is not in the online physical-device section."
    return 2
  fi
  if ! grep -F "$watch_id" "$online_section"; then
    echo "Configured Watch $watch_id is not in the online physical-device section."
    return 2
  fi
}

run_physical_device_gate() {
  local started_at finished_at status detail log_path preflight_status online_status
  local args=(
    "$PYTHON_BIN" "$ROOT_DIR/script/check_physical_device_readiness.py"
    --json "$ARTIFACT_DIR/physical-device-readiness.json"
    --markdown "$ARTIFACT_DIR/physical-device-readiness.md"
  )
  if [[ "$RUN_PHYSICAL_DEVICE_BUILDS" == "1" ]]; then
    args+=(--run-build)
  fi

  started_at="$(utc_now)"
  log_path="$LOG_DIR/physical-device-readiness.log"
  printf '[%s] %s\n' "$started_at" "$(command_string "${args[@]}")" >> "$COMMANDS_FILE"
  printf 'Gate: Physical iPhone and Watch readiness\nStarted: %s\n' "$started_at" > "$log_path"

  set +e
  physical_devices_are_exact_and_online 2>&1 | tee -a "$log_path"
  online_status=${PIPESTATUS[0]}
  "${args[@]}" 2>&1 | tee -a "$log_path"
  preflight_status=${PIPESTATUS[0]}
  set -e

  finished_at="$(utc_now)"
  status="$(classify_physical_result "$online_status" "$preflight_status")"
  case "$status" in
    PASS) detail="exact online iPhone and Watch destinations passed fail-closed preflight" ;;
    BLOCKED) detail="exact physical devices are offline or unavailable (online check $online_status, preflight $preflight_status)" ;;
    FAIL) detail="physical readiness command or gate failed (online check $online_status, preflight $preflight_status)" ;;
  esac
  printf '\nFinished: %s\nOnline check: %s\nPreflight: %s\nStatus: %s\n' \
    "$finished_at" "$online_status" "$preflight_status" "$status" >> "$log_path"
  record_gate physical "Physical iPhone and Watch readiness" "$status" "$started_at" "$finished_at" "$detail" "$log_path"
}

write_summary() {
  local repo_status="PASS"
  if [[ "$repo_failures" -ne 0 ]]; then
    repo_status="FAIL"
  fi

  {
    echo "# IdeaForge Production Verification"
    echo
    echo "- Run ID: \`$RUN_ID\`"
    echo "- Started from commit: \`$(git rev-parse HEAD)\`"
    echo "- Verification input manifest: \`$INPUT_MANIFEST_BEFORE\`"
    echo "- Finished: \`$(utc_now)\`"
    echo "- Repository verification: **$repo_status**"
    echo "- Physical-device readiness: **$physical_status**"
    echo "- External blockers: **$external_blockers**"
    echo "- External failures: **$external_failures**"
    echo "- Artifact directory: \`$ARTIFACT_DIR\`"
    echo
    echo "| Category | Gate | Status | Started | Finished | Detail | Log |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    while IFS=$'\t' read -r category name status started finished detail log_path; do
      echo "| $category | $name | $status | $started | $finished | $detail | \`$log_path\` |"
    done < "$RESULTS_FILE"
    echo
    echo "## Readiness Boundary"
    echo
    echo "A repository PASS covers generated project, assets/plists/privacy, unit and self-tests, local sync E2E, warnings-as-errors simulator and generic iOS builds, focused iPhone UI tests, deterministic foreground iOS visual and accessibility evidence including Reduce Motion, Watch embedding, privacy-log review, development-signed archive checks when identities exist, Git whitespace, and clean app-process shutdown. Development archives are not distribution-ready artifacts."
    echo
    echo "The privacy-log review checks privacy leakage only. It does not prove crash freedom, retry-loop behavior, or persistence correctness; those broader runtime-log analyses are separately reported as NOT RUN."
    echo
    echo "It does not claim Mac visual inspection, physical Watch-to-iPhone-to-Mac sync, physical installation, App Store export/upload, Developer ID direct-download distribution readiness, notarization, or Mac UI automation when those gates are BLOCKED or NOT RUN. Direct-download distribution readiness is reported separately and requires the explicitly enabled notarized mode."
  } > "$SUMMARY_FILE"

  cat "$SUMMARY_FILE"
}

capture_verification_input_manifest > "$INPUT_MANIFEST_BEFORE"

run_gate repo xcodegen "Generate Xcode project" "$XCODEGEN_BIN" generate
run_gate repo python-runtime "Validate production verifier Python runtime" \
  "$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3, 10); print(sys.version)'
run_gate repo task7-verifier-regressions "Task 7 verifier and runtime regression self-tests" \
  "$ROOT_DIR/script/test_verify_production.sh"
run_gate repo task7-visual-regressions "Task 7 iOS visual-gate regression self-tests" \
  "$ROOT_DIR/script/test_ios_accessibility_matrix.sh"
if [[ -d "$ROOT_DIR/AppStore" ]]; then
  run_gate repo app-store-assets "Validate app, privacy, and App Store assets" \
    "$PYTHON_BIN" "$ROOT_DIR/script/validate_app_store_assets.py" \
    --json "$ARTIFACT_DIR/app-store-assets.json" \
    --markdown "$ARTIFACT_DIR/app-store-assets.md"
else
  run_gate repo public-source-assets "Validate public-source app and privacy assets" \
    "$PYTHON_BIN" "$ROOT_DIR/script/validate_app_store_assets.py" --public-source \
    --json "$ARTIFACT_DIR/app-store-assets.json" \
    --markdown "$ARTIFACT_DIR/app-store-assets.md"
  record_nonrun_gate external "Private App Store metadata and screenshots" "NOT RUN" \
    "The public source snapshot intentionally excludes its private AppStore release package."
fi
run_gate repo plist-privacy "Validate plist capabilities and privacy manifests" validate_plists_and_privacy
run_gate repo swift-test "Run SwiftPM tests" swift test

run_gate repo backend-migration-self-test "Backend migration self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/migrate_backend.py" --self-test
run_gate repo production-backend-preflight-self-test "Production backend preflight self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/production_backend_preflight.py" --self-test
run_gate repo production-database-self-test "Production database readiness self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_production_database.py" --self-test
run_gate repo deployed-backend-self-test "Deployed backend live-smoke contract self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_deployed_backend.py" --self-test
run_gate repo live-ai-self-test "Live AI provider smoke contract self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_live_ai_provider.py" --self-test
run_gate repo app-store-server-self-test "App Store Server API smoke contract self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_app_store_server_api.py" --self-test
run_gate repo apns-self-test "APNs delivery readiness self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_apns_delivery.py" --self-test
run_gate repo watch-simulator-resolver-self-test "Watch simulator resolver self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/resolve_watch_simulator.py" --self-test
run_gate repo ios-screenshot-validator-self-test "iOS screenshot raster validator self-test" \
  "$PYTHON_BIN" "$ROOT_DIR/script/validate_ios_screenshot.py" --self-test

run_or_record_live_gate "$RUN_LIVE_DEPLOYED_BACKEND" live-deployed-backend \
  "Live deployed backend readiness" \
  "IDEAFORGE_BACKEND_PUBLIC_BASE_URL,IDEAFORGE_BACKEND_TOKEN,IDEAFORGE_BACKEND_WORKSPACE_ID" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_deployed_backend.py" \
  --report "$ARTIFACT_DIR/live-deployed-backend.md"
run_or_record_live_gate "$RUN_LIVE_AI_PROVIDER" live-ai-provider \
  "Live AI provider readiness" \
  "OPENAI_API_KEY,IDEAFORGE_LIVE_AI_TRANSCRIPTION_AUDIO_PATH" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_live_ai_provider.py" --send \
  --report "$ARTIFACT_DIR/live-ai-provider.md"
run_or_record_live_gate "$RUN_LIVE_APP_STORE_SERVER_API" live-app-store-server \
  "Live App Store Server API readiness" \
  "APP_STORE_SERVER_ENVIRONMENT,APP_STORE_ISSUER_ID,APP_STORE_KEY_ID,APP_STORE_PRIVATE_KEY_P8_PATH,APP_STORE_TRANSACTION_ID,APP_STORE_EXPECTED_PRODUCT_IDS,APP_STORE_ROOT_CA_PEM" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_app_store_server_api.py" --send \
  --report "$ARTIFACT_DIR/live-app-store-server-api.md"
run_or_record_live_gate "$RUN_LIVE_APNS" live-apns \
  "Live APNs readiness" \
  "APNS_ENVIRONMENT,APNS_TEAM_ID,APNS_KEY_ID,APNS_AUTH_KEY_P8_PATH,APNS_DEVICE_TOKEN,IDEAFORGE_APNS_WORKSPACE_ID" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_apns_delivery.py" --send \
  --report "$ARTIFACT_DIR/live-apns.md"

if [[ "$RUN_LOCAL_SYNC_E2E" == "1" ]]; then
  run_gate repo local-sync-e2e "Local cross-device sync E2E" \
    "$PYTHON_BIN" "$ROOT_DIR/script/run_local_sync_e2e.py"
else
  record_nonrun_gate repo "Local cross-device sync E2E" FAIL \
    "RUN_LOCAL_SYNC_E2E=0 omits a required production gate."
fi

run_gate repo mac-build "macOS warnings-as-errors build" \
  xcodebuild -project "$PROJECT" -scheme IdeaForgeMac -configuration Debug \
  -derivedDataPath "$MAC_DERIVED_DATA" -destination "platform=macOS" \
  -resultBundlePath "$ARTIFACT_DIR/xcresults/mac-build.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build

run_gate repo ios-generic-build "iOS generic device warnings-as-errors build" \
  xcodebuild -project "$PROJECT" -scheme IdeaForgeiOS -configuration Debug \
  -derivedDataPath "$IOS_GENERIC_DERIVED_DATA" -destination "generic/platform=iOS" \
  -resultBundlePath "$ARTIFACT_DIR/xcresults/ios-generic-build.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build

run_gate repo ios-build "iOS simulator warnings-as-errors build" \
  xcodebuild -project "$PROJECT" -scheme IdeaForgeiOS -configuration Debug \
  -derivedDataPath "$IOS_DERIVED_DATA" -destination "$IOS_DESTINATION" \
  -resultBundlePath "$ARTIFACT_DIR/xcresults/ios-build.xcresult" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build

run_gate repo watch-generic-build "watchOS generic simulator warnings-as-errors build" \
  xcodebuild -project "$PROJECT" -scheme IdeaForgeWatch -configuration Debug \
  -derivedDataPath "$WATCH_GENERIC_DERIVED_DATA" -destination "$WATCH_GENERIC_DESTINATION" \
  -resultBundlePath "$ARTIFACT_DIR/xcresults/watch-generic-build.xcresult" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build

run_gate repo watch-ultra-destination "Resolve exact Apple Watch Ultra 3 simulator destination" \
  resolve_watch_ultra_destination
if [[ -s "$ARTIFACT_DIR/watch-ultra-destination.txt" ]]; then
  WATCH_ULTRA_DESTINATION="$(cat "$ARTIFACT_DIR/watch-ultra-destination.txt")"
else
  WATCH_ULTRA_DESTINATION="invalid/watchOS-simulator-destination"
fi
run_gate repo watch-ultra-build "Apple Watch Ultra 3 simulator warnings-as-errors build" \
  xcodebuild -project "$PROJECT" -scheme IdeaForgeWatch -configuration Debug \
  -derivedDataPath "$WATCH_ULTRA_DERIVED_DATA" -destination "$WATCH_ULTRA_DESTINATION" \
  -resultBundlePath "$ARTIFACT_DIR/xcresults/watch-ultra-build.xcresult" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build

run_gate repo watch-embedding "Verify iPhone app embeds Watch app" verify_embedded_watch_app
run_gate repo ios-ui-baseline "Prepare deterministic iOS focused-test baseline" prepare_ios_ui_baseline

if [[ "$RUN_IOS_UI_SMOKE_SPLIT" == "1" ]]; then
  ios_ui_tests=(
    testTaskFirstInboxHierarchy
    testTaskFirstInboxStatusPriority
    testTaskFirstFailureAccessibilitySemantics
    testPrimaryTabsExposeProductionWorkflowSurfaces
    testRetainedCapabilityReachabilityMatrix
    testAccountCapabilityReachabilityMatrix
    testLocalSpeechCapabilityProducesVisibleOutcome
    testFailedUploadReviewAndRecordingDetailExposeSafeRetry
    testAccountUploadDiagnosticsExposeOneCurrentRowPerRecording
    testInvalidUploadConfigurationFailsBackgroundCallerOutcomes
    testAccountHubExposesCommerceAndBackendControls
    testAccountSyncStateMatrixShowsPublishedAndLocalOnlyHandoffCopy
    testAppearanceAccessibilityCoreSurfacesRemainUsable
    testAccountPublishWorkspaceExplainsCapabilityGate
    testAccountRefreshWorkspaceExplainsCapabilityGate
    testAccountHubShowsSyncConflictReviewBeforeMerge
    testAccountHubSyncConflictCustomItemEditorsAreReachable
    testRecordingPermissionDeniedShowsVisibleError
    testRecoveredRecordingCheckpointReturnsToInboxAfterRelaunch
    testProjectDetailExposesTranscriptReviewSurface
    testIdeasAgentAndQuestionAnswerFlow
  )
  for ios_ui_test in "${ios_ui_tests[@]}"; do
    run_gate repo "ios-ui-$ios_ui_test" "iOS UI: $ios_ui_test" \
      run_focused_ios_ui_test "$ios_ui_test"
  done
else
  run_gate repo ios-ui-suite "iOS UI suite" env IOS_DESTINATION="$IOS_DESTINATION" \
    IOS_UI_REPORT_DIR="$ARTIFACT_DIR/ios-ui" "$ROOT_DIR/script/run_ios_ui_smoke.sh"
fi

if [[ "$RUN_IOS_ACCESSIBILITY_MATRIX" == "1" ]]; then
  run_gate repo ios-accessibility-matrix "iOS task-first visual and accessibility matrix" \
    env IOS_UI_REPORT_DIR="$ARTIFACT_DIR/ios-accessibility" \
    IOS_ACCESSIBILITY_SUMMARY="$ARTIFACT_DIR/ios-accessibility/matrix.md" \
    IOS_ACCESSIBILITY_EVIDENCE="$ARTIFACT_DIR/ios-accessibility/visual-evidence.tsv" \
    IOS_ACCESSIBILITY_VISUAL_MARKER="$ARTIFACT_DIR/ios-accessibility/visual-scenarios.pass" \
    IOS_ACCESSIBILITY_REDUCE_MOTION_MARKER="$ARTIFACT_DIR/ios-accessibility/reduce-motion-ledger.md" \
    "$ROOT_DIR/script/run_ios_accessibility_matrix.sh"
  run_gate repo ios-visual-evidence "iOS authoritative XCTest visual attachments" \
    validate_ios_visual_scenarios
  run_gate repo ios-reduce-motion-evidence "iOS Reduce Motion evidence ledger" \
    validate_ios_reduce_motion_evidence
else
  record_nonrun_gate repo "iOS task-first visual and accessibility matrix" FAIL \
    "RUN_IOS_ACCESSIBILITY_MATRIX=0 omits a required production gate."
  record_nonrun_gate repo "iOS authoritative XCTest visual attachments" FAIL \
    "RUN_IOS_ACCESSIBILITY_MATRIX=0 omits required repository-owned visual evidence."
  record_nonrun_gate repo "iOS Reduce Motion evidence ledger" FAIL \
    "RUN_IOS_ACCESSIBILITY_MATRIX=0 omits required Reduce Motion visual evidence."
fi

if [[ "$RUN_MAC_UI_TESTS" == "1" && "$MAC_UI_AUTOMATION_AUTHORIZED" == "1" ]]; then
  run_gate repo mac-ui-tests "Complete macOS UI test target" \
    xcodebuild -project "$PROJECT" -scheme IdeaForgeMac -configuration Debug \
    -derivedDataPath "$ROOT_DIR/DerivedData-production-mac-ui" -destination "platform=macOS" \
    -resultBundlePath "$ARTIFACT_DIR/xcresults/mac-ui-tests.xcresult" \
    -only-testing:IdeaForgeMacUITests \
    test
else
  record_nonrun_gate external "Complete macOS UI test target" BLOCKED \
    "One-time Xcode UI Automation authorization is not confirmed; the verifier did not invoke the authorization prompt. Set RUN_MAC_UI_TESTS=1 and MAC_UI_AUTOMATION_AUTHORIZED=1 only after granting it manually."
fi

if [[ "$RUN_PRIVACY_LOG_REVIEW" == "1" ]]; then
  run_gate repo privacy-log-review "Review privacy-safe IdeaForge logs" \
    "$PYTHON_BIN" "$ROOT_DIR/script/review_privacy_logs.py" --last "$PRIVACY_LOG_REVIEW_LAST"
else
  record_nonrun_gate repo "Review privacy-safe IdeaForge logs" FAIL \
    "RUN_PRIVACY_LOG_REVIEW=0 omits a required production gate."
fi
record_nonrun_gate repo "Runtime crash/retry-loop/persistence log analysis" "NOT RUN" \
  "The automated log review is intentionally limited to privacy leakage; crash freedom, retry-loop behavior, and persistence correctness are not claimed from that evidence."

run_gate external signing-identities "Inspect Apple code-signing identities" \
  security find-identity -p codesigning -v

if grep -Eq 'Apple (Development|Distribution)' "$LOG_DIR/signing-identities.log"; then
  if [[ "$RUN_RELEASE_SIGNING" == "0" ]]; then
    record_nonrun_gate repo "Development-signed Release archives (not distribution-ready)" FAIL \
      "Signing identities exist, but RUN_RELEASE_SIGNING=0 omitted the required signing check."
  else
    run_gate repo prepare-release-archives "Retain previous release archive artifacts" prepare_release_archive_directory
    run_gate repo release-signing "Development-signed Release archives (not distribution-ready)" \
      env DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" "$ROOT_DIR/script/check_release_signing.sh"
    run_gate repo verify-release-signatures "Verify development archive signatures and Watch embedding" \
      verify_release_archives
  fi
else
  record_nonrun_gate external "Development-signed Release archives (not distribution-ready)" BLOCKED \
    "No Apple Development or Distribution identity was found; local development archive signing was not reported as passing."
fi

record_nonrun_gate external "App Store distribution export and upload" "NOT RUN" \
  "Archive signatures do not prove App Store export, upload, processing, or review."

if [[ "$RUN_DIRECT_MAC_RELEASE" == "1" ]]; then
  if [[ "$DIRECT_MAC_RELEASE_MODE" == "package-only" ]]; then
    run_gate external direct-mac-local-export "Developer ID local export and signature audit" \
      env \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      DEVELOPER_ID_APPLICATION="325BE7BDA73543F37311F400F231DC751E87FB77" \
      RELEASE_VERSION="$DIRECT_MAC_RELEASE_VERSION" \
      "$ROOT_DIR/script/release_macos.sh" --package-only
    record_nonrun_gate external "Developer ID notarized direct-download release" "NOT RUN" \
      "DIRECT_MAC_RELEASE_MODE=package-only intentionally made no notarization request."
    record_nonrun_gate external "Direct-download distribution readiness" "NOT RUN" \
      "The local Developer ID export is signature proof only; secure timestamp, notarization, stapling, and Gatekeeper distribution proof are not claimed."
  else
    direct_release_failures_before="$external_failures"
    run_gate external direct-mac-notarized-release "Developer ID notarized direct-download release" \
      env \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      DEVELOPER_ID_APPLICATION="325BE7BDA73543F37311F400F231DC751E87FB77" \
      RELEASE_VERSION="$DIRECT_MAC_RELEASE_VERSION" \
      NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}" \
      "$ROOT_DIR/script/release_macos.sh" --notarize
    if [[ "$external_failures" == "$direct_release_failures_before" ]]; then
      record_nonrun_gate external "Developer ID local export and signature audit" PASS \
        "The notarized release pipeline included the exact-identity archive, export, and nested signature audit."
      record_nonrun_gate external "Direct-download distribution readiness" PASS \
        "The explicit notarized release pipeline passed app and DMG notarization plus staple validation and emitted final release assets."
    else
      record_nonrun_gate external "Developer ID local export and signature audit" FAIL \
        "The explicitly enabled notarized release pipeline failed before full local export/signature proof could be claimed."
      record_nonrun_gate external "Direct-download distribution readiness" FAIL \
        "The explicitly enabled notarized release pipeline failed; direct-download readiness is not claimed."
    fi
  fi
else
  record_nonrun_gate external "Developer ID local export and signature audit" "NOT RUN" \
    "RUN_DIRECT_MAC_RELEASE=0; the direct-release script was not invoked."
  record_nonrun_gate external "Developer ID notarized direct-download release" "NOT RUN" \
    "RUN_DIRECT_MAC_RELEASE=0; no Apple notarization request was made."
  record_nonrun_gate external "Direct-download distribution readiness" "NOT RUN" \
    "Direct-download readiness requires explicit RUN_DIRECT_MAC_RELEASE=1 and DIRECT_MAC_RELEASE_MODE=notarize."
fi

run_physical_device_gate

run_gate repo verification-input-stability "Verification inputs remained stable during the run" \
  verify_verification_inputs_unchanged
run_gate repo git-diff-check "Git whitespace validation" git diff --check
run_gate repo process-health "Terminate app processes and verify clean shutdown" \
  "$PYTHON_BIN" "$ROOT_DIR/script/check_app_process_health.py"

write_summary

if [[ "$repo_failures" -ne 0 ]]; then
  echo "Repository verification failed: $repo_failures required gate(s) failed."
  exit 1
fi
if [[ "$external_failures" -ne 0 ]]; then
  echo "Explicit external verification failed: $external_failures gate(s)."
  exit 1
fi
if [[ "$physical_status" == "FAIL" ]]; then
  echo "Physical-device readiness failed and cannot be waived."
  exit 1
fi
if [[ "$physical_status" != "PASS" && "$ALLOW_BLOCKED_PHYSICAL_DEVICE_GATE" != "1" ]]; then
  echo "Physical-device readiness is $physical_status and remains fail-closed."
  echo "Set ALLOW_BLOCKED_PHYSICAL_DEVICE_GATE=1 only to report repository verification separately."
  exit 2
fi

echo "Repository verification passed. Physical-device readiness: $physical_status."
echo "Evidence: $ARTIFACT_DIR"
