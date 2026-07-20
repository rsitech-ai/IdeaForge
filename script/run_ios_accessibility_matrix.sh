#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="${IOS_UI_REPORT_DIR:-$ROOT_DIR/build/reports}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
IOS_SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17}"
IOS_SIMULATOR_OS="${IOS_SIMULATOR_OS:-26.5}"
IOS_SIMULATOR_UDID="${IOS_SIMULATOR_UDID:-}"
IOS_UI_DERIVED_DATA="${IOS_ACCESSIBILITY_DERIVED_DATA:-$ROOT_DIR/DerivedData-production-ios-accessibility}"
IOS_UI_TIMEOUT_SECONDS="${IOS_ACCESSIBILITY_TIMEOUT_SECONDS:-360}"
IOS_UI_STABILIZATION_SECONDS="${IOS_ACCESSIBILITY_STABILIZATION_SECONDS:-4}"
IOS_UI_TEST_TARGET="IdeaForgeiOSUITests/IdeaForgeiOSUITests"
IOS_APP_BUNDLE_ID="${IOS_APP_BUNDLE_ID:-com.s1kor.ideaforge.ios}"
SUMMARY_MD="${IOS_ACCESSIBILITY_SUMMARY:-$REPORT_DIR/ios-accessibility-matrix-$TIMESTAMP.md}"
EVIDENCE_TSV="${IOS_ACCESSIBILITY_EVIDENCE:-$REPORT_DIR/visual-evidence.tsv}"
VISUAL_MARKER="${IOS_ACCESSIBILITY_VISUAL_MARKER:-$REPORT_DIR/visual-scenarios.pass}"
REDUCE_MOTION_MARKER="${IOS_ACCESSIBILITY_REDUCE_MOTION_MARKER:-$REPORT_DIR/reduce-motion-ledger.md}"

render_reduce_motion_ledger() {
  local timestamp="$1"
  local simulator="$2"
  local readback="$3"
  local evidence_row="$4"
  printf '# IdeaForge iOS Reduce Motion Evidence Ledger\n\n'
  printf 'Date: %s\n\n' "$timestamp"
  printf 'Simulator: %s\n\n' "$simulator"
  printf '%s\n' '- Scenario: `recovered-recording-reduce-motion`'
  printf '%s\n' '- Requested system value: `1` (enabled)'
  printf '%s\n' "- Simulator readback after stabilization: \`$readback\`"
  printf '%s\n' '- XCTest assertion: `UIAccessibility.isReduceMotionEnabled == true`'
  printf '%s\n' '- Foreground proof: `XCUIApplication.state == runningForeground` immediately before and after the XCTest screenshot attachment.'
  printf '%s\n\n' "- Evidence row: \`$evidence_row\`"
  printf '%s\n' 'Final status: **PASS**'
}

if [[ "${1:-}" == "--self-test" ]]; then
  ledger="$(render_reduce_motion_ledger 20260713-test 'iPhone fixture' 1 $'recovered-recording-reduce-motion\t-uiTestingRecoveredRecording\tlight\tlarge\tdisabled\t1\tresult\tattachments')"
  grep -Fq 'Scenario: `recovered-recording-reduce-motion`' <<< "$ledger"
  grep -Fq 'Simulator readback after stabilization: `1`' <<< "$ledger"
  grep -Fq 'UIAccessibility.isReduceMotionEnabled == true' <<< "$ledger"
  grep -Fq 'Final status: **PASS**' <<< "$ledger"
  echo "run_ios_accessibility_matrix.sh self-test passed"
  exit 0
fi

mkdir -p "$REPORT_DIR"

device_id=""
resolved_summary=""
original_appearance=""
original_content_size=""
original_increase_contrast=""
original_reduce_motion=""
restored=0

print_section() {
  printf '\n==> %s\n' "$1"
}

restore_ui_settings() {
  if [[ "$restored" == "1" || -z "$device_id" ]]; then
    return
  fi
  restored=1
  if [[ -n "$original_appearance" && "$original_appearance" != "unsupported" && "$original_appearance" != "unknown" ]]; then
    xcrun simctl ui "$device_id" appearance "$original_appearance" >/dev/null 2>&1 || true
  fi
  if [[ -n "$original_content_size" && "$original_content_size" != "unsupported" && "$original_content_size" != "unknown" ]]; then
    xcrun simctl ui "$device_id" content_size "$original_content_size" >/dev/null 2>&1 || true
  fi
  if [[ -n "$original_increase_contrast" && "$original_increase_contrast" != "unsupported" && "$original_increase_contrast" != "unknown" ]]; then
    xcrun simctl ui "$device_id" increase_contrast "$original_increase_contrast" >/dev/null 2>&1 || true
  fi
  if [[ "$original_reduce_motion" == "0" || "$original_reduce_motion" == "1" ]]; then
    local restore_bool="false"
    if [[ "$original_reduce_motion" == "1" ]]; then
      restore_bool="true"
    fi
    xcrun simctl spawn "$device_id" defaults write com.apple.Accessibility ReduceMotionEnabled -bool "$restore_bool" >/dev/null 2>&1 || true
  fi
}

