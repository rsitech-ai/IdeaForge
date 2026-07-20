#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/IdeaForge.xcodeproj"
EXPORT_OPTIONS="$ROOT_DIR/Config/DeveloperIDExportOptions.plist"
RELEASE_ROOT="$ROOT_DIR/dist/release"
EXPECTED_TEAM="2NY8A789TN"
EXPECTED_IDENTITY="325BE7BDA73543F37311F400F231DC751E87FB77"
MODE=""
ALLOW_DIRTY=0

# Raw Apple credentials are intentionally unsupported. Real notarization uses
# only NOTARY_KEYCHAIN_PROFILE, and child processes never inherit common raw
# credential variables if a caller happened to define them.
unset APPLE_ID APPLE_APP_SPECIFIC_PASSWORD NOTARY_PASSWORD AC_USERNAME AC_PASSWORD \
  ASC_PROVIDER APP_STORE_CONNECT_API_KEY APP_STORE_CONNECT_API_ISSUER \
  APP_STORE_CONNECT_API_KEY_PATH

usage() {
  cat <<'EOF'
Usage: release_macos.sh (--package-only | --notarize) [--allow-dirty]

  --package-only  Archive, Developer ID export, and local signature audit only.
                  This mode never contacts Apple and is not notarization proof.
  --notarize      Submit, staple, and package the direct-download release.
  --allow-dirty   Permit a dirty tree only with --package-only for local proof.
EOF
}

