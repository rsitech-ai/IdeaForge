#!/usr/bin/env python3
"""Regression tests for public Git metadata auditing in hosted CI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
AUDITOR = SCRIPT_DIR / "audit_public_git_metadata.py"


class PublicGitMetadataAuditTests(unittest.TestCase):
    def git(self, root: Path, *arguments: str, identity: str = "neutral") -> str:
        if identity == "owner":
            name, email = "Rafal Sikora", "owner@example.invalid"
        else:
            name, email = "IdeaForge Source Release", "source-release@ideaforge.invalid"
        result = subprocess.run(
            [
                "git",
                "-c", f"user.name={name}",
                "-c", f"user.email={email}",
                "-C", str(root),
                *arguments,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def create_pull_request_merge(self, root: Path) -> tuple[str, Path]:
        self.git(root, "init", "-b", "main")
        (root / "fixture.txt").write_text("base\n", encoding="utf-8")
        self.git(root, "add", "fixture.txt")
        self.git(root, "commit", "-m", "legacy base", identity="owner")
        legacy_commit = self.git(root, "rev-parse", "HEAD")

        self.git(root, "checkout", "-b", "feature")
        (root / "feature.txt").write_text("feature\n", encoding="utf-8")
        self.git(root, "add", "feature.txt")
        self.git(root, "commit", "-m", "feature")

        self.git(root, "checkout", "main")
        (root / "main.txt").write_text("main\n", encoding="utf-8")
        self.git(root, "add", "main.txt")
        self.git(root, "commit", "-m", "main")
        self.git(root, "merge", "--no-ff", "feature", "-m", "synthetic pull request merge", identity="owner")
        merge_commit = self.git(root, "rev-parse", "HEAD")

        baseline = root / "legacy.json"
        baseline.write_text(
            json.dumps({"schema_version": 1, "legacy_commits": [legacy_commit]}),
            encoding="utf-8",
        )
        return merge_commit, baseline

    def run_audit(self, root: Path, baseline: Path, *, event: str, sha: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "GITHUB_EVENT_NAME": event,
                "GITHUB_REF": "refs/pull/4/merge" if event == "pull_request" else "refs/heads/main",
                "GITHUB_SHA": sha,
            }
        )
        return subprocess.run(
            [
                sys.executable,
                str(AUDITOR),
                "--new-only",
                "--root", str(root),
                "--baseline", str(baseline),
            ],
            env=environment,
            capture_output=True,
            text=True,
        )

    def test_ignores_only_hosted_pull_request_synthetic_merge_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            merge_commit, baseline = self.create_pull_request_merge(root)

            result = self.run_audit(root, baseline, event="pull_request", sha=merge_commit)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("1 acknowledged legacy exposure(s)", result.stdout)
            self.assertNotIn(merge_commit, result.stderr)

    def test_does_not_ignore_same_commit_for_push_event(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            merge_commit, baseline = self.create_pull_request_merge(root)

            result = self.run_audit(root, baseline, event="push", sha=merge_commit)

            self.assertEqual(result.returncode, 1)
            self.assertIn(f"new owner-email metadata exposure: {merge_commit}", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
