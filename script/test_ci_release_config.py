#!/usr/bin/env python3
"""Repository contract tests for public CI and protected Mac releases."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
CI = ROOT / ".github/workflows/ci.yml"
RELEASE = ROOT / ".github/workflows/release-macos.yml"
DEPENDABOT = ROOT / ".github/dependabot.yml"
APPCAST = ROOT / "updates/appcast.xml"
SBOM = ROOT / "script/generate_sbom.py"
METADATA_AUDIT = ROOT / "script/audit_public_git_metadata.py"


class CIReleaseConfigurationTests(unittest.TestCase):
    def test_ci_is_read_only_pinned_and_runs_repository_gates(self) -> None:
        text = CI.read_text(encoding="utf-8")
        self.assertIn("permissions:\n  contents: read", text)
        self.assertIn("pull_request:", text)
        self.assertIn("push:", text)
        self.assertIn("fetch-depth: 0", text)
        self.assertIn("audit_public_git_metadata.py --new-only", text)
        self.assertIn("runs-on: macos-26", text)
        self.assertIn("/Applications/Xcode_26.6.app", text)
        self.assertIn("9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0", text)
        self.assertIn("043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", text)
        self.assertIn("090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef", text)
        for command in (
            "swift test",
            "test_audit_public_source.py",
            "test_audit_public_git_metadata.py",
            "test_create_public_source_snapshot.py",
            "test_release_macos.sh",
            "test_verify_production.sh",
            "mock_backend.py --self-test",
            "audit_public_source.py",
            "CODE_SIGNING_ALLOWED=NO",
            "test -f IdeaForge.xcodeproj/project.pbxproj",
        ):
            self.assertIn(command, text)

    def test_workflows_fail_closed_on_clean_tree_checks_and_cover_all_app_targets(self) -> None:
        ci = CI.read_text(encoding="utf-8")
        release = RELEASE.read_text(encoding="utf-8")

        for workflow in (ci, release):
            self.assertNotIn('test -z "$(git status --porcelain --untracked-files=all)"', workflow)
            self.assertIn('worktree_status="$(git status --porcelain --untracked-files=all)"', workflow)
            self.assertIn('test -z "$worktree_status"', workflow)
            self.assertIn("python3 script/test_sparkle_configuration.py", workflow)

        for scheme in ("IdeaForgeMac", "IdeaForgeiOS", "IdeaForgeWatch"):
            self.assertIn(f"-scheme {scheme}", ci)
        self.assertGreaterEqual(ci.count("SWIFT_TREAT_WARNINGS_AS_ERRORS=YES"), 3)

    def test_release_uses_protected_environment_and_short_lived_secrets(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertIn("environment:\n      name: release", text)
        self.assertIn("contents: write", text)
        self.assertIn("attestations: write", text)
        self.assertIn("id-token: write", text)
        self.assertIn("runs-on: macos-26", text)
        self.assertIn("/Applications/Xcode_26.6.app", text)
        self.assertIn("9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0", text)
        self.assertIn("043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", text)
        self.assertIn("a1948c3f048ba23858d222213b7c278aabede763", text)
        for required in (
            "DEVELOPER_ID_P12_BASE64",
            "DEVELOPER_ID_P12_PASSWORD",
            "SIGNING_KEYCHAIN_PASSWORD",
            "NOTARY_API_KEY_P8_BASE64",
            "NOTARY_API_KEY_ID",
            "NOTARY_API_ISSUER_ID",
            "SPARKLE_ED25519_PRIVATE_KEY",
        ):
            self.assertIn(f"secrets.{required}", text)
        for boundary in (
            "security create-keychain",
            "security set-key-partition-list",
            "notarytool store-credentials",
            "release_macos.sh --notarize",
            "generate_keys\" --account ideaforge-release",
            "generate_appcast\" \\",
            "--account ideaforge-release",
            "generate_sbom.py",
            "gh release create",
            "gh release edit",
            "updates/appcast.xml",
            "security delete-keychain",
        ):
            self.assertIn(boundary, text)
        self.assertNotIn("APPLE_APP_SPECIFIC_PASSWORD", text)
        self.assertNotIn("pull_request_target", text)
        self.assertIn("audit_public_git_metadata.py --strict", text)
        self.assertIn('--draft \\', text)
        self.assertIn('--notes-file "$release_notes"', text)
        self.assertNotIn("--generate-notes", text)
        self.assertLess(text.index("--draft \\"), text.index("contents/updates/appcast.xml"))

    def test_public_history_gate_requires_clean_canonical_history(self) -> None:
        new_only = subprocess.run(
            [sys.executable, str(METADATA_AUDIT), "--new-only"],
            capture_output=True,
            text=True,
        )
        strict = subprocess.run(
            [sys.executable, str(METADATA_AUDIT), "--strict"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(new_only.returncode, 0, new_only.stderr)
        self.assertEqual(strict.returncode, 0, strict.stderr)
        self.assertIn("0 acknowledged legacy exposure(s)", new_only.stdout)
        self.assertIn("0 acknowledged legacy exposure(s)", strict.stdout)

    def test_dependabot_tracks_pinned_github_actions(self) -> None:
        text = DEPENDABOT.read_text(encoding="utf-8")
        self.assertIn('package-ecosystem: "github-actions"', text)
        self.assertIn('directory: "/"', text)
        self.assertIn("interval: weekly", text)

    def test_placeholder_appcast_is_valid_and_has_no_unsigned_update(self) -> None:
        tree = ET.parse(APPCAST)
        channel = tree.getroot().find("channel")
        self.assertIsNotNone(channel)
        self.assertEqual(channel.findtext("title"), "IdeaForge updates")
        self.assertEqual(channel.findall("item"), [])

    def test_sbom_generator_is_deterministic_and_matches_release_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            environment = {"SOURCE_DATE_EPOCH": "1784156400", "IDEAFORGE_SOURCE_COMMIT": "a" * 40}
            command = [sys.executable, str(SBOM), "--root", str(ROOT), "--version", "0.1.0"]
            first_run = subprocess.run(command + ["--output", str(first)], env=environment, capture_output=True, text=True)
            second_run = subprocess.run(command + ["--output", str(second)], env=environment, capture_output=True, text=True)
            self.assertEqual(first_run.returncode, 0, first_run.stderr)
            self.assertEqual(second_run.returncode, 0, second_run.stderr)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            payload = json.loads(first.read_text(encoding="utf-8"))
            packages = {item["name"]: item for item in payload["packages"]}
            self.assertEqual(packages["IdeaForge"]["versionInfo"], "0.1.0")
            self.assertEqual(packages["IdeaForge"]["licenseConcluded"], "Apache-2.0")
            self.assertEqual(packages["Sparkle"]["versionInfo"], "2.9.4")
            self.assertEqual(packages["Sparkle"]["licenseConcluded"], "MIT")
            self.assertEqual(
                payload["documentNamespace"],
                "https://github.com/rsitech-ai/IdeaForge/releases/download/v0.1.0/"
                + "IdeaForge-0.1.0-sbom-"
                + "a" * 40
                + ".spdx.json",
            )
            self.assertEqual(
                packages["IdeaForge"]["downloadLocation"],
                "https://github.com/rsitech-ai/IdeaForge/tree/v0.1.0",
            )
            self.assertEqual(
                packages["IdeaForge"]["externalRefs"][0]["referenceLocator"],
                "git+https://github.com/rsitech-ai/IdeaForge@" + "a" * 40,
            )
            self.assertEqual(
                packages["Sparkle"]["externalRefs"][1]["referenceLocator"],
                "git+https://github.com/sparkle-project/Sparkle@b6496a74a087257ef5e6da1c5b29a447a60f5bd7",
            )
            self.assertEqual(
                packages["Sparkle"]["checksums"][0]["checksumValue"],
                "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0",
            )
            self.assertIn("Sparkle@2.9.4", packages["Sparkle"]["externalRefs"][0]["referenceLocator"])

    def test_sbom_generator_rejects_version_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "sbom.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SBOM),
                    "--root",
                    str(ROOT),
                    "--version",
                    "9.9.9",
                    "--output",
                    str(output),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match project.yml", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
