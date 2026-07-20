#!/usr/bin/env python3
"""Behavior tests for the public-source privacy and provenance auditor."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
AUDITOR = SCRIPT_DIR / "audit_public_source.py"
SPARKLE_LICENSE = SCRIPT_DIR.parent / "ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt"


class PublicSourceAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary_directory.name)
        self._audit_run_index = 0

    def tearDown(self) -> None:
        self._temporary_directory.cleanup()

    def write(self, relative_path: str, content: str | bytes) -> Path:
        destination = self.root / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            destination.write_bytes(content)
        else:
            destination.write_text(content, encoding="utf-8")
        return destination

    def add_provenance(self, relative_path: str, content: bytes) -> None:
        digest = hashlib.sha256(content).hexdigest()
        manifest = (
            "# Asset provenance\n\n"
            "| Path | SHA-256 | Origin | License |\n"
            "| --- | --- | --- | --- |\n"
            f"| `{relative_path}` | `{digest}` | Maintainer-created | Apache-2.0 |\n"
        )
        self.write("ASSET_PROVENANCE.md", manifest)

    def run_audit(
        self,
        *,
        profile: str = "public",
        max_file_bytes: int = 1024 * 1024,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        self._audit_run_index += 1
        json_report = self.root / f"audit-report-{self._audit_run_index}.json"
        markdown_report = self.root / f"audit-report-{self._audit_run_index}.md"
        command = [
            sys.executable,
            str(AUDITOR),
            str(self.root),
            "--profile",
            profile,
            "--max-file-bytes",
            str(max_file_bytes),
            "--json-out",
            str(json_report),
            "--markdown-out",
            str(markdown_report),
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        report = json.loads(json_report.read_text(encoding="utf-8")) if json_report.exists() else {}
        return result, report

    def assert_single_finding(self, report: dict[str, object], category: str) -> None:
        findings = report.get("findings", [])
        self.assertEqual(len(findings), 1, findings)
        self.assertEqual(findings[0]["category"], category)

    def test_clean_tree_writes_machine_and_human_reports(self) -> None:
        image = b"deterministic-image"
        self.write("Sources/IdeaForgeAssets/icon.png", image)
        self.add_provenance("Sources/IdeaForgeAssets/icon.png", image)
        self.write("Sources/IdeaForgeCore/Example.swift", "struct Example {}\n")

        result, report = self.run_audit()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["finding_count"], 0)
        self.assertTrue((self.root / "audit-report-1.md").is_file())

    def test_rejects_concrete_user_home_path(self) -> None:
        private_path = "/Us" + "ers/name/IdeaForge/private.txt"
        self.write("Sources/leak.txt", private_path)

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "user_home_path")

    def test_rejects_gmail_address(self) -> None:
        address = "private.person@" + "gmail.com"
        self.write("Sources/leak.txt", address)

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "gmail_address")

    def test_allows_only_hash_verified_verbatim_third_party_license(self) -> None:
        license_bytes = SPARKLE_LICENSE.read_bytes()
        destination = "ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt"
        self.write(destination, license_bytes)
        allowed_result, allowed_report = self.run_audit()
        self.assertEqual(allowed_result.returncode, 0, allowed_result.stderr)
        self.assertEqual(allowed_report["finding_count"], 0)

        self.write(destination, license_bytes + b"\nlocal edit\n")
        rejected_result, rejected_report = self.run_audit()
        self.assertNotEqual(rejected_result.returncode, 0)
        categories = {finding["category"] for finding in rejected_report["findings"]}
        self.assertIn("gmail_address", categories)

    def test_rejects_physical_udid(self) -> None:
        udid = "00008120" + "-001210A13C92201E"
        self.write("Sources/leak.txt", f"IDEAFORGE_IOS_DEVICE_ID={udid}\n")

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "physical_udid")

    def test_rejects_private_key_marker(self) -> None:
        marker = "-----BEGIN " + "PRIVATE KEY-----"
        self.write("Sources/leak.pem.txt", marker)

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "private_key_marker")

    def test_nul_byte_does_not_hide_ascii_denylist_markers(self) -> None:
        samples = (
            ("user_home_path", ("/Us" + "ers/name/private.txt").encode()),
            ("gmail_address", ("private.person@" + "gmail.com").encode()),
            ("physical_udid", ("00008120" + "-001210A13C92201E").encode()),
            ("private_key_marker", ("-----BEGIN " + "PRIVATE KEY-----").encode()),
        )
        for index, (category, marker) in enumerate(samples):
            with self.subTest(category=category):
                self.write(f"Sources/nul-{index}.bin", b"prefix\0" + marker + b"\xffsuffix")
                result, report = self.run_audit()
                self.assertNotEqual(result.returncode, 0)
                self.assert_single_finding(report, category)
                (self.root / f"Sources/nul-{index}.bin").unlink()

    def test_allows_clean_nul_bearing_binary_and_provenanced_image(self) -> None:
        self.write("Sources/model.bin", b"\x00\xff\x10clean-binary\x00")
        image = b"\x89PNG\r\n\x1a\n\x00clean-image"
        self.write("Sources/IdeaForgeAssets/icon.png", image)
        self.add_provenance("Sources/IdeaForgeAssets/icon.png", image)

        result, report = self.run_audit()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["finding_count"], 0)

    def test_rejects_symlink_in_audited_tree(self) -> None:
        link = self.root / "Sources/private-link"
        link.parent.mkdir(parents=True)
        os.symlink("/Us" + "ers/name/private/source", link)

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "symlink")

    def test_rejects_report_output_symlinks_without_writing_through_them(self) -> None:
        for output_kind in ("json", "markdown"):
            with self.subTest(output_kind=output_kind):
                external = self.root.parent / f"external-{output_kind}-{self.root.name}"
                sentinel = f"unchanged-{output_kind}\n"
                external.write_text(sentinel, encoding="utf-8")
                json_report = self.root / f"symlink-report-{output_kind}.json"
                markdown_report = self.root / f"symlink-report-{output_kind}.md"
                linked_output = json_report if output_kind == "json" else markdown_report
                os.symlink(external, linked_output)
                result = subprocess.run(
                    [
                        sys.executable,
                        str(AUDITOR),
                        str(self.root),
                        "--json-out",
                        str(json_report),
                        "--markdown-out",
                        str(markdown_report),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("report output", result.stderr)
                self.assertEqual(external.read_text(encoding="utf-8"), sentinel)
                other_output = markdown_report if output_kind == "json" else json_report
                self.assertFalse(other_output.exists(), "validation must happen before either report is opened")
                linked_output.unlink()
                if json_report.exists():
                    json_report.unlink()
                if markdown_report.exists():
                    markdown_report.unlink()
                external.unlink()

    def test_rejects_existing_report_output_before_opening_other_report(self) -> None:
        json_report = self.root / "existing-report.json"
        markdown_report = self.root / "other-report.md"
        sentinel = "existing-report-must-not-change\n"
        json_report.write_text(sentinel, encoding="utf-8")

        result = subprocess.run(
            [
                sys.executable,
                str(AUDITOR),
                str(self.root),
                "--json-out",
                str(json_report),
                "--markdown-out",
                str(markdown_report),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("report output must be absent", result.stderr)
        self.assertEqual(json_report.read_text(encoding="utf-8"), sentinel)
        self.assertFalse(markdown_report.exists())

    def test_rejects_report_output_outside_audit_root(self) -> None:
        outside_report = self.root.parent / f"outside-{self.root.name}.json"
        markdown_report = self.root / "contained-report.md"

        result = subprocess.run(
            [
                sys.executable,
                str(AUDITOR),
                str(self.root),
                "--json-out",
                str(outside_report),
                "--markdown-out",
                str(markdown_report),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contained by the audit root", result.stderr)
        self.assertFalse(outside_report.exists())
        self.assertFalse(markdown_report.exists())

    def test_rejects_release_credential_file_type(self) -> None:
        self.write("Config/AuthKey_PRIVATE.p8", b"opaque-key-bytes")

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "release_credential_file")

    def test_rejects_unprovenanced_image(self) -> None:
        self.write("Sources/IdeaForgeAssets/unlisted.png", b"image")

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "unprovenanced_image")

    def test_rejects_provenance_hash_mismatch(self) -> None:
        image = b"changed-image"
        self.write("Sources/IdeaForgeAssets/icon.png", image)
        self.add_provenance("Sources/IdeaForgeAssets/icon.png", b"original-image")

        result, report = self.run_audit()

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "image_hash_mismatch")

    def test_rejects_oversized_non_allowlisted_blob(self) -> None:
        self.write("Sources/blob.bin", b"x" * 65)

        result, report = self.run_audit(max_file_bytes=64)

        self.assertNotEqual(result.returncode, 0)
        self.assert_single_finding(report, "oversized_blob")

    def test_allows_only_exact_deterministic_privacy_fixture(self) -> None:
        allowed = "/Us" + "ers/private/recordings/pending.m4a"
        fixture_path = "Tests/IdeaForgeCoreTests/IdeaForgeCoreTests.swift"
        self.write(fixture_path, f'let path = "{allowed}"\n')

        allowed_result, allowed_report = self.run_audit()

        self.assertEqual(allowed_result.returncode, 0, allowed_result.stderr)
        self.assertEqual(allowed_report["finding_count"], 0)

        unlisted = "/Us" + "ers/private/recordings/not-reviewed.m4a"
        self.write(fixture_path, f'let path = "{unlisted}"\n')

        rejected_result, rejected_report = self.run_audit()

        self.assertNotEqual(rejected_result.returncode, 0)
        self.assert_single_finding(rejected_report, "user_home_path")

    def test_private_source_profile_excludes_only_declared_private_history(self) -> None:
        private_path = "/Us" + "ers/name/private.txt"
        self.write("docs/evidence/private-note.txt", private_path)
        self.write("Sources/Public.swift", "struct Public {}\n")

        result, report = self.run_audit(profile="private-source")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["finding_count"], 0)
        self.assertIn("docs/evidence", report["excluded_paths"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
