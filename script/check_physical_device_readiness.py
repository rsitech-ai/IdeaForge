#!/usr/bin/env python3
"""Fail-closed preflight for IdeaForge physical iPhone/Watch production proof.

The normal production verifier proves repo-side simulator and build gates. This
script covers the external hardware gate: Apple Developer signing, a real
iPhone, a real Apple Watch, and explicit physical destinations for the iOS and
watchOS targets.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence


ROOT_DIR = Path(__file__).resolve().parents[1]
PROJECT = ROOT_DIR / "IdeaForge.xcodeproj"
IOS_SCHEME = "IdeaForgeiOS"
WATCH_SCHEME = "IdeaForgeWatch"


@dataclass(frozen=True)
class CommandResult:
    command: list[str]
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class PhysicalDevice:
    name: str
    udid: str
    os_version: str | None
    kind: str


@dataclass(frozen=True)
class XcodeDestination:
    platform: str
    identifier: str | None
    name: str


@dataclass(frozen=True)
class XctraceDeviceAnalysis:
    devices: list[PhysicalDevice]
    recognized_rows: int
    malformed_rows: list[str]


@dataclass(frozen=True)
class XcodeDestinationAnalysis:
    destinations: list[XcodeDestination]
    recognized_sections: int
    malformed_rows: list[str]


@dataclass(frozen=True)
class Gate:
    name: str
    status: str
    detail: str
    remediation: str


@dataclass(frozen=True)
class ReadinessReport:
    status: str
    gates: list[Gate]
    physical_devices: list[PhysicalDevice]
    ios_destinations: list[XcodeDestination]
    watch_destinations: list[XcodeDestination]
    commands: list[dict[str, object]]


class ReadinessError(Exception):
    pass


def aggregate_status(gates: list[Gate]) -> str:
    if any(gate.status == "fail" for gate in gates):
        return "fail"
    if any(gate.status == "blocked" for gate in gates):
        return "blocked"
    return "pass"


def exit_code_for_status(status: str) -> int:
    return {"pass": 0, "blocked": 2, "fail": 1}[status]


def run_command(command: Sequence[str], timeout: int = 60) -> CommandResult:
    try:
        completed = subprocess.run(
            list(command),
            cwd=ROOT_DIR,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
        return CommandResult(list(command), completed.returncode, completed.stdout, completed.stderr)
    except FileNotFoundError as error:
        return CommandResult(list(command), 127, "", str(error))
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        stderr = error.stderr if isinstance(error.stderr, str) else ""
        return CommandResult(list(command), 124, stdout, stderr or f"timed out after {timeout}s")


def generate_project(commands: list[CommandResult]) -> Gate:
    if PROJECT.exists():
        return Gate("Xcode project", "pass", "IdeaForge.xcodeproj exists.", "None.")

    result = run_command(["xcodegen", "generate"], timeout=120)
    commands.append(result)
    if result.returncode == 0 and PROJECT.exists():
        return Gate("Xcode project", "pass", "Generated IdeaForge.xcodeproj.", "None.")
    return Gate(
        "Xcode project",
        "fail",
        "IdeaForge.xcodeproj is missing and xcodegen generation did not succeed.",
        "Install/configure XcodeGen, then run `xcodegen generate`.",
    )


def extract_development_team(show_build_settings_output: str) -> str:
    for line in show_build_settings_output.splitlines():
        if "DEVELOPMENT_TEAM =" not in line:
            continue
        _, value = line.split("=", 1)
        return value.strip()
    return ""


def check_signing_team(commands: list[CommandResult]) -> tuple[Gate, str]:
    env_team = os.environ.get("DEVELOPMENT_TEAM", "").strip()
    if env_team:
        return (
            Gate(
                "Apple Developer team",
                "pass",
                f"Using DEVELOPMENT_TEAM from environment: {env_team}.",
                "None.",
            ),
            env_team,
        )

    result = run_command(
        [
            "xcodebuild",
            "-project",
            str(PROJECT),
            "-scheme",
            IOS_SCHEME,
            "-configuration",
            "Release",
            "-showBuildSettings",
        ],
        timeout=90,
    )
    commands.append(result)
    if result.returncode != 0:
        return (
            Gate(
                "Apple Developer team",
                "fail",
                f"xcodebuild failed while reading Release signing settings (exit {result.returncode}).",
                "Read the captured command output and fix the Xcode project or toolchain before retrying.",
            ),
            "",
        )
    team = extract_development_team(result.stdout)
    if team:
        return (
            Gate(
                "Apple Developer team",
                "pass",
                f"Project Release settings provide DEVELOPMENT_TEAM={team}.",
                "None.",
            ),
            team,
        )
    return (
        Gate(
            "Apple Developer team",
            "blocked",
            "No Apple Developer team is configured for Release signing.",
            "Set DEVELOPMENT_TEAM in project.yml or export DEVELOPMENT_TEAM=<team-id>, regenerate the project, and rerun this script.",
        ),
        "",
    )


XCTRACE_DEVICE_PATTERN = re.compile(
    r"^(?P<name>.+?)(?: \((?P<os>[\d.]+)\))? \((?P<udid>[0-9A-Fa-f-]{8,}|[A-Z0-9-]{8,})\)$"
)


def analyze_xctrace_devices(output: str) -> XctraceDeviceAnalysis:
    devices: list[PhysicalDevice] = []
    malformed_rows: list[str] = []
    recognized_rows = 0
    in_devices = False

    for raw_line in output.splitlines():
        line = raw_line.strip()
        if line == "== Devices ==":
            in_devices = True
            continue
        if line.startswith("== ") and line != "== Devices ==":
            in_devices = False
            continue
        if not in_devices or not line:
            continue

        match = XCTRACE_DEVICE_PATTERN.match(line)
        if match is None:
            malformed_rows.append(line)
            continue

        recognized_rows += 1
        name = match.group("name").strip()
        if name.endswith(" Mac") or name in {"Mac", "MacBook Pro", "Mac mini", "Mac Studio"}:
            continue

        kind = "watch" if "Watch" in name else "iphone" if "iPhone" in name else "other"
        if kind == "other":
            continue
        devices.append(
            PhysicalDevice(
                name=name,
                udid=match.group("udid"),
                os_version=match.group("os"),
                kind=kind,
            )
        )
    return XctraceDeviceAnalysis(
        devices=devices,
        recognized_rows=recognized_rows,
        malformed_rows=malformed_rows,
    )


def parse_xctrace_devices(output: str) -> list[PhysicalDevice]:
    return analyze_xctrace_devices(output).devices


def xctrace_format_error(analysis: XctraceDeviceAnalysis) -> str | None:
    if analysis.malformed_rows:
        return "; ".join(analysis.malformed_rows[:3])
    return None


def has_xctrace_devices_section(output: str) -> bool:
    return any(line.strip() == "== Devices ==" for line in output.splitlines())


def list_physical_devices(commands: list[CommandResult]) -> tuple[Gate, list[PhysicalDevice]]:
    result = run_command(["xcrun", "xctrace", "list", "devices"], timeout=60)
    commands.append(result)
    if result.returncode != 0:
        return (
            Gate(
                "Physical device discovery",
                "fail",
                f"xcrun xctrace failed while listing devices (exit {result.returncode}).",
                "Fix the Xcode command-line tool failure, then rerun device discovery.",
            ),
            [],
        )

    if not has_xctrace_devices_section(result.stdout):
        return (
            Gate(
                "Physical device discovery",
                "fail",
                "xcrun xctrace returned an unrecognized device-list format.",
                "Fix the Xcode command-line tool or update the parser before classifying hardware availability.",
            ),
            [],
        )

    analysis = analyze_xctrace_devices(result.stdout)
    format_error = xctrace_format_error(analysis)
    if format_error is not None:
        return (
            Gate(
                "Physical device discovery",
                "fail",
                f"xcrun xctrace returned unrecognized rows in the device section: {format_error}.",
                "Fix the Xcode command-line tool or update the parser before classifying hardware availability.",
            ),
            [],
        )

    devices = analysis.devices
    if not devices:
        return (
            Gate(
                "Physical device discovery",
                "blocked",
                "No physical iPhone or Apple Watch devices were detected.",
                "Connect and trust the physical iPhone and paired Apple Watch.",
            ),
            [],
        )

    summary = ", ".join(f"{device.name} ({device.udid})" for device in devices)
    return (
        Gate("Physical device discovery", "pass", f"Detected physical devices: {summary}.", "None."),
        devices,
    )


def analyze_showdestinations(output: str) -> XcodeDestinationAnalysis:
    destinations: list[XcodeDestination] = []
    malformed_rows: list[str] = []
    recognized_sections = 0
    in_destination_section = False
    for line in output.splitlines():
        stripped = line.strip()
        if re.search(r"(?:Available|Ineligible) destinations for ", stripped):
            recognized_sections += 1
            in_destination_section = True
            continue
        if not in_destination_section or not stripped:
            continue
        if not stripped.startswith("{") or not stripped.endswith("}"):
            malformed_rows.append(stripped)
            continue
        fields: dict[str, str] = {}
        body = stripped[1:-1]
        for item in body.split(","):
            if ":" not in item:
                continue
            key, value = item.split(":", 1)
            fields[key.strip()] = value.strip()
        platform = fields.get("platform", "")
        name = fields.get("name", "")
        identifier = fields.get("id")
        if platform and name:
            destinations.append(XcodeDestination(platform=platform, identifier=identifier, name=name))
        else:
            malformed_rows.append(stripped)
    return XcodeDestinationAnalysis(
        destinations=destinations,
        recognized_sections=recognized_sections,
        malformed_rows=malformed_rows,
    )


def parse_showdestinations(output: str) -> list[XcodeDestination]:
    return analyze_showdestinations(output).destinations


def analyze_showdestination_streams(stdout: str, stderr: str) -> XcodeDestinationAnalysis:
    stdout_analysis = analyze_showdestinations(stdout)
    if stdout_analysis.recognized_sections:
        return stdout_analysis
    return analyze_showdestinations(stderr)


def showdestinations_format_error(analysis: XcodeDestinationAnalysis) -> str | None:
    if analysis.malformed_rows:
        return "; ".join(analysis.malformed_rows[:3])
    return None


def has_showdestinations_section(output: str) -> bool:
    return re.search(r"(?:Available|Ineligible) destinations for ", output) is not None


def devices_from_destinations(destinations: list[XcodeDestination]) -> list[PhysicalDevice]:
    devices: list[PhysicalDevice] = []
    for destination in destinations:
        if destination.identifier is None or "Simulator" in destination.platform:
            continue
        if destination.name.startswith("Any ") or "placeholder" in destination.identifier:
            continue
        kind = "watch" if "watchOS" in destination.platform else "iphone" if destination.platform == "iOS" else "other"
        if kind == "other":
            continue
        devices.append(
            PhysicalDevice(
                name=destination.name,
                udid=destination.identifier,
                os_version=None,
                kind=kind,
            )
        )
    return devices


def merge_devices(primary: list[PhysicalDevice], secondary: list[PhysicalDevice]) -> list[PhysicalDevice]:
    merged: dict[tuple[str, str], PhysicalDevice] = {}
    for device in [*primary, *secondary]:
        merged[(device.kind, device.udid)] = device
    return list(merged.values())


def reconcile_discovery_gate(discovery_gate: Gate, physical_devices: list[PhysicalDevice]) -> Gate:
    if discovery_gate.status == "fail":
        return discovery_gate
    if not physical_devices:
        return discovery_gate
    summary = ", ".join(f"{device.name} ({device.udid})" for device in physical_devices)
    if discovery_gate.status == "pass":
        return Gate(
            "Physical device discovery",
            "pass",
            f"Detected physical devices: {summary}.",
            "None.",
        )
    return Gate(
        "Physical device discovery",
        "pass",
        f"xctrace did not report devices, but xcodebuild exposes physical destinations: {summary}.",
        "None.",
    )


def show_destinations(scheme: str, commands: list[CommandResult]) -> tuple[Gate, list[XcodeDestination]]:
    result = run_command(
        ["xcodebuild", "-project", str(PROJECT), "-scheme", scheme, "-showdestinations"],
        timeout=120,
    )
    commands.append(result)
    analysis = analyze_showdestination_streams(result.stdout, result.stderr)
    destinations = analysis.destinations
    if result.returncode != 0:
        return (
            Gate(
                f"{scheme} destinations",
                "fail",
                f"xcodebuild failed while resolving destinations for {scheme} (exit {result.returncode}).",
                "Read the captured xcodebuild output and fix the project or toolchain before rerunning.",
            ),
            destinations,
        )
    if analysis.recognized_sections == 0:
        return (
            Gate(
                f"{scheme} destinations",
                "fail",
                f"xcodebuild returned an unrecognized destination-list format for {scheme}.",
                "Fix the Xcode project/toolchain or update the parser before classifying device availability.",
            ),
            destinations,
        )
    format_error = showdestinations_format_error(analysis)
    if format_error is not None:
        return (
            Gate(
                f"{scheme} destinations",
                "fail",
                f"xcodebuild returned unrecognized destination rows for {scheme}: {format_error}.",
                "Fix the Xcode project/toolchain or update the parser before classifying device availability.",
            ),
            destinations,
        )
    return (
        Gate(
            f"{scheme} destinations",
            "pass" if destinations else "blocked",
            f"Resolved {len(destinations)} destinations for {scheme}.",
            "Connect trusted physical devices and resolve provisioning if no physical destinations are listed.",
        ),
        destinations,
    )


def destination_matches(destinations: list[XcodeDestination], device_id: str | None, platform_fragment: str) -> bool:
    if not device_id:
        return False
    for destination in destinations:
        if platform_fragment not in destination.platform:
            continue
        if destination.identifier == device_id:
            return True
    return False


def require_exact_device_id(env_name: str, devices: list[PhysicalDevice], kind: str) -> Gate:
    configured = os.environ.get(env_name, "").strip()
    matching = [device for device in devices if device.kind == kind]
    if configured:
        if any(device.udid == configured for device in matching):
            return Gate(env_name, "pass", f"{env_name} points at a detected {kind} device.", "None.")
        return Gate(
            env_name,
            "blocked",
            f"{env_name} is set but does not match any detected {kind} device.",
            f"Set {env_name} to one of the detected physical {kind} UDIDs.",
        )
    if matching:
        options = ", ".join(f"{device.name}={device.udid}" for device in matching)
        return Gate(
            env_name,
            "blocked",
            f"Detected {kind} device(s), but {env_name} is not set: {options}.",
            f"Export {env_name}=<physical-{kind}-udid> so production proof targets exact hardware.",
        )
    return Gate(
        env_name,
        "blocked",
        f"No physical {kind} device was detected.",
        f"Connect the physical {kind} device, trust it, and export {env_name}=<udid>.",
    )


def check_destination_gate(
    name: str,
    destinations: list[XcodeDestination],
    env_name: str,
    platform_fragment: str,
) -> Gate:
    device_id = os.environ.get(env_name, "").strip()
    if destination_matches(destinations, device_id or None, platform_fragment):
        return Gate(name, "pass", f"xcodebuild exposes {device_id} for {platform_fragment}.", "None.")
    if not device_id:
        return Gate(
            name,
            "blocked",
            f"No exact {env_name} is configured, so generic Xcode destinations are not accepted as physical proof.",
            f"Export {env_name}=<physical-device-udid> and rerun.",
        )
    return Gate(
        name,
        "blocked",
        f"xcodebuild does not expose the configured physical {platform_fragment} destination.",
        "Resolve signing/provisioning, keep the device unlocked and trusted, then rerun.",
    )


def run_physical_build(
    scheme: str,
    destination: str,
    team_id: str,
    derived_data_name: str,
    commands: list[CommandResult],
) -> Gate:
    result = run_command(
        [
            "xcodebuild",
            "-quiet",
            "-project",
            str(PROJECT),
            "-scheme",
            scheme,
            "-configuration",
            "Debug",
            "-derivedDataPath",
            str(ROOT_DIR / derived_data_name),
            "-destination",
            destination,
            f"DEVELOPMENT_TEAM={team_id}",
            "build",
        ],
        timeout=600,
    )
    commands.append(result)
    if result.returncode == 0:
        return Gate(f"{scheme} physical build", "pass", f"{scheme} built for {destination}.", "None.")
    failure = summarize_xcodebuild_failure(result)
    return Gate(
        f"{scheme} physical build",
        "fail",
        f"{scheme} did not build for {destination}. {failure}",
        "Read the captured xcodebuild output, fix signing/provisioning/device trust, and rerun.",
    )


def summarize_xcodebuild_failure(result: CommandResult) -> str:
    combined = "\n".join([result.stdout, result.stderr])
    interesting_patterns = (
        "xcodebuild: error:",
        "error:",
        "No profiles",
        "requires a provisioning profile",
        "may need to be unlocked",
        "Timed out waiting",
    )
    lines = [
        line.strip()
        for line in combined.splitlines()
        if any(pattern in line for pattern in interesting_patterns)
    ]
    if not lines:
        return f"xcodebuild exited with status {result.returncode}."
    return " ".join(dict.fromkeys(lines[-3:]))


def make_report(run_build: bool) -> ReadinessReport:
    commands: list[CommandResult] = []
    gates: list[Gate] = []

    gates.append(generate_project(commands))
    signing_gate, team_id = check_signing_team(commands)
    gates.append(signing_gate)

    discovery_gate, physical_devices = list_physical_devices(commands)

    ios_gate, ios_destinations = show_destinations(IOS_SCHEME, commands)
    watch_gate, watch_destinations = show_destinations(WATCH_SCHEME, commands)
    physical_devices = merge_devices(
        physical_devices,
        devices_from_destinations(ios_destinations + watch_destinations),
    )
    gates.append(reconcile_discovery_gate(discovery_gate, physical_devices))
    gates.append(require_exact_device_id("IDEAFORGE_IOS_DEVICE_ID", physical_devices, "iphone"))
    gates.append(require_exact_device_id("IDEAFORGE_WATCH_DEVICE_ID", physical_devices, "watch"))
    gates.extend([ios_gate, watch_gate])
    gates.append(
        check_destination_gate(
            "iPhone physical destination",
            ios_destinations,
            "IDEAFORGE_IOS_DEVICE_ID",
            "iOS",
        )
    )
    gates.append(
        check_destination_gate(
            "Apple Watch physical destination",
            watch_destinations,
            "IDEAFORGE_WATCH_DEVICE_ID",
            "watchOS",
        )
    )

    if run_build:
        ios_id = os.environ.get("IDEAFORGE_IOS_DEVICE_ID", "").strip()
        watch_id = os.environ.get("IDEAFORGE_WATCH_DEVICE_ID", "").strip()
        if team_id and ios_id:
            gates.append(
                run_physical_build(
                    IOS_SCHEME,
                    f"platform=iOS,id={ios_id}",
                    team_id,
                    "DerivedData-physical-ios",
                    commands,
                )
            )
        else:
            gates.append(
                Gate(
                    f"{IOS_SCHEME} physical build",
                    "blocked",
                    "Skipped because DEVELOPMENT_TEAM or IDEAFORGE_IOS_DEVICE_ID is missing.",
                    "Configure signing and exact iPhone UDID, then rerun with --run-build.",
                )
            )
        if team_id and watch_id:
            gates.append(
                run_physical_build(
                    WATCH_SCHEME,
                    f"platform=watchOS,id={watch_id}",
                    team_id,
                    "DerivedData-physical-watch",
                    commands,
                )
            )
        else:
            gates.append(
                Gate(
                    f"{WATCH_SCHEME} physical build",
                    "blocked",
                    "Skipped because DEVELOPMENT_TEAM or IDEAFORGE_WATCH_DEVICE_ID is missing.",
                    "Configure signing and exact Watch UDID, then rerun with --run-build.",
                )
            )
    else:
        gates.append(
            Gate(
                "Physical build proof",
                "blocked",
                "Preflight ran without --run-build, so no physical iPhone/watchOS build proof was captured.",
                "Run `./script/check_physical_device_readiness.py --run-build` after signing and device IDs are configured.",
            )
        )

    status = aggregate_status(gates)
    command_payload = [
        {
            "command": command.command,
            "returncode": command.returncode,
            "stdout_tail": command.stdout[-4000:],
            "stderr_tail": command.stderr[-4000:],
        }
        for command in commands
    ]
    return ReadinessReport(
        status=status,
        gates=gates,
        physical_devices=physical_devices,
        ios_destinations=ios_destinations,
        watch_destinations=watch_destinations,
        commands=command_payload,
    )


def render_markdown(report: ReadinessReport) -> str:
    lines = [
        "# IdeaForge Physical Device Readiness",
        "",
        f"Status: **{report.status}**",
        "",
        "| Gate | Status | Detail | Remediation |",
        "| --- | --- | --- | --- |",
    ]
    for gate in report.gates:
        lines.append(
            f"| {gate.name} | {gate.status} | {gate.detail.replace('|', '/')} | {gate.remediation.replace('|', '/')} |"
        )
    lines.extend(
        [
            "",
            "## Required Production Proof After This Passes",
            "",
            "- Record on the physical Apple Watch while offline.",
            "- Append a second clip to the same Watch recording without overwriting the first clip.",
            "- Reconnect the paired iPhone and confirm automatic or manual transfer creates pending iPhone work.",
            "- Publish the workspace from iPhone to backend, then verify the Mac applies or conflict-reviews the remote revision.",
            "- Run local speech on the physical iPhone recording and capture quality/permission behavior.",
            "- Capture background/interrupted upload recovery and revoked microphone permission behavior on real devices.",
        ]
    )
    return "\n".join(lines) + "\n"


def write_report_files(report: ReadinessReport, json_path: str | None, markdown_path: str | None) -> None:
    if json_path:
        path = Path(json_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(report), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if markdown_path:
        path = Path(markdown_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(render_markdown(report), encoding="utf-8")


def run_self_test() -> None:
    assert aggregate_status([Gate("offline", "blocked", "", "")]) == "blocked"
    assert aggregate_status([Gate("tool", "fail", "", ""), Gate("offline", "blocked", "", "")]) == "fail"
    assert aggregate_status([Gate("ready", "pass", "", "")]) == "pass"
    assert exit_code_for_status("pass") == 0
    assert exit_code_for_status("blocked") == 2
    assert exit_code_for_status("fail") == 1

    devices = parse_xctrace_devices(
        """
