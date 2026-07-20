#!/usr/bin/env python3
"""Detect owner contact leakage in reachable Git commit metadata."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
OWNER_NAME = "Rafał Sikora"
ALLOWED_OWNER_EMAIL_SUFFIXES = ("@users.noreply.github.com", "@ideaforge.invalid")


def arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--new-only", action="store_true")
    mode.add_argument("--strict", action="store_true")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--baseline",
        type=Path,
        default=ROOT / "Config/public-history-legacy.json",
    )
    return parser.parse_args(argv)


def legacy_commits(path: Path) -> set[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1:
        raise ValueError("unsupported legacy metadata baseline schema")
    commits = payload.get("legacy_commits")
    if not isinstance(commits, list) or not all(
        isinstance(item, str) and len(item) == 40 for item in commits
    ):
        raise ValueError("legacy_commits must contain full Git object IDs")
    return set(commits)


def synthetic_pull_request_merge_commit(root: Path) -> set[str]:
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        return set()
    github_ref = os.environ.get("GITHUB_REF", "")
    if not (github_ref.startswith("refs/pull/") and github_ref.endswith("/merge")):
        return set()
    github_sha = os.environ.get("GITHUB_SHA", "")
    head = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if github_sha != head:
        return set()
    parent_record = subprocess.run(
        ["git", "-C", str(root), "rev-list", "--parents", "-n", "1", head],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    return {head} if len(parent_record) == 3 else set()


def exposed_commits(root: Path) -> set[str]:
    result = subprocess.run(
        [
            "git", "-C", str(root), "log", "HEAD",
            "--format=%H%x00%an%x00%ae%x00%cn%x00%ce",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    exposed: set[str] = set()
    for line in result.stdout.splitlines():
        fields = line.split("\0")
        if len(fields) != 5:
            raise ValueError("unexpected Git log record")
        commit, author_name, author_email, committer_name, committer_email = fields
        identities = ((author_name, author_email), (committer_name, committer_email))
        if any(
            name == OWNER_NAME
            and not email.casefold().endswith(ALLOWED_OWNER_EMAIL_SUFFIXES)
            for name, email in identities
        ):
            exposed.add(commit)
    return exposed


def main(argv: list[str] | None = None) -> int:
    args = arguments(sys.argv[1:] if argv is None else argv)
    try:
        root = args.root.resolve(strict=True)
        baseline = legacy_commits(args.baseline.resolve(strict=True))
        exposed = exposed_commits(root) - synthetic_pull_request_merge_commit(root)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"audit_public_git_metadata.py: {error}", file=sys.stderr)
        return 2

    unexpected = exposed - baseline
    stale = baseline - exposed
    if stale and args.new_only:
        print("Legacy metadata baseline contains commits that are no longer exposed; remove them.", file=sys.stderr)
        return 2
    for commit in sorted(exposed):
        classification = "legacy" if commit in baseline else "new"
        print(f"{classification} owner-email metadata exposure: {commit}", file=sys.stderr)
    if unexpected:
        print("New owner-email metadata exposure is forbidden.", file=sys.stderr)
        return 1
    if args.strict and exposed:
        print("Strict public-history audit failed: legacy metadata still requires remediation.", file=sys.stderr)
        return 1
    print(f"Public Git metadata audit passed: {len(exposed)} acknowledged legacy exposure(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
