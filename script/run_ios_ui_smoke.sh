#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/IdeaForge.xcodeproj"
SCHEME="IdeaForgeiOS"
CONFIGURATION="${CONFIGURATION:-Debug}"
IOS_DESTINATION="${IOS_DESTINATION:-}"
IOS_SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17}"
IOS_SIMULATOR_OS="${IOS_SIMULATOR_OS:-26.5}"
IOS_SIMULATOR_UDID="${IOS_SIMULATOR_UDID:-}"
IOS_UI_DERIVED_DATA="${IOS_UI_DERIVED_DATA:-$ROOT_DIR/DerivedData-production-ios}"
IOS_UI_TIMEOUT_SECONDS="${IOS_UI_TIMEOUT_SECONDS:-900}"
IOS_UI_ONLY_TESTING="${IOS_UI_ONLY_TESTING:-IdeaForgeiOSUITests}"
IOS_UI_TERMINATE_BUNDLE_IDS="${IOS_UI_TERMINATE_BUNDLE_IDS:-com.s1kor.ideaforge.ios com.usafe.native}"
IOS_UI_SHUTDOWN_OTHER_BOOTED_SIMULATORS="${IOS_UI_SHUTDOWN_OTHER_BOOTED_SIMULATORS:-1}"
REPORT_DIR="${IOS_UI_REPORT_DIR:-$ROOT_DIR/build/reports}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
IOS_UI_LOG="${IOS_UI_LOG:-$REPORT_DIR/ios-ui-smoke-$TIMESTAMP.log}"
IOS_UI_RESULT_BUNDLE="${IOS_UI_RESULT_BUNDLE:-$REPORT_DIR/ios-ui-smoke-$TIMESTAMP.xcresult}"

mkdir -p "$REPORT_DIR"

xcodebuild_pid=""

cleanup() {
  if [[ -n "$xcodebuild_pid" ]] && kill -0 "$xcodebuild_pid" 2>/dev/null; then
    kill "$xcodebuild_pid" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

print_section() {
  printf '\n==> %s\n' "$1"
}

resolve_ios_destination() {
  if [[ -n "$IOS_DESTINATION" ]]; then
    echo "Using explicit iOS UI destination: $IOS_DESTINATION"
    return
  fi

  local simctl_json
  simctl_json="$REPORT_DIR/ios-ui-simulators-$TIMESTAMP.json"
  xcrun simctl list devices available --json > "$simctl_json"

  local resolver_args=(--json "$simctl_json" --name "$IOS_SIMULATOR_NAME" --os "$IOS_SIMULATOR_OS")
  if [[ -n "$IOS_SIMULATOR_UDID" ]]; then
    resolver_args+=(--udid "$IOS_SIMULATOR_UDID")
  fi

  IOS_DESTINATION="$(
    "$ROOT_DIR/script/resolve_ios_simulator.py" "${resolver_args[@]}"
  )"

  local resolved_summary
  resolved_summary="$(
    "$ROOT_DIR/script/resolve_ios_simulator.py" "${resolver_args[@]}" --format summary
  )"

  echo "Resolved iOS UI simulator: $resolved_summary"
  echo "Resolved destination: $IOS_DESTINATION"
}