== Devices ==
Sikor MacBook Pro (15.0) (00000000-0000-0000-0000-000000000000)
Rafal iPhone (18.5) (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)
Apple Watch Ultra 3 (11.5) (FFFFFFFF-GGGG-HHHH-IIII-JJJJJJJJJJJJ)
== Simulators ==
iPhone 17 (26.5) (SIM-UDID)
"""
    )
    assert [device.kind for device in devices] == ["iphone", "watch"]
    assert devices[0].udid == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    assert has_xctrace_devices_section("== Devices ==\nMac (MAC-ID)\n")
    assert not has_xctrace_devices_section("unexpected tool output")
    malformed_xctrace = analyze_xctrace_devices(
        """
== Devices ==
Rafal MacBook Pro [MAC-ID]
== Simulators ==
"""
    )
    assert malformed_xctrace.recognized_rows == 0
    assert malformed_xctrace.malformed_rows == ["Rafal MacBook Pro [MAC-ID]"]
    assert xctrace_format_error(malformed_xctrace) == "Rafal MacBook Pro [MAC-ID]"
    empty_xctrace = analyze_xctrace_devices(
        """
== Devices ==
== Simulators ==
"""
    )
    assert xctrace_format_error(empty_xctrace) is None
    mixed_xctrace = analyze_xctrace_devices(
        """
