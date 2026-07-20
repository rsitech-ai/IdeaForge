#!/usr/bin/env python3
"""Review IdeaForge unified logs for privacy-sensitive leakage."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPORT_DIR = ROOT / "build" / "reports"
SUBSYSTEM = "com.s1kor.ideaforge"


@dataclass(frozen=True)
class Finding:
    rule: str
    line: int
    excerpt: str


@dataclass(frozen=True)
class ReviewReport:
    status: str
    source: str
    line_count: int
    findings: list[Finding]
    checked_rules: list[str]


class PrivacyRule:
    def __init__(self, identifier: str, pattern: str) -> None:
        self.identifier = identifier
        self.regex = re.compile(pattern)


RULES = [
    PrivacyRule(
        "bearer-or-api-secret",
        r"(?i)(?:\bauthorization\b\s*[:=]\s*bearer\s+(?:\"[^\"]*\"|'[^']*'|[^\s\"']+)|\bbearer\s+(?:\"[^\"]*\"|'[^']*'|[^\s\"']+)|\b(?:api[_ -]?key|secret|password)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s\"']+))",
    ),
    PrivacyRule("openai-key", r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    PrivacyRule("apns-token-value", r"(?i)\b(?:apns|device)\s*token\b\s*[:=]\s*[0-9a-f]{32,}"),
    PrivacyRule("absolute-local-path", r"(?:/Users|/private/var|/var/folders|/var/mobile|/tmp)/[^\s\"']+"),
    PrivacyRule("audio-or-object-key", r"\b(?:audio|recordings|objects)/[A-Za-z0-9._/\-]+\.(?:m4a|caf|wav|mp3|json|md)\b"),
    PrivacyRule("raw-transcript-field", r"(?i)\b(?:cleanText|transcriptText|rawTranscript|clean transcript)\b\s*[:=]"),
    PrivacyRule("url-value", r"https?://[^\s\"']+"),
    PrivacyRule("email-address", r"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b",),
]

UNIFIED_LOG_METADATA = (
    re.compile(r"^Timestamp\b"),
    re.compile(r"^Filtering the log data using\b"),
)


def redact_all(line: str) -> str:
    redacted = line
    for rule in RULES:
        redacted = rule.regex.sub("[REDACTED]", redacted)
    return redacted.strip()


def is_unified_log_metadata(line: str) -> bool:
    stripped = line.strip()
    return any(pattern.search(stripped) for pattern in UNIFIED_LOG_METADATA)


def review_lines(lines: list[str], source: str) -> ReviewReport:
    findings: list[Finding] = []
    event_lines = [
        (index, line)
        for index, line in enumerate(lines, start=1)
        if line.strip() and not is_unified_log_metadata(line)
    ]
    for index, line in event_lines:
        excerpt = redact_all(line)
        for rule in RULES:
            if rule.regex.search(line):
                findings.append(Finding(rule.identifier, index, excerpt))

    status = "pass" if event_lines and not findings else "blocked"
    return ReviewReport(
        status=status,
        source=source,
        line_count=len(event_lines),
        findings=findings,
        checked_rules=[rule.identifier for rule in RULES],
    )


def collect_unified_logs(last: str, predicate: str) -> tuple[list[str], str]:
    command = [
        "/usr/bin/log",
        "show",
        "--last",
        last,
        "--info",
        "--style",
        "compact",
        "--predicate",
        predicate,
    ]
    result = subprocess.run(command, check=False, text=True, capture_output=True, timeout=90)
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "log show failed").strip()
        raise RuntimeError(message)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    return lines, " ".join(command)


def render_markdown(report: ReviewReport) -> str:
    lines = [
        "# IdeaForge Privacy Log Review",
        "",
        f"Status: **{report.status}**",
        "",
        f"- Source: `{report.source}`",
        f"- Lines reviewed: {report.line_count}",
        f"- Rules checked: {', '.join(report.checked_rules)}",
        "",
    ]
    if not report.findings and report.line_count > 0:
        lines.extend(
            [
                "## Evidence",
                "",
                "- App-subsystem event records were present.",
                "- No bearer/API secrets, APNs token values, local file paths, audio/object keys, raw transcript fields, URLs, or email addresses were detected.",
                "- Findings, if any, are reported with redacted excerpts only.",
                "- Scope is limited to privacy leakage. This review does not prove crash freedom, retry-loop behavior, or persistence correctness.",
                "",
            ]
        )
    elif report.line_count == 0:
        lines.extend(
            [
                "## Blocker",
                "",
                "- No app-subsystem event records were available, so runtime log privacy could not be proven.",
                "",
            ]
        )
    else:
        lines.extend(["## Findings", "", "| Rule | Line | Redacted excerpt |", "| --- | ---: | --- |"])
        for finding in report.findings:
            excerpt = finding.excerpt.replace("|", "\\|")
            lines.append(f"| {finding.rule} | {finding.line} | `{excerpt}` |")
        lines.append("")
    return "\n".join(lines)


def write_report(report: ReviewReport, json_path: Path, markdown_path: Path) -> None:
    json_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(
        json.dumps(
            {
                **asdict(report),
                "findings": [asdict(finding) for finding in report.findings],
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    markdown_path.write_text(render_markdown(report), encoding="utf-8")


def run_self_test() -> None:
    header_only = review_lines(["Timestamp               Ty Process[PID:TID]"], "self-test-header")
    assert header_only.status == "blocked", header_only
    assert header_only.line_count == 0, header_only

    metadata_only = review_lines(
        [
            'Filtering the log data using "subsystem == com.s1kor.ideaforge"',
            "Timestamp                       Thread     Type        Activity             PID    TTL",
        ],
        "self-test-metadata",
    )
    assert metadata_only.status == "blocked", metadata_only
    assert metadata_only.line_count == 0, metadata_only

    safe_lines = [
        "IdeaForge[1] Sync: Remote notification sync skipped; blocker: missingCapability",
        "IdeaForge[2] Recording: Upload retry scheduled for recording <private>",
        "IdeaForge[3] Lifecycle: iOS app appeared",
    ]
    safe = review_lines(safe_lines, "self-test-safe")
    assert safe.status == "pass", safe

    ios_path = review_lines(
        ["Saved recording at /var/mobile/Containers/Data/Application/PRIVATE/Documents/voice.m4a"],
        "self-test-ios-path",
    )
    assert {finding.rule for finding in ios_path.findings} == {"absolute-local-path"}, ios_path
    assert ios_path.status == "blocked", ios_path

    unsafe_lines = [
        "Authorization: Bearer dev-token-secret",
        "Saved object at /Users/example/private/audio.m4a",
        "cleanText: Mock transcript fixture.",
        "APNs token: " + (("01234567" + "89abcdef") * 4),
        "Backend URL https://example.invalid/v1/workspace/snapshot",
        "support email user@example.com",
        "audio/idea_ideaforge/rec_watch_1.m4a",
    ]
    unsafe = review_lines(unsafe_lines, "self-test-unsafe")
    expected_rules = {
        "bearer-or-api-secret",
        "raw-transcript-field",
        "apns-token-value",
        "url-value",
        "email-address",
        "audio-or-object-key",
        "absolute-local-path",
    }
    actual_rules = {finding.rule for finding in unsafe.findings}
    assert expected_rules.issubset(actual_rules), actual_rules
    assert unsafe.status == "blocked", unsafe

    compound_secret = (
        "IdeaForge[4] Authorization: Bearer ABCDEFGH+UNREDACTED/TAIL== "
        "password=abcdefgh!UNREDACTED-TAIL "
        "https://api.example.invalid/private owner@example.com"
    )
    compound = review_lines([compound_secret], "self-test-compound-secret")
    assert compound.status == "blocked", compound
    assert len(compound.findings) == 3, compound
    for finding in compound.findings:
        assert "UNREDACTED" not in finding.excerpt, finding
        assert "abcdefgh" not in finding.excerpt, finding
        assert "api.example.invalid" not in finding.excerpt, finding
        assert "owner@example.com" not in finding.excerpt, finding
        assert finding.excerpt.count("[REDACTED]") == 4, finding
    print("review_privacy_logs.py self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--last", default="10m", help="Unified log lookback window. Default: 10m.")
    parser.add_argument(
        "--predicate",
        default=f'subsystem == "{SUBSYSTEM}"',
        help="Unified log predicate. Default filters the IdeaForge subsystem.",
    )
    parser.add_argument("--input", action="append", help="Review a text file instead of querying unified logs.")
    parser.add_argument("--json", help="JSON report path.")
    parser.add_argument("--markdown", help="Markdown report path.")
    parser.add_argument("--self-test", action="store_true", help="Run parser self-tests.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    json_path = Path(args.json) if args.json else REPORT_DIR / f"privacy-log-review-{timestamp}.json"
    markdown_path = Path(args.markdown) if args.markdown else REPORT_DIR / f"privacy-log-review-{timestamp}.md"

    try:
        if args.input:
            lines: list[str] = []
            sources: list[str] = []
            for input_path in args.input:
                path = Path(input_path)
                sources.append(str(path))
                lines.extend(path.read_text(encoding="utf-8").splitlines())
            report = review_lines(lines, ", ".join(sources))
        else:
            lines, source = collect_unified_logs(args.last, args.predicate)
            report = review_lines(lines, source)
    except Exception as error:  # noqa: BLE001 - CLI should convert all collection failures to a blocked report.
        report = ReviewReport(
            status="blocked",
            source=f"collection failed: {error}",
            line_count=0,
            findings=[],
            checked_rules=[rule.identifier for rule in RULES],
        )

    write_report(report, json_path, markdown_path)
    print(render_markdown(report))
    print(f"JSON: {json_path}")
    print(f"Markdown: {markdown_path}")
    return 0 if report.status == "pass" else 2


if __name__ == "__main__":
    sys.exit(main())
