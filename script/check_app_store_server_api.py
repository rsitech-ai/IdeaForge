#!/usr/bin/env python3
"""Fail-closed App Store Server API credential smoke for IdeaForge."""

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
from typing import Any, Callable, Mapping
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from mock_backend import AppStoreTransactionJWSVerifier, openssl_signed_app_store_transaction_jws


DEFAULT_BUNDLE_ID = "com.s1kor.ideaforge.ios"
DEFAULT_PRODUCT_IDS = ("com.s1kor.ideaforge.pro.monthly", "com.s1kor.ideaforge.pro.yearly")
APPLE_JWT_AUDIENCE = "appstoreconnect-v1"


class AppStoreServerAPICheckError(RuntimeError):
    """Raised when App Store Server API proof is missing or unsafe."""


@dataclass(frozen=True)
class AppStoreServerAPIConfig:
    environment: str
    issuer_id: str
    key_id: str
    private_key_path: Path
    bundle_id: str
    transaction_id: str
    expected_product_ids: tuple[str, ...]
    timeout_seconds: float
    root_ca_pem_path: Path

    @property
    def endpoint_host(self) -> str:
        if self.environment == "production":
            return "api.storekit.itunes.apple.com"
        return "api.storekit-sandbox.itunes.apple.com"

    @property
    def transaction_url(self) -> str:
        return f"https://{self.endpoint_host}/inApps/v1/transactions/{self.transaction_id}"


RequestJSON = Callable[[str, dict[str, str], float], tuple[int, dict[str, Any]]]


def _fingerprint(value: str | bytes, length: int = 16) -> str:
    data = value if isinstance(value, bytes) else value.encode("utf-8")
    return hashlib.sha256(data).hexdigest()[:length]


def _required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise AppStoreServerAPICheckError(f"{name} is required")
    return value


def _base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _base64url_json(payload: Mapping[str, Any]) -> str:
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return _base64url(encoded)


def _decode_base64url_json(segment: str) -> dict[str, Any]:
    padding = "=" * ((4 - len(segment) % 4) % 4)
    data = base64.urlsafe_b64decode((segment + padding).encode("ascii"))
    payload = json.loads(data.decode("utf-8"))
    if not isinstance(payload, dict):
        raise AppStoreServerAPICheckError("JWT segment is not a JSON object")
    return payload