destination_id() {
  if [[ "$IOS_DESTINATION" =~ id=([^,[:space:]]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

print_diagnostics() {
  local status="$1"

  print_section "iOS UI smoke diagnostics: $status"
  echo "Destination: $IOS_DESTINATION"
  echo "DerivedData: $IOS_UI_DERIVED_DATA"
  echo "Result bundle: $IOS_UI_RESULT_BUNDLE"
  echo "Log: $IOS_UI_LOG"

  if [[ -f "$IOS_UI_LOG" ]]; then
    print_section "Last 160 log lines"
    tail -n 160 "$IOS_UI_LOG" || true
  fi

  print_section "Booted simulators"
  xcrun simctl list devices booted || true

  print_section "Available iPhone simulators"
  xcrun simctl list devices available | grep -E 'iPhone|Booted|Shutdown' | tail -n 100 || true

  print_section "Xcode destinations"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>&1 | tail -n 120 || true

  print_section "Relevant processes"
  ps -axo pid,etime,command | grep -E 'xcodebuild|XCTest|Simulator|IdeaForge' | grep -v grep || true
}

print_section "Resolving iOS UI smoke destination"
resolve_ios_destination

print_section "Preflighting iOS UI smoke destination"
IOS_UI_DESTINATIONS_LOG="$REPORT_DIR/ios-ui-destinations-$TIMESTAMP.log"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations > "$IOS_UI_DESTINATIONS_LOG" 2>&1 || {
  print_diagnostics "destination discovery failed"
  exit 65
}

resolved_destination_id="$(destination_id)"
if [[ -n "$resolved_destination_id" ]] && ! grep -F "id:$resolved_destination_id" "$IOS_UI_DESTINATIONS_LOG" >/dev/null; then
  if xcrun simctl list devices available | grep -F "($resolved_destination_id)" >/dev/null; then
    echo "Resolved destination id was not reported by xcodebuild but is available in simctl: $resolved_destination_id"
  else
    echo "Resolved destination id was not reported by xcodebuild: $resolved_destination_id"
    print_diagnostics "resolved destination unavailable"
    exit 65
  fi
fi

if [[ -n "$resolved_destination_id" ]]; then
  if [[ "$IOS_UI_SHUTDOWN_OTHER_BOOTED_SIMULATORS" == "1" ]]; then
    while IFS= read -r booted_simulator_id; do
      if [[ -n "$booted_simulator_id" && "$booted_simulator_id" != "$resolved_destination_id" ]]; then
        echo "Shutting down unrelated booted simulator: $booted_simulator_id"
        xcrun simctl shutdown "$booted_simulator_id" >/dev/null 2>&1 || true
      fi
    done < <(xcrun simctl list devices booted | sed -n 's/.*(\([A-F0-9-]*\)) (Booted).*/\1/p')
  fi
  for bundle_id in $IOS_UI_TERMINATE_BUNDLE_IDS; do
    xcrun simctl terminate "$resolved_destination_id" "$bundle_id" >/dev/null 2>&1 || true
  done
fi

print_section "Running iOS UI smoke tests"
echo "Destination: $IOS_DESTINATION"
echo "Timeout: ${IOS_UI_TIMEOUT_SECONDS}s"
echo "Result bundle: $IOS_UI_RESULT_BUNDLE"
echo "Log: $IOS_UI_LOG"

set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$IOS_UI_DERIVED_DATA" \
  -destination "$IOS_DESTINATION" \
  -resultBundlePath "$IOS_UI_RESULT_BUNDLE" \
  -only-testing:"$IOS_UI_ONLY_TESTING" \
  test > "$IOS_UI_LOG" 2>&1 &
xcodebuild_pid=$!

elapsed=0
interval=5
while kill -0 "$xcodebuild_pid" 2>/dev/null; do
  if (( elapsed >= IOS_UI_TIMEOUT_SECONDS )); then
    echo "iOS UI smoke timed out after ${IOS_UI_TIMEOUT_SECONDS}s."
    kill -INT "$xcodebuild_pid" 2>/dev/null || true
    sleep 5
    kill -TERM "$xcodebuild_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$xcodebuild_pid" 2>/dev/null || true
    wait "$xcodebuild_pid" >/dev/null 2>&1
    xcodebuild_pid=""
    print_diagnostics "timeout"
    exit 124
  fi

  sleep "$interval"
  elapsed=$((elapsed + interval))
done

wait "$xcodebuild_pid"
status=$?
xcodebuild_pid=""
set -e

if [[ "$status" -ne 0 ]]; then
  print_diagnostics "xcodebuild exited $status"
  exit "$status"
fi

print_section "iOS UI smoke passed"
tail -n 80 "$IOS_UI_LOG" || true
echo "Result bundle: $IOS_UI_RESULT_BUNDLE"
