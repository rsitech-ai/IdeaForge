#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT_DIR/script/verify_production.sh"

grep -Fq 'XCODEGEN_BIN="${XCODEGEN_BIN:-xcodegen}"' "$VERIFIER"
grep -Fq 'PYTHON_BIN="${PYTHON_BIN:-python3}"' "$VERIFIER"
grep -Fq 'command -v "$XCODEGEN_BIN"' "$VERIFIER"
grep -Fq 'command -v "$PYTHON_BIN"' "$VERIFIER"
grep -A6 -F 'macOS warnings-as-errors build' "$VERIFIER" | grep -F 'CODE_SIGNING_ALLOWED=NO' >/dev/null
grep -A6 -F 'iOS generic device warnings-as-errors build' "$VERIFIER" | grep -F 'CODE_SIGNING_ALLOWED=NO' >/dev/null

grep -Fq 'generic/platform=iOS' "$VERIFIER"
grep -Fq 'iOS generic device warnings-as-errors build' "$VERIFIER"
grep -Fq 'resolve_watch_simulator.py' "$VERIFIER"
grep -Fq 'Resolve exact Apple Watch Ultra 3 simulator destination' "$VERIFIER"
grep -Fq 'is_exact_watch_destination' "$VERIFIER"
grep -Fq -- '--udid "$requested_udid"' "$VERIFIER"
grep -Fq 'WATCH_ULTRA_DESTINATION="${WATCH_ULTRA_DESTINATION:-}"' "$VERIFIER"
if grep -Fq 'WATCH_ULTRA_DESTINATION="${WATCH_ULTRA_DESTINATION:-platform=watchOS Simulator,name=' "$VERIFIER"; then
  echo "Verifier still defaults to an ambiguous name-based Watch destination."
  exit 1
fi
/opt/homebrew/bin/python3 "$ROOT_DIR/script/resolve_watch_simulator.py" --self-test
grep -Fq 'validate_ios_screenshot.py' "$VERIFIER"
/opt/homebrew/bin/python3 "$ROOT_DIR/script/validate_ios_screenshot.py" --self-test
/opt/homebrew/bin/python3 "$ROOT_DIR/script/check_physical_device_readiness.py" --self-test
/opt/homebrew/bin/python3 "$ROOT_DIR/script/review_privacy_logs.py" --self-test
/opt/homebrew/bin/python3 "$ROOT_DIR/script/check_app_process_health.py" --self-test

grep -Fq -- '-only-testing:IdeaForgeMacUITests' "$VERIFIER"
if grep -Fq 'IdeaForgeMacUITests/IdeaForgeMacUITests/' "$VERIFIER"; then
  echo "Mac UI gate must not select an incomplete per-test subset."
  exit 1
fi

for live_contract in \
  RUN_LIVE_DEPLOYED_BACKEND \
  RUN_LIVE_AI_PROVIDER \
  RUN_LIVE_APP_STORE_SERVER_API \
  RUN_LIVE_APNS \
  'Live deployed backend readiness' \
  'Live AI provider readiness' \
  'Live App Store Server API readiness' \
  'Live APNs readiness'; do
  grep -Fq "$live_contract" "$VERIFIER"
done

grep -Fq 'classify_physical_result()' "$VERIFIER"
grep -Fq 'Physical-device readiness failed and cannot be waived.' "$VERIFIER"
grep -Fq 'invalid or unreadable prerequisites' "$VERIFIER"
grep -Fq 'classify_live_prerequisites' "$VERIFIER"
grep -Fq 'live check not executed; missing prerequisites' "$VERIFIER"
grep -Fq 'Live request executed: yes (explicit opt-in)' "$VERIFIER"

"$VERIFIER" --self-test
RUN_GATE_SELF_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_GATE_SELF_TEST_DIR"' EXIT
VERIFY_PRODUCTION_ARTIFACT_DIR="$RUN_GATE_SELF_TEST_DIR" "$VERIFIER" --self-test-run-gate

grep -Fq 'check_app_process_health.py' "$VERIFIER"
if grep -Fq 'process-health "Terminate app processes and verify clean shutdown" terminate_app_processes' "$VERIFIER"; then
  echo "Verifier still uses the legacy swallowed-error process-health function."
  exit 1
fi

for visual_contract in \
  'iOS authoritative XCTest visual attachments' \
  'iOS Reduce Motion evidence ledger' \
  'validate_ios_visual_scenarios' \
  'validate_ios_reduce_motion_evidence'; do
  grep -Fq "$visual_contract" "$VERIFIER"
done
grep -Fq 'grep -Fq "IdeaForge-$scenario" "$attachment_dir/manifest.json"' "$VERIFIER"
grep -Fq "grep -q 'PNG image data'" "$VERIFIER"
if grep -Fq 'iOS accessibility screenshot inspection' "$VERIFIER"; then
  echo "Verifier still classifies repository-owned iOS visual evidence as non-authoritative."
  exit 1
fi

grep -Fq 'Runtime crash/retry-loop/persistence log analysis' "$VERIFIER"
grep -Fq 'Verification inputs remained stable during the run' "$VERIFIER"
grep -Fq 'verification-inputs-before.sha256' "$VERIFIER"
grep -Fq 'Package.swift project.yml README.md Sources Tests script docs .github' "$VERIFIER"
grep -Fq 'testIdeasAgentAndQuestionAnswerFlow' "$VERIFIER"
grep -Fq 'NSPrivacyAccessedAPICategoryDiskSpace' "$VERIFIER"
grep -Fq '<string>E174.1</string>' "$VERIFIER"
grep -Fq 'NSPrivacyAccessedAPICategoryUserDefaults' "$VERIFIER"
grep -Fq '<string>CA92.1</string>' "$VERIFIER"
grep -Fq 'validate_app_store_assets.py" --public-source' "$VERIFIER"
grep -Fq 'Private App Store metadata and screenshots' "$VERIFIER"

for direct_release_contract in \
  'RUN_DIRECT_MAC_RELEASE="${RUN_DIRECT_MAC_RELEASE:-0}"' \
  'DIRECT_MAC_RELEASE_MODE="${DIRECT_MAC_RELEASE_MODE:-package-only}"' \
  'Development-signed Release archives (not distribution-ready)' \
  'Developer ID local export and signature audit' \
  'Developer ID notarized direct-download release' \
  'Direct-download distribution readiness'; do
  grep -Fq "$direct_release_contract" "$VERIFIER"
done
grep -Fq 'if [[ "$RUN_DIRECT_MAC_RELEASE" == "1" ]]' "$VERIFIER"
grep -Fq '"$ROOT_DIR/script/release_macos.sh" --package-only' "$VERIFIER"
grep -Fq '"$ROOT_DIR/script/release_macos.sh" --notarize' "$VERIFIER"
grep -Fq 'RUN_DIRECT_MAC_RELEASE=0; the direct-release script was not invoked.' "$VERIFIER"
grep -Fq 'Development-signed Release archive check (not distribution-ready)' "$ROOT_DIR/script/check_release_signing.sh"
if grep -Fq 'Create distribution-ready Release archives' "$VERIFIER"; then
  echo "Verifier still labels development archives as distribution-ready."
  exit 1
fi

echo "test_verify_production.sh passed"