trap restore_ui_settings EXIT

resolve_destination() {
  local simctl_json
  simctl_json="$REPORT_DIR/ios-accessibility-simulators-$TIMESTAMP.json"
  xcrun simctl list devices available --json > "$simctl_json"

  local resolver_args=(--json "$simctl_json" --name "$IOS_SIMULATOR_NAME" --os "$IOS_SIMULATOR_OS")
  if [[ -n "$IOS_SIMULATOR_UDID" ]]; then
    resolver_args+=(--udid "$IOS_SIMULATOR_UDID")
  fi

  local destination
  destination="$("$ROOT_DIR/script/resolve_ios_simulator.py" "${resolver_args[@]}")"
  if [[ "$destination" =~ id=([^,[:space:]]+) ]]; then
    device_id="${BASH_REMATCH[1]}"
  else
    echo "Resolved iOS destination did not include a simulator id: $destination"
    exit 65
  fi

  resolved_summary="$("$ROOT_DIR/script/resolve_ios_simulator.py" "${resolver_args[@]}" --format summary)"
}

read_supported_ui_setting() {
  local option="$1"
  local value
  value="$(xcrun simctl ui "$device_id" "$option" | tr -d '[:space:]')"
  if [[ "$value" == "unsupported" || "$value" == "unknown" || -z "$value" ]]; then
    echo "Simulator UI option $option is not available on $device_id: $value"
    exit 65
  fi
  echo "$value"
}

set_ui_setting() {
  local option="$1"
  local value="$2"
  xcrun simctl ui "$device_id" "$option" "$value" >/dev/null

  local actual
  actual="$(read_supported_ui_setting "$option")"
  if [[ "$actual" != "$value" ]]; then
    echo "Simulator UI option $option did not apply. Expected $value, got $actual."
    exit 65
  fi
}

read_reduce_motion() {
  xcrun simctl spawn "$device_id" defaults read com.apple.Accessibility ReduceMotionEnabled 2>/dev/null \
    | tr -d '[:space:]'
}

set_reduce_motion() {
  local expected="$1"
  local bool_value="false"
  if [[ "$expected" == "1" ]]; then
    bool_value="true"
  fi
  xcrun simctl spawn "$device_id" defaults write com.apple.Accessibility ReduceMotionEnabled -bool "$bool_value"
  local actual
  actual="$(read_reduce_motion)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Simulator Reduce Motion did not apply. Expected $expected, got $actual."
    exit 65
  fi
}

apply_and_verify_settings() {
  local appearance="$1"
  local content_size="$2"
  local increase_contrast="$3"
  local reduce_motion="$4"

  set_ui_setting appearance "$appearance"
  set_ui_setting content_size "$content_size"
  set_ui_setting increase_contrast "$increase_contrast"
  set_reduce_motion "$reduce_motion"
  sleep "$IOS_UI_STABILIZATION_SECONDS"
  [[ "$(xcrun simctl ui "$device_id" appearance)" == "$appearance" ]]
  [[ "$(xcrun simctl ui "$device_id" content_size)" == "$content_size" ]]
  [[ "$(xcrun simctl ui "$device_id" increase_contrast)" == "$increase_contrast" ]]
  [[ "$(read_reduce_motion)" == "$reduce_motion" ]]
}

