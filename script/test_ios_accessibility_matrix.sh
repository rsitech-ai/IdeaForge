#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MATRIX="$ROOT_DIR/script/run_ios_accessibility_matrix.sh"
UI_TESTS="$ROOT_DIR/Tests/IdeaForgeiOSUITests/IdeaForgeiOSUITests.swift"
VERIFIER="$ROOT_DIR/script/verify_production.sh"

bash -n "$MATRIX"
"$MATRIX" --self-test
grep -Fq 'xcresulttool export attachments' "$MATRIX"
grep -Fq 'attachments/$TIMESTAMP/$slug' "$MATRIX"
grep -Fq -- "-name '*.png'" "$MATRIX"
grep -Fq 'ReduceMotionEnabled' "$MATRIX"
grep -Fq 'bool_value="true"' "$MATRIX"
grep -Fq 'restore_bool="true"' "$MATRIX"
grep -Fq 'IOS_ACCESSIBILITY_STABILIZATION_SECONDS' "$MATRIX"
grep -Fq 'sleep "$IOS_UI_STABILIZATION_SECONDS"' "$MATRIX"
for visual_test in \
  testTaskFirstVisualEvidenceCapturesForegroundFixtureClean \
  testTaskFirstVisualEvidenceCapturesForegroundFixtureQueued \
  testTaskFirstVisualEvidenceCapturesForegroundFixtureFailed \
  testTaskFirstVisualEvidenceCapturesForegroundFixtureOffline \
  testTaskFirstVisualEvidenceCapturesForegroundFixtureConflict \
  testTaskFirstVisualEvidenceCapturesForegroundFixtureRecoveredReduceMotion; do
  grep -Fq "$visual_test" "$MATRIX"
  grep -Fq "$visual_test" "$UI_TESTS"
done
if grep -Fq 'IDEAFORGE_VISUAL_SCENARIO' "$UI_TESTS"; then
  echo "Visual XCTest still depends on shell environment propagation."
  exit 1
fi
grep -Fq 'runningForeground' "$UI_TESTS"
grep -Fq 'XCUIScreen.main.screenshot()' "$UI_TESTS"
grep -Fq 'pngRepresentation' "$UI_TESTS"
grep -Fq 'app.activate()' "$UI_TESTS"
grep -Fq 'app.wait(for: .runningForeground' "$UI_TESTS"
grep -Fq 'appFrame.contains(elementFrame)' "$UI_TESTS"
grep -Fq 'CIAreaAverage' "$UI_TESTS"
grep -Fq 'averageLuminance' "$UI_TESTS"
grep -Fq 'Light visual fixture rendered with unexpectedly low luminance' "$UI_TESTS"
grep -Fq 'Dark visual fixture rendered with unexpectedly high luminance' "$UI_TESTS"
grep -Fq 'application.launchArguments.append("-uiTestingDarkAppearance")' "$UI_TESTS"
grep -Fq 'Thread.sleep(forTimeInterval: 8)' "$UI_TESTS"
grep -Fq 'Thread.sleep(forTimeInterval: 2)' "$UI_TESTS"
grep -Fq 'apply_and_verify_settings' "$MATRIX"
if grep -Fq 'reboot_and_verify_settings' "$MATRIX"; then
  echo "Accessibility matrix still reboots between visual scenarios."
  exit 1
fi
grep -Fq '["Inbox", "Ideas", "Questions", "Account"]' "$UI_TESTS"
grep -Fq 'iOS authoritative XCTest visual attachments' "$VERIFIER"
grep -Fq 'iOS Reduce Motion evidence ledger' "$VERIFIER"

if grep -Eq 'simctl io .*screenshot' "$MATRIX"; then
  echo "Accessibility matrix still uses unstable post-test simulator screenshots."
  exit 1
fi

echo "test_ios_accessibility_matrix.sh passed"
