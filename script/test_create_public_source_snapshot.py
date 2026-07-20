#!/usr/bin/env python3
"""Focused integration tests for the standalone public snapshot builder."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
SNAPSHOT_SCRIPT = SCRIPT_DIR / "create_public_source_snapshot.sh"
AUDITOR = SCRIPT_DIR / "audit_public_source.py"


class PublicSourceSnapshotTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory()
        self.temporary_root = Path(self._temporary_directory.name)
        self.source = self.temporary_root / "private-source"
        self.destination = self.temporary_root / "public-source"

    def tearDown(self) -> None:
        self._temporary_directory.cleanup()

    def git(self, *arguments: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=cwd or self.source,
            capture_output=True,
            text=True,
            check=check,
        )

    def write(self, relative_path: str, content: str | bytes) -> Path:
        destination = self.source / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            destination.write_bytes(content)
        else:
            destination.write_text(content, encoding="utf-8")
        return destination

    def create_fixture_repository(self) -> None:
        self.source.mkdir()
        self.git("init", "-b", "private-main")
        self.git("config", "user.name", "Private Fixture")
        self.git("config", "user.email", "private-fixture@example.test")
        self.write("README.md", "# Fixture\n")
        self.write("PUBLIC_SOURCE_AUDIT.json", '{"status":"stale"}\n')
        self.write("PUBLIC_SOURCE_AUDIT.md", "# Stale generated audit\n")
        self.write("Sources/App.swift", "struct App {}\n")
        image = b"build-critical-icon"
        self.write("Sources/IdeaForgeAssets/icon.png", image)
        digest = hashlib.sha256(image).hexdigest()
        self.write(
            "ASSET_PROVENANCE.md",
            "# Asset provenance\n\n"
            "| Path | SHA-256 | Origin | License |\n"
            "| --- | --- | --- | --- |\n"
            f"| `Sources/IdeaForgeAssets/icon.png` | `{digest}` | Maintainer-created | Apache-2.0 |\n",
        )
        self.write("script/audit_public_source.py", AUDITOR.read_bytes())

        excluded_files = {
            ".codex/environments/environment.toml": "agent environment\n",
            ".superpowers/sdd/task-report.md": "agent scratch\n",
            ".vscode/settings.json": "{}\n",
            "AppStore/review-notes.md": "private review evidence\n",
            "DerivedData-ios/build.txt": "derived output\n",
            "build/output.txt": "build output\n",
            "dist/release.txt": "distribution output\n",
            "docs/audits/private.md": "private audit\n",
            "docs/evidence/private.png": "historical screenshot\n",
            "docs/superpowers/plan.md": "private implementation plan\n",
        }
        for path, content in excluded_files.items():
            self.write(path, content)

        self.git("add", "-A", "--force")
        self.git("commit", "-m", "private fixture history")

    def run_snapshot(self, *, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                str(SNAPSHOT_SCRIPT),
                "--source",
                str(self.source),
                "--destination",
                str(self.destination),
            ],
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )

    def test_creates_audited_single_commit_main_snapshot(self) -> None:
        self.create_fixture_repository()
        private_commit = self.git("rev-parse", "HEAD").stdout.strip()

        result = self.run_snapshot()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.destination / ".git").is_dir())
        self.assertTrue((self.destination / "Sources/IdeaForgeAssets/icon.png").is_file())
        self.assertEqual(self.git("branch", "--show-current", cwd=self.destination).stdout.strip(), "main")
        self.assertEqual(self.git("rev-list", "--count", "HEAD", cwd=self.destination).stdout.strip(), "1")
        self.assertEqual(
            self.git("log", "-1", "--format=%an%x00%ae", cwd=self.destination).stdout.strip(),
            "Rafal Sikora\x0024563931+s1korrrr@users.noreply.github.com",
        )
        self.assertIn(
            "Signed-off-by: Rafal Sikora <24563931+s1korrrr@users.noreply.github.com>",
            self.git("log", "-1", "--format=%B", cwd=self.destination).stdout,
        )
        old_object = self.git("cat-file", "-e", f"{private_commit}^{{commit}}", cwd=self.destination, check=False)
        self.assertNotEqual(old_object.returncode, 0)

        excluded = (
            ".codex",
            ".superpowers",
            ".vscode",
            "AppStore",
            "DerivedData-ios",
            "build",
            "dist",
            "docs/audits",
            "docs/evidence",
            "docs/superpowers",
        )
        for path in excluded:
            self.assertFalse((self.destination / path).exists(), path)

        self.assertFalse((self.destination / "PUBLIC_SOURCE_AUDIT.json").exists())
        self.assertFalse((self.destination / "PUBLIC_SOURCE_AUDIT.md").exists())
        tracked_paths = set(
            self.git("ls-tree", "-r", "--name-only", "HEAD", cwd=self.destination).stdout.splitlines()
        )
        self.assertNotIn("PUBLIC_SOURCE_AUDIT.json", tracked_paths)
        self.assertNotIn("PUBLIC_SOURCE_AUDIT.md", tracked_paths)
        self.assertIn("Public-source audit: PASS", result.stderr)

    def test_rejects_dirty_source(self) -> None:
        self.create_fixture_repository()
        self.write("README.md", "# Dirty fixture\n")

        result = self.run_snapshot()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean committed source tree", result.stderr)
        self.assertFalse(self.destination.exists())

    def test_fails_closed_when_git_status_fails(self) -> None:
        self.create_fixture_repository()
        fake_bin = self.temporary_root / "fake-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        fake_git.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "-C" ] && [ "$3" = "status" ]; then\n'
            '  echo "simulated git status failure" >&2\n'
            "  exit 73\n"
            "fi\n"
            f"exec {shlex.quote(real_git)} \"$@\"\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"

        result = self.run_snapshot(environment=environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not inspect Git status", result.stderr)
        self.assertFalse(self.destination.exists())

    def test_fails_closed_when_git_ls_tree_fails(self) -> None:
        self.create_fixture_repository()
        fake_bin = self.temporary_root / "fake-ls-tree-bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        fake_git.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "-C" ] && [ "$3" = "ls-tree" ]; then\n'
            '  echo "simulated git ls-tree failure" >&2\n'
            "  exit 74\n"
            "fi\n"
            f"exec {shlex.quote(real_git)} \"$@\"\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"

        result = self.run_snapshot(environment=environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not enumerate committed paths", result.stderr)
        self.assertFalse(self.destination.exists())

    def test_rejects_release_credential_before_extracting_snapshot(self) -> None:
        self.create_fixture_repository()
        self.write("Config/AuthKey_PRIVATE.p8", b"opaque-key-bytes")
        self.git("add", "-A", "--force")
        self.git("commit", "-m", "add forbidden credential")

        result = self.run_snapshot()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release credential", result.stderr)
        self.assertFalse(self.destination.exists())

    def test_audits_before_initializing_public_git_history(self) -> None:
        self.create_fixture_repository()
        private_path = "/Us" + "ers/name/private.txt"
        self.write("Sources/Leak.txt", private_path)
        self.git("add", "-A")
        self.git("commit", "-m", "add privacy leak")
        fake_bin = self.temporary_root / "fake-init-bin"
        fake_bin.mkdir()
        init_log = self.temporary_root / "git-init.log"
        fake_git = fake_bin / "git"
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        fake_git.write_text(
            "#!/bin/sh\n"
            'for argument in "$@"; do\n'
            '  if [ "$argument" = "init" ]; then\n'
            f"    printf 'init\\n' >> {shlex.quote(str(init_log))}\n"
            "    break\n"
            "  fi\n"
            "done\n"
            f"exec {shlex.quote(real_git)} \"$@\"\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"

        result = self.run_snapshot(environment=environment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public-source audit", result.stderr.lower())
        self.assertFalse(init_log.exists(), "git init ran before the public-source audit passed")
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