run_scenario() {
  local slug="$1"
  local appearance="$2"
  local content_size="$3"
  local increase_contrast="$4"
  local reduce_motion="$5"
  local fixture_argument="$6"
  local test_name="$7"

  local log_path="$REPORT_DIR/ios-accessibility-$slug-$TIMESTAMP.log"
  local result_bundle="$REPORT_DIR/ios-accessibility-$slug-$TIMESTAMP.xcresult"
  local attachment_dir="$REPORT_DIR/attachments/$TIMESTAMP/$slug"

  print_section "Running iOS accessibility scenario: $slug"
  apply_and_verify_settings "$appearance" "$content_size" "$increase_contrast" "$reduce_motion"

  IOS_DESTINATION="platform=iOS Simulator,id=$device_id" \
  IOS_UI_DERIVED_DATA="$IOS_UI_DERIVED_DATA" \
  IOS_UI_TIMEOUT_SECONDS="$IOS_UI_TIMEOUT_SECONDS" \
  IOS_UI_ONLY_TESTING="$IOS_UI_TEST_TARGET/$test_name" \
  IOS_UI_LOG="$log_path" \
  IOS_UI_RESULT_BUNDLE="$result_bundle" \
    "$ROOT_DIR/script/run_ios_ui_smoke.sh"

  grep -F "$test_name]' passed" "$log_path"
  grep -Fq 'Executed 1 test, with 0 failures' "$log_path"

  mkdir -p "$attachment_dir"
  xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$attachment_dir"
  test -f "$attachment_dir/manifest.json"
  grep -Fq "IdeaForge-$slug" "$attachment_dir/manifest.json"
  local screenshot_count
  screenshot_count="$(find "$attachment_dir" -type f -name '*.png' | wc -l | tr -d ' ')"
  if [[ "$screenshot_count" -ne 1 ]]; then
    echo "Expected exactly one exported foreground screenshot for $slug, found $screenshot_count."
    exit 65
  fi
  find "$attachment_dir" -type f -name '*.png' -print0 \
    | xargs -0 file \
    | grep -q 'PNG image data'

  {
    echo "| $slug | $fixture_argument | $appearance | $content_size | $increase_contrast | $reduce_motion | passed | \`$result_bundle\` | \`$attachment_dir\` |"
  } >> "$SUMMARY_MD"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$slug" "$fixture_argument" "$appearance" "$content_size" "$increase_contrast" "$reduce_motion" \
    "$result_bundle" "$attachment_dir" >> "$EVIDENCE_TSV"
}

print_section "Resolving iOS accessibility matrix destination"
resolve_destination
echo "Resolved simulator: $resolved_summary"

print_section "Booting simulator"
xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$device_id" -b

original_appearance="$(read_supported_ui_setting appearance)"
original_content_size="$(read_supported_ui_setting content_size)"
original_increase_contrast="$(read_supported_ui_setting increase_contrast)"
original_reduce_motion="$(read_reduce_motion)"

printf 'scenario\tfixture\tappearance\tcontent_size\tincrease_contrast\treduce_motion\tresult_bundle\tattachment_dir\n' > "$EVIDENCE_TSV"

cat > "$SUMMARY_MD" <<EOF
# IdeaForge iOS Appearance And Accessibility Matrix

Date: $TIMESTAMP

Simulator: $resolved_summary

Original settings:

- Appearance: $original_appearance
- Content size: $original_content_size
- Increase Contrast: $original_increase_contrast
- Reduce Motion: $original_reduce_motion

Focused tests: six named foreground XCTest visual fixtures under \`$IOS_UI_TEST_TARGET\`.

| Scenario | Fixture | Appearance | Content Size | Increase Contrast | Reduce Motion | Status | Result Bundle | Foreground XCTest Attachment |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
EOF

run_scenario "clean-light" "light" "large" "disabled" "0" "-uiTestingClean" "testTaskFirstVisualEvidenceCapturesForegroundFixtureClean"
run_scenario "queued-light" "light" "large" "disabled" "0" "-uiTestingQueuedUpload" "testTaskFirstVisualEvidenceCapturesForegroundFixtureQueued"
run_scenario "failed-dark" "dark" "large" "disabled" "0" "-uiTestingFailedUpload" "testTaskFirstVisualEvidenceCapturesForegroundFixtureFailed"
run_scenario "offline-accessibility" "light" "accessibility-large" "disabled" "0" "-uiTestingOfflineWatch" "testTaskFirstVisualEvidenceCapturesForegroundFixtureOffline"
run_scenario "conflict-contrast" "dark" "accessibility-extra-large" "enabled" "0" "-uiTestingSyncConflict" "testTaskFirstVisualEvidenceCapturesForegroundFixtureConflict"
run_scenario "recovered-recording-reduce-motion" "light" "large" "disabled" "1" "-uiTestingRecoveredRecording" "testTaskFirstVisualEvidenceCapturesForegroundFixtureRecoveredReduceMotion"

test "$(tail -n +2 "$EVIDENCE_TSV" | wc -l | tr -d ' ')" -eq 6
cut -f1 "$EVIDENCE_TSV" | tail -n +2 > "$VISUAL_MARKER"
reduce_motion_row="$(awk -F '\t' '$1 == "recovered-recording-reduce-motion" && $6 == "1" { print $0 }' "$EVIDENCE_TSV")"
render_reduce_motion_ledger \
  "$TIMESTAMP" \
  "$resolved_summary" \
  "$(read_reduce_motion)" \
  "$reduce_motion_row" > "$REDUCE_MOTION_MARKER"
test -s "$VISUAL_MARKER"
test -s "$REDUCE_MOTION_MARKER"

restore_ui_settings
apply_and_verify_settings \
  "$original_appearance" \
  "$original_content_size" \
  "$original_increase_contrast" \
  "$original_reduce_motion"

{
  echo ""
  echo "Final status: **pass**"
} >> "$SUMMARY_MD"

print_section "iOS accessibility matrix passed"
cat "$SUMMARY_MD"
