#!/usr/bin/env python3
"""Resolve one iOS Simulator destination from `simctl list devices --json`."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from typing import Any


RUNTIME_PATTERN = re.compile(r"^com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)$")


@dataclass(frozen=True)
class Simulator:
    name: str
    os_version: str
    runtime: str
    udid: str
    state: str

    @property
    def destination(self) -> str:
        return f"platform=iOS Simulator,id={self.udid}"

    @property
    def summary(self) -> str:
        return f"{self.name} / iOS {self.os_version} / {self.state} / {self.udid}"


class ResolutionError(Exception):
    def __init__(self, message: str, code: int = 1) -> None:
        super().__init__(message)
        self.code = code


def runtime_os_version(runtime: str) -> str | None:
    match = RUNTIME_PATTERN.match(runtime)
    if match is None:
        return None
    return f"{match.group(1)}.{match.group(2)}"


def flatten_simulators(payload: dict[str, Any]) -> list[Simulator]:
    simulators: list[Simulator] = []
    devices = payload.get("devices")
    if not isinstance(devices, dict):
        raise ResolutionError("simctl JSON does not contain a devices object")

    for runtime, runtime_devices in devices.items():
        os_version = runtime_os_version(runtime)
        if os_version is None:
            continue
        if not isinstance(runtime_devices, list):
            continue
        for device in runtime_devices:
            if not isinstance(device, dict):
                continue
            if not device.get("isAvailable", False):
                continue
            name = device.get("name")
            udid = device.get("udid")
            state = device.get("state", "Unknown")
            if isinstance(name, str) and isinstance(udid, str):
                simulators.append(
                    Simulator(
                        name=name,
                        os_version=os_version,
                        runtime=runtime,
                        udid=udid,
                        state=str(state),
                    )
                )
    return simulators


def resolve_by_udid(simulators: list[Simulator], udid: str) -> Simulator:
    matches = [simulator for simulator in simulators if simulator.udid == udid]
    if len(matches) == 1:
        return matches[0]
    raise ResolutionError(f"No available iOS simulator found for UDID {udid}", code=2)


def resolve_by_name_and_os(simulators: list[Simulator], name: str, os_version: str) -> Simulator:
    matches = [
        simulator
        for simulator in simulators
        if simulator.name == name and simulator.os_version == os_version
    ]
    matches.sort(key=lambda simulator: (simulator.name, simulator.os_version, simulator.udid))

    if len(matches) == 1:
        return matches[0]

    if len(matches) > 1:
        options = "\n".join(f"- {simulator.summary}" for simulator in matches)
        raise ResolutionError(
            f"Ambiguous iOS simulator selection for {name} / iOS {os_version}:\n{options}",
            code=3,
        )

    available = "\n".join(f"- {simulator.summary}" for simulator in simulators)
    raise ResolutionError(
        f"No available iOS simulator found for {name} / iOS {os_version}.\n"
        f"Available iOS simulators:\n{available}",
        code=2,
    )


def load_payload(path: str | None) -> dict[str, Any]:
    try:
        if path:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        return json.load(sys.stdin)
    except json.JSONDecodeError as error:
        raise ResolutionError(f"Invalid simctl JSON: {error}") from error


def resolve(payload: dict[str, Any], name: str, os_version: str, udid: str | None) -> Simulator:
    simulators = flatten_simulators(payload)
    if udid:
        return resolve_by_udid(simulators, udid)
    return resolve_by_name_and_os(simulators, name, os_version)


def run_self_test() -> None:
    fixture = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [
                {"isAvailable": True, "name": "Apple Watch", "udid": "WATCH", "state": "Shutdown"}
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"isAvailable": True, "name": "iPhone 17", "udid": "IPHONE-17-265", "state": "Shutdown"},
                {"isAvailable": True, "name": "iPhone 17 Pro", "udid": "IPHONE-17-PRO", "state": "Booted"},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [
                {"isAvailable": True, "name": "iPhone 17", "udid": "IPHONE-17-262", "state": "Shutdown"}
            ],
        }
    }

    selected = resolve(fixture, "iPhone 17", "26.5", None)
    assert selected.udid == "IPHONE-17-265"
    assert selected.destination == "platform=iOS Simulator,id=IPHONE-17-265"

    selected_by_udid = resolve(fixture, "unused", "0.0", "IPHONE-17-PRO")
    assert selected_by_udid.name == "iPhone 17 Pro"

    duplicate_fixture = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"isAvailable": True, "name": "iPhone 17", "udid": "A", "state": "Shutdown"},
                {"isAvailable": True, "name": "iPhone 17", "udid": "B", "state": "Shutdown"},
            ]
        }
    }
    try:
        resolve(duplicate_fixture, "iPhone 17", "26.5", None)
    except ResolutionError as error:
        assert error.code == 3
    else:
        raise AssertionError("duplicate simulator selection did not fail closed")

    print("resolve_ios_simulator.py self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="iPhone 17", help="Exact simulator device name")
    parser.add_argument("--os", default="26.5", help="Exact iOS runtime version, for example 26.5")
    parser.add_argument("--udid", help="Exact simulator UDID to validate and use")
    parser.add_argument("--json", help="Path to simctl JSON; stdin is used when omitted")
    parser.add_argument(
        "--format",
        choices=("destination", "summary", "udid"),
        default="destination",
        help="Output format",
    )
    parser.add_argument("--self-test", action="store_true", help="Run built-in resolver tests")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        run_self_test()
        return 0

    try:
        selected = resolve(load_payload(args.json), args.name, args.os, args.udid)
    except ResolutionError as error:
        print(error, file=sys.stderr)
        return error.code

    if args.format == "summary":
        print(selected.summary)
    elif args.format == "udid":
        print(selected.udid)
    else:
        print(selected.destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
