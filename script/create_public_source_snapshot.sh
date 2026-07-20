#!/usr/bin/env bash
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_SOURCE="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SOURCE_ROOT="$DEFAULT_SOURCE"
DESTINATION=""

usage() {
  cat >&2 <<'EOF'
Usage: create_public_source_snapshot.sh --destination PATH [--source PATH]

Creates an audited standalone public-source repository from committed HEAD.
The destination must not already exist.
EOF
}

fail() {
  echo "create_public_source_snapshot.sh: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || fail "--source requires a path"
      SOURCE_ROOT="$2"
      shift 2
      ;;
    --destination)
      [[ $# -ge 2 ]] || fail "--destination requires a path"
      DESTINATION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$DESTINATION" ]] || {
  usage
  fail "--destination is required"
}
[[ -d "$SOURCE_ROOT" ]] || fail "source is not a directory: $SOURCE_ROOT"
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"

SOURCE_TOPLEVEL="$(git -C "$SOURCE_ROOT" rev-parse --show-toplevel 2>/dev/null)" || \
  fail "source is not a Git working tree"
[[ "$SOURCE_TOPLEVEL" == "$SOURCE_ROOT" ]] || fail "--source must be the Git repository root"
git -C "$SOURCE_ROOT" rev-parse --verify HEAD^{commit} >/dev/null 2>&1 || \
  fail "source has no committed HEAD"

git_status_output=""
if ! git_status_output="$(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=all)"; then
  fail "could not inspect Git status"
fi
if [[ -n "$git_status_output" ]]; then
  fail "a clean committed source tree is required"
fi

DESTINATION_PARENT="$(dirname "$DESTINATION")"
DESTINATION_NAME="$(basename "$DESTINATION")"
[[ -d "$DESTINATION_PARENT" ]] || fail "destination parent does not exist: $DESTINATION_PARENT"
DESTINATION_PARENT="$(cd "$DESTINATION_PARENT" && pwd -P)"
DESTINATION="$DESTINATION_PARENT/$DESTINATION_NAME"
[[ ! -e "$DESTINATION" ]] || fail "destination already exists: $DESTINATION"

TREE_LISTING="$(mktemp "$DESTINATION_PARENT/.ideaforge-public-tree.XXXXXX")"
ARCHIVE_FILE=""
STAGING=""
cleanup() {
  if [[ -n "${TREE_LISTING:-}" && -f "$TREE_LISTING" ]]; then
    rm -f "$TREE_LISTING"
  fi
  if [[ -n "${STAGING:-}" && -d "$STAGING" ]]; then
    rm -rf "$STAGING"
  fi
  if [[ -n "${ARCHIVE_FILE:-}" && -f "$ARCHIVE_FILE" ]]; then
    rm -f "$ARCHIVE_FILE"
  fi
}
trap cleanup EXIT INT TERM

if ! git -C "$SOURCE_ROOT" ls-tree -r -z --name-only HEAD > "$TREE_LISTING"; then
  fail "could not enumerate committed paths"
fi

credential_path=""
while IFS= read -r -d '' committed_path; do
  lower_path="$(printf '%s' "$committed_path" | tr '[:upper:]' '[:lower:]')"
  case "$lower_path" in
    .git|.git/*|*/.git|*/.git/*)
      fail "committed archive contains forbidden Git metadata: $committed_path"
      ;;
    *.p8|*.p12|*.pem|*.key|*.cer|*.mobileprovision|*.provisionprofile|\
    .env|*/.env|.env.*|*/.env.*|\
    notary-credentials|*/notary-credentials|notary-credentials.*|*/notary-credentials.*|\
    release-credentials|*/release-credentials|release-credentials.*|*/release-credentials.*)
      credential_path="$committed_path"
      break
      ;;
  esac
done < "$TREE_LISTING"
[[ -z "$credential_path" ]] || fail "committed archive contains a release credential path: $credential_path"

