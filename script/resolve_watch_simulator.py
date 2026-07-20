#!/usr/bin/env python3
"""Resolve one exact watchOS Simulator UDID from simctl JSON."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from typing import Any


RUNTIME_PATTERN = re.compile(r"^com\.apple\.CoreSimulator\.SimRuntime\.watchOS-(\d+)-(\d+)$")
UDID_PATTERN = re.compile(r"^[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}$")


@dataclass(frozen=True)
class Simulator:
    name: str
    os_version: str
    udid: str
    state: str

    @property
    def destination(self) -> str:
        return f"platform=watchOS Simulator,id={self.udid}"

    @property
    def summary(self) -> str:
        return f"{self.name} / watchOS {self.os_version} / {self.state} / {self.udid}"


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
    devices = payload.get("devices")
    if not isinstance(devices, dict):
        raise ResolutionError("simctl JSON does not contain a devices object")

    by_udid: dict[str, Simulator] = {}
    for runtime, runtime_devices in devices.items():
        os_version = runtime_os_version(runtime)
        if os_version is None or not isinstance(runtime_devices, list):
            continue
        for device in runtime_devices:
            if not isinstance(device, dict) or not device.get("isAvailable", False):
                continue
            name = device.get("name")
            udid = device.get("udid")
            if not isinstance(name, str) or not isinstance(udid, str) or not UDID_PATTERN.fullmatch(udid):
                continue
            simulator = Simulator(
                name=name,
                os_version=os_version,
                udid=udid,
                state=str(device.get("state", "Unknown")),
            )
            previous = by_udid.get(udid)
            if previous is not None and previous != simulator:
                raise ResolutionError(f"Conflicting simctl records for watchOS simulator UDID {udid}")
            by_udid[udid] = simulator
    return sorted(by_udid.values(), key=lambda item: (item.name, item.os_version, item.udid))


def resolve(
    payload: dict[str, Any],
    name: str,
    os_version: str,
    requested_udid: str | None,
) -> Simulator:
    simulators = flatten_simulators(payload)
    if requested_udid:
        matches = [item for item in simulators if item.udid == requested_udid]
        if len(matches) == 1:
            selected = matches[0]
            if selected.name != name or selected.os_version != os_version:
                raise ResolutionError(
                    f"Watch simulator {requested_udid} is {selected.name} / watchOS "
                    f"{selected.os_version}, expected {name} / watchOS {os_version}",
                    code=2,
                )
            return selected
        raise ResolutionError(
            f"No available watchOS simulator found for exact UDID {requested_udid}",
            code=2,
        )

    matches = [
        item for item in simulators if item.name == name and item.os_version == os_version
    ]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        options = "\n".join(f"- {item.summary}" for item in matches)
        raise ResolutionError(
            f"Ambiguous watchOS simulator selection for {name} / watchOS {os_version}; "
            f"multiple distinct UDIDs matched:\n{options}",
            code=3,
        )
    available = "\n".join(f"- {item.summary}" for item in simulators)
    raise ResolutionError(
        f"No available watchOS simulator found for {name} / watchOS {os_version}.\n"
        f"Available watchOS simulators:\n{available}",
        code=2,
    )


def load_payload(path: str | None) -> dict[str, Any]:
    try:
        if path:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        return json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as error:
        raise ResolutionError(f"Unable to read simctl JSON: {error}") from error


def fixture(*udids: str) -> dict[str, Any]:
    return {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [
                {
                    "isAvailable": True,
                    "name": "Apple Watch Ultra 3 (49mm)",
                    "udid": udid,
                    "state": "Shutdown",
                }
                for udid in udids
            ]
        }
    }


def run_self_test() -> None:
    first = "013B508D-6AF3-4C83-AB8D-D9EA3ED42ACE"
    second = "113B508D-6AF3-4C83-AB8D-D9EA3ED42ACE"

    selected = resolve(fixture(first), "Apple Watch Ultra 3 (49mm)", "26.5", None)
    assert selected.destination == f"platform=watchOS Simulator,id={first}"

    duplicate_representation = fixture(first, first)
    assert resolve(duplicate_representation, "Apple Watch Ultra 3 (49mm)", "26.5", None).udid == first
    assert resolve(fixture(first), "Apple Watch Ultra 3 (49mm)", "26.5", first).udid == first

    try:
        resolve(fixture(first), "Apple Watch Series 11 (46mm)", "26.5", first)
    except ResolutionError as error:
        assert error.code == 2
        assert "expected Apple Watch Series 11 (46mm)" in str(error)
    else:
        raise AssertionError("exact UDID bypassed the requested Watch model")

    wrong_os_payload = {
        "devices": {
            "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [
                {
                    "isAvailable": True,
                    "name": "Apple Watch Ultra 3 (49mm)",
                    "udid": first,
                    "state": "Shutdown",
                }
            ]
        }
    }
    try:
        resolve(wrong_os_payload, "Apple Watch Ultra 3 (49mm)", "26.5", first)
    except ResolutionError as error:
        assert error.code == 2
        assert "watchOS 27.0" in str(error)
    else:
        raise AssertionError("exact UDID bypassed the requested watchOS version")

    for payload, expected_code in ((fixture(), 2), (fixture(first, second), 3)):
        try:
            resolve(payload, "Apple Watch Ultra 3 (49mm)", "26.5", None)
        except ResolutionError as error:
            assert error.code == expected_code
        else:
            raise AssertionError("watchOS simulator resolution did not fail closed")

    invalid_udid = fixture("not-a-real-udid")
    try:
        resolve(invalid_udid, "Apple Watch Ultra 3 (49mm)", "26.5", None)
    except ResolutionError as error:
        assert error.code == 2
    else:
        raise AssertionError("invalid simulator UDID was accepted")

    print("resolve_watch_simulator.py self-test passed")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="Apple Watch Ultra 3 (49mm)")
    parser.add_argument("--os", default="26.5")
    parser.add_argument("--udid", help="Exact available watchOS simulator UDID")
    parser.add_argument("--json", help="Path to simctl devices JSON; stdin is used when omitted")
    parser.add_argument(
        "--format",
        choices=("destination", "summary", "udid"),
        default="destination",
    )
    parser.add_argument("--self-test", action="store_true")
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
