#!/usr/bin/env python3
"""Validate repo-local App Store preparation artifacts for IdeaForge."""

from __future__ import annotations

import argparse
import json
import plistlib
import struct
from collections import defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ICONSETS = {
    "macOS": ROOT / "Sources/IdeaForgeAssets/MacAssets.xcassets/AppIconMac.appiconset",
    "iOS": ROOT / "Sources/IdeaForgeAssets/iOSAssets.xcassets/AppIconiOS.appiconset",
    "watchOS": ROOT / "Sources/IdeaForgeAssets/WatchAssets.xcassets/AppIconWatch.appiconset",
}
SCREENSHOT_MANIFEST = ROOT / "AppStore/screenshots/manifest.json"
METADATA = ROOT / "AppStore/metadata/en-US.md"
REVIEW_NOTES = ROOT / "AppStore/review-notes.md"
SUPPORT = ROOT / "SUPPORT.md"
PRIVACY = ROOT / "PRIVACY.md"
PROJECT = ROOT / "project.yml"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def markdown_field(markdown: str, heading: str) -> str:
    marker = f"## {heading}\n"
    start = markdown.find(marker)
    if start == -1:
        return ""
    start += len(marker)
    next_heading = markdown.find("\n## ", start)
    body = markdown[start:] if next_heading == -1 else markdown[start:next_heading]
    return body.strip()


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


def expected_png_size(size_text: str, scale_text: str) -> tuple[int, int] | None:
    try:
        width_points, height_points = (float(value) for value in size_text.split("x", 1))
        scale = int(scale_text.removesuffix("x"))
    except (AttributeError, ValueError):
        return None
    return (round(width_points * scale), round(height_points * scale))


def validate_icon_catalog(
    platform: str,
    iconset: Path,
    required: set[tuple[str, str, str]],
    issues: list[str],
) -> None:
    contents_path = iconset / "Contents.json"
    if not contents_path.exists():
        issues.append(f"{platform} AppIcon asset catalog is missing.")
        return
    try:
        contents = json.loads(read_text(contents_path))
    except json.JSONDecodeError as error:
        issues.append(f"{platform} AppIcon Contents.json is invalid JSON: {error}.")
        return

    images = contents.get("images")
    if not isinstance(images, list) or not images:
        issues.append(f"{platform} AppIcon Contents.json must declare image entries.")
        return

    seen = set()
    for image in images:
        if not isinstance(image, dict):
            issues.append(f"{platform} AppIcon image entry must be an object.")
            continue
        key = (
            str(image.get("idiom", "")),
            str(image.get("size", "")),
            str(image.get("scale", "")),
        )
        seen.add(key)
        filename = str(image.get("filename", "")).strip()
        if not filename:
            issues.append(f"{platform} AppIcon entry {key} is missing a filename.")
            continue
        file_path = iconset / filename
        if not file_path.exists():
            issues.append(f"{platform} AppIcon file is missing: {file_path.relative_to(ROOT)}.")
            continue
        size = png_size(file_path)
        if size is None:
            issues.append(f"{platform} AppIcon file is not a valid PNG: {file_path.relative_to(ROOT)}.")
            continue
        expected_size = expected_png_size(key[1], key[2])
        if expected_size is None:
            issues.append(f"{platform} AppIcon entry {key} has an invalid size or scale.")
            continue
        if size != expected_size:
            issues.append(
                f"{platform} AppIcon file {file_path.relative_to(ROOT)} is {size[0]}x{size[1]} "
                f"but catalog entry {key[1]} {key[2]} requires {expected_size[0]}x{expected_size[1]}."
            )

    missing = sorted(required - seen)
    for idiom, size, scale in missing:
        issues.append(f"{platform} AppIcon missing required entry {idiom} {size} {scale}.")

def validate_icon_catalogs(issues: list[str], evidence: list[str]) -> None:
    required_by_platform = {
        "macOS": {
            ("mac", "512x512", "2x"),
        },
        "iOS": {
            ("ios-marketing", "1024x1024", "1x"),
            ("iphone", "60x60", "3x"),
        },
        "watchOS": {
            ("watch-marketing", "1024x1024", "1x"),
            ("watch", "50x50", "2x"),
        },
    }
    before = len(issues)
    for platform, iconset in ICONSETS.items():
        validate_icon_catalog(platform, iconset, required_by_platform[platform], issues)
    if len(issues) == before:
        evidence.append("Target-specific AppIcon catalogs include required iOS marketing, watch marketing, mac 1024px, iPhone, and Watch entries.")