STAGING="$(mktemp -d "$DESTINATION_PARENT/.ideaforge-public-source.XXXXXX")"

archive_paths=(
  "."
  ":(exclude).build" ":(exclude).build/**"
  ":(exclude).codex" ":(exclude).codex/**"
  ":(exclude).idea" ":(exclude).idea/**"
  ":(exclude).superpowers" ":(exclude).superpowers/**"
  ":(exclude).vscode" ":(exclude).vscode/**"
  ":(exclude)AppStore" ":(exclude)AppStore/**"
  ":(exclude)build" ":(exclude)build/**"
  ":(exclude)dist" ":(exclude)dist/**"
  ":(exclude,glob)DerivedData*" ":(exclude,glob)DerivedData*/**"
  ":(exclude,glob)**/xcuserdata/**"
  ":(exclude,glob)**/*.xcuserstate"
  ":(exclude,glob)**/*.xcresult/**"
  ":(exclude,glob)**/*.swp"
  ":(exclude,glob)**/.DS_Store"
  ":(exclude,glob)**/__pycache__/**"
  ":(exclude,glob)**/*.pyc"
  ":(exclude)PUBLIC_SOURCE_AUDIT.json"
  ":(exclude)PUBLIC_SOURCE_AUDIT.md"
  ":(exclude)docs/app-store-release-checklist.md"
  ":(exclude)docs/audits" ":(exclude)docs/audits/**"
  ":(exclude)docs/e2e-ship-audit-2026-07-10.md"
  ":(exclude)docs/evidence" ":(exclude)docs/evidence/**"
  ":(exclude,glob)docs/iphone-*.md"
  ":(exclude)docs/original-plan-gap-map.md"
  ":(exclude)docs/production-plan.md"
  ":(exclude)docs/production-readiness.md"
  ":(exclude)docs/superpowers" ":(exclude)docs/superpowers/**"
  ":(exclude,glob)docs/swiftui-polish-audit-*.md"
)

ARCHIVE_FILE="$(mktemp "$DESTINATION_PARENT/.ideaforge-public-archive.XXXXXX")"
git -C "$SOURCE_ROOT" archive --format=tar --output="$ARCHIVE_FILE" HEAD -- "${archive_paths[@]}"
tar -xf "$ARCHIVE_FILE" -C "$STAGING"
rm -f "$ARCHIVE_FILE"
ARCHIVE_FILE=""

[[ ! -e "$STAGING/.git" ]] || fail "archive unexpectedly contains Git metadata"
[[ -f "$STAGING/script/audit_public_source.py" ]] || fail "snapshot is missing its audit tool"

AUDIT_JSON="$STAGING/.public-source-audit.json"
AUDIT_MARKDOWN="$STAGING/.public-source-audit.md"
python3 "$STAGING/script/audit_public_source.py" "$STAGING" \
  --profile public \
  --json-out "$AUDIT_JSON" \
  --markdown-out "$AUDIT_MARKDOWN"
rm -f "$AUDIT_JSON" "$AUDIT_MARKDOWN"

# Auditing must complete before this point. The public repository intentionally
# uses a new non-personal identity and contains none of the source Git objects.
git -c init.templateDir= -C "$STAGING" init -b main >/dev/null
git -C "$STAGING" config user.name "IdeaForge Source Release"
git -C "$STAGING" config user.email "source-release@ideaforge.invalid"
git -C "$STAGING" add -A
git -c commit.gpgsign=false -C "$STAGING" commit --no-gpg-sign -m "Initial public source release" >/dev/null

PUBLIC_COMMIT="$(git -C "$STAGING" rev-parse HEAD)"
mv "$STAGING" "$DESTINATION"
STAGING=""
trap - EXIT INT TERM

echo "Public source snapshot: PASS" >&2
echo "Destination: $DESTINATION" >&2
echo "Branch: main" >&2
echo "Commit: $PUBLIC_COMMIT" >&2