== Devices ==
Rafal MacBook Pro (00000000-0000-0000-0000-000000000000)
Rafal iPhone [AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE]
== Simulators ==
"""
    )
    assert mixed_xctrace.recognized_rows == 1
    assert xctrace_format_error(mixed_xctrace) == "Rafal iPhone [AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE]"

    destinations = parse_showdestinations(
        """
Available destinations for the "IdeaForgeiOS" scheme:
    { platform:iOS, arch:arm64, id:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name:Rafal iPhone }
    { platform:iOS Simulator, id:SIM-UDID, OS:26.5, name:iPhone 17 }
"""
    )
    assert len(destinations) == 2
    assert has_showdestinations_section('Available destinations for the "IdeaForgeiOS" scheme:')
    assert not has_showdestinations_section("unexpected tool output")
    malformed_destinations = analyze_showdestinations(
        """
Available destinations for the "IdeaForgeiOS" scheme:
    [ platform:iOS, id:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name:Rafal iPhone ]
"""
    )
    assert malformed_destinations.destinations == []
    assert malformed_destinations.malformed_rows == [
        "[ platform:iOS, id:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name:Rafal iPhone ]"
    ]
    assert showdestinations_format_error(malformed_destinations) == (
        "[ platform:iOS, id:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name:Rafal iPhone ]"
    )
    empty_destinations = analyze_showdestinations(
        'Available destinations for the "IdeaForgeiOS" scheme:\n'
    )
    assert showdestinations_format_error(empty_destinations) is None
    mixed_destinations = analyze_showdestinations(
        """
