#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/IdeaForge.xcodeproj"
SCHEME="IdeaForgeiOS"
REPORT_DIR="${IOS_PERF_REPORT_DIR:-$ROOT_DIR/build/reports}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

IOS_SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17}"
IOS_SIMULATOR_OS="${IOS_SIMULATOR_OS:-26.5}"
IOS_SIMULATOR_UDID="${IOS_SIMULATOR_UDID:-}"
IOS_UI_ONLY_TESTING="${IOS_UI_ONLY_TESTING:-IdeaForgeiOSUITests/IdeaForgeiOSUITests/testPrimaryTabsExposeProductionWorkflowSurfaces}"
IOS_UI_TIMEOUT_SECONDS="${IOS_UI_TIMEOUT_SECONDS:-420}"
TRACE_TEMPLATE="${TRACE_TEMPLATE:-Time Profiler}"
TRACE_SECONDS="${TRACE_SECONDS:-90s}"
TRACE_SLUG="${TRACE_SLUG:-$(echo "$TRACE_TEMPLATE" | tr '[:upper:] ' '[:lower:]-')}"
TRACE_PATH="${TRACE_PATH:-$REPORT_DIR/ideaforge-ios-$TRACE_SLUG-$TIMESTAMP.trace}"
TRACE_LOG="${TRACE_LOG:-$REPORT_DIR/ideaforge-ios-$TRACE_SLUG-$TIMESTAMP.log}"
TRACE_SUMMARY="${TRACE_SUMMARY:-$REPORT_DIR/ideaforge-ios-$TRACE_SLUG-$TIMESTAMP.md}"
TRACE_TOC="${TRACE_TOC:-$REPORT_DIR/ideaforge-ios-$TRACE_SLUG-$TIMESTAMP-toc.xml}"
TRACE_EXPORT_LOG="${TRACE_EXPORT_LOG:-$REPORT_DIR/ideaforge-ios-$TRACE_SLUG-$TIMESTAMP-export.log}"
TRACE_STOP_TIMEOUT_SECONDS="${TRACE_STOP_TIMEOUT_SECONDS:-45}"

mkdir -p "$REPORT_DIR"

