#!/usr/bin/env python3
"""Generate the deterministic SPDX 2.3 SBOM for an IdeaForge source release."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import os
import re
import subprocess
import sys


EXPECTED_SPARKLE_LOCATION = "https://github.com/sparkle-project/Sparkle"
EXPECTED_SPARKLE_VERSION = "2.9.4"
EXPECTED_SPARKLE_REVISION = "b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
EXPECTED_SPARKLE_SPM_ARCHIVE_SHA256 = "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"


def arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def project_version(root: Path) -> str:
    text = (root / "project.yml").read_text(encoding="utf-8")
    match = re.search(r'^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$', text, flags=re.MULTILINE)
    if match is None:
        raise ValueError("project.yml has no MARKETING_VERSION")
    return match.group(1)


def sparkle_pin(root: Path) -> tuple[str, str, str]:
    text = (root / "project.yml").read_text(encoding="utf-8")
    match = re.search(
        r"^\s{2}Sparkle:\s*$\n"
        r"^\s{4}url:\s*(\S+)\s*$\n"
        r"^\s{4}revision:\s*([0-9a-f]{40})(?:\s+#\s+Sparkle\s+([^\s]+))?\s*$",
        text,
        flags=re.MULTILINE,
    )
    if match is None:
        raise ValueError("project.yml must contain one immutable Sparkle revision pin")
    location, revision, version = match.groups()
    if (
        location != EXPECTED_SPARKLE_LOCATION
        or revision != EXPECTED_SPARKLE_REVISION
        or version != EXPECTED_SPARKLE_VERSION
    ):
        raise ValueError("Sparkle pin does not match project.yml release policy")
    return location, version, revision


def source_commit(root: Path) -> str:
    supplied = os.environ.get("IDEAFORGE_SOURCE_COMMIT", "")
    if supplied:
        commit = supplied
    else:
        commit = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("source commit must be a 40-character lowercase Git object ID")
    return commit


def created_timestamp(root: Path) -> str:
    raw_epoch = os.environ.get("SOURCE_DATE_EPOCH", "")
    if raw_epoch:
        epoch = int(raw_epoch)
    else:
        epoch = int(
            subprocess.run(
                ["git", "-C", str(root), "show", "-s", "--format=%ct", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        )
    if epoch < 0:
        raise ValueError("SOURCE_DATE_EPOCH must not be negative")
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_document(root: Path, version: str) -> dict[str, object]:
    configured_version = project_version(root)
    if version != configured_version:
        raise ValueError(f"version {version} does not match project.yml {configured_version}")
    sparkle_location, sparkle_version, sparkle_revision = sparkle_pin(root)
    commit = source_commit(root)
    return {
        "SPDXID": "SPDXRef-DOCUMENT",
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "name": f"IdeaForge-{version}",
        "documentNamespace": (
            f"https://github.com/rsitech-ai/IdeaForge/releases/download/v{version}/"
            f"IdeaForge-{version}-sbom-{commit}.spdx.json"
        ),
        "creationInfo": {
            "created": created_timestamp(root),
            "creators": ["Tool: IdeaForge release tooling"],
        },
        "packages": [
            {
                "SPDXID": "SPDXRef-Package-IdeaForge",
                "name": "IdeaForge",
                "versionInfo": version,
                "downloadLocation": f"https://github.com/rsitech-ai/IdeaForge/tree/v{version}",
                "filesAnalyzed": False,
                "licenseConcluded": "Apache-2.0",
                "licenseDeclared": "Apache-2.0",
                "copyrightText": "See NOTICE",
                "externalRefs": [
                    {
                        "referenceCategory": "OTHER",
                        "referenceType": "vcs",
                        "referenceLocator": f"git+https://github.com/rsitech-ai/IdeaForge@{commit}",
                    }
                ],
            },
            {
                "SPDXID": "SPDXRef-Package-Sparkle",
                "name": "Sparkle",
                "versionInfo": sparkle_version,
                "downloadLocation": sparkle_location,
                "filesAnalyzed": False,
                "licenseConcluded": "MIT",
                "licenseDeclared": "MIT",
                "copyrightText": "See Sparkle upstream license",
                "checksums": [
                    {"algorithm": "SHA256", "checksumValue": EXPECTED_SPARKLE_SPM_ARCHIVE_SHA256}
                ],
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": f"pkg:github/sparkle-project/Sparkle@{sparkle_version}",
                    },
                    {
                        "referenceCategory": "OTHER",
                        "referenceType": "vcs",
                        "referenceLocator": f"git+{sparkle_location}@{sparkle_revision}",
                    },
                ],
            },
        ],
        "relationships": [
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": "SPDXRef-Package-IdeaForge",
            },
            {
                "spdxElementId": "SPDXRef-Package-IdeaForge",
                "relationshipType": "DEPENDS_ON",
                "relatedSpdxElement": "SPDXRef-Package-Sparkle",
            },
        ],
    }


def main(argv: list[str] | None = None) -> int:
    args = arguments(sys.argv[1:] if argv is None else argv)
    try:
        root = args.root.resolve(strict=True)
        if not root.is_dir():
            raise ValueError("root is not a directory")
        document = build_document(root, args.version)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (OSError, ValueError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"generate_sbom.py: {error}", file=sys.stderr)
        return 2
    print(f"SPDX SBOM: {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