Available destinations for the "IdeaForgeiOS" scheme:
    { platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
    [ platform:iOS, id:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name:Rafal iPhone ]
"""
    )
    assert len(mixed_destinations.destinations) == 1
    assert showdestinations_format_error(mixed_destinations) == (
        "[ platform:iOS, id:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name:Rafal iPhone ]"
    )
    stderr_safe_destinations = analyze_showdestination_streams(
        'Available destinations for the "IdeaForgeiOS" scheme:\n'
        "    { platform:iOS, id:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE, name:Rafal iPhone }\n",
        "xcodebuild: warning: unrelated diagnostic\n",
    )
    assert len(stderr_safe_destinations.destinations) == 1
    assert showdestinations_format_error(stderr_safe_destinations) is None

    original_run_command = run_command
    fixture = CommandResult([], 0, "", "")
    try:
        def fixture_run_command(command: Sequence[str], timeout: int = 60) -> CommandResult:
            return CommandResult(list(command), fixture.returncode, fixture.stdout, fixture.stderr)

        globals()["run_command"] = fixture_run_command

        fixture = CommandResult([], 0, "== Devices ==\n== Simulators ==\n", "")
        empty_xctrace_gate, _ = list_physical_devices([])
        assert empty_xctrace_gate.status == "blocked"

        fixture = CommandResult([], 0, "== Devices ==\nRafal iPhone [MALFORMED-ID]\n", "")
        malformed_xctrace_gate, _ = list_physical_devices([])
        assert malformed_xctrace_gate.status == "fail"

        fixture = CommandResult([], 0, 'Available destinations for the "IdeaForgeiOS" scheme:\n', "")
        empty_destinations_gate, _ = show_destinations(IOS_SCHEME, [])
        assert empty_destinations_gate.status == "blocked"

        fixture = CommandResult(
            [],
            0,
            'Available destinations for the "IdeaForgeiOS" scheme:\n'
            "    [ platform:iOS, id:MALFORMED-ID, name:Rafal iPhone ]\n",
            "",
        )
        malformed_destinations_gate, _ = show_destinations(IOS_SCHEME, [])
        assert malformed_destinations_gate.status == "fail"
    finally:
        globals()["run_command"] = original_run_command

    assert destination_matches(destinations, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "iOS")
    assert not destination_matches(destinations, "SIM-UDID", "watchOS")
    destination_devices = devices_from_destinations(destinations)
    assert [device.kind for device in destination_devices] == ["iphone"]
    assert destination_devices[0].udid == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    failed_discovery = Gate("Physical device discovery", "fail", "xctrace failed", "Fix xctrace.")
    assert reconcile_discovery_gate(failed_discovery, destination_devices).status == "fail"

    assert extract_development_team("    DEVELOPMENT_TEAM = 2NY8A789TN\n") == "2NY8A789TN"
    print("check_physical_device_readiness.py self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Run parser and gate self-tests.")
    parser.add_argument("--run-build", action="store_true", help="Run physical iOS/watchOS builds when gates allow it.")
    parser.add_argument("--json", help="Write a JSON readiness report to this path.")
    parser.add_argument("--markdown", help="Write a Markdown readiness report to this path.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    report = make_report(run_build=args.run_build)
    write_report_files(report, args.json, args.markdown)
    print(render_markdown(report))
    return exit_code_for_status(report.status)


if __name__ == "__main__":
    raise SystemExit(main())
