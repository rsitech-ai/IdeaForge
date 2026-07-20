#!/usr/bin/env python3
"""Fail-closed APNs sender/delivery readiness gate for IdeaForge."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Mapping


class APNSDeliveryCheckError(RuntimeError):
    """Raised when APNs delivery proof cannot be trusted."""


KNOWN_TOPICS = {"workspace_sync", "recording_processing", "account"}
DEFAULT_BUNDLE_ID = "com.s1kor.ideaforge.ios"


@dataclass(frozen=True)
class APNSDeliveryConfig:
    environment: str
    team_id: str
    key_id: str
    auth_key_path: Path
    bundle_id: str
    device_token: str
    workspace_id: str
    topics: tuple[str, ...]
    remote_updated_at: str | None = None

    @property
    def endpoint_host(self) -> str:
        if self.environment == "production":
            return "api.push.apple.com"
        return "api.sandbox.push.apple.com"

    @property
    def endpoint_url(self) -> str:
        return f"https://{self.endpoint_host}/3/device/{self.device_token}"


def _required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise APNSDeliveryCheckError(f"{name} is required")
    return value


def _fingerprint(value: str, length: int = 16) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def _validate_identifier(name: str, value: str) -> None:
    if not re.fullmatch(r"[A-Z0-9]{10}", value):
        raise APNSDeliveryCheckError(f"{name} must be a 10-character Apple identifier")


def _validate_bundle_id(value: str) -> None:
    if value != DEFAULT_BUNDLE_ID:
        raise APNSDeliveryCheckError(f"APNS_BUNDLE_ID must be {DEFAULT_BUNDLE_ID}")


def _validate_device_token(value: str) -> str:
    normalized = value.strip().lower()
    if not normalized or len(normalized) < 64 or len(normalized) % 2 != 0:
        raise APNSDeliveryCheckError("APNS_DEVICE_TOKEN must be a hex APNs device token")
    if not all(character in "0123456789abcdef" for character in normalized):
        raise APNSDeliveryCheckError("APNS_DEVICE_TOKEN must contain only hex characters")
    if len(set(normalized)) == 1:
        raise APNSDeliveryCheckError("APNS_DEVICE_TOKEN must not be a placeholder token")
    return normalized


def _validate_workspace_id(value: str) -> None:
    lower = value.lower()
    if value == "local-dev-workspace" or lower.startswith(("local", "dev", "test", "fixture", "example")):
        raise APNSDeliveryCheckError("IDEAFORGE_APNS_WORKSPACE_ID must not be a local fixture")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}", value):
        raise APNSDeliveryCheckError("IDEAFORGE_APNS_WORKSPACE_ID has an unsupported format")


def _validate_auth_key(path: Path) -> None:
    if not path.is_absolute():
        raise APNSDeliveryCheckError("APNS_AUTH_KEY_P8_PATH must be absolute")
    if not path.is_file():
        raise APNSDeliveryCheckError("APNS_AUTH_KEY_P8_PATH must point to an existing .p8 private key")
    preview = path.read_text(encoding="utf-8", errors="ignore")[:2048]
    if "PRIVATE KEY" not in preview:
        raise APNSDeliveryCheckError("APNS_AUTH_KEY_P8_PATH does not look like an APNs private key")


def _parse_topics(raw: str) -> tuple[str, ...]:
    values = []
    for item in raw.split(","):
        topic = item.strip()
        if not topic:
            continue
        if topic not in KNOWN_TOPICS:
            raise APNSDeliveryCheckError(f"Unsupported APNs IdeaForge topic: {topic}")
        if topic not in values:
            values.append(topic)
    if not values:
        raise APNSDeliveryCheckError("IDEAFORGE_APNS_TOPICS must include at least one topic")
    return tuple(values)


def load_config(env: Mapping[str, str], *, allow_sandbox: bool = False) -> APNSDeliveryConfig:
    environment = _required(env, "APNS_ENVIRONMENT")
    if environment not in {"production", "sandbox"}:
        raise APNSDeliveryCheckError("APNS_ENVIRONMENT must be production or sandbox")
    if environment != "production" and not allow_sandbox:
        raise APNSDeliveryCheckError("APNS_ENVIRONMENT must be production for release delivery proof")

    team_id = _required(env, "APNS_TEAM_ID")
    key_id = _required(env, "APNS_KEY_ID")
    _validate_identifier("APNS_TEAM_ID", team_id)
    _validate_identifier("APNS_KEY_ID", key_id)

    auth_key_path = Path(_required(env, "APNS_AUTH_KEY_P8_PATH")).expanduser()
    _validate_auth_key(auth_key_path)

    bundle_id = env.get("APNS_BUNDLE_ID", DEFAULT_BUNDLE_ID).strip() or DEFAULT_BUNDLE_ID
    _validate_bundle_id(bundle_id)

    device_token = _validate_device_token(_required(env, "APNS_DEVICE_TOKEN"))

    workspace_id = _required(env, "IDEAFORGE_APNS_WORKSPACE_ID")
    _validate_workspace_id(workspace_id)

    topics = _parse_topics(env.get("IDEAFORGE_APNS_TOPICS", "workspace_sync,recording_processing"))
    remote_updated_at = env.get("IDEAFORGE_APNS_REMOTE_UPDATED_AT", "").strip() or None

    return APNSDeliveryConfig(
        environment=environment,
        team_id=team_id,
        key_id=key_id,
        auth_key_path=auth_key_path,
        bundle_id=bundle_id,
        device_token=device_token,
        workspace_id=workspace_id,
        topics=topics,
        remote_updated_at=remote_updated_at,
    )


def _base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _read_der_length(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise APNSDeliveryCheckError("Malformed ECDSA signature")
    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    count = first & 0x7F
    if count == 0 or count > 2 or offset + count > len(data):
        raise APNSDeliveryCheckError("Malformed ECDSA signature length")
    length = int.from_bytes(data[offset:offset + count], "big")
    return length, offset + count


def der_ecdsa_signature_to_raw(der: bytes) -> bytes:
    offset = 0
    if not der or der[offset] != 0x30:
        raise APNSDeliveryCheckError("ECDSA signature must be a DER sequence")
    offset += 1
    sequence_length, offset = _read_der_length(der, offset)
    if offset + sequence_length != len(der):
        raise APNSDeliveryCheckError("ECDSA signature sequence length mismatch")

    values = []
    for _ in range(2):
        if offset >= len(der) or der[offset] != 0x02:
            raise APNSDeliveryCheckError("ECDSA signature missing integer component")
        offset += 1
        integer_length, offset = _read_der_length(der, offset)
        integer_bytes = der[offset:offset + integer_length]
        offset += integer_length
        integer_bytes = integer_bytes.lstrip(b"\x00")
        if not integer_bytes or len(integer_bytes) > 32:
            raise APNSDeliveryCheckError("ECDSA signature integer has unsupported size")
        values.append(integer_bytes.rjust(32, b"\x00"))
    return b"".join(values)


def build_provider_jwt(config: APNSDeliveryConfig, *, issued_at: int | None = None) -> str:
    issued_at = int(time.time()) if issued_at is None else issued_at
    header = {"alg": "ES256", "kid": config.key_id}
    claims = {"iss": config.team_id, "iat": issued_at}
    signing_input = ".".join(
        [
            _base64url(json.dumps(header, separators=(",", ":"), sort_keys=True).encode("utf-8")),
            _base64url(json.dumps(claims, separators=(",", ":"), sort_keys=True).encode("utf-8")),
        ]
    )
    process = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(config.auth_key_path)],
        input=signing_input.encode("ascii"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise APNSDeliveryCheckError("OpenSSL could not sign the APNs provider token")
    signature = der_ecdsa_signature_to_raw(process.stdout)
    return f"{signing_input}.{_base64url(signature)}"


def build_payload(config: APNSDeliveryConfig) -> dict[str, Any]:
    envelope: dict[str, Any] = {
        "workspaceID": config.workspace_id,
        "topics": list(config.topics),
    }
    if config.remote_updated_at:
        envelope["remoteUpdatedAt"] = config.remote_updated_at
    return {
        "aps": {"content-available": 1},
        "ideaforge": envelope,
    }


def _curl_supports_http2() -> bool:
    process = subprocess.run(
        ["curl", "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        return False
    return "HTTP2" in process.stdout or "HTTP/2" in process.stdout


def send_apns_push(config: APNSDeliveryConfig) -> dict[str, Any]:
    if not _curl_supports_http2():
        raise APNSDeliveryCheckError("curl with HTTP/2 support is required for APNs delivery proof")

    token = build_provider_jwt(config)
    payload = json.dumps(build_payload(config), separators=(",", ":"), sort_keys=True)
    with TemporaryDirectory() as temp_root:
        root = Path(temp_root)
        payload_path = root / "payload.json"
        headers_path = root / "headers.txt"
        body_path = root / "body.json"
        payload_path.write_text(payload, encoding="utf-8")
        process = subprocess.run(
            [
                "curl",
                "--http2",
                "--silent",
                "--show-error",
                "--request",
                "POST",
                "--dump-header",
                str(headers_path),
                "--output",
                str(body_path),
                "--write-out",
                "%{http_code}",
                "--header",
                f"authorization: bearer {token}",
                "--header",
                f"apns-topic: {config.bundle_id}",
                "--header",
                "apns-push-type: background",
                "--header",
                "apns-priority: 5",
                "--header",
                "apns-expiration: 0",
                "--header",
                "content-type: application/json",
                "--data-binary",
                f"@{payload_path}",
                config.endpoint_url,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if process.returncode != 0:
            raise APNSDeliveryCheckError("APNs curl request failed before a response was accepted")
        status_code = process.stdout.strip()
        headers = headers_path.read_text(encoding="utf-8", errors="ignore")
        body = body_path.read_text(encoding="utf-8", errors="ignore").strip()
        apns_id = ""
        for line in headers.splitlines():
            if line.lower().startswith("apns-id:"):
                apns_id = line.split(":", 1)[1].strip()
                break
        reason = ""
        if body:
            try:
                reason = str(json.loads(body).get("reason", ""))
            except json.JSONDecodeError:
                reason = "non_json_response"
        return {
            "statusCode": status_code,
            "accepted": status_code == "200",
            "apnsID": apns_id,
            "reason": reason,
        }


def readiness_report(config: APNSDeliveryConfig, *, send_result: dict[str, Any] | None = None) -> dict[str, Any]:
    if send_result is None:
        status = "ready"
    else:
        status = "accepted" if send_result.get("accepted") else "rejected"
    return {
        "status": status,
        "environment": config.environment,
        "endpointHost": config.endpoint_host,
        "bundleID": config.bundle_id,
        "teamFingerprint": _fingerprint(config.team_id),
        "keyFingerprint": _fingerprint(config.key_id),
        "authKeyFingerprint": _fingerprint(str(config.auth_key_path.resolve())),
        "deviceTokenFingerprint": _fingerprint(config.device_token),
        "workspaceFingerprint": _fingerprint(config.workspace_id),
        "topics": list(config.topics),
        "payloadShape": "silent-content-available-ideaforge-envelope",
        "curlHTTP2Available": _curl_supports_http2(),
        "apns": send_result,
    }


def render_report(report: dict[str, Any]) -> str:
    lines = [
        "# IdeaForge APNs Delivery Readiness",
        "",
        f"- Status: {report['status']}",
        f"- Environment: {report['environment']}",
        f"- Endpoint host: {report['endpointHost']}",
        f"- Bundle ID: {report['bundleID']}",
        f"- Team fingerprint: {report['teamFingerprint']}",
        f"- Key fingerprint: {report['keyFingerprint']}",
        f"- Auth key fingerprint: {report['authKeyFingerprint']}",
        f"- Device token fingerprint: {report['deviceTokenFingerprint']}",
        f"- Workspace fingerprint: {report['workspaceFingerprint']}",
        f"- Topics: {', '.join(report['topics'])}",
        f"- Payload shape: {report['payloadShape']}",
        f"- curl HTTP/2 available: {str(report['curlHTTP2Available']).lower()}",
    ]
    if report.get("apns"):
        apns = report["apns"]
        lines.extend(
            [
                f"- APNs status code: {apns.get('statusCode')}",
                f"- APNs accepted: {str(apns.get('accepted')).lower()}",
                f"- APNs ID: {apns.get('apnsID') or 'none'}",
                f"- APNs reason: {apns.get('reason') or 'none'}",
            ]
        )
    lines.append("")
    return "\n".join(lines)


def write_report(report: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix == ".json":
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        path.write_text(render_report(report), encoding="utf-8")


def _self_test_key(path: Path) -> None:
    process = subprocess.run(
        ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if process.returncode != 0:
        raise AssertionError("OpenSSL EC key generation failed for self-test")


def run_self_test() -> None:
    der_signature = bytes.fromhex(
        "3045022100ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "02200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    )
    raw_signature = der_ecdsa_signature_to_raw(der_signature)
    assert len(raw_signature) == 64
    assert raw_signature[:32] == bytes.fromhex("ff" * 32)
    assert raw_signature[32:] == bytes.fromhex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")

    with TemporaryDirectory() as temp_root:
        root = Path(temp_root)
        key_path = root / "AuthKey_AB12CD34EF.p8"
        _self_test_key(key_path)
        env = {
            "APNS_ENVIRONMENT": "production",
            "APNS_TEAM_ID": "ABCDE12345",
            "APNS_KEY_ID": "AB12CD34EF",
            "APNS_AUTH_KEY_P8_PATH": str(key_path),
            "APNS_BUNDLE_ID": DEFAULT_BUNDLE_ID,
            "APNS_DEVICE_TOKEN": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "IDEAFORGE_APNS_WORKSPACE_ID": "workspace-prod-01",
            "IDEAFORGE_APNS_TOPICS": "workspace_sync,recording_processing,workspace_sync",
            "IDEAFORGE_APNS_REMOTE_UPDATED_AT": "2026-07-02T12:00:00Z",
        }
        config = load_config(env)
        jwt = build_provider_jwt(config, issued_at=1_789_000_000)
        assert jwt.count(".") == 2
        payload = build_payload(config)
        assert payload["aps"] == {"content-available": 1}
        assert payload["ideaforge"]["topics"] == ["workspace_sync", "recording_processing"]
        report = readiness_report(config)
        serialized = json.dumps(report, sort_keys=True)
        assert env["APNS_DEVICE_TOKEN"] not in serialized
        assert str(key_path) not in serialized
        assert report["deviceTokenFingerprint"]

        negative_cases = {
            "sandbox without allowance": {"APNS_ENVIRONMENT": "sandbox"},
            "bad team": {"APNS_TEAM_ID": "TEAM"},
            "bad bundle": {"APNS_BUNDLE_ID": "com.example.app"},
            "bad token": {"APNS_DEVICE_TOKEN": "0" * 64},
            "local workspace": {"IDEAFORGE_APNS_WORKSPACE_ID": "local-dev-workspace"},
            "unknown topic": {"IDEAFORGE_APNS_TOPICS": "workspace_sync,raw_transcript"},
            "relative key": {"APNS_AUTH_KEY_P8_PATH": "AuthKey_AB12CD34EF.p8"},
        }
        for name, override in negative_cases.items():
            bad_env = dict(env)
            bad_env.update(override)
            try:
                load_config(bad_env)
            except APNSDeliveryCheckError:
                continue
            raise AssertionError(f"negative case unexpectedly passed: {name}")
        sandbox_env = dict(env)
        sandbox_env["APNS_ENVIRONMENT"] = "sandbox"
        assert load_config(sandbox_env, allow_sandbox=True).endpoint_host == "api.sandbox.push.apple.com"

    print("IdeaForge APNs delivery readiness self-test passed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Check IdeaForge APNs delivery readiness.")
    parser.add_argument("--allow-sandbox", action="store_true", help="Allow sandbox APNs checks; not release proof.")
    parser.add_argument("--send", action="store_true", help="Send the silent push to APNs using live credentials.")
    parser.add_argument("--report")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return

    try:
        config = load_config(os.environ, allow_sandbox=args.allow_sandbox)
        send_result = send_apns_push(config) if args.send else None
        report = readiness_report(config, send_result=send_result)
    except APNSDeliveryCheckError as error:
        raise SystemExit(f"APNs delivery readiness failed: {error}") from error

    if args.report:
        write_report(report, Path(args.report))
    else:
        print(render_report(report), end="")

    if args.send and not (send_result or {}).get("accepted"):
        raise SystemExit(2)


if __name__ == "__main__":
    main()
