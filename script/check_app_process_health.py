#!/usr/bin/env python3
"""Fail-closed IdeaForge macOS and simulator process cleanup check."""

from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import dataclass
from typing import Sequence


IOS_BUNDLE_ID = "com.s1kor.ideaforge.ios"
WATCH_BUNDLE_ID = "com.s1kor.ideaforge.ios.watch"


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class CleanupClassification:
    status: str
    detail: str


def run_command(command: Sequence[str], timeout: int = 30) -> CommandResult:
    try:
        completed = subprocess.run(
            list(command),
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)
    except FileNotFoundError as error:
        return CommandResult(127, "", str(error))
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        stderr = error.stderr if isinstance(error.stderr, str) else ""
        return CommandResult(124, stdout, stderr or f"timed out after {timeout}s")


def classify_simulator_cleanup(
    before_query_returncode: int,
    running_before: bool,
    terminate_returncode: int | None,
    after_query_returncode: int,
    running_after: bool,
) -> CleanupClassification:
    if before_query_returncode != 0:
        return CleanupClassification("fail", "simulator process-state query failed before cleanup")
    if running_before and terminate_returncode != 0:
        return CleanupClassification("fail", "simulator app termination command failed")
    if after_query_returncode != 0:
        return CleanupClassification("fail", "simulator process-state query failed after cleanup")
    if running_after:
        return CleanupClassification("fail", "simulator app remains registered after cleanup")
    return CleanupClassification("pass", "simulator app is not running")


def bundle_is_running(launchctl_output: str, bundle_id: str) -> bool:
    return any(
        f"UIKitApplication:{bundle_id}[" in line or line.rstrip().endswith(bundle_id)
        for line in launchctl_output.splitlines()
    )


def list_booted_simulators() -> tuple[list[str], str | None]:
    result = run_command(["xcrun", "simctl", "list", "devices", "booted", "--json"])
    if result.returncode != 0:
        return [], "simctl could not list booted simulators"
    try:
        payload = json.loads(result.stdout)
        identifiers = [
            device["udid"]
            for devices in payload.get("devices", {}).values()
            for device in devices
            if device.get("state") == "Booted" and isinstance(device.get("udid"), str)
        ]
    except (json.JSONDecodeError, KeyError, TypeError):
        return [], "simctl returned malformed booted-simulator JSON"
    return identifiers, None


def clean_simulator(simulator_id: str) -> list[str]:
    failures: list[str] = []
    before = run_command(["xcrun", "simctl", "spawn", simulator_id, "launchctl", "list"])
    running_before = {
        bundle_id: bundle_is_running(before.stdout, bundle_id)
        for bundle_id in (IOS_BUNDLE_ID, WATCH_BUNDLE_ID)
    }
    terminate_results: dict[str, int | None] = {IOS_BUNDLE_ID: None, WATCH_BUNDLE_ID: None}
    if before.returncode == 0:
        for bundle_id, is_running in running_before.items():
            if is_running:
                terminate_results[bundle_id] = run_command(
                    ["xcrun", "simctl", "terminate", simulator_id, bundle_id]
                ).returncode

    after = run_command(["xcrun", "simctl", "spawn", simulator_id, "launchctl", "list"])
    for bundle_id in (IOS_BUNDLE_ID, WATCH_BUNDLE_ID):
        classification = classify_simulator_cleanup(
            before.returncode,
            running_before[bundle_id],
            terminate_results[bundle_id],
            after.returncode,
            bundle_is_running(after.stdout, bundle_id),
        )
        if classification.status != "pass":
            failures.append(f"{simulator_id} {bundle_id}: {classification.detail}")
    return failures


def clean_macos_app() -> list[str]:
    before = run_command(["pgrep", "-x", "IdeaForge"])
    if before.returncode not in (0, 1):
        return ["macOS IdeaForge process query failed before cleanup"]
    if before.returncode == 0:
        terminated = run_command(["pkill", "-x", "IdeaForge"])
        if terminated.returncode != 0:
            return ["macOS IdeaForge termination command failed"]
    after = run_command(["pgrep", "-x", "IdeaForge"])
    if after.returncode not in (0, 1):
        return ["macOS IdeaForge process query failed after cleanup"]
    if after.returncode == 0:
        return ["macOS IdeaForge process remains after cleanup"]
    return []


def check_process_health() -> list[str]:
    failures = clean_macos_app()
    simulator_ids, discovery_error = list_booted_simulators()
    if discovery_error:
        failures.append(discovery_error)
        return failures
    for simulator_id in simulator_ids:
        failures.extend(clean_simulator(simulator_id))
    return failures


def run_self_test() -> None:
    assert classify_simulator_cleanup(0, False, None, 0, False).status == "pass"
    assert classify_simulator_cleanup(0, True, 0, 0, False).status == "pass"
    assert classify_simulator_cleanup(0, True, 1, 0, True).status == "fail"
    assert classify_simulator_cleanup(0, True, 1, 0, False).status == "fail"
    assert classify_simulator_cleanup(0, True, 0, 0, True).status == "fail"
    assert classify_simulator_cleanup(1, False, None, 0, False).status == "fail"
    assert classify_simulator_cleanup(0, False, None, 1, False).status == "fail"
    assert bundle_is_running(
        "123\t0\tUIKitApplication:com.s1kor.ideaforge.ios[942b][rb-legacy]",
        IOS_BUNDLE_ID,
    )
    assert not bundle_is_running("-\t0\tcom.apple.Preferences", IOS_BUNDLE_ID)
    print("check_app_process_health.py self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        run_self_test()
        return 0
    failures = check_process_health()
    if failures:
        print("IdeaForge process health: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("IdeaForge process health: PASS")
    print("- No IdeaForge macOS process remains.")
    print("- Every booted simulator reports no running IdeaForge iOS or Watch app bundle.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
