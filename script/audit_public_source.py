#!/usr/bin/env python3
"""Fail-closed privacy, credential, blob, and image-provenance audit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Iterable


DEFAULT_MAX_FILE_BYTES = 5 * 1024 * 1024
IMAGE_SUFFIXES = frozenset({".gif", ".heic", ".jpeg", ".jpg", ".pdf", ".png", ".svg", ".webp"})
PRIVATE_SOURCE_EXCLUSIONS = (
    "AppStore",
    "docs/app-store-release-checklist.md",
    "docs/audits",
    "docs/e2e-ship-audit-2026-07-10.md",
    "docs/evidence",
    "docs/iphone-consistency-agent-2026-07-03.md",
    "docs/iphone-inbox-polish-2026-07-03.md",
    "docs/original-plan-gap-map.md",
    "docs/production-plan.md",
    "docs/production-readiness.md",
    "docs/superpowers",
    "docs/swiftui-polish-audit-2026-06-29.md",
    "docs/swiftui-polish-audit-2026-06-30.md",
)
GENERATED_DIRECTORY_NAMES = frozenset(
    {
        ".build",
        ".codex",
        ".git",
        ".idea",
        ".superpowers",
        ".vscode",
        "__pycache__",
        "build",
        "dist",
        "xcuserdata",
    }
)
RELEASE_CREDENTIAL_SUFFIXES = frozenset(
    {".cer", ".key", ".mobileprovision", ".p12", ".p8", ".pem", ".provisionprofile"}
)
RELEASE_CREDENTIAL_NAMES = frozenset({".env.release", "notary-credentials", "release-credentials"})
USER_HOME_PREFIX = "/Us" + "ers"
# These exact strings exercise privacy redaction behavior. No directory-wide or
# category-wide exception is permitted.
DETERMINISTIC_TEXT_FIXTURES = frozenset(
    {
        (
            "Tests/IdeaForgeCoreTests/Fixtures/workflow_prompt_regressions.json",
            "user_home_path",
            f"{USER_HOME_PREFIX}/example/dev/apps/IdeaForge",
        ),
        (
            "Tests/IdeaForgeCoreTests/IdeaForgeCoreTests.swift",
            "user_home_path",
            f"{USER_HOME_PREFIX}/person/recordings/secret.m4a",
        ),
        (
            "Tests/IdeaForgeCoreTests/IdeaForgeCoreTests.swift",
            "user_home_path",
            f"{USER_HOME_PREFIX}/private",
        ),
        (
            "Tests/IdeaForgeCoreTests/IdeaForgeCoreTests.swift",
            "user_home_path",
            f"{USER_HOME_PREFIX}/private/recordings/failed.m4a",
        ),
        (
            "Tests/IdeaForgeCoreTests/IdeaForgeCoreTests.swift",
            "user_home_path",
            f"{USER_HOME_PREFIX}/private/recordings/pending.m4a",
        ),
        (
            "script/review_privacy_logs.py",
            "user_home_path",
            f"{USER_HOME_PREFIX}/example/private/audio.m4a",
        ),
    }
)
# Upstream legal text must remain verbatim, including author contact details.
# The exact hash prevents this narrow exception from masking edited content.
VERBATIM_THIRD_PARTY_LICENSES = {
    "ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt":
        "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe",
}

TEXT_PATTERNS = (
    (
        "user_home_path",
        re.compile(r"/Users/[A-Za-z0-9._@+-]+(?:/[A-Za-z0-9._@+,:=-]+)*"),
        "Concrete macOS user home path",
    ),
    (
        "gmail_address",
        re.compile(r"(?i)\b[A-Z0-9._%+-]+@gmail\.com\b"),
        "Personal Gmail address",
    ),
    (
        "physical_udid",
        re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"),
        "Physical Apple device identifier",
    ),
    (
        "private_key_marker",
        re.compile(r"-----BEGIN\s+(?:(?:RSA|EC|OPENSSH)\s+)?PRIVATE\s+KEY-----"),
        "Private-key material marker",
    ),
)


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="Tree to audit")
    parser.add_argument(
        "--profile",
        choices=("public", "private-source"),
        default="public",
        help="private-source excludes only paths intentionally omitted from publication",
    )
    parser.add_argument(
        "--max-file-bytes",
        type=int,
        default=DEFAULT_MAX_FILE_BYTES,
        help="Fail on larger files unless the file is a provenanced image",
    )
    parser.add_argument("--json-out", type=Path, required=True)
    parser.add_argument("--markdown-out", type=Path, required=True)
    return parser.parse_args(argv)


def path_is_within(relative_path: str, prefix: str) -> bool:
    return relative_path == prefix or relative_path.startswith(prefix + "/")


def is_generated_path(relative_path: Path) -> bool:
    for part in relative_path.parts:
        if part in GENERATED_DIRECTORY_NAMES or part.startswith("DerivedData"):
            return True
    return relative_path.name == ".DS_Store"


def iter_audited_files(
    root: Path,
    profile: str,
) -> Iterable[tuple[Path, str]]:
    for path in sorted(root.rglob("*")):
        if not path.is_symlink() and not path.is_file():
            continue
        relative = path.relative_to(root)
        relative_string = relative.as_posix()
        if is_generated_path(relative):
            continue
        if profile == "private-source" and any(
            path_is_within(relative_string, excluded) for excluded in PRIVATE_SOURCE_EXCLUSIONS
        ):
            continue
        yield path, relative_string


def load_provenance(root: Path) -> dict[str, str]:
    manifest = root / "ASSET_PROVENANCE.md"
    if manifest.is_symlink() or not manifest.is_file():
        return {}
    entries: dict[str, str] = {}
    row_pattern = re.compile(r"\|\s*`([^`]+)`\s*\|\s*`([0-9a-f]{64})`\s*\|")
    for match in row_pattern.finditer(manifest.read_text(encoding="utf-8")):
        entries[match.group(1)] = match.group(2)
    return entries


def is_release_credential_path(relative_path: str) -> bool:
    path = Path(relative_path)
    lower_name = path.name.lower()
    if path.suffix.lower() in RELEASE_CREDENTIAL_SUFFIXES:
        return True
    return any(lower_name == name or lower_name.startswith(name + ".") for name in RELEASE_CREDENTIAL_NAMES)


def finding(category: str, path: str, message: str, line: int | None = None) -> dict[str, object]:
    result: dict[str, object] = {"category": category, "path": path, "message": message}
    if line is not None:
        result["line"] = line
    return result


def validate_report_output(root: Path, requested: Path, label: str) -> Path:
    candidate = requested if requested.is_absolute() else Path.cwd() / requested
    if candidate.exists() or candidate.is_symlink():
        raise ValueError(f"{label} report output must be absent: {requested}")
    parent = candidate.parent.resolve(strict=True)
    if not parent.is_dir():
        raise ValueError(f"{label} report output parent is not a directory: {requested}")
    try:
        parent.relative_to(root)
    except ValueError as error:
        raise ValueError(f"{label} report output must be contained by the audit root: {requested}") from error
    return parent / candidate.name


def validate_boundaries(args: argparse.Namespace) -> None:
    root = args.root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError(f"audit root is not a directory: {args.root}")
    args.root = root
    args.json_out = validate_report_output(root, args.json_out, "JSON")
    args.markdown_out = validate_report_output(root, args.markdown_out, "Markdown")
    if args.json_out == args.markdown_out:
        raise ValueError("JSON and Markdown report outputs must be different paths")


def audit(args: argparse.Namespace) -> dict[str, object]:
    root = args.root
    if args.max_file_bytes <= 0:
        raise ValueError("--max-file-bytes must be positive")

    provenance = load_provenance(root)
    findings: list[dict[str, object]] = []
    scanned_file_count = 0
    image_count = 0

    for path, relative_path in iter_audited_files(root, args.profile):
        scanned_file_count += 1
        if path.is_symlink():
            findings.append(finding("symlink", relative_path, "Symbolic links are not allowed in audited trees"))
            continue
        size = path.stat().st_size
        suffix = path.suffix.lower()

        if is_release_credential_path(relative_path):
            findings.append(
                finding("release_credential_file", relative_path, "Release credential file type or name")
            )

        if suffix in IMAGE_SUFFIXES:
            image_count += 1
            expected_hash = provenance.get(relative_path)
            if expected_hash is None:
                findings.append(
                    finding("unprovenanced_image", relative_path, "Image has no hash-based provenance entry")
                )
            else:
                actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
                if actual_hash != expected_hash:
                    findings.append(
                        finding("image_hash_mismatch", relative_path, "Image does not match its provenance hash")
                    )

        if size > args.max_file_bytes and relative_path not in provenance:
            findings.append(
                finding(
                    "oversized_blob",
                    relative_path,
                    f"File exceeds the {args.max_file_bytes}-byte limit",
                )
            )

        data = path.read_bytes()
        verbatim_license = (
            relative_path in VERBATIM_THIRD_PARTY_LICENSES
            and hashlib.sha256(data).hexdigest() == VERBATIM_THIRD_PARTY_LICENSES[relative_path]
        )
        text = data.decode("utf-8", errors="replace")
        for line_number, line in enumerate(text.splitlines(), start=1):
            for category, pattern, message in TEXT_PATTERNS:
                for match in pattern.finditer(line):
                    value = match.group(0)
                    if (relative_path, category, value) in DETERMINISTIC_TEXT_FIXTURES:
                        continue
                    if verbatim_license and category == "gmail_address":
                        continue
                    findings.append(finding(category, relative_path, message, line_number))

    findings.sort(key=lambda item: (str(item["path"]), int(item.get("line", 0)), str(item["category"])))
    excluded_paths = list(PRIVATE_SOURCE_EXCLUSIONS) if args.profile == "private-source" else []
    return {
        "schema_version": 1,
        "profile": args.profile,
        "status": "pass" if not findings else "fail",
        "finding_count": len(findings),
        "findings": findings,
        "scanned_file_count": scanned_file_count,
        "image_count": image_count,
        "provenance_entry_count": len(provenance),
        "excluded_paths": excluded_paths,
    }


def render_markdown(report: dict[str, object]) -> str:
    lines = [
        "# Public-source audit",
        "",
        f"- Status: **{str(report['status']).upper()}**",
        f"- Profile: `{report['profile']}`",
        f"- Files scanned: {report['scanned_file_count']}",
        f"- Images checked: {report['image_count']}",
        f"- Provenance entries: {report['provenance_entry_count']}",
        f"- Findings: {report['finding_count']}",
    ]
    excluded_paths = report["excluded_paths"]
    if excluded_paths:
        lines.extend(["", "## Profile exclusions", ""])
        lines.extend(f"- `{path}`" for path in excluded_paths)
    findings = report["findings"]
    if findings:
        lines.extend(["", "## Findings", ""])
        for item in findings:
            location = item["path"]
            if "line" in item:
                location = f"{location}:{item['line']}"
            lines.append(f"- `{item['category']}` at `{location}`: {item['message']}")
    return "\n".join(lines) + "\n"


def write_text_exclusive(path: Path, content: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(content)


def write_reports(args: argparse.Namespace, report: dict[str, object]) -> None:
    write_text_exclusive(args.json_out, json.dumps(report, indent=2, sort_keys=True) + "\n")
    write_text_exclusive(args.markdown_out, render_markdown(report))


def main(argv: list[str] | None = None) -> int:
    args = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        validate_boundaries(args)
        report = audit(args)
        write_reports(args, report)
    except (OSError, ValueError) as error:
        print(f"public-source audit error: {error}", file=sys.stderr)
        return 2
    print(
        f"Public-source audit: {str(report['status']).upper()} "
        f"({report['finding_count']} findings, {report['scanned_file_count']} files)",
        file=sys.stderr,
    )
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