def validate_project_wiring(issues: list[str], evidence: list[str]) -> None:
    project = read_text(PROJECT)
    expected = {
        "IdeaForgeMac": ("Sources/IdeaForgeAssets/MacAssets.xcassets", "AppIconMac"),
        "IdeaForgeiOS": ("Sources/IdeaForgeAssets/iOSAssets.xcassets", "AppIconiOS"),
        "IdeaForgeWatch": ("Sources/IdeaForgeAssets/WatchAssets.xcassets", "AppIconWatch"),
    }
    before = len(issues)
    for target, (asset_path, icon_name) in expected.items():
        target_index = project.find(f"  {target}:")
        if target_index == -1:
            issues.append(f"{target} is missing from project.yml.")
            continue
        next_target = project.find("\n  IdeaForge", target_index + 1)
        block = project[target_index:] if next_target == -1 else project[target_index:next_target]
        if asset_path not in block:
            issues.append(f"{target} does not include {asset_path}.")
        if f"ASSETCATALOG_COMPILER_APPICON_NAME: {icon_name}" not in block:
            issues.append(f"{target} does not set ASSETCATALOG_COMPILER_APPICON_NAME to {icon_name}.")
    if len(issues) == before:
        evidence.append("project.yml wires target-specific AppIcon catalogs through all app targets.")


def validate_metadata(issues: list[str], evidence: list[str], public_source: bool) -> None:
    required_documents = [SUPPORT, PRIVACY] if public_source else [METADATA, REVIEW_NOTES, SUPPORT, PRIVACY]
    for path in required_documents:
        if not path.exists():
            issues.append(f"Missing release document: {path.relative_to(ROOT)}.")

    if public_source:
        evidence.append(
            "Public support and privacy documents are present; private App Store metadata is intentionally outside this source snapshot."
        )
        return

    if not METADATA.exists():
        return
    metadata = read_text(METADATA)
    app_name = markdown_field(metadata, "App Name")
    subtitle = markdown_field(metadata, "Subtitle")
    keywords = markdown_field(metadata, "Keywords")
    description = markdown_field(metadata, "Description")
    support_url = markdown_field(metadata, "Support URL")
    privacy_url = markdown_field(metadata, "Privacy Policy URL")

    if not (2 <= len(app_name) <= 30):
        issues.append("App Store app name must be 2-30 characters.")
    if not (1 <= len(subtitle) <= 30):
        issues.append("App Store subtitle must be 1-30 characters.")
    if len(keywords) > 100:
        issues.append("App Store keywords must be 100 characters or fewer.")
    if len(description) < 120:
        issues.append("App Store description is too short for review.")
    if not support_url.startswith("https://"):
        issues.append("Support URL must be an https URL.")
    if not privacy_url.startswith("https://"):
        issues.append("Privacy Policy URL must be an https URL.")

    if REVIEW_NOTES.exists():
        review_notes = read_text(REVIEW_NOTES)
        for blocked in ["DEVELOPMENT_TEAM", "App Store Connect", "Physical iPhone"]:
            if blocked not in review_notes:
                issues.append(f"Review notes should name blocker: {blocked}.")

    evidence.append("App Store metadata draft, support document, privacy summary, and review notes are present.")


def validate_screenshot_manifest(issues: list[str], evidence: list[str]) -> None:
    if not SCREENSHOT_MANIFEST.exists():
        issues.append("Screenshot manifest is missing.")
        return
    try:
        manifest = json.loads(read_text(SCREENSHOT_MANIFEST))
    except json.JSONDecodeError as error:
        issues.append(f"Screenshot manifest is invalid JSON: {error}.")
        return
    sets = manifest.get("sets")
    if not isinstance(sets, list) or not sets:
        issues.append("Screenshot manifest must include screenshot sets.")
        return
    per_platform: dict[str, int] = defaultdict(int)
    for item in sets:
        if not isinstance(item, dict):
            issues.append("Screenshot manifest entry must be an object.")
            continue
        platform = str(item.get("platform", "")).strip()
        path_text = str(item.get("path", "")).strip()
        purpose = str(item.get("purpose", "")).strip()
        if not platform or not purpose:
            issues.append("Screenshot manifest entries require platform and purpose.")
        path = ROOT / path_text
        if not path.exists():
            issues.append(f"Screenshot candidate is missing: {path_text}.")
            continue
        if path.suffix.lower() not in {".png", ".jpg", ".jpeg"}:
            issues.append(f"Screenshot candidate must be PNG/JPEG: {path_text}.")
        if png_size(path) is None and path.suffix.lower() == ".png":
            issues.append(f"Screenshot PNG is invalid: {path_text}.")
        per_platform[platform] += 1

    for platform in ["iOS", "macOS", "watchOS"]:
        count = per_platform.get(platform, 0)
        if not (1 <= count <= 10):
            issues.append(f"{platform} screenshot manifest must include 1-10 candidates; found {count}.")
    evidence.append("Candidate screenshots exist for iOS, macOS, and watchOS.")