print_section() {
  printf '\n==> %s\n' "$1"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

write_summary() {
  local status="$1"
  local detail="$2"

  cat > "$TRACE_SUMMARY" <<EOF
# IdeaForge iOS Instruments Trace

Status: $status

- Template: $TRACE_TEMPLATE
- Simulator: ${resolved_summary:-unresolved}
- UI smoke: $IOS_UI_ONLY_TESTING
- Trace artifact: $TRACE_PATH
- Trace log: $TRACE_LOG
- Trace TOC: $TRACE_TOC
- Trace export log: $TRACE_EXPORT_LOG
- Detail: $detail

This trace is repo-side simulator Instruments performance evidence only when
Status is pass. It does not replace physical-device SwiftUI/App Responsiveness
proof for Watch capture, background upload, or real local speech quality.
EOF
}

validate_trace_artifact() {
  if [[ ! -d "$TRACE_PATH" && ! -f "$TRACE_PATH" ]]; then
    return 20
  fi

  rm -f "$TRACE_TOC" "$TRACE_EXPORT_LOG"
  if ! xcrun xctrace export --input "$TRACE_PATH" --toc --output "$TRACE_TOC" > "$TRACE_EXPORT_LOG" 2>&1; then
    return 21
  fi

  if [[ ! -s "$TRACE_TOC" ]]; then
    echo "xctrace export created an empty table of contents." > "$TRACE_EXPORT_LOG"
    return 22
  fi
}

resolve_simulator_udid() {
  if [[ -n "$IOS_SIMULATOR_UDID" ]]; then
    "$ROOT_DIR/script/resolve_ios_simulator.py" \
      --json "$simctl_json" \
      --udid "$IOS_SIMULATOR_UDID" \
      --format udid
    return
  fi

  "$ROOT_DIR/script/resolve_ios_simulator.py" \
    --json "$simctl_json" \
    --name "$IOS_SIMULATOR_NAME" \
    --os "$IOS_SIMULATOR_OS" \
    --format udid
}

cleanup_trace() {
  if [[ -n "${trace_pid:-}" ]] && kill -0 "$trace_pid" 2>/dev/null; then
    kill -TERM "$trace_pid" 2>/dev/null || true
    wait "$trace_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup_trace INT TERM

cd "$ROOT_DIR"

print_section "Checking xctrace template"
if ! xcrun xctrace list templates | grep -Fx "$TRACE_TEMPLATE" >/dev/null; then
  fail "xctrace template '$TRACE_TEMPLATE' is not available on this machine"
fi

if [[ ! -d "$PROJECT" ]]; then
  print_section "Regenerating Xcode project"
  xcodegen generate
fi

print_section "Resolving iOS simulator"
simctl_json="$REPORT_DIR/ios-perf-simulators-$TIMESTAMP.json"
xcrun simctl list devices available --json > "$simctl_json"
resolved_udid="$(resolve_simulator_udid)"
resolved_summary="$(
  "$ROOT_DIR/script/resolve_ios_simulator.py" \
    --json "$simctl_json" \
    --udid "$resolved_udid" \
    --format summary
)"
echo "Resolved simulator: $resolved_summary"

print_section "Preflighting Xcode destination"
destinations_log="$REPORT_DIR/ios-perf-destinations-$TIMESTAMP.log"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations > "$destinations_log" 2>&1 || {
  tail -n 120 "$destinations_log" >&2 || true
  fail "xcodebuild could not resolve $SCHEME destinations"
}
if ! grep -F "id:$resolved_udid" "$destinations_log" >/dev/null; then
  if xcrun simctl list devices available | grep -F "($resolved_udid)" >/dev/null; then
    echo "Resolved simulator id was not reported by xcodebuild but is available in simctl: $resolved_udid"
  else
    tail -n 120 "$destinations_log" >&2 || true
    fail "resolved simulator was not reported by xcodebuild or simctl: $resolved_udid"
  fi
fi

print_section "Booting simulator for trace"
xcrun simctl boot "$resolved_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$resolved_udid" -b

print_section "Starting Instruments trace"
echo "Template: $TRACE_TEMPLATE"
echo "Device: $resolved_udid"
echo "Trace: $TRACE_PATH"
echo "Trace log: $TRACE_LOG"
xcrun xctrace record \
  --template "$TRACE_TEMPLATE" \
  --device "$resolved_udid" \
  --all-processes \
  --time-limit "$TRACE_SECONDS" \
  --output "$TRACE_PATH" \
  --no-prompt > "$TRACE_LOG" 2>&1 &
trace_pid=$!

sleep 8
if ! kill -0 "$trace_pid" 2>/dev/null; then
  tail -n 120 "$TRACE_LOG" >&2 || true
  fail "xctrace exited before UI smoke started"
fi

print_section "Running focused iOS UI smoke during trace"
IOS_SIMULATOR_UDID="$resolved_udid" \
IOS_UI_ONLY_TESTING="$IOS_UI_ONLY_TESTING" \
IOS_UI_TIMEOUT_SECONDS="$IOS_UI_TIMEOUT_SECONDS" \
IOS_UI_REPORT_DIR="$REPORT_DIR" \
"$ROOT_DIR/script/run_ios_ui_smoke.sh"

print_section "Waiting for trace to finish"
elapsed=0
interval=5
trace_timed_out=0
while kill -0 "$trace_pid" 2>/dev/null; do
  if (( elapsed >= TRACE_STOP_TIMEOUT_SECONDS )); then
    trace_timed_out=1
    kill -TERM "$trace_pid" 2>/dev/null || true
    sleep 3
    kill -KILL "$trace_pid" 2>/dev/null || true
    break
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

set +e
wait "$trace_pid"
trace_status=$?
set -e
trace_pid=""
if [[ "$trace_timed_out" -eq 1 ]]; then
  trace_status=124
fi
if [[ "$trace_status" -ne 0 ]]; then
  set +e
  validate_trace_artifact
  export_status=$?
  set -e
  if [[ "$export_status" -eq 0 ]]; then
    write_summary "pass" "Focused iOS UI smoke passed and xctrace exited with status $trace_status, but the saved trace exported a valid table of contents."
    print_section "Instruments trace captured"
    echo "Summary: $TRACE_SUMMARY"
    echo "Trace: $TRACE_PATH"
    echo "Trace TOC: $TRACE_TOC"
    exit 0
  fi

  tail -n 120 "$TRACE_LOG" >&2 || true
  tail -n 120 "$TRACE_EXPORT_LOG" >&2 || true
  write_summary "blocked" "xctrace exited with status $trace_status after the UI smoke completed, and trace export validation failed with status $export_status."
  echo "Summary: $TRACE_SUMMARY"
  exit 2
fi

set +e
validate_trace_artifact
export_status=$?
set -e
if [[ "$export_status" -ne 0 ]]; then
  tail -n 120 "$TRACE_LOG" >&2 || true
  tail -n 120 "$TRACE_EXPORT_LOG" >&2 || true
  write_summary "blocked" "xctrace exited cleanly but trace export validation failed with status $export_status."
  echo "Summary: $TRACE_SUMMARY"
  exit 2
fi

write_summary "pass" "Focused iOS UI smoke passed while xctrace recorded and saved an export-validated trace artifact."

print_section "Instruments trace captured"
echo "Summary: $TRACE_SUMMARY"
echo "Trace: $TRACE_PATH"
echo "Trace TOC: $TRACE_TOC"