def _read_der_length(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise AppStoreServerAPICheckError("Malformed ECDSA signature")
    first = data[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    count = first & 0x7F
    if count == 0 or count > 2 or offset + count > len(data):
        raise AppStoreServerAPICheckError("Malformed ECDSA signature length")
    return int.from_bytes(data[offset:offset + count], "big"), offset + count


def der_ecdsa_signature_to_raw(der: bytes) -> bytes:
    offset = 0
    if not der or der[offset] != 0x30:
        raise AppStoreServerAPICheckError("ECDSA signature must be a DER sequence")
    offset += 1
    sequence_length, offset = _read_der_length(der, offset)
    if offset + sequence_length != len(der):
        raise AppStoreServerAPICheckError("ECDSA signature sequence length mismatch")

    values: list[bytes] = []
    for _ in range(2):
        if offset >= len(der) or der[offset] != 0x02:
            raise AppStoreServerAPICheckError("ECDSA signature missing integer component")
        offset += 1
        integer_length, offset = _read_der_length(der, offset)
        integer_bytes = der[offset:offset + integer_length].lstrip(b"\x00")
        offset += integer_length
        if not integer_bytes or len(integer_bytes) > 32:
            raise AppStoreServerAPICheckError("ECDSA signature integer has unsupported size")
        values.append(integer_bytes.rjust(32, b"\x00"))
    return b"".join(values)


def _validate_environment(value: str, *, allow_sandbox: bool) -> str:
    environment = value.strip()
    if environment not in {"production", "sandbox"}:
        raise AppStoreServerAPICheckError("APP_STORE_SERVER_ENVIRONMENT must be production or sandbox")
    if environment != "production" and not allow_sandbox:
        raise AppStoreServerAPICheckError("APP_STORE_SERVER_ENVIRONMENT must be production for release proof")
    return environment


def _validate_issuer_id(value: str) -> str:
    issuer_id = value.strip()
    if not re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        issuer_id,
    ):
        raise AppStoreServerAPICheckError("APP_STORE_ISSUER_ID must be an App Store Connect issuer UUID")
    if issuer_id.lower() in {"00000000-0000-0000-0000-000000000000"}:
        raise AppStoreServerAPICheckError("APP_STORE_ISSUER_ID must not be a placeholder")
    return issuer_id


def _validate_key_id(value: str) -> str:
    key_id = value.strip()
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
        raise AppStoreServerAPICheckError("APP_STORE_KEY_ID must be a 10-character Apple key identifier")
    if len(set(key_id)) == 1:
        raise AppStoreServerAPICheckError("APP_STORE_KEY_ID must not be a placeholder")
    return key_id


def _validate_private_key(path: Path) -> Path:
    if not path.is_absolute():
        raise AppStoreServerAPICheckError("APP_STORE_PRIVATE_KEY_P8_PATH must be absolute")
    if not path.is_file():
        raise AppStoreServerAPICheckError("APP_STORE_PRIVATE_KEY_P8_PATH must point to an existing .p8 private key")
    preview = path.read_text(encoding="utf-8", errors="ignore")[:4096]
    if "PRIVATE KEY" not in preview:
        raise AppStoreServerAPICheckError("APP_STORE_PRIVATE_KEY_P8_PATH does not look like a private key")
    return path


def _validate_bundle_id(value: str) -> str:
    bundle_id = value.strip()
    if bundle_id != DEFAULT_BUNDLE_ID:
        raise AppStoreServerAPICheckError(f"APP_STORE_BUNDLE_ID must be {DEFAULT_BUNDLE_ID}")
    return bundle_id


def _validate_transaction_id(value: str) -> str:
    transaction_id = value.strip()
    if not re.fullmatch(r"[0-9]{6,32}", transaction_id):
        raise AppStoreServerAPICheckError("APP_STORE_TRANSACTION_ID must be a numeric App Store transaction ID")
    if len(set(transaction_id)) == 1:
        raise AppStoreServerAPICheckError("APP_STORE_TRANSACTION_ID must not be a placeholder")
    return transaction_id


def _parse_product_ids(value: str) -> tuple[str, ...]:
    raw = value.strip()
    product_ids = DEFAULT_PRODUCT_IDS if not raw else tuple(item.strip() for item in raw.split(",") if item.strip())
    if not product_ids:
        raise AppStoreServerAPICheckError("APP_STORE_EXPECTED_PRODUCT_IDS must include at least one product ID")
    invalid = [
        product_id
        for product_id in product_ids
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{2,127}", product_id)
        or any(marker in product_id.lower() for marker in ("example", "placeholder", "fixture", "test"))
    ]
    if invalid:
        raise AppStoreServerAPICheckError("APP_STORE_EXPECTED_PRODUCT_IDS contains unsupported product IDs")
    return tuple(dict.fromkeys(product_ids))


def _validate_root_ca_pem(path: Path) -> Path:
    if not path.is_absolute():
        raise AppStoreServerAPICheckError("APP_STORE_ROOT_CA_PEM must be absolute")
    if not path.is_file():
        raise AppStoreServerAPICheckError("APP_STORE_ROOT_CA_PEM must point to an existing Apple root CA PEM")
    preview = path.read_text(encoding="utf-8", errors="ignore")[:4096]
    if "BEGIN CERTIFICATE" not in preview:
        raise AppStoreServerAPICheckError("APP_STORE_ROOT_CA_PEM does not look like a PEM certificate")
    return path


def _timeout(env: Mapping[str, str]) -> float:
    raw = env.get("APP_STORE_SERVER_TIMEOUT_SECONDS", "15").strip()
    try:
        value = float(raw)
    except ValueError as error:
        raise AppStoreServerAPICheckError("APP_STORE_SERVER_TIMEOUT_SECONDS must be numeric") from error
    if value < 1 or value > 120:
        raise AppStoreServerAPICheckError("APP_STORE_SERVER_TIMEOUT_SECONDS must be between 1 and 120")
    return value


def load_config(env: Mapping[str, str], *, allow_sandbox: bool = False) -> AppStoreServerAPIConfig:
    return AppStoreServerAPIConfig(
        environment=_validate_environment(_required(env, "APP_STORE_SERVER_ENVIRONMENT"), allow_sandbox=allow_sandbox),
        issuer_id=_validate_issuer_id(_required(env, "APP_STORE_ISSUER_ID")),
        key_id=_validate_key_id(_required(env, "APP_STORE_KEY_ID")),
        private_key_path=_validate_private_key(Path(_required(env, "APP_STORE_PRIVATE_KEY_P8_PATH")).expanduser()),
        bundle_id=_validate_bundle_id(env.get("APP_STORE_BUNDLE_ID", DEFAULT_BUNDLE_ID).strip() or DEFAULT_BUNDLE_ID),
        transaction_id=_validate_transaction_id(_required(env, "APP_STORE_TRANSACTION_ID")),
        expected_product_ids=_parse_product_ids(env.get("APP_STORE_EXPECTED_PRODUCT_IDS", "")),
        timeout_seconds=_timeout(env),
        root_ca_pem_path=_validate_root_ca_pem(Path(_required(env, "APP_STORE_ROOT_CA_PEM")).expanduser()),
    )


def build_app_store_jwt(config: AppStoreServerAPIConfig, *, issued_at: int | None = None) -> str:
    issued_at = int(time.time()) if issued_at is None else issued_at
    expires_at = issued_at + 20 * 60
    header = {
        "alg": "ES256",
        "kid": config.key_id,
        "typ": "JWT",
    }
    claims = {
        "aud": APPLE_JWT_AUDIENCE,
        "bid": config.bundle_id,
        "exp": expires_at,
        "iat": issued_at,
        "iss": config.issuer_id,
    }
    signing_input = f"{_base64url_json(header)}.{_base64url_json(claims)}"
    process = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(config.private_key_path)],
        input=signing_input.encode("ascii"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise AppStoreServerAPICheckError("OpenSSL could not sign the App Store Server API JWT")
    signature = der_ecdsa_signature_to_raw(process.stdout)
    return f"{signing_input}.{_base64url(signature)}"


def request_json(url: str, headers: dict[str, str], timeout_seconds: float) -> tuple[int, dict[str, Any]]:
    request = Request(url, headers=headers, method="GET")
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            status = int(response.status)
            data = response.read()
    except HTTPError as error:
        status = int(error.code)
        data = error.read()
    except URLError as error:
        raise AppStoreServerAPICheckError(f"App Store Server API request failed: {error.reason}") from error
    try:
        decoded = json.loads(data.decode("utf-8")) if data else {}
    except json.JSONDecodeError as error:
        raise AppStoreServerAPICheckError(f"App Store Server API returned non-JSON status {status}") from error
    if not isinstance(decoded, dict):
        raise AppStoreServerAPICheckError("App Store Server API returned a non-object JSON payload")
    return status, decoded


def _decode_compact_jws_payload(compact_jws: str) -> dict[str, Any]:
    parts = compact_jws.split(".")
    if len(parts) != 3 or any(not part for part in parts):
        raise AppStoreServerAPICheckError("signedTransactionInfo must be JWS compact serialization")
    return _decode_base64url_json(parts[1])


def _verify_transaction_signature(config: AppStoreServerAPIConfig, signed_transaction: str) -> None:
    transaction = _decode_compact_jws_payload(signed_transaction)
    verifier = AppStoreTransactionJWSVerifier(trusted_root_pem=str(config.root_ca_pem_path))
    issue = verifier.verify(
        {
            "signedTransactionJWS": signed_transaction,
            "productID": str(transaction.get("productId") or ""),
            "transactionID": str(transaction.get("transactionId") or ""),
            "originalTransactionID": str(transaction.get("originalTransactionId") or ""),
            "appBundleID": str(transaction.get("bundleId") or ""),
        }
    )
    if issue:
        raise AppStoreServerAPICheckError(f"signedTransactionInfo failed cryptographic verification: {issue}")


def _validate_transaction_payload(config: AppStoreServerAPIConfig, payload: dict[str, Any]) -> dict[str, Any]:
    signed_transaction = str(payload.get("signedTransactionInfo") or "").strip()
    if not signed_transaction:
        raise AppStoreServerAPICheckError("transaction response is missing signedTransactionInfo")
    _verify_transaction_signature(config, signed_transaction)
    transaction = _decode_compact_jws_payload(signed_transaction)
    product_id = str(transaction.get("productId") or "").strip()
    transaction_id = str(transaction.get("transactionId") or "").strip()
    original_transaction_id = str(transaction.get("originalTransactionId") or "").strip()
    bundle_id = str(transaction.get("bundleId") or "").strip()
    environment = str(transaction.get("environment") or "").strip()

    if transaction_id != config.transaction_id:
        raise AppStoreServerAPICheckError("transaction response does not match APP_STORE_TRANSACTION_ID")
    if not original_transaction_id:
        raise AppStoreServerAPICheckError("transaction response is missing originalTransactionId")
    if product_id not in config.expected_product_ids:
        raise AppStoreServerAPICheckError("transaction response productId is not in APP_STORE_EXPECTED_PRODUCT_IDS")
    if bundle_id != config.bundle_id:
        raise AppStoreServerAPICheckError("transaction response bundleId does not match APP_STORE_BUNDLE_ID")
    if environment and environment.lower() != config.environment:
        raise AppStoreServerAPICheckError("transaction response environment does not match APP_STORE_SERVER_ENVIRONMENT")

    return {
        "productID": product_id,
        "transactionID": transaction_id,
        "originalTransactionID": original_transaction_id,
        "bundleID": bundle_id,
        "environment": environment or config.environment,
        "type": str(transaction.get("type") or "unknown"),
        "ownershipType": str(transaction.get("inAppOwnershipType") or "unknown"),
        "purchaseDatePresent": transaction.get("purchaseDate") is not None,
        "expiresDatePresent": transaction.get("expiresDate") is not None,
    }


def run_smoke(
    config: AppStoreServerAPIConfig,
    requester: RequestJSON = request_json,
    *,
    issued_at: int | None = None,
) -> dict[str, Any]:
    token = build_app_store_jwt(config, issued_at=issued_at)
    status, payload = requester(
        config.transaction_url,
        {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        },
        config.timeout_seconds,
    )
    if not (200 <= status < 300):
        reason = payload.get("errorCode") or payload.get("errorMessage") or payload.get("error") or "unknown"
        raise AppStoreServerAPICheckError(f"App Store Server API returned HTTP {status}: {reason}")
    transaction = _validate_transaction_payload(config, payload)
    report = {
        "status": "ready",
        "environment": config.environment,
        "endpointHost": config.endpoint_host,
        "bundleID": config.bundle_id,
        "issuerFingerprint": _fingerprint(config.issuer_id),
        "keyFingerprint": _fingerprint(config.key_id),
        "privateKeyFingerprint": _fingerprint(str(config.private_key_path.resolve())),
        "transactionFingerprint": _fingerprint(config.transaction_id),
        "expectedProductFingerprints": [_fingerprint(product_id) for product_id in config.expected_product_ids],
        "response": {
            "productFingerprint": _fingerprint(transaction["productID"]),
            "originalTransactionFingerprint": _fingerprint(transaction["originalTransactionID"]),
            "type": transaction["type"],
            "ownershipType": transaction["ownershipType"],
            "purchaseDatePresent": transaction["purchaseDatePresent"],
            "expiresDatePresent": transaction["expiresDatePresent"],
        },
    }
    _assert_report_redacted(config, report, payload)
    return report


def _assert_report_redacted(
    config: AppStoreServerAPIConfig,
    report: Mapping[str, Any],
    provider_payload: Mapping[str, Any],
) -> None:
    serialized = json.dumps(report, sort_keys=True)
    forbidden = [
        config.issuer_id,
        config.key_id,
        str(config.private_key_path),
        str(config.private_key_path.resolve()),
        config.transaction_id,
        config.transaction_url,
        "https://",
        "http://",
        str(provider_payload.get("signedTransactionInfo") or ""),
    ]
    forbidden.extend(config.expected_product_ids)
    if any(value and value in serialized for value in forbidden):
        raise AppStoreServerAPICheckError("App Store Server API report contains raw credentials, IDs, JWS, or URL data")


def render_report(report: Mapping[str, Any]) -> str:
    response = report["response"]
    return "\n".join(
        [
            "# IdeaForge App Store Server API Smoke",
            "",
            f"- Status: {report['status']}",
            f"- Environment: {report['environment']}",
            f"- Endpoint host: {report['endpointHost']}",
            f"- Bundle ID: {report['bundleID']}",
            f"- Issuer fingerprint: {report['issuerFingerprint']}",
            f"- Key fingerprint: {report['keyFingerprint']}",
            f"- Private key fingerprint: {report['privateKeyFingerprint']}",
            f"- Transaction fingerprint: {report['transactionFingerprint']}",
            f"- Expected product fingerprints: {', '.join(report['expectedProductFingerprints'])}",
            f"- Response product fingerprint: {response['productFingerprint']}",
            f"- Original transaction fingerprint: {response['originalTransactionFingerprint']}",
            f"- Type: {response['type']}",
            f"- Ownership type: {response['ownershipType']}",
            f"- Purchase date present: {str(response['purchaseDatePresent']).lower()}",
            f"- Expires date present: {str(response['expiresDatePresent']).lower()}",
        ]
    ) + "\n"


def write_report(path: Path, report: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix.lower() == ".json":
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


def _fake_signed_transaction(
    product_id: str,
    transaction_id: str,
    original_transaction_id: str,
    bundle_id: str,
    environment: str,
) -> str:
    header = _base64url_json({"alg": "ES256", "typ": "JWT"})
    payload = _base64url_json(
        {
            "bundleId": bundle_id,
            "environment": environment,
            "expiresDate": 1_789_086_400_000,
            "inAppOwnershipType": "PURCHASED",
            "originalTransactionId": original_transaction_id,
            "productId": product_id,
            "purchaseDate": 1_789_000_000_000,
            "transactionId": transaction_id,
            "type": "Auto-Renewable Subscription",
        }
    )
    return f"{header}.{payload}.{_base64url(b'self-test-signature')}"


def run_self_test() -> None:
    der_signature = bytes.fromhex(
        "3045022100ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        "02200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    )
    raw_signature = der_ecdsa_signature_to_raw(der_signature)
    assert len(raw_signature) == 64

    with TemporaryDirectory() as temp_root:
        root = Path(temp_root)
        key_path = root / "SubscriptionKey_AB12CD34EF.p8"
        _self_test_key(key_path)
        chain_workdir = root / "chain"
        chain_workdir.mkdir()
        signed_transaction, root_ca_path = openssl_signed_app_store_transaction_jws(
            DEFAULT_PRODUCT_IDS[0],
            "123456789012345",
            "123456789000000",
            DEFAULT_BUNDLE_ID,
            chain_workdir,
        )
        env = {
            "APP_STORE_SERVER_ENVIRONMENT": "production",
            "APP_STORE_ISSUER_ID": "12345678-1234-4234-9234-123456789abc",
            "APP_STORE_KEY_ID": "AB12CD34EF",
            "APP_STORE_PRIVATE_KEY_P8_PATH": str(key_path),
            "APP_STORE_BUNDLE_ID": DEFAULT_BUNDLE_ID,
            "APP_STORE_TRANSACTION_ID": "123456789012345",
            "APP_STORE_EXPECTED_PRODUCT_IDS": ",".join(DEFAULT_PRODUCT_IDS),
            "APP_STORE_ROOT_CA_PEM": str(root_ca_path),
        }
        config = load_config(env)
        jwt = build_app_store_jwt(config, issued_at=1_789_000_000)
        parts = jwt.split(".")
        assert len(parts) == 3
        header = _decode_base64url_json(parts[0])
        claims = _decode_base64url_json(parts[1])
        assert header["alg"] == "ES256"
        assert header["kid"] == env["APP_STORE_KEY_ID"]
        assert claims["aud"] == APPLE_JWT_AUDIENCE
        assert claims["bid"] == DEFAULT_BUNDLE_ID
        assert claims["exp"] - claims["iat"] == 1200

        def fake_request(url: str, headers: dict[str, str], timeout_seconds: float) -> tuple[int, dict[str, Any]]:
            assert url == config.transaction_url
            assert headers["Authorization"].startswith("Bearer ")
            assert headers["Accept"] == "application/json"
            assert timeout_seconds == 15
            return 200, {"signedTransactionInfo": signed_transaction}

        report = run_smoke(config, fake_request, issued_at=1_789_000_000)
        serialized = json.dumps(report, sort_keys=True)
        assert env["APP_STORE_ISSUER_ID"] not in serialized
        assert env["APP_STORE_KEY_ID"] not in serialized
        assert str(key_path) not in serialized
        assert env["APP_STORE_TRANSACTION_ID"] not in serialized
        assert signed_transaction not in serialized
        assert "https://" not in serialized
        assert report["response"]["productFingerprint"] == _fingerprint(DEFAULT_PRODUCT_IDS[0])

        negative_env_cases = [
            ({}, "APP_STORE_SERVER_ENVIRONMENT is required"),
            ({**env, "APP_STORE_SERVER_ENVIRONMENT": "sandbox"}, "must be production"),
            ({**env, "APP_STORE_ISSUER_ID": "00000000-0000-0000-0000-000000000000"}, "must not be"),
            ({**env, "APP_STORE_KEY_ID": "AAAAAAAAAA"}, "must not be"),
            ({**env, "APP_STORE_PRIVATE_KEY_P8_PATH": "relative.p8"}, "must be absolute"),
            ({**env, "APP_STORE_BUNDLE_ID": "com.example.app"}, "must be com.s1kor"),
            ({**env, "APP_STORE_TRANSACTION_ID": "111111111111"}, "must not be"),
            ({**env, "APP_STORE_EXPECTED_PRODUCT_IDS": "example.product"}, "unsupported product"),
            ({**env, "APP_STORE_ROOT_CA_PEM": ""}, "APP_STORE_ROOT_CA_PEM is required"),
            ({**env, "APP_STORE_ROOT_CA_PEM": "relative.pem"}, "must be absolute"),
        ]
        for bad_env, expected in negative_env_cases:
            try:
                load_config(bad_env)
                raise AssertionError(f"Expected bad env to fail: {expected}")
            except AppStoreServerAPICheckError as error:
                assert expected in str(error)

        sandbox_env = {**env, "APP_STORE_SERVER_ENVIRONMENT": "sandbox"}
        assert load_config(sandbox_env, allow_sandbox=True).endpoint_host == "api.storekit-sandbox.itunes.apple.com"

        bad_product_workdir = root / "chain-bad-product"
        bad_product_workdir.mkdir()
        bad_transaction, bad_root_ca_path = openssl_signed_app_store_transaction_jws(
            "com.s1kor.ideaforge.unknown",
            env["APP_STORE_TRANSACTION_ID"],
            "123456789000000",
            DEFAULT_BUNDLE_ID,
            bad_product_workdir,
        )
        bad_product_config = load_config({**env, "APP_STORE_ROOT_CA_PEM": str(bad_root_ca_path)})
        try:
            run_smoke(
                bad_product_config,
                lambda _url, _headers, _timeout: (200, {"signedTransactionInfo": bad_transaction}),
            )
            raise AssertionError("Expected unexpected product to fail")
        except AppStoreServerAPICheckError as error:
            assert "productId" in str(error)

        unsigned_transaction = _fake_signed_transaction(
            DEFAULT_PRODUCT_IDS[0],
            env["APP_STORE_TRANSACTION_ID"],
            "123456789000000",
            DEFAULT_BUNDLE_ID,
            "production",
        )
        try:
            run_smoke(config, lambda _url, _headers, _timeout: (200, {"signedTransactionInfo": unsigned_transaction}))
            raise AssertionError("Expected unsigned transaction JWS to fail cryptographic verification")
        except AppStoreServerAPICheckError as error:
            assert "cryptographic verification" in str(error)

        try:
            _verify_transaction_signature(bad_product_config, signed_transaction)
        except AppStoreServerAPICheckError:
            pass
        else:
            raise AssertionError("Expected chain signed by a different root to fail verification")

        try:
            run_smoke(config, lambda _url, _headers, _timeout: (404, {"errorCode": 4040010}))
            raise AssertionError("Expected provider HTTP error to fail")
        except AppStoreServerAPICheckError as error:
            assert "HTTP 404" in str(error)

    print("IdeaForge App Store Server API smoke self-test passed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a fail-closed IdeaForge App Store Server API smoke.")
    parser.add_argument("--allow-sandbox", action="store_true", help="Allow sandbox checks; not release proof.")
    parser.add_argument("--self-test", action="store_true", help="Run deterministic no-network contract tests.")
    parser.add_argument("--send", action="store_true", help="Call Apple's App Store Server API with live credentials.")
    parser.add_argument("--report", type=Path, help="Write a redacted markdown or JSON report.")
    args = parser.parse_args()

    try:
        if args.self_test:
            run_self_test()
            return
        config = load_config(os.environ, allow_sandbox=args.allow_sandbox)
        if not args.send:
            raise AppStoreServerAPICheckError("App Store Server API smoke requires explicit --send")
        report = run_smoke(config)
        if args.report:
            write_report(args.report, report)
        else:
            print(render_report(report), end="")
    except AppStoreServerAPICheckError as error:
        raise SystemExit(f"App Store Server API smoke failed: {error}") from error


if __name__ == "__main__":
    main()