def parse_accessed_api_reasons(manifest: dict[str, Any]) -> dict[str, set[str]]:
    accessed_types = manifest.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(accessed_types, list):
        raise ValueError("NSPrivacyAccessedAPITypes must be an array")

    declared_reasons: dict[str, set[str]] = {}
    for item in accessed_types:
        if not isinstance(item, dict):
            raise ValueError("accessed API entries must be dictionaries")
        category = item.get("NSPrivacyAccessedAPIType")
        reasons = item.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(category, str) or not isinstance(reasons, list) or not all(
            isinstance(reason, str) for reason in reasons
        ):
            raise ValueError("accessed API declarations must contain a category and string reason array")
        declared_reasons.setdefault(category, set()).update(reasons)
    return declared_reasons


def validate_privacy_manifests(issues: list[str], evidence: list[str]) -> None:
    manifests = [
        ROOT / "Sources/IdeaForgeMac/PrivacyInfo.xcprivacy",
        ROOT / "Sources/IdeaForgeiOS/PrivacyInfo.xcprivacy",
        ROOT / "Sources/IdeaForgeWatch/PrivacyInfo.xcprivacy",
    ]
    before = len(issues)
    for path in manifests:
        if not path.exists():
            issues.append(f"Privacy manifest missing: {path.relative_to(ROOT)}.")
            continue
        try:
            manifest = plistlib.loads(path.read_bytes())
        except Exception as error:  # noqa: BLE001
            issues.append(f"Privacy manifest is invalid: {path.relative_to(ROOT)} ({error}).")
            continue
        try:
            declared_reasons = parse_accessed_api_reasons(manifest)
        except ValueError as error:
            issues.append(f"Privacy manifest {path.relative_to(ROOT)} is malformed: {error}.")
            continue
        expected_reasons = {
            "NSPrivacyAccessedAPICategoryDiskSpace": "E174.1",
            "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
        }
        for category, reason in expected_reasons.items():
            if reason not in declared_reasons.get(category, set()):
                issues.append(
                    f"Privacy manifest {path.relative_to(ROOT)} must declare {category} reason {reason}."
                )
    if len(issues) == before:
        evidence.append(
            "Privacy manifests parse and declare required Disk Space and User Defaults reasons for Mac, iOS, and watchOS."
        )


def build_report(issues: list[str], evidence: list[str]) -> str:
    status = "pass" if not issues else "blocked"
    lines = [
        "# IdeaForge App Store Assets Validation",
        "",
        f"Status: **{status}**",
        "",
        "## Evidence",
        "",
    ]
    lines.extend(f"- {item}" for item in evidence)
    lines.extend(["", "## Issues", ""])
    if issues:
        lines.extend(f"- {item}" for item in issues)
    else:
        lines.append("- None.")
    lines.extend(
        [
            "",
            "## External Blockers Not Proven By This Script",
            "",
            "- Apple Developer team, certificates, profiles, and release archive.",
            "- App Store Connect app record, product setup, metadata upload, privacy labels, and screenshot upload.",
            "- Physical iPhone and paired Apple Watch release smoke.",
            "- Deployed backend, App Store Server API validation, monitoring, backup, and restore drills.",
            "",
        ]
    )
    return "\n".join(lines)


def validate(public_source: bool = False) -> tuple[list[str], list[str]]:
    issues: list[str] = []
    evidence: list[str] = []
    validate_icon_catalogs(issues, evidence)
    validate_project_wiring(issues, evidence)
    validate_metadata(issues, evidence, public_source)
    if not public_source:
        validate_screenshot_manifest(issues, evidence)
    validate_privacy_manifests(issues, evidence)
    return issues, evidence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", default="build/reports/app-store-assets.json")
    parser.add_argument("--markdown", default="build/reports/app-store-assets.md")
    parser.add_argument(
        "--public-source",
        action="store_true",
        help="Validate public source assets without private App Store metadata or screenshots.",
    )
    args = parser.parse_args()

    issues, evidence = validate(public_source=args.public_source)
    report = build_report(issues, evidence)
    json_path = ROOT / args.json
    markdown_path = ROOT / args.markdown
    json_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(
        json.dumps(
            {
                "status": "pass" if not issues else "blocked",
                "profile": "public-source" if args.public_source else "private-release",
                "issues": issues,
                "evidence": evidence,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    markdown_path.write_text(report, encoding="utf-8")
    print(report)
    return 0 if not issues else 2


if __name__ == "__main__":
    raise SystemExit(main())