fail() {
  echo "release_macos.sh: $*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --package-only|--notarize)
      [[ -z "$MODE" ]] || fail "choose exactly one release mode"
      MODE="$1"
      ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$MODE" ]] || fail "choose --package-only or --notarize"
if [[ "$ALLOW_DIRTY" == "1" && "$MODE" != "--package-only" ]]; then
  fail "--allow-dirty is restricted to the local --package-only mode"
fi

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
[[ "$DEVELOPMENT_TEAM" == "$EXPECTED_TEAM" ]] \
  || fail "DEVELOPMENT_TEAM must equal $EXPECTED_TEAM"
[[ "$DEVELOPER_ID_APPLICATION" == "$EXPECTED_IDENTITY" ]] \
  || fail "DEVELOPER_ID_APPLICATION must equal $EXPECTED_IDENTITY"

RELEASE_VERSION="${RELEASE_VERSION:-}"
if [[ -z "$RELEASE_VERSION" ]]; then
  exact_tag="$(git -C "$ROOT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
  if [[ "$exact_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)$ ]]; then
    RELEASE_VERSION="${BASH_REMATCH[1]}"
  else
    fail "RELEASE_VERSION is required when HEAD has no exact v<version> tag"
  fi
fi
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
  || fail "RELEASE_VERSION must be a semantic version"

PROJECT_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
[[ -n "$PROJECT_VERSION" && "$RELEASE_VERSION" == "$PROJECT_VERSION" ]] \
  || fail "RELEASE_VERSION $RELEASE_VERSION does not match project MARKETING_VERSION ${PROJECT_VERSION:-missing}"

[[ -d "$PROJECT" ]] || fail "generated Xcode project is missing: $PROJECT"
[[ -f "$EXPORT_OPTIONS" ]] || fail "Developer ID export options are missing: $EXPORT_OPTIONS"

FINAL_DMG="$RELEASE_ROOT/IdeaForge-$RELEASE_VERSION.dmg"
FINAL_ZIP="$RELEASE_ROOT/IdeaForge-$RELEASE_VERSION.zip"
FINAL_SUMS="$RELEASE_ROOT/SHA256SUMS"
FINAL_MANIFEST="$RELEASE_ROOT/manifest.json"
LOCAL_EXPORT_DIR="$RELEASE_ROOT/local-export/IdeaForge-$RELEASE_VERSION"

if [[ "$MODE" == "--notarize" ]]; then
  collision_paths=("$FINAL_DMG" "$FINAL_ZIP" "$FINAL_SUMS" "$FINAL_MANIFEST" "$RELEASE_ROOT/notary")
else
  collision_paths=("$LOCAL_EXPORT_DIR")
fi
for collision_path in "${collision_paths[@]}"; do
  [[ ! -e "$collision_path" ]] \
    || fail "Refusing to overwrite existing release output: $collision_path"
done

if [[ "$MODE" == "--notarize" ]]; then
  git_worktree_state="$(git -C "$ROOT_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)"
  [[ "$git_worktree_state" == "true" ]] \
    || fail "real notarization requires a valid Git worktree"
  if ! git_status="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"; then
    fail "unable to verify clean Git worktree: git status failed"
  fi
  if [[ -n "$git_status" ]]; then
    fail "Git worktree must be clean; --allow-dirty is permitted only for local package proof"
  fi
  exact_tag="$(git -C "$ROOT_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
  [[ "$exact_tag" == "v$RELEASE_VERSION" ]] \
    || fail "real notarization requires exact Git tag v$RELEASE_VERSION at HEAD"
elif git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ "$ALLOW_DIRTY" != "1" && -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
    fail "Git worktree must be clean; --allow-dirty is permitted only for local package proof"
  fi
fi
if [[ "$MODE" == "--notarize" ]]; then
  [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]] \
    || fail "NOTARY_KEYCHAIN_PROFILE is required for real notarization"
fi

identity_listing="$(security find-identity -p codesigning -v 2>&1 || true)"
grep -Fq "$EXPECTED_IDENTITY" <<< "$identity_listing" \
  || fail "exact Developer ID Application identity is not installed: $EXPECTED_IDENTITY"

mkdir -p "$RELEASE_ROOT"
WORK_DIR="$(mktemp -d "$RELEASE_ROOT/.work.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
ARCHIVE_PATH="$WORK_DIR/IdeaForgeMac.xcarchive"
EXPORT_PATH="$WORK_DIR/export"

echo "==> Archiving IdeaForgeMac with exact Developer ID identity"
archive_app() {
  xcodebuild \
    -quiet \
    -project "$PROJECT" \
    -scheme IdeaForgeMac \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM" \
    CODE_SIGN_IDENTITY="$EXPECTED_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    "$@" \
    archive
}
if [[ "$MODE" == "--package-only" ]]; then
  # Developer ID signing otherwise requests Apple's secure timestamp service.
  # The offline artifact is deliberately labeled local_export_verified, never
  # distribution-ready; the notarization path below requires timestamps.
  archive_app OTHER_CODE_SIGN_FLAGS=--timestamp=none
else
  archive_app
fi

echo "==> Exporting Developer ID application locally"
xcodebuild \
  -quiet \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

EXPORTED_APP="$EXPORT_PATH/IdeaForge.app"
[[ -d "$EXPORTED_APP" ]] || fail "Developer ID export did not produce IdeaForge.app"
for legal_resource in \
  LICENSE \
  NOTICE \
  THIRD_PARTY_NOTICES.md \
  ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt; do
  [[ -f "$EXPORTED_APP/Contents/Resources/$legal_resource" ]] \
    || fail "exported application omitted required legal resource: $legal_resource"
done

audit_code_signature() {
  local target="$1"
  local require_sandbox="$2"
  local require_timestamp="$3"
  local details entitlements

  codesign --verify --strict --verbose=2 "$target"
  details="$(codesign --display --verbose=4 "$target" 2>&1)"
  grep -Fq "TeamIdentifier=$EXPECTED_TEAM" <<< "$details" \
    || fail "signature team mismatch: $target"
  grep -Eq '(^|[=(])runtime([,)]|$)|^Runtime Version=' <<< "$details" \
    || fail "hardened runtime is missing: $target"
  if [[ "$require_timestamp" == "1" ]]; then
    grep -Eq '^Timestamp=.+$' <<< "$details" \
      || fail "secure timestamp is missing: $target"
  fi

  entitlements="$(codesign --display --entitlements :- "$target" 2>/dev/null || true)"
  if grep -Fq '<key>com.apple.security.get-task-allow</key>' <<< "$entitlements"; then
    fail "get-task-allow entitlement is forbidden: $target"
  fi
  if [[ "$require_sandbox" == "1" ]]; then
    grep -Eq '<key>com\.apple\.security\.app-sandbox</key>[[:space:]]*<true/>' <<< "$entitlements" \
      || fail "App Sandbox entitlement is missing: $target"
  fi
}

echo "==> Auditing main and nested Developer ID signatures"
REQUIRE_SECURE_TIMESTAMP=1
[[ "$MODE" != "--package-only" ]] || REQUIRE_SECURE_TIMESTAMP=0
audit_code_signature "$EXPORTED_APP" 1 "$REQUIRE_SECURE_TIMESTAMP"
while IFS= read -r -d '' nested_file; do
  if file -b "$nested_file" | grep -Fq 'Mach-O'; then
    audit_code_signature "$nested_file" 0 "$REQUIRE_SECURE_TIMESTAMP"
  fi
done < <(find "$EXPORTED_APP/Contents" -type f -print0)

write_manifest() {
  local output="$1"
  local readiness="$2"
  local mode="$3"
  /usr/bin/python3 - "$output" "$RELEASE_VERSION" "$readiness" "$mode" "$EXPECTED_TEAM" "$EXPECTED_IDENTITY" <<'PY'
import json
import pathlib
import sys

output, version, readiness, mode, team, identity = sys.argv[1:]
path = pathlib.Path(output)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
    "product": "IdeaForge",
    "version": version,
    "mode": mode,
    "readiness": readiness,
    "development_team": team,
    "developer_id_application_sha1": identity,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

if [[ "$MODE" == "--package-only" ]]; then
  mkdir -p "$LOCAL_EXPORT_DIR"
  cp -R "$EXPORTED_APP" "$LOCAL_EXPORT_DIR/IdeaForge.app"
  write_manifest "$LOCAL_EXPORT_DIR/manifest.json" "local_export_verified" "package-only"
  echo "Readiness: local_export_verified (Developer ID export/signature proof only; no Apple notarization request was made)."
  echo "Artifact: $LOCAL_EXPORT_DIR"
  exit 0
fi

NOTARY_DIR="$RELEASE_ROOT/notary"
mkdir -p "$NOTARY_DIR"

sanitize_notary_json() {
  local input="$1"
  local output="$2"
  local kind="$3"
  /usr/bin/python3 - "$input" "$output" "$kind" <<'PY'
import json
import pathlib
import sys

input_path, output_path, kind = sys.argv[1:]
try:
    payload = json.loads(pathlib.Path(input_path).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    print(f"Malformed notarization JSON: {error}", file=sys.stderr)
    raise SystemExit(65)

if not isinstance(payload, dict):
    print("Malformed notarization JSON: top-level value is not an object", file=sys.stderr)
    raise SystemExit(65)

if kind == "submission":
    safe = {key: payload[key] for key in ("id", "status", "message") if key in payload}
    if not isinstance(safe.get("id"), str) or not isinstance(safe.get("status"), str):
        print("Malformed notarization JSON: string id and status are required", file=sys.stderr)
        raise SystemExit(65)
else:
    safe = {
        key: payload[key]
        for key in ("jobId", "status", "statusSummary")
        if key in payload
    }
    issues = payload.get("issues", [])
    if isinstance(issues, list):
        safe["issues"] = [
            {
                key: issue[key]
                for key in ("severity", "code", "path", "message", "docUrl", "architecture")
                if key in issue
            }
            for issue in issues
            if isinstance(issue, dict)
        ]

path = pathlib.Path(output_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(safe, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_notary_log_retrieval_failure() {
  local output="$1"
  local job_id="$2"
  local notarization_status="$3"
  /usr/bin/python3 - "$output" "$job_id" "$notarization_status" <<'PY'
import json
import pathlib
import sys

output_path, job_id, notarization_status = sys.argv[1:]
safe = {
    "diagnostic": "notary_log_retrieval_failed",
    "job_id": job_id,
    "notarization_status": notarization_status,
    "raw_output_disposition": "discarded",
}
path = pathlib.Path(output_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(safe, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

notarize_and_staple() {
  local slug="$1"
  local submitted_artifact="$2"
  local staple_target="$3"
  local staple_label="$4"
  local raw_submit="$WORK_DIR/$slug-submit.raw.json"
  local raw_stderr="$WORK_DIR/$slug-submit.stderr"
  local safe_submit="$NOTARY_DIR/$slug-submit.json"
  local job_id status

  if ! xcrun notarytool submit "$submitted_artifact" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait --output-format json > "$raw_submit" 2> "$raw_stderr"; then
    fail "notarytool submit failed for $slug; raw output was discarded"
  fi
  sanitize_notary_json "$raw_submit" "$safe_submit" submission
  IFS=$'\t' read -r job_id status < <(
    /usr/bin/python3 - "$safe_submit" <<'PY'
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(f"{payload['id']}\t{payload['status']}")
PY
  )

  if [[ "$status" != "Accepted" ]]; then
    local raw_log="$WORK_DIR/$slug-failure-log.raw.json"
    local raw_log_stderr="$WORK_DIR/$slug-failure-log.stderr"
    local safe_log="$NOTARY_DIR/$slug-failure-log.json"
    if xcrun notarytool log "$job_id" \
      --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
      --output-format json > "$raw_log" 2> "$raw_log_stderr"; then
      sanitize_notary_json "$raw_log" "$safe_log" log
    else
      write_notary_log_retrieval_failure "$safe_log" "$job_id" "$status"
      fail "Notarization status is $status, expected Accepted; notarytool log retrieval failed; see $safe_log"
    fi
    fail "Notarization status is $status, expected Accepted; see $safe_submit"
  fi

  if ! xcrun stapler staple "$staple_target" >/dev/null 2>&1; then
    fail "Failed to staple $staple_label"
  fi
  if ! xcrun stapler validate "$staple_target" >/dev/null 2>&1; then
    fail "Failed to validate stapled $staple_label"
  fi
}

APP_SUBMISSION_ZIP="$WORK_DIR/IdeaForge-app-notarization.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$EXPORTED_APP" "$APP_SUBMISSION_ZIP"
echo "==> Submitting exported application for notarization"
notarize_and_staple app "$APP_SUBMISSION_ZIP" "$EXPORTED_APP" "exported application"

DMG_STAGE="$WORK_DIR/dmg-stage"
mkdir -p "$DMG_STAGE"
cp -R "$EXPORTED_APP" "$DMG_STAGE/IdeaForge.app"
ln -s /Applications "$DMG_STAGE/Applications"
TEMP_DMG="$WORK_DIR/IdeaForge-$RELEASE_VERSION.dmg"
echo "==> Creating and signing direct-download DMG"
hdiutil create \
  -volname "IdeaForge" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -ov "$TEMP_DMG"
codesign --force --timestamp --sign "$EXPECTED_IDENTITY" "$TEMP_DMG"
codesign --verify --strict --verbose=2 "$TEMP_DMG"
DMG_SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$TEMP_DMG" 2>&1)"
grep -Fq "TeamIdentifier=$EXPECTED_TEAM" <<< "$DMG_SIGNATURE_DETAILS" \
  || fail "DMG signature team mismatch"
grep -Eq '^Timestamp=.+$' <<< "$DMG_SIGNATURE_DETAILS" \
  || fail "DMG secure timestamp is missing"

echo "==> Submitting signed DMG for notarization"
notarize_and_staple dmg "$TEMP_DMG" "$TEMP_DMG" "DMG"
mv "$TEMP_DMG" "$FINAL_DMG"

echo "==> Creating update ZIP and checksums"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$EXPORTED_APP" "$FINAL_ZIP"
(
  cd "$RELEASE_ROOT"
  shasum -a 256 "$(basename "$FINAL_DMG")" "$(basename "$FINAL_ZIP")" > "$(basename "$FINAL_SUMS")"
)
write_manifest "$FINAL_MANIFEST" "notarized_release_ready" "notarize"

echo "Readiness: notarized_release_ready"
echo "DMG: $FINAL_DMG"
echo "Update ZIP: $FINAL_ZIP"
echo "Checksums: $FINAL_SUMS"
echo "Manifest: $FINAL_MANIFEST"
