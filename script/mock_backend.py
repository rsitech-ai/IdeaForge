#!/usr/bin/env python3
"""Dependency-free local backend for IdeaForge app integration smoke tests."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import secrets
import subprocess
import sqlite3
import textwrap
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from backend_migrations import BACKEND_SCHEMA_VERSION, BackendMigrationError, run_backend_migrations


class InvalidJSONBodyError(Exception):
    """Raised when a request body is not a JSON object."""


DEFAULT_TOKEN = "dev-token"
DEFAULT_WORKSPACE_ID = "local-dev-workspace"
DEFAULT_STATE_DIR = ".local/backend"
CAP_UPLOAD_RECORDINGS = "upload_recordings"
CAP_SYNC_WORKSPACE = "sync_workspace"
CAP_RUN_AI_WORKFLOWS = "run_ai_workflows"
CAP_RECONCILE_BILLING = "reconcile_billing"
CAP_MANAGE_ACCOUNT = "manage_account"
CAP_REGISTER_PUSH_NOTIFICATIONS = "register_push_notifications"
DEFAULT_CAPABILITIES = [
    CAP_UPLOAD_RECORDINGS,
    CAP_SYNC_WORKSPACE,
    CAP_RUN_AI_WORKFLOWS,
    CAP_RECONCILE_BILLING,
    CAP_MANAGE_ACCOUNT,
    CAP_REGISTER_PUSH_NOTIFICATIONS,
]
ENTITLEMENT_LIMITS = {
    "audio_bytes_stored": 50_000_000.0,
    "transcription_seconds": 1_800.0,
    "workflow_runs": 100.0,
    "artifacts_generated": 250.0,
}
OPENAI_TRANSCRIPTION_ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"
OPENAI_RESPONSES_ENDPOINT = "https://api.openai.com/v1/responses"
DEFAULT_OPENAI_TRANSCRIPTION_MODEL = "gpt-4o-transcribe"
DEFAULT_OPENAI_WORKFLOW_MODEL = "gpt-5.4-mini"
APP_STORE_JWS_FIXTURE_MODE = "fixture"
APP_STORE_JWS_SIGNED_DATA_MODE = "signed-data"


def privacy_fingerprint(value: str, length: int = 16) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def json_payload_from_bytes(data: bytes) -> dict[str, Any]:
    try:
        decoded = json.loads(data.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {"error": "invalid_provider_response", "retryable": True}
    return decoded if isinstance(decoded, dict) else {"error": "invalid_provider_response", "retryable": True}


class OpenAITranscriptionProvider:
    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_OPENAI_TRANSCRIPTION_MODEL,
        endpoint: str = OPENAI_TRANSCRIPTION_ENDPOINT,
        http_post: Callable[[str, dict[str, str], bytes], tuple[int, dict[str, Any]]] | None = None,
    ):
        self.api_key = api_key.strip()
        self.model = model.strip() or DEFAULT_OPENAI_TRANSCRIPTION_MODEL
        self.endpoint = endpoint.strip() or OPENAI_TRANSCRIPTION_ENDPOINT
        self.http_post = http_post or self._default_http_post

    def transcribe(
        self,
        audio: bytes,
        filename: str,
        language_hint: str,
        prompt: str,
        duration: int,
        is_marked_important: bool,
    ) -> tuple[int, dict[str, Any]]:
        if not self.api_key:
            return 503, {
                "error": "provider_not_configured",
                "code": "provider_not_configured",
                "retryable": False,
            }
        if not audio:
            return 400, {"error": "empty_audio_object", "retryable": False}

        boundary = f"ideaforge-{uuid.uuid4().hex}"
        body = self._multipart_body(
            boundary=boundary,
            fields={
                "model": self.model,
                "response_format": "json",
                **({"language": language_hint} if language_hint else {}),
                **({"prompt": prompt} if prompt else {}),
            },
            file_field="file",
            filename=filename or "recording.m4a",
            file_bytes=audio,
        )
        status, payload = self.http_post(
            self.endpoint,
            {
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
            },
            body,
        )
        if status < 200 or status >= 300:
            return status, {
                "error": payload.get("error", "provider_request_failed"),
                "code": payload.get("code", payload.get("error", "provider_request_failed")),
                "retryable": status in {408, 409, 425, 429, 500, 502, 503, 504},
            }
        text = str(payload.get("text", "")).strip()
        if not text:
            return 502, {"error": "provider_empty_transcript", "retryable": True}
        return 200, {
            "cleanText": text,
            "segments": [
                {
                    "id": "seg_provider_1",
                    "startSeconds": 0,
                    "endSeconds": duration,
                    "text": text,
                    "isMarkedImportant": is_marked_important,
                }
            ],
            "unclearFragments": [],
        }

    def _multipart_body(
        self,
        boundary: str,
        fields: dict[str, str],
        file_field: str,
        filename: str,
        file_bytes: bytes,
    ) -> bytes:
        chunks: list[bytes] = []
        for name, value in fields.items():
            chunks.append(f"--{boundary}\r\n".encode("utf-8"))
            chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
            chunks.append(str(value).encode("utf-8"))
            chunks.append(b"\r\n")
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(
            f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'.encode("utf-8")
        )
        chunks.append(b"Content-Type: application/octet-stream\r\n\r\n")
        chunks.append(file_bytes)
        chunks.append(b"\r\n")
        chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
        return b"".join(chunks)

    def _default_http_post(self, url: str, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        request = Request(url, data=body, headers=headers, method="POST")
        try:
            with urlopen(request, timeout=60) as response:
                return response.status, json_payload_from_bytes(response.read())
        except HTTPError as error:
            return error.code, json_payload_from_bytes(error.read())
        except URLError:
            return 503, {"error": "provider_unreachable", "retryable": True}


class OpenAIWorkflowProvider:
    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_OPENAI_WORKFLOW_MODEL,
        endpoint: str = OPENAI_RESPONSES_ENDPOINT,
        http_post: Callable[[str, dict[str, str], bytes], tuple[int, dict[str, Any]]] | None = None,
    ):
        self.api_key = api_key.strip()
        self.model = model.strip() or DEFAULT_OPENAI_WORKFLOW_MODEL
        self.endpoint = endpoint.strip() or OPENAI_RESPONSES_ENDPOINT
        self.http_post = http_post or self._default_http_post

    def generate(
        self,
        template: dict[str, Any],
        project: dict[str, Any],
        output_contract: dict[str, Any],
        output_kinds: list[Any],
    ) -> tuple[int, dict[str, Any]]:
        if not self.api_key:
            return 503, {
                "error": "provider_not_configured",
                "code": "provider_not_configured",
                "retryable": False,
            }
        structured_output = output_contract.get("structuredOutput")
        if not isinstance(structured_output, dict):
            return 400, {"error": "missing_structured_output", "retryable": False}
        schema = structured_output.get("schema")
        if not isinstance(schema, dict):
            return 400, {"error": "missing_structured_output_schema", "retryable": False}

        body = {
            "model": self.model,
            "store": False,
            "input": [
                {
                    "role": "system",
                    "content": (
                        "You generate IdeaForge workflow artifacts for a privacy-reviewed app backend. "
                        "Return only JSON that matches the supplied schema. Do not call external tools, "
                        "do not invent user commitments, and include reviewable markdown in each artifact."
                    ),
                },
                {
                    "role": "user",
                    "content": json.dumps(
                        {
                            "template": template,
                            "project": project,
                            "expectedArtifactKinds": [str(kind) for kind in output_kinds],
                            "artifactOutputs": output_contract.get("artifactOutputs", []),
                            "rubricRequirements": output_contract.get("rubricRequirements", []),
                        },
                        sort_keys=True,
                    ),
                },
            ],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": str(structured_output.get("name", "ideaforge_workflow_output_v1")),
                    "strict": True,
                    "schema": schema,
                }
            },
        }
        status, payload = self.http_post(
            self.endpoint,
            {
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            json.dumps(body, sort_keys=True).encode("utf-8"),
        )
        if status < 200 or status >= 300:
            return status, self._provider_failure(payload, status)

        provider_status = str(payload.get("status", "completed")).strip().lower()
        if provider_status and provider_status != "completed":
            return 502, {
                "error": f"provider_response_{provider_status}",
                "code": f"provider_response_{provider_status}",
                "retryable": provider_status in {"queued", "in_progress", "incomplete"},
            }

        output_text, refusal = self._extract_output_text(payload)
        if refusal:
            return 403, {
                "error": "provider_refusal",
                "code": "provider_refusal",
                "retryable": False,
            }
        if not output_text:
            return 502, {"error": "provider_empty_workflow_output", "retryable": True}
        try:
            decoded = json.loads(output_text)
        except json.JSONDecodeError:
            return 502, {"error": "provider_invalid_workflow_json", "retryable": True}
        if not isinstance(decoded, dict) or not isinstance(decoded.get("artifacts"), list):
            return 502, {"error": "provider_invalid_workflow_artifacts", "retryable": True}
        return 200, {"artifacts": decoded["artifacts"]}

    def _extract_output_text(self, payload: dict[str, Any]) -> tuple[str | None, bool]:
        direct_output = payload.get("output_text")
        if isinstance(direct_output, str) and direct_output.strip():
            return direct_output.strip(), False
        output_items = payload.get("output")
        if not isinstance(output_items, list):
            return None, False
        for output_item in output_items:
            if not isinstance(output_item, dict):
                continue
            content = output_item.get("content")
            if not isinstance(content, list):
                continue
            for content_item in content:
                if not isinstance(content_item, dict):
                    continue
                if content_item.get("type") == "refusal" or content_item.get("refusal"):
                    return None, True
                text = content_item.get("text")
                if isinstance(text, str) and text.strip():
                    return text.strip(), False
        return None, False

    def _provider_failure(self, payload: dict[str, Any], status: int) -> dict[str, Any]:
        error = payload.get("error")
        if isinstance(error, dict):
            code = str(error.get("code") or error.get("type") or "provider_request_failed")
        else:
            code = str(payload.get("code") or error or "provider_request_failed")
        return {
            "error": code,
            "code": code,
            "retryable": status in {408, 409, 425, 429, 500, 502, 503, 504},
        }

    def _default_http_post(self, url: str, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        request = Request(url, data=body, headers=headers, method="POST")
        try:
            with urlopen(request, timeout=120) as response:
                return response.status, json_payload_from_bytes(response.read())
        except HTTPError as error:
            return error.code, json_payload_from_bytes(error.read())
        except URLError:
            return 503, {"error": "provider_unreachable", "retryable": True}


def decode_base64url_json(segment: str) -> dict[str, Any] | None:
    try:
        padding = "=" * ((4 - len(segment) % 4) % 4)
        decoded = base64.urlsafe_b64decode((segment + padding).encode("ascii"))
        payload = json.loads(decoded.decode("utf-8"))
        return payload if isinstance(payload, dict) else None
    except (binascii.Error, json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return None


def app_store_transaction_jws_issue(transaction: dict[str, Any]) -> str | None:
    compact_jws = str(transaction.get("signedTransactionJWS", "")).strip()
    if not compact_jws:
        return "missing_signed_transaction_jws"
    segments = compact_jws.split(".")
    if len(segments) != 3 or any(not segment for segment in segments):
        return "malformed_app_store_transaction_jws"
    header = decode_base64url_json(segments[0])
    payload = decode_base64url_json(segments[1])
    if not isinstance(header, dict) or not isinstance(payload, dict):
        return "malformed_app_store_transaction_jws"
    if header.get("alg") != "ES256":
        return "unsupported_app_store_transaction_algorithm"
    claim_pairs = [
        ("productId", "productID"),
        ("transactionId", "transactionID"),
        ("originalTransactionId", "originalTransactionID"),
        ("bundleId", "appBundleID"),
    ]
    for claim_key, transaction_key in claim_pairs:
        if str(payload.get(claim_key, "")).strip() != str(transaction.get(transaction_key, "")).strip():
            return "app_store_transaction_claim_mismatch"
    return None


class AppStoreTransactionJWSVerifier:
    def __init__(
        self,
        mode: str = APP_STORE_JWS_SIGNED_DATA_MODE,
        trusted_root_pem: str | None = None,
    ) -> None:
        self.mode = mode
        self.trusted_root_pem = trusted_root_pem.strip() if trusted_root_pem else ""

    def verify(self, transaction: dict[str, Any]) -> str | None:
        structural_issue = app_store_transaction_jws_issue(transaction)
        if structural_issue:
            return structural_issue
        if self.mode == APP_STORE_JWS_FIXTURE_MODE:
            return None
        if self.mode != APP_STORE_JWS_SIGNED_DATA_MODE:
            return "app_store_transaction_verifier_mode_invalid"
        return self._verify_signed_data(str(transaction.get("signedTransactionJWS", "")).strip())

    def _verify_signed_data(self, compact_jws: str) -> str | None:
        segments = compact_jws.split(".")
        header = decode_base64url_json(segments[0]) or {}
        x5c = header.get("x5c")
        if not isinstance(x5c, list) or len(x5c) < 3 or not all(isinstance(item, str) and item.strip() for item in x5c):
            return "missing_app_store_transaction_certificate_chain"
        if not self.trusted_root_pem:
            return "app_store_server_verifier_not_configured"
        trusted_root = Path(self.trusted_root_pem)
        if not trusted_root.is_file():
            return "app_store_server_root_ca_unavailable"

        try:
            signature_raw = decode_base64url_bytes(segments[2])
            if len(signature_raw) != 64:
                return "invalid_app_store_transaction_signature"
            signature_der = raw_ecdsa_signature_to_der(signature_raw)
            signing_input = f"{segments[0]}.{segments[1]}".encode("ascii")
            with TemporaryDirectory() as directory:
                workdir = Path(directory)
                leaf_path = write_pem_certificate(workdir / "leaf.pem", x5c[0])
                untrusted_path = workdir / "untrusted.pem"
                with untrusted_path.open("w", encoding="utf-8") as handle:
                    for index, certificate in enumerate(x5c[1:-1] if len(x5c) > 2 else x5c[1:]):
                        if index:
                            handle.write("\n")
                        handle.write(pem_certificate(certificate))
                public_key_path = workdir / "leaf-public-key.pem"
                signature_path = workdir / "signature.der"
                signing_input_path = workdir / "signed-data.bin"
                signature_path.write_bytes(signature_der)
                signing_input_path.write_bytes(signing_input)

                verify_command = [
                    "openssl",
                    "verify",
                    "-CAfile",
                    str(trusted_root),
                ]
                if untrusted_path.read_text(encoding="utf-8").strip():
                    verify_command.extend(["-untrusted", str(untrusted_path)])
                verify_command.append(str(leaf_path))
                if subprocess.run(verify_command, capture_output=True, text=True, check=False).returncode != 0:
                    return "invalid_app_store_transaction_certificate_chain"

                public_key = subprocess.run(
                    ["openssl", "x509", "-in", str(leaf_path), "-pubkey", "-noout"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if public_key.returncode != 0 or "BEGIN PUBLIC KEY" not in public_key.stdout:
                    return "invalid_app_store_transaction_certificate_chain"
                public_key_path.write_text(public_key.stdout, encoding="utf-8")

                signature_check = subprocess.run(
                    [
                        "openssl",
                        "dgst",
                        "-sha256",
                        "-verify",
                        str(public_key_path),
                        "-signature",
                        str(signature_path),
                        str(signing_input_path),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if signature_check.returncode != 0:
                    return "invalid_app_store_transaction_signature"
        except FileNotFoundError:
            return "openssl_unavailable_for_app_store_transaction_verification"
        except (binascii.Error, UnicodeDecodeError, ValueError, OSError):
            return "malformed_app_store_transaction_jws"
        return None


def decode_base64url_bytes(segment: str) -> bytes:
    padding = "=" * ((4 - len(segment) % 4) % 4)
    return base64.urlsafe_b64decode((segment + padding).encode("ascii"))


def raw_ecdsa_signature_to_der(signature: bytes) -> bytes:
    if len(signature) != 64:
        raise ValueError("ES256 signatures must be 64 raw bytes.")

    def encode_integer(value: bytes) -> bytes:
        normalized = value.lstrip(b"\x00") or b"\x00"
        if normalized[0] & 0x80:
            normalized = b"\x00" + normalized
        return b"\x02" + encode_der_length(len(normalized)) + normalized

    r = encode_integer(signature[:32])
    s = encode_integer(signature[32:])
    sequence = r + s
    return b"\x30" + encode_der_length(len(sequence)) + sequence


def encode_der_length(length: int) -> bytes:
    if length < 0x80:
        return bytes([length])
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(encoded)]) + encoded


def pem_certificate(base64_der: str) -> str:
    compact = "".join(base64_der.strip().split())
    wrapped = "\n".join(textwrap.wrap(compact, 64))
    return f"-----BEGIN CERTIFICATE-----\n{wrapped}\n-----END CERTIFICATE-----\n"


def write_pem_certificate(path: Path, base64_der: str) -> Path:
    path.write_text(pem_certificate(base64_der), encoding="utf-8")
    return path


def fixture_app_store_transaction_jws(
    product_id: str,
    transaction_id: str,
    original_transaction_id: str,
    bundle_id: str,
) -> str:
    return ".".join(
        [
            base64url_json_segment({"alg": "ES256", "typ": "JWT"}),
            base64url_json_segment(
                {
                    "productId": product_id,
                    "transactionId": transaction_id,
                    "originalTransactionId": original_transaction_id,
                    "bundleId": bundle_id,
                }
            ),
            base64.urlsafe_b64encode(b"fixture-signature").decode("ascii").rstrip("="),
        ]
    )


def base64url_json_segment(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(encoded).decode("ascii").rstrip("=")


def base64url_bytes(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def openssl_signed_app_store_transaction_jws(
    product_id: str,
    transaction_id: str,
    original_transaction_id: str,
    bundle_id: str,
    workdir: Path,
) -> tuple[str, Path]:
    root_key = workdir / "root.key"
    root_cert = workdir / "root.pem"
    intermediate_key = workdir / "intermediate.key"
    intermediate_csr = workdir / "intermediate.csr"
    intermediate_cert = workdir / "intermediate.pem"
    leaf_key = workdir / "leaf.key"
    leaf_csr = workdir / "leaf.csr"
    leaf_cert = workdir / "leaf.pem"
    intermediate_ext = workdir / "intermediate.ext"
    leaf_ext = workdir / "leaf.ext"

    run_openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(root_key)])
    run_openssl([
        "req", "-x509", "-new", "-key", str(root_key), "-sha256", "-days", "1",
        "-subj", "/CN=IdeaForge Test App Store Root", "-out", str(root_cert),
    ])
    run_openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(intermediate_key)])
    run_openssl([
        "req", "-new", "-key", str(intermediate_key), "-subj",
        "/CN=IdeaForge Test App Store Intermediate", "-out", str(intermediate_csr),
    ])
    intermediate_ext.write_text(
        "\n".join([
            "basicConstraints=critical,CA:TRUE,pathlen:0",
            "keyUsage=critical,keyCertSign,cRLSign",
            "subjectKeyIdentifier=hash",
            "authorityKeyIdentifier=keyid,issuer",
        ]),
        encoding="utf-8",
    )
    run_openssl([
        "x509", "-req", "-in", str(intermediate_csr), "-CA", str(root_cert),
        "-CAkey", str(root_key), "-CAcreateserial", "-out", str(intermediate_cert),
        "-days", "1", "-sha256", "-extfile", str(intermediate_ext),
    ])
    run_openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(leaf_key)])
    run_openssl([
        "req", "-new", "-key", str(leaf_key), "-subj",
        "/CN=IdeaForge Test App Store Transaction Signer", "-out", str(leaf_csr),
    ])
    leaf_ext.write_text(
        "\n".join([
            "basicConstraints=critical,CA:FALSE",
            "keyUsage=critical,digitalSignature",
            "subjectKeyIdentifier=hash",
            "authorityKeyIdentifier=keyid,issuer",
        ]),
        encoding="utf-8",
    )
    run_openssl([
        "x509", "-req", "-in", str(leaf_csr), "-CA", str(intermediate_cert),
        "-CAkey", str(intermediate_key), "-CAcreateserial", "-out", str(leaf_cert),
        "-days", "1", "-sha256", "-extfile", str(leaf_ext),
    ])

    header = base64url_json_segment({
        "alg": "ES256",
        "typ": "JWT",
        "x5c": [
            openssl_certificate_der_base64(leaf_cert),
            openssl_certificate_der_base64(intermediate_cert),
            openssl_certificate_der_base64(root_cert),
        ],
    })
    payload = base64url_json_segment({
        "productId": product_id,
        "transactionId": transaction_id,
        "originalTransactionId": original_transaction_id,
        "bundleId": bundle_id,
    })
    signing_input = f"{header}.{payload}".encode("ascii")
    signing_input_path = workdir / "signed-data.bin"
    signature_der_path = workdir / "signature.der"
    signing_input_path.write_bytes(signing_input)
    run_openssl(["dgst", "-sha256", "-sign", str(leaf_key), "-out", str(signature_der_path), str(signing_input_path)])
    return f"{header}.{payload}.{base64url_bytes(der_ecdsa_signature_to_raw(signature_der_path.read_bytes()))}", root_cert


def run_openssl(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["openssl", *arguments], capture_output=True, text=True, check=True)


def openssl_certificate_der_base64(certificate_path: Path) -> str:
    result = subprocess.run(
        ["openssl", "x509", "-in", str(certificate_path), "-outform", "DER"],
        capture_output=True,
        check=True,
    )
    return base64.b64encode(result.stdout).decode("ascii")


def der_ecdsa_signature_to_raw(signature: bytes) -> bytes:
    cursor = 0
    if not signature or signature[cursor] != 0x30:
        raise ValueError("DER ECDSA signature must be a sequence.")
    cursor += 1
    _, cursor = read_der_length(signature, cursor)
    r, cursor = read_der_integer(signature, cursor)
    s, _ = read_der_integer(signature, cursor)
    if len(r) > 32 or len(s) > 32:
        raise ValueError("ES256 DER signature integers are too large.")
    return r.rjust(32, b"\x00") + s.rjust(32, b"\x00")


def read_der_length(value: bytes, cursor: int) -> tuple[int, int]:
    if cursor >= len(value):
        raise ValueError("Missing DER length.")
    length = value[cursor]
    cursor += 1
    if length < 0x80:
        return length, cursor
    length_bytes = length & 0x7F
    if length_bytes == 0 or cursor + length_bytes > len(value):
        raise ValueError("Invalid DER length.")
    return int.from_bytes(value[cursor : cursor + length_bytes], "big"), cursor + length_bytes


def read_der_integer(value: bytes, cursor: int) -> tuple[bytes, int]:
    if cursor >= len(value) or value[cursor] != 0x02:
        raise ValueError("Missing DER integer.")
    cursor += 1
    length, cursor = read_der_length(value, cursor)
    integer = value[cursor : cursor + length]
    if len(integer) != length:
        raise ValueError("Truncated DER integer.")
    return integer.lstrip(b"\x00") or b"\x00", cursor + length


def is_safe_object_identifier(value: str) -> bool:
    """Single object-key path component: alphanumerics plus - _ . and no dot-only names."""
    if not value or value.strip(".") == "":
        return False
    return all(character.isalnum() or character in {"-", "_", "."} for character in value)


def safe_identifier(text: str) -> str:
    clean = []
    for character in text.strip().lower():
        if character.isalnum():
            clean.append(character)
        elif character in {"-", "_"}:
            clean.append("_")
    return "".join(clean).strip("_")


def iso_now() -> str:
    return "2026-06-29T20:00:00Z"


def seed_workspace() -> dict[str, Any]:
    now = iso_now()
    workflow_template = {
        "id": "wf_prd",
        "name": "App Idea -> PRD",
        "summary": "Turns a strengthened idea into a product requirements document.",
        "outputKinds": ["prd"],
        "steps": [
            {
                "id": "step_prd",
                "name": "Generate PRD",
                "kind": "artifact",
                "inputKeys": ["idea_summary", "answers"],
                "outputSchemaName": "PRDArtifact",
                "requiresUserReview": True,
                "modelPolicy": "balanced",
                "version": 1,
            }
        ],
    }
    project = {
        "id": "idea_mock_backend",
        "title": "Mock Backend Idea",
        "status": "draft",
        "source": "iphone",
        "createdAt": now,
        "updatedAt": now,
        "summary": "A local backend contract fixture for IdeaForge development.",
        "tags": ["appIdea"],
        "score": {"confidence": 0.7, "completeness": 0.5, "risk": 0.3},
        "transcript": {
            "cleanText": "Mock backend transcript fixture.",
            "segments": [],
            "unclearFragments": [],
        },
        "recordings": [
            {
                "id": "rec_mock_backend",
                "ideaProjectID": "idea_mock_backend",
                "deviceName": "iPhone",
                "durationSeconds": 42,
                "localFileStatus": "uploaded",
                "syncStatus": "uploaded",
                "localAudioPath": None,
                "audioObjectKey": "audio/idea_mock_backend/rec_mock_backend.m4a",
                "languageHint": "en",
                "createdAt": now,
                "markerOffsets": [12],
            }
        ],
        "questions": [
            {
                "id": "q_mock_first_user",
                "prompt": "Who is the first user?",
                "answer": None,
                "isBlocking": True,
            }
        ],
        "artifacts": [],
        "assumptions": [],
        "validationExperiments": [],
        "codexTasks": [],
    }
    return {
        "projects": [project],
        "workflowTemplates": [workflow_template],
        "uploadJobs": [],
        "privacyMode": "standardCloud",
        "syncHealth": {
            "watchReachable": True,
            "queuedUploads": 0,
            "lastSuccessfulSync": now,
            "failingItems": 0,
        },
        "selectedProjectID": project["id"],
        "updatedAt": now,
    }


class MockBackendState:
    def __init__(
        self,
        token: str,
        workspace_id: str = DEFAULT_WORKSPACE_ID,
        capabilities: list[str] | None = None,
        storage: "FileBackendStorage | None" = None,
        transcription_provider: OpenAITranscriptionProvider | None = None,
        workflow_provider: OpenAIWorkflowProvider | None = None,
        app_store_jws_verifier: AppStoreTransactionJWSVerifier | None = None,
    ) -> None:
        self.token = token
        self.workspace_id = workspace_id
        self.capabilities = capabilities or DEFAULT_CAPABILITIES
        self.storage = storage
        self.transcription_provider = transcription_provider
        self.workflow_provider = workflow_provider
        self.app_store_jws_verifier = app_store_jws_verifier or AppStoreTransactionJWSVerifier()
        self.workspace = storage.load_workspace() if storage else seed_workspace()
        self.uploaded_objects: dict[str, str] = {}
        self.upload_receipts: dict[str, dict[str, Any]] = {}
        self.push_registrations: dict[str, dict[str, Any]] = {}
        # ponytail: single lock serializes snapshot publish under ThreadingHTTPServer;
        # upgrade path is per-workspace revision rows once this backend goes multi-tenant.
        self.snapshot_lock = threading.Lock()

    def check_authorization(
        self,
        authorization: str | None,
        workspace_id: str | None,
    ) -> tuple[bool, int, dict[str, Any] | None]:
        provided = (authorization or "").encode("utf-8")
        expected = f"Bearer {self.token}".encode("utf-8")
        normalized_workspace_id = (workspace_id or "").strip()
        token_matches = secrets.compare_digest(provided, expected)
        if token_matches and normalized_workspace_id == self.workspace_id:
            return True, 200, None
        if token_matches:
            return False, 403, {"error": "workspace_scope_mismatch", "detail": "Workspace scope is missing or invalid."}
        if self.storage and normalized_workspace_id:
            account = self.storage.load_account(normalized_workspace_id)
            if account and secrets.compare_digest(provided, f"Bearer {account['bearer_token']}".encode("utf-8")):
                return True, 200, None
        return False, 401, {"error": "unauthorized", "detail": "Bearer token is missing or invalid."}

    def check_capability(self, capability: str) -> tuple[bool, int, dict[str, Any] | None]:
        if capability not in self.capabilities:
            return False, 403, {"error": "capability_forbidden", "detail": "Session is missing the required capability."}
        return True, 200, None

    def upload_recording(self, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
        recording_id = headers.get("x-ideaforge-recording-id", "").strip()
        idea_id = headers.get("x-ideaforge-idea-id", "").strip()
        upload_job_id = headers.get("x-ideaforge-upload-job-id", "").strip()
        content_digest = headers.get("x-ideaforge-content-sha256", "").strip().lower()
        declared_length = headers.get("content-length", "").strip()
        if not recording_id or not idea_id or not upload_job_id or not content_digest or not declared_length:
            return 400, {"error": "missing_headers"}
        if not is_safe_object_identifier(recording_id) or not is_safe_object_identifier(idea_id):
            return 400, {"error": "invalid_object_identifier"}
        if not body:
            return 400, {"error": "empty_upload"}
        if declared_length != str(len(body)):
            return 400, {"error": "content_length_mismatch"}
        actual_digest = hashlib.sha256(body).hexdigest()
        if content_digest != actual_digest:
            return 400, {"error": "content_digest_mismatch"}
        existing_receipt = self.upload_receipts.get(upload_job_id)
        if existing_receipt:
            if (
                existing_receipt["recordingID"] != recording_id
                or existing_receipt["ideaProjectID"] != idea_id
                or existing_receipt["contentSHA256"] != actual_digest
                or existing_receipt["byteCount"] != len(body)
            ):
                return 409, {"error": "idempotency_conflict"}
            return 200, {"objectKey": existing_receipt["objectKey"], "idempotentReplay": True}
        object_key = f"audio/{idea_id}/{recording_id}.m4a"
        self.uploaded_objects[recording_id] = object_key
        self.upload_receipts[upload_job_id] = {
            "recordingID": recording_id,
            "ideaProjectID": idea_id,
            "objectKey": object_key,
            "byteCount": len(body),
            "contentSHA256": actual_digest,
        }
        if self.storage:
            self.storage.write_object(object_key, body)
            self.storage.record_object(
                object_key,
                recording_id,
                idea_id,
                len(body),
                headers.get("content-type", "application/octet-stream"),
            )
            job_id = self.storage.record_job(
                "recording_upload",
                "completed",
                idea_id=idea_id,
                recording_id=recording_id,
                object_key=object_key,
                detail={"byteCount": len(body), "uploadJobID": upload_job_id},
            )
            self.storage.record_usage("audio_bytes_stored", len(body), idea_id=idea_id, job_id=job_id)
            self.storage.append_audit_event(
                "recording_uploaded",
                {
                    "recordingID": recording_id,
                    "ideaProjectID": idea_id,
                    "byteCount": len(body),
                },
            )
        return 200, {"objectKey": object_key}

    def object_metadata(self, object_key: str) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 404, {"error": "audio_object_not_found", "retryable": True}
        metadata = self.storage.object_metadata(object_key)
        if metadata is None:
            return 404, {"error": "audio_object_not_found", "retryable": True}
        return 200, metadata

    def workspace_snapshot(self, query: dict[str, list[str]]) -> tuple[int, dict[str, Any]]:
        _ = query.get("since", [])
        if self.storage:
            self.workspace = self.storage.load_workspace()
        return 200, self.workspace

    def publish_workspace_snapshot(
        self,
        headers: dict[str, str],
        payload: dict[str, Any],
    ) -> tuple[int, dict[str, Any]]:
        if not isinstance(payload, dict):
            return 400, {"error": "invalid_workspace_snapshot", "detail": "Workspace snapshot must be a JSON object."}
        accepted_updated_at = str(payload.get("updatedAt") or "").strip()
        if not accepted_updated_at:
            return 400, {"error": "invalid_workspace_snapshot", "detail": "Workspace snapshot requires updatedAt."}

        with self.snapshot_lock:
            if self.storage:
                self.workspace = self.storage.load_workspace()
            current_updated_at = str(self.workspace.get("updatedAt") or "").strip()
            expected_remote_updated_at = headers.get("x-ideaforge-base-remote-updated-at", "").strip()
            if expected_remote_updated_at and current_updated_at and expected_remote_updated_at != current_updated_at:
                return 409, {
                    "error": "workspace_revision_conflict",
                    "retryable": False,
                    "currentUpdatedAt": current_updated_at,
                }

            self.workspace = payload
            if self.storage:
                self.storage.write_workspace(payload)
                self.storage.append_audit_event(
                    "workspace_snapshot_published",
                    {
                        "projectCount": len(payload.get("projects", [])),
                        "uploadJobCount": len(payload.get("uploadJobs", [])),
                        "workflowTemplateCount": len(payload.get("workflowTemplates", [])),
                        "updatedAt": accepted_updated_at,
                    },
                )
        scoped_workspace_id = headers.get("x-ideaforge-workspace-id", "").strip() or self.workspace_id
        return 200, {
            "workspaceID": scoped_workspace_id,
            "acceptedUpdatedAt": accepted_updated_at,
        }

    def register_push_device(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        token = str(payload.get("apnsDeviceToken", "")).strip().lower()
        environment = str(payload.get("environment", "")).strip()
        platform = str(payload.get("platform", "")).strip()
        bundle_id = str(payload.get("bundleID", "")).strip()
        app_version = str(payload.get("appVersion", "")).strip()
        topics = payload.get("topics")
        if (
            not token
            or len(token) < 64
            or len(token) % 2 != 0
            or any(char not in "0123456789abcdef" for char in token)
        ):
            return 400, {"error": "invalid_apns_device_token", "retryable": False}
        if environment not in {"sandbox", "production"}:
            return 400, {"error": "invalid_push_environment", "retryable": False}
        if platform not in {"ios", "watchos", "macos"}:
            return 400, {"error": "invalid_push_platform", "retryable": False}
        if not bundle_id or not app_version:
            return 400, {"error": "missing_app_identity", "retryable": False}
        if not isinstance(topics, list) or not topics or any(not isinstance(topic, str) or not topic.strip() for topic in topics):
            return 400, {"error": "invalid_push_topics", "retryable": False}

        token_fingerprint = privacy_fingerprint(token)
        device_id = f"apns_{token_fingerprint}"
        receipt = {
            "workspaceID": self.workspace_id,
            "deviceID": device_id,
            "tokenFingerprint": token_fingerprint,
            "environment": environment,
            "platform": platform,
            "enabledTopics": topics,
            "registeredAt": iso_now(),
        }
        self.push_registrations[device_id] = {
            "workspaceID": self.workspace_id,
            "deviceID": device_id,
            "tokenFingerprint": token_fingerprint,
            "environment": environment,
            "platform": platform,
            "bundleID": bundle_id,
            "appVersion": app_version,
            "topics": list(topics),
        }
        if self.storage:
            self.storage.append_audit_event(
                "push_device_registered",
                {
                    "workspaceID": self.workspace_id,
                    "deviceID": device_id,
                    "tokenFingerprint": token_fingerprint,
                    "platform": platform,
                    "environment": environment,
                    "topicCount": len(topics),
                },
            )
        return 200, receipt

    def validate_audio_chunks(
        self,
        payload: dict[str, Any],
        object_key: str,
        duration: int,
    ) -> tuple[bool, dict[str, Any] | None]:
        chunks = payload.get("audioChunks")
        if not isinstance(chunks, list) or not chunks:
            return False, {"error": "invalid_audio_chunks", "detail": "Transcription requires a non-empty audio chunk plan."}
        expected_start = 0
        previous_end = 0
        for index, chunk in enumerate(chunks):
            if not isinstance(chunk, dict):
                return False, {"error": "invalid_audio_chunks", "detail": "Audio chunks must be objects."}
            chunk_object_key = str(chunk.get("audioObjectKey", "")).strip()
            start = chunk.get("startSeconds")
            end = chunk.get("endSeconds")
            if chunk_object_key != object_key or not isinstance(start, int) or not isinstance(end, int):
                return False, {"error": "invalid_audio_chunks", "detail": "Audio chunks must reference the submitted object and integer bounds."}
            if start < 0 or end <= start or end > duration:
                return False, {"error": "invalid_audio_chunks", "detail": "Audio chunk bounds are outside the recording duration."}
            if index == 0 and start != 0:
                return False, {"error": "invalid_audio_chunks", "detail": "First audio chunk must start at zero."}
            if index > 0 and (start > previous_end or start <= expected_start):
                return False, {"error": "invalid_audio_chunks", "detail": "Audio chunks must be ordered and leave no gaps."}
            expected_start = start
            previous_end = end
        if previous_end != duration:
            return False, {"error": "invalid_audio_chunks", "detail": "Audio chunks must cover the full recording duration."}
        return True, None

    def transcribe(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        recording_id = str(payload.get("recordingID", "")).strip()
        object_key = str(payload.get("audioObjectKey", "")).strip()
        if not recording_id or not object_key:
            return 400, {"error": "missing_recording"}
        if self.storage and not self.storage.object_exists(object_key):
            return 404, {"error": "audio_object_not_found", "retryable": True}
        hint = str(payload.get("hint", "")).strip()
        text = hint or f"Mock transcript for {recording_id}."
        duration = max(int(payload.get("durationSeconds", 1)), 1)
        valid_chunks, chunk_error = self.validate_audio_chunks(payload, object_key, duration)
        if not valid_chunks:
            return 400, chunk_error or {"error": "invalid_audio_chunks"}
        entitlement_denial = self.entitlement_denial("transcription_seconds", duration)
        if entitlement_denial:
            return 402, entitlement_denial
        if self.transcription_provider:
            chunks = payload.get("audioChunks")
            if len(chunks) > 1:
                return 501, {
                    "error": "audio_chunk_slicing_unavailable",
                    "code": "audio_chunk_slicing_unavailable",
                    "retryable": False,
                }
            if not self.storage:
                return 503, {
                    "error": "provider_storage_unavailable",
                    "code": "provider_storage_unavailable",
                    "retryable": False,
                }
            audio_path = self.storage.object_path(object_key)
            if not audio_path.exists():
                return 404, {"error": "audio_object_not_found", "retryable": True}
            status, provider_payload = self.transcription_provider.transcribe(
                audio_path.read_bytes(),
                filename=Path(object_key).name,
                language_hint=str(payload.get("languageHint", "")).strip(),
                prompt=hint,
                duration=duration,
                is_marked_important=bool(payload.get("markerOffsets", [])),
            )
            if status < 200 or status >= 300:
                return status, provider_payload
            transcript = provider_payload
        else:
            transcript = {
                "cleanText": text,
                "segments": [
                    {
                        "id": f"seg_{recording_id}",
                        "startSeconds": 0,
                        "endSeconds": duration,
                        "text": text,
                        "isMarkedImportant": bool(payload.get("markerOffsets", [])),
                    }
                ],
                "unclearFragments": [],
            }
        if self.storage:
            job_id = self.storage.record_job(
                "transcription",
                "running",
                idea_id=str(payload.get("ideaProjectID", "")).strip() or None,
                recording_id=recording_id,
                object_key=object_key,
                detail={
                    "durationSeconds": duration,
                    "provider": "openai" if self.transcription_provider else "mock",
                },
            )
            self.storage.write_transcription_result(job_id, transcript)
            return 202, {"jobID": job_id, "status": "queued"}
        return 200, transcript

    def transcription_job(self, job_id: str) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 404, {"error": "job_not_found"}
        job = self.storage.read_job(job_id)
        if not job or job.get("kind") != "transcription":
            return 404, {"error": "job_not_found"}
        transcript = self.storage.read_transcription_result(job_id)
        if not transcript:
            return 500, {"error": "transcription_result_missing", "retryable": False}
        if job.get("status") != "completed":
            self.storage.complete_job(job_id)
            duration = float((job.get("detail") or {}).get("durationSeconds", 0.0))
            if duration > 0:
                self.storage.record_usage(
                    "transcription_seconds",
                    duration,
                    idea_id=job.get("ideaProjectID"),
                    job_id=job_id,
                )
            self.storage.append_audit_event(
                "transcription_completed",
                {
                    "recordingID": job.get("recordingID"),
                    "ideaProjectID": job.get("ideaProjectID"),
                    "jobID": job_id,
                },
            )
        return 200, {
            "jobID": job_id,
            "status": "completed",
            "transcript": transcript,
        }

    def workflow_markdown(self, kind: str, project_title: str) -> str:
        common = """
## Validation
- Evidence comes from the submitted IdeaForge project payload.

## Risks
- Review scope, boundary assumptions, and delivery tradeoffs before acting.

## Next Steps
- Review the generated artifact and attach acceptance checks.
"""
        if kind == "prd":
            body = f"""
# PRD: {project_title}

## Goals
- Turn the captured idea into a reviewed product plan.

## Requirements
- Keep transcript, questions, and artifacts traceable.
- Preserve local-first review before cloud or external handoff.

## Acceptance Criteria
- Generated artifacts are reviewed before implementation.
- Required sections are present for release planning.
"""
        elif kind == "architecture":
            body = f"""
# Architecture: {project_title}

## Decision
Use the existing IdeaForge app/service boundaries and keep provider output behind validation.

## Components
- SwiftUI app surfaces.
- Shared IdeaForgeCore models and services.
- Backend AI adapter.

## Risks
- Provider output can drift unless schema and rubric checks remain enforced.
"""
        elif kind == "uxFlow":
            body = f"""
# UX Flow: {project_title}

## User Journey
- Capture an idea from Watch, iPhone, or Mac.
- Review transcript, questions, workflow runs, and artifacts.
- Export a build packet only after explicit review.

## Screens
- Inbox, project overview, transcript, questions, runs, artifacts, Codex handoff, account, and export review.

## States
- Empty, queued, recording, uploading, failed, offline, permission denied, review needed, and ready-for-build states.

## Edge Cases
- Interrupted uploads, duplicate transfers, sync conflicts, revoked permissions, long transcripts, and partial workflow failures.
"""
        elif kind == "dataModel":
            body = f"""
# Data Model: {project_title}

## Entities
- IdeaProject, Recording, Transcript, Artifact, WorkflowRun, UploadJob, Question, Assumption, ValidationExperiment, and CodexTask.

## Relationships
- Projects own recordings, questions, artifacts, assumptions, validation experiments, workflow runs, and Codex tasks.

## Storage
- Local JSON workspace state, encrypted local audio objects, Keychain-held secrets, and scoped backend objects.

## Retention Rules
- Never delete local audio before confirmed safe state; avoid raw transcript, audio path, token, and credential logs.
"""
        elif kind == "apiDesign":
            body = f"""
# API Design: {project_title}

## Endpoints
- Account provisioning, signed recording upload, workspace sync, restore drill, account usage, and workflow execution.

## Payloads
- Requests include stable project IDs, idempotency keys, content length, SHA-256 digests, schema names, and review status.

## Auth Scope
- Use workspace-bound sessions, explicit backend configuration, Keychain-backed credentials, and privacy-mode gates.

## Failure Modes
- Fail closed on digest mismatch, idempotency conflict, missing configuration, revoked credentials, schema mismatch, and unsafe deletion state.
"""
        elif kind == "codexTaskBundle":
            body = f"""
# Codex Packet: {project_title}

## Repo Context
Implement inside the IdeaForge repository with existing SwiftPM and SwiftUI patterns.

## Tasks
- Inspect current app behavior.
- Make the smallest tested change.
- Keep external writes blocked without explicit approval.

## Checks
- Run swift test.
- Run the production verifier before handoff.

## Approval Boundary
Review before running external tools or making public writes without operator approval.
"""
        elif kind == "roadmap":
            body = f"""
# Roadmap: {project_title}

## Scope
- Capture, refine, validate, and export the idea.

## Sequence
- Stabilize capture.
- Review planning artifacts.
- Verify handoff boundaries.

## Risks
- Scope can expand without explicit review gates.
"""
        elif kind == "issueBundle":
            body = f"""
# Issue Bundle: {project_title}

## Issues
- Build capture, transcription, review, workflow execution, sync, export, and release-readiness slices.

## Labels
- macOS, iOS, watchOS, privacy, backend, workflow, verification, and release.

## Dependencies
- Capture and storage precede upload; transcript review precedes artifact export; schema validation precedes Codex handoff.

## Acceptance Checks
- Run swift test, backend self-test, production verifier, macOS launch smoke, iOS UI smoke, and privacy-safe log review.
"""
        elif kind == "validationPlan":
            body = f"""
# Validation Plan: {project_title}

## Evidence
- Validate the highest-risk assumption with a small user test.

## Risks
- Missing user evidence can make the plan overconfident.

## Acceptance Criteria
- At least one validation result is attached before release planning.
"""
        elif kind == "launchChecklist":
            body = f"""
# Launch Checklist: {project_title}

## Release Gates
- Clean tests, production verifier, signing review, package validation, upload readiness, and fail-closed release blockers.

## App Store Assets
- App icon, screenshots, metadata, privacy nutrition labels, support URL, review notes, and subscription metadata.

## Privacy Checks
- Verify local-first storage, Keychain secrets, redacted logs, explicit backend opt-in, and retention behavior.

## Monitoring Checks
- Confirm telemetry categories, restore drill, upload retry visibility, sync health, crash review, and rollback instructions.
"""
        else:
            body = f"""
# {project_title}

## Evidence
- Generated by the local IdeaForge mock backend for `{kind}`.

## Risks
- Review before treating this as production evidence.

## Next Steps
- Add acceptance criteria and owner review.
"""
        return f"{body.strip()}\n{common.strip()}"

    def markdown_with_output_contract(
        self,
        markdown: str,
        kind: str,
        project_title: str,
        output_contract: dict[str, Any] | None,
    ) -> str:
        if not isinstance(output_contract, dict):
            return markdown
        artifact_outputs = output_contract.get("artifactOutputs")
        if not isinstance(artifact_outputs, list):
            return markdown
        matching_output = next(
            (
                output
                for output in artifact_outputs
                if isinstance(output, dict) and str(output.get("kind", "")) == kind
            ),
            None,
        )
        if not matching_output:
            return markdown
        required_fields = matching_output.get("requiredFields")
        if not isinstance(required_fields, list):
            return markdown

        additions: list[str] = []
        for field in required_fields:
            if not isinstance(field, dict):
                continue
            field_name = str(field.get("name", "")).strip()
            if not field_name or markdown_contains_schema_field(markdown, field_name):
                continue
            summary = str(field.get("summary", "")).strip() or "Required structured output field."
            additions.append(
                f"## {schema_field_title(field_name)}\n"
                f"Mock structured output for {project_title}: {summary}"
            )

        if not additions:
            return markdown
        return f"{markdown}\n\n" + "\n\n".join(additions)

    def run_workflow(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        template = payload.get("template")
        project = payload.get("project")
        if not isinstance(template, dict) or not isinstance(project, dict):
            return 400, {"error": "missing_workflow_payload"}
        output_kinds = template.get("outputKinds") or ["prd"]
        workflow_denial = self.entitlement_denial("workflow_runs", 1)
        if workflow_denial:
            return 402, workflow_denial
        artifact_denial = self.entitlement_denial("artifacts_generated", len(output_kinds))
        if artifact_denial:
            return 402, artifact_denial
        output_contract = payload.get("outputContract")
        if not isinstance(output_contract, dict):
            return 400, {"error": "missing_output_contract"}
        structured_output_error = validate_structured_output_contract(output_contract, output_kinds)
        if structured_output_error:
            return 400, {"error": structured_output_error}
        project_id = str(project.get("id", "idea"))
        project_title = str(project.get("title", "Idea"))
        if self.workflow_provider:
            provider_status, provider_payload = self.workflow_provider.generate(
                template,
                project,
                output_contract,
                output_kinds,
            )
            if provider_status < 200 or provider_status >= 300:
                return provider_status, provider_payload
            artifacts = provider_payload.get("artifacts")
            if not isinstance(artifacts, list):
                return 502, {"error": "provider_invalid_workflow_artifacts", "retryable": True}
        else:
            artifacts = [
                {
                    "id": f"artifact_mock_{kind}_{project_id}",
                    "kind": kind,
                    "title": f"{kind}: {project_title}",
                    "markdown": self.markdown_with_output_contract(
                        self.workflow_markdown(str(kind), project_title),
                        str(kind),
                        project_title,
                        output_contract,
                    ),
                    "version": 1,
                    "createdBy": "mock-backend",
                    "createdAt": iso_now(),
                }
                for kind in output_kinds
            ]
        if self.storage:
            job_id = self.storage.record_job(
                "workflow",
                "running",
                idea_id=project_id,
                workflow_template_id=template.get("id"),
                detail={"artifactCount": len(artifacts), "outputKinds": output_kinds},
            )
            self.storage.write_workflow_result(job_id, artifacts)
            return 202, {"jobID": job_id, "status": "queued"}
        return 200, {"artifacts": artifacts}

    def workflow_job(self, job_id: str) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 404, {"error": "job_not_found"}
        job = self.storage.read_job(job_id)
        if not job or job.get("kind") != "workflow":
            return 404, {"error": "job_not_found"}
        artifacts = self.storage.read_workflow_result(job_id)
        if artifacts is None:
            return 500, {"error": "workflow_result_missing", "retryable": False}
        if job.get("status") != "completed":
            self.storage.complete_job(job_id)
            artifact_count = len(artifacts)
            self.storage.record_usage("workflow_runs", 1, idea_id=job.get("ideaProjectID"), job_id=job_id)
            self.storage.record_usage("artifacts_generated", artifact_count, idea_id=job.get("ideaProjectID"), job_id=job_id)
            self.storage.append_audit_event(
                "workflow_completed",
                {
                    "workflowTemplateID": job.get("workflowTemplateID"),
                    "ideaProjectID": job.get("ideaProjectID"),
                    "artifactCount": artifact_count,
                    "jobID": job_id,
                },
            )
        return 200, {
            "jobID": job_id,
            "status": "completed",
            "artifacts": artifacts,
        }

    def audit_events(self) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 200, {"events": []}
        return 200, {"events": self.storage.read_audit_events()}

    def jobs(self) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 200, {"jobs": []}
        return 200, {"jobs": self.storage.list_jobs()}

    def operations_status(self) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 503, {
                "status": "blocked",
                "generatedAt": iso_now(),
                "checks": [{"name": "database", "status": "missing"}],
            }
        return 200, self.storage.operations_status()

    def backup_manifest(self) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 503, {
                "error": "backup_storage_unavailable",
                "retryable": True,
            }
        return 200, self.storage.backup_manifest()

    def operations_metrics(self) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 503, {
                "error": "metrics_storage_unavailable",
                "retryable": True,
            }
        return 200, self.storage.operations_metrics()

    def restore_drill(self, request: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        if not self.storage:
            return 503, {
                "error": "restore_drill_storage_unavailable",
                "retryable": True,
            }
        return 200, self.storage.restore_drill(request)

    def account_payload(self, workspace_id: str | None = None) -> dict[str, Any]:
        requested_workspace_id = (workspace_id or self.workspace_id).strip()
        account = self.storage.load_account(requested_workspace_id) if self.storage else None
        if account:
            return {
                "userID": account["user_id"],
                "email": account["email"],
                "workspaceID": account["workspace_id"],
                "account": {
                    "id": account["account_id"],
                    "planName": account["plan_name"],
                    "planStatus": account["plan_status"],
                },
                "capabilities": list(account["capabilities"]),
                "accountPortalURL": f"https://accounts.example.test/workspaces/{account['workspace_id']}",
                "accountDeletionURL": f"https://accounts.example.test/workspaces/{account['workspace_id']}/delete",
            }
        return {
            "userID": "user_local_dev",
            "email": "builder@example.test",
            "workspaceID": self.workspace_id,
            "account": {
                "id": "acct_local_dev",
                "planName": "Pro",
                "planStatus": "active",
            },
            "capabilities": self.capabilities,
            "accountPortalURL": "https://accounts.example.test/ideaforge",
            "accountDeletionURL": "https://accounts.example.test/ideaforge/delete",
        }

    def auth_session(self, workspace_id: str | None = None) -> tuple[int, dict[str, Any]]:
        return 200, self.account_payload(workspace_id)

    def provision_account(self, payload: dict[str, Any], idempotency_key: str | None = None) -> tuple[int, dict[str, Any]]:
        email = str(payload.get("email", "")).strip().lower()
        workspace_id = str(payload.get("workspaceID", "")).strip()
        display_name = str(payload.get("displayName", "")).strip()
        if "@" not in email or email.startswith("@") or email.endswith("@"):
            return 400, {"error": "invalid_email", "detail": "Provisioning requires a valid email address."}
        if not safe_identifier(workspace_id) or safe_identifier(workspace_id) != workspace_id.lower().replace("-", "_"):
            return 400, {"error": "invalid_workspace_id", "detail": "Workspace ID must be stable and URL safe."}
        if not self.storage:
            return 503, {"error": "provisioning_storage_unavailable"}

        existing = self.storage.load_account(workspace_id)
        created = existing is None
        if existing and existing["email"] != email:
            return 409, {"error": "workspace_already_provisioned"}
        if created:
            account = self.storage.provision_account(
                email=email,
                workspace_id=workspace_id,
                display_name=display_name,
                capabilities=DEFAULT_CAPABILITIES,
            )
            job_id = self.storage.record_job(
                "account_provisioning",
                "completed",
                detail={
                    "workspaceID": workspace_id,
                    "accountID": account["account_id"],
                    "idempotencyKeyPresent": bool((idempotency_key or "").strip()),
                    "emailDomain": email.split("@", 1)[1],
                },
            )
            self.storage.append_audit_event(
                "account_provisioned",
                {
                    "jobID": job_id,
                    "workspaceID": workspace_id,
                    "accountID": account["account_id"],
                    "emailDomain": email.split("@", 1)[1],
                },
            )
        else:
            account = existing

        session = self.account_payload(workspace_id)
        return 201 if created else 200, {
            "workspaceID": account["workspace_id"],
            "account": session["account"],
            "session": session,
            "bearerToken": account["bearer_token"],
            "created": created,
        }

    def usage_summary(self, workspace_id: str | None = None) -> tuple[int, dict[str, Any]]:
        usage = self.storage.usage_summary() if self.storage else []
        session = self.account_payload(workspace_id)
        return 200, {
            "account": session["account"],
            "accountPortalURL": session["accountPortalURL"],
            "accountDeletionURL": session["accountDeletionURL"],
            "workspaceID": session["workspaceID"],
            "usage": usage,
            "entitlements": self.entitlements_for_usage(usage),
        }

    def reconcile_billing(self, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        reason = str(payload.get("reason", "")).strip()
        if reason not in {"purchase", "restore", "refresh"}:
            return 400, {"error": "invalid_billing_reason"}
        transactions = payload.get("transactions")
        if not isinstance(transactions, list) or not transactions:
            return 400, {"error": "missing_app_store_transactions"}
        product_ids: list[str] = []
        for transaction in transactions:
            if not isinstance(transaction, dict):
                return 400, {"error": "invalid_app_store_transaction"}
            product_id = str(transaction.get("productID", "")).strip()
            transaction_id = str(transaction.get("transactionID", "")).strip()
            original_transaction_id = str(transaction.get("originalTransactionID", "")).strip()
            app_bundle_id = str(transaction.get("appBundleID", "")).strip()
            signed_transaction_jws = str(transaction.get("signedTransactionJWS", "")).strip()
            if not all([product_id, transaction_id, original_transaction_id, app_bundle_id, signed_transaction_jws]):
                return 400, {"error": "incomplete_app_store_transaction_evidence"}
            jws_issue = self.app_store_jws_verifier.verify(transaction)
            if jws_issue:
                return 400, {"error": jws_issue}
            product_ids.append(product_id)
        if self.storage:
            job_id = self.storage.record_job(
                "billing_reconciliation",
                "completed",
                detail={
                    "reason": reason,
                    "transactionCount": len(transactions),
                    "productIDs": sorted(set(product_ids)),
                },
            )
            self.storage.append_audit_event(
                "billing_reconciled",
                {
                    "jobID": job_id,
                    "reason": reason,
                    "transactionCount": len(transactions),
                    "productIDs": sorted(set(product_ids)),
                },
            )
        return self.usage_summary()

    def entitlements_for_usage(self, usage: list[dict[str, Any]]) -> list[dict[str, Any]]:
        used_by_metric = {
            str(item.get("metric", "")): float(item.get("quantity", 0.0))
            for item in usage
            if item.get("metric") in ENTITLEMENT_LIMITS
        }
        return [
            {
                "metric": metric,
                "includedQuantity": included,
                "usedQuantity": used_by_metric.get(metric, 0.0),
                "remainingQuantity": max(included - used_by_metric.get(metric, 0.0), 0.0),
            }
            for metric, included in ENTITLEMENT_LIMITS.items()
        ]

    def entitlement_denial(self, metric: str, requested_quantity: float) -> dict[str, Any] | None:
        if not self.storage:
            return None
        included_quantity = ENTITLEMENT_LIMITS.get(metric)
        if included_quantity is None:
            return {
                "error": "missing_entitlement",
                "code": "missing_entitlement",
                "metric": metric,
                "retryable": False,
            }
        usage = self.storage.usage_summary()
        used_quantity = next(
            (float(item.get("quantity", 0.0)) for item in usage if item.get("metric") == metric),
            0.0,
        )
        remaining_quantity = max(included_quantity - used_quantity, 0.0)
        if remaining_quantity < requested_quantity:
            return {
                "error": "entitlement_exhausted",
                "code": "entitlement_exhausted",
                "metric": metric,
                "retryable": False,
                "remainingQuantity": remaining_quantity,
            }
        return None


def normalized_schema_field_label(text: str) -> str:
    return " ".join(text.replace("_", " ").replace("-", " ").split()).lower()


def normalized_schema_line(line: str) -> str:
    text = line.strip()
    while text and text[0] in "#*-•0123456789. ":
        text = text[1:].strip()
    if ":" in text:
        text = text.split(":", 1)[0]
    return normalized_schema_field_label(text)


def markdown_contains_schema_field(markdown: str, field_name: str) -> bool:
    expected = normalized_schema_field_label(field_name)
    return any(
        line == expected or line.startswith(f"{expected} ")
        for line in (normalized_schema_line(raw_line) for raw_line in markdown.splitlines())
    )


def schema_field_title(field_name: str) -> str:
    return " ".join(
        word[:1].upper() + word[1:].lower()
        for word in field_name.replace("_", " ").replace("-", " ").split()
    )


def validate_structured_output_contract(
    output_contract: dict[str, Any],
    output_kinds: list[Any],
) -> str | None:
    structured_output = output_contract.get("structuredOutput")
    if not isinstance(structured_output, dict):
        return "missing_structured_output"
    if structured_output.get("strict") is not True:
        return "structured_output_not_strict"
    schema = structured_output.get("schema")
    if not isinstance(schema, dict):
        return "missing_structured_output_schema"
    if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
        return "invalid_structured_output_root_schema"
    properties = schema.get("properties")
    if not isinstance(properties, dict):
        return "missing_structured_output_properties"
    artifacts_schema = properties.get("artifacts")
    if not isinstance(artifacts_schema, dict) or artifacts_schema.get("type") != "array":
        return "missing_artifacts_array_schema"
    item_schema = artifacts_schema.get("items")
    if not isinstance(item_schema, dict):
        return "missing_artifact_item_schema"
    item_properties = item_schema.get("properties")
    if not isinstance(item_properties, dict):
        return "missing_artifact_item_properties"
    kind_schema = item_properties.get("kind")
    if not isinstance(kind_schema, dict):
        return "missing_artifact_kind_schema"
    expected_kinds = [str(kind) for kind in output_kinds]
    if kind_schema.get("enum") != expected_kinds:
        return "artifact_kind_schema_mismatch"
    return None


class FileBackendStorage:
    def __init__(self, state_dir: Path) -> None:
        self.state_dir = state_dir
        self.objects_dir = state_dir / "objects"
        self.workspace_path = state_dir / "workspace.json"
        self.audit_path = state_dir / "audit.jsonl"
        self.db_path = state_dir / "backend.db"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.objects_dir.mkdir(parents=True, exist_ok=True)
        self.initialize_database()
        if not self.workspace_path.exists():
            self.write_workspace(seed_workspace())
        self.write_object("audio/idea_mock_backend/rec_mock_backend.m4a", b"seed-audio")
        self.record_object(
            "audio/idea_mock_backend/rec_mock_backend.m4a",
            "rec_mock_backend",
            "idea_mock_backend",
            len(b"seed-audio"),
            "audio/mp4",
        )

    def initialize_database(self) -> None:
        run_backend_migrations(self.state_dir)

    def applied_migrations(self) -> list[dict[str, Any]]:
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            rows = connection.execute(
                """
                SELECT version, applied_at
                FROM schema_migrations
                ORDER BY applied_at, version
                """
            ).fetchall()
        return [
            {
                "version": row["version"],
                "appliedAt": row["applied_at"],
            }
            for row in rows
        ]

    def table_counts(self) -> dict[str, int]:
        tables = {
            "accounts": "accounts",
            "auditEvents": None,
            "jobs": "jobs",
            "objects": "objects",
            "transcriptionResults": "transcription_results",
            "workflowResults": "workflow_results",
            "usageEvents": "usage_events",
        }
        counts: dict[str, int] = {}
        with sqlite3.connect(self.db_path) as connection:
            for label, table in tables.items():
                if table is None:
                    continue
                row = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
                counts[label] = int(row[0]) if row else 0
        counts["auditEvents"] = len(self.read_audit_events())
        return counts

    def tenant_summaries(self) -> list[dict[str, Any]]:
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            rows = connection.execute(
                """
                SELECT
                    workspace_id,
                    account_id,
                    plan_name,
                    plan_status,
                    capabilities_json,
                    created_at
                FROM accounts
                ORDER BY workspace_id
                """
            ).fetchall()
        return [
            {
                "workspaceID": row["workspace_id"],
                "accountID": row["account_id"],
                "planName": row["plan_name"],
                "planStatus": row["plan_status"],
                "capabilitiesCount": len(json.loads(row["capabilities_json"])),
                "createdAt": row["created_at"],
            }
            for row in rows
        ]

    def operations_status(self) -> dict[str, Any]:
        migrations = self.applied_migrations()
        current_migration_applied = any(item["version"] == BACKEND_SCHEMA_VERSION for item in migrations)
        workspace = self.load_workspace()
        seed_object_available = self.object_exists("audio/idea_mock_backend/rec_mock_backend.m4a")
        checks = [
            {"name": "database", "status": "ok" if self.db_path.exists() else "missing"},
            {"name": "schema_migrations", "status": "ok" if current_migration_applied else "missing"},
            {"name": "workspace", "status": "ok" if bool(workspace.get("projects")) else "empty"},
            {"name": "object_storage", "status": "ok" if seed_object_available else "missing_seed_object"},
        ]
        status = "ready" if all(check["status"] == "ok" for check in checks) else "degraded"
        return {
            "status": status,
            "generatedAt": iso_now(),
            "schema": {
                "currentVersion": BACKEND_SCHEMA_VERSION,
                "appliedMigrations": migrations,
            },
            "checks": checks,
            "counts": self.table_counts(),
            "tenants": self.tenant_summaries(),
        }

    def backup_manifest(self) -> dict[str, Any]:
        workspace = self.load_workspace()
        with sqlite3.connect(self.db_path) as connection:
            row = connection.execute(
                "SELECT COUNT(*) AS object_count, COALESCE(SUM(byte_count), 0) AS total_bytes FROM objects"
            ).fetchone()
        object_count = int(row[0]) if row else 0
        total_bytes = int(row[1]) if row else 0
        return {
            "generatedAt": iso_now(),
            "schemaVersion": BACKEND_SCHEMA_VERSION,
            "workspace": {
                "projectCount": len(workspace.get("projects", [])),
                "workflowTemplateCount": len(workspace.get("workflowTemplates", [])),
                "uploadJobCount": len(workspace.get("uploadJobs", [])),
                "updatedAt": workspace.get("updatedAt"),
            },
            "storage": {
                "objectCount": object_count,
                "totalObjectBytes": total_bytes,
            },
            "operations": {
                "accountCount": self.table_counts()["accounts"],
                "auditEventCount": self.table_counts()["auditEvents"],
                "jobCount": self.table_counts()["jobs"],
                "usageEventCount": self.table_counts()["usageEvents"],
            },
            "tenants": self.tenant_summaries(),
            "privacy": {
                "includesRawTranscript": False,
                "includesRawAudio": False,
                "includesBearerTokens": False,
                "includesEmailAddresses": False,
                "includesGeneratedArtifacts": False,
            },
        }

    def restore_drill(self, request: dict[str, Any]) -> dict[str, Any]:
        manifest = self.backup_manifest()
        source_generated_at = str(request.get("backupGeneratedAt") or "")
        requested_schema = str(request.get("schemaVersion") or "")
        privacy = {
            "includesRawTranscript": False,
            "includesRawAudio": False,
            "includesBearerTokens": False,
            "includesEmailAddresses": False,
            "includesGeneratedArtifacts": False,
            "includesLocalPaths": False,
        }
        checks = [
            {
                "name": "schema_version",
                "status": "ok" if requested_schema == BACKEND_SCHEMA_VERSION else "mismatch",
            },
            {
                "name": "backup_reference",
                "status": "ok" if source_generated_at else "missing",
            },
            {
                "name": "workspace_snapshot",
                "status": "ok" if manifest["workspace"]["projectCount"] > 0 else "empty",
            },
            {
                "name": "object_inventory",
                "status": "ok" if manifest["storage"]["objectCount"] > 0 and manifest["storage"]["totalObjectBytes"] > 0 else "empty",
            },
            {
                "name": "operations_tables",
                "status": "ok" if manifest["operations"]["accountCount"] > 0 else "empty",
            },
            {
                "name": "privacy_redaction",
                "status": "ok" if not any(privacy.values()) and manifest["privacy"] == {
                    "includesRawTranscript": False,
                    "includesRawAudio": False,
                    "includesBearerTokens": False,
                    "includesEmailAddresses": False,
                    "includesGeneratedArtifacts": False,
                } else "leaking",
            },
        ]
        return {
            "status": "passed" if all(check["status"] == "ok" for check in checks) else "failed",
            "generatedAt": iso_now(),
            "sourceBackupGeneratedAt": source_generated_at,
            "schemaVersion": BACKEND_SCHEMA_VERSION,
            "checks": checks,
            "restored": {
                "workspace": manifest["workspace"],
                "storage": manifest["storage"],
                "operations": manifest["operations"],
            },
            "privacy": privacy,
        }

    def operations_metrics(self) -> dict[str, Any]:
        status = self.operations_status()["status"]
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            status_rows = connection.execute(
                """
                SELECT status, COUNT(*) AS count
                FROM jobs
                GROUP BY status
                ORDER BY status
                """
            ).fetchall()
            kind_rows = connection.execute(
                """
                SELECT kind, COUNT(*) AS count
                FROM jobs
                GROUP BY kind
                ORDER BY kind
                """
            ).fetchall()
            storage_row = connection.execute(
                "SELECT COUNT(*) AS object_count, COALESCE(SUM(byte_count), 0) AS total_bytes FROM objects"
            ).fetchone()
        privacy = {
            "includesRawTranscript": False,
            "includesRawAudio": False,
            "includesBearerTokens": False,
            "includesEmailAddresses": False,
            "includesGeneratedArtifacts": False,
            "includesLocalPaths": False,
        }
        return {
            "status": status,
            "generatedAt": iso_now(),
            "schemaVersion": BACKEND_SCHEMA_VERSION,
            "jobCountsByStatus": {row["status"]: int(row["count"]) for row in status_rows},
            "jobCountsByKind": {row["kind"]: int(row["count"]) for row in kind_rows},
            "storage": {
                "objectCount": int(storage_row["object_count"]) if storage_row else 0,
                "totalObjectBytes": int(storage_row["total_bytes"]) if storage_row else 0,
            },
            "usage": self.usage_summary(),
            "privacy": privacy,
        }

    def next_id(self, prefix: str, table: str) -> str:
        with sqlite3.connect(self.db_path) as connection:
            row = connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
        count = int(row[0]) if row else 0
        return f"{prefix}_{count + 1}"

    def load_workspace(self) -> dict[str, Any]:
        with self.workspace_path.open("r", encoding="utf-8") as handle:
            return json.load(handle)

    def write_workspace(self, workspace: dict[str, Any]) -> None:
        temporary_path = self.workspace_path.with_suffix(".json.tmp")
        with temporary_path.open("w", encoding="utf-8") as handle:
            json.dump(workspace, handle, indent=2, sort_keys=True)
            handle.write("\n")
        temporary_path.replace(self.workspace_path)

    def provision_account(
        self,
        *,
        email: str,
        workspace_id: str,
        display_name: str,
        capabilities: list[str],
    ) -> dict[str, Any]:
        suffix = safe_identifier(workspace_id)
        account = {
            "workspace_id": workspace_id,
            "account_id": f"acct_{suffix}",
            "user_id": f"user_{suffix}",
            "email": email,
            "display_name": display_name or None,
            "plan_name": "Free",
            "plan_status": "trialing",
            "bearer_token": f"token_{suffix}",
            "capabilities": capabilities,
            "created_at": iso_now(),
        }
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                INSERT INTO accounts (
                    workspace_id,
                    account_id,
                    user_id,
                    email,
                    display_name,
                    plan_name,
                    plan_status,
                    bearer_token,
                    capabilities_json,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    account["workspace_id"],
                    account["account_id"],
                    account["user_id"],
                    account["email"],
                    account["display_name"],
                    account["plan_name"],
                    account["plan_status"],
                    account["bearer_token"],
                    json.dumps(account["capabilities"], sort_keys=True),
                    account["created_at"],
                ),
            )
        return account

    def load_account(self, workspace_id: str) -> dict[str, Any] | None:
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            row = connection.execute(
                """
                SELECT
                    workspace_id,
                    account_id,
                    user_id,
                    email,
                    display_name,
                    plan_name,
                    plan_status,
                    bearer_token,
                    capabilities_json,
                    created_at
                FROM accounts
                WHERE workspace_id = ?
                """,
                (workspace_id,),
            ).fetchone()
        if row is None:
            return None
        return {
            "workspace_id": row["workspace_id"],
            "account_id": row["account_id"],
            "user_id": row["user_id"],
            "email": row["email"],
            "display_name": row["display_name"],
            "plan_name": row["plan_name"],
            "plan_status": row["plan_status"],
            "bearer_token": row["bearer_token"],
            "capabilities": json.loads(row["capabilities_json"]),
            "created_at": row["created_at"],
        }

    def write_object(self, object_key: str, body: bytes) -> Path:
        destination = self.object_path(object_key)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(body)
        return destination

    def record_object(
        self,
        object_key: str,
        recording_id: str,
        idea_id: str,
        byte_count: int,
        content_type: str = "application/octet-stream",
    ) -> None:
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                INSERT OR REPLACE INTO objects (
                    object_key,
                    recording_id,
                    idea_id,
                    byte_count,
                    content_type,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (object_key, recording_id, idea_id, byte_count, content_type, iso_now()),
            )

    def object_exists(self, object_key: str) -> bool:
        try:
            return self.object_path(object_key).exists()
        except ValueError:
            return False

    def object_metadata(self, object_key: str) -> dict[str, Any] | None:
        if not object_key.strip():
            return None
        try:
            is_available = self.object_path(object_key).exists()
        except ValueError:
            return None
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            row = connection.execute(
                """
                SELECT object_key, recording_id, idea_id, byte_count, content_type, created_at
                FROM objects
                WHERE object_key = ?
                """,
                (object_key,),
            ).fetchone()
        if row is None:
            return None
        return {
            "objectKey": row["object_key"],
            "recordingID": row["recording_id"],
            "ideaProjectID": row["idea_id"],
            "byteCount": row["byte_count"],
            "contentType": row["content_type"],
            "createdAt": row["created_at"],
            "isAvailable": is_available,
        }

    def object_path(self, object_key: str) -> Path:
        raw_parts = object_key.split("/")
        if any(part in ("", ".", "..") for part in raw_parts):
            raise ValueError("Object key contains invalid path segments.")
        clean_parts = raw_parts
        if not clean_parts:
            raise ValueError("Object key must contain at least one path segment.")
        destination = self.objects_dir.joinpath(*clean_parts).resolve()
        root = self.objects_dir.resolve()
        if root != destination and root not in destination.parents:
            raise ValueError("Object key escapes storage root.")
        return destination

    def append_audit_event(self, event_type: str, payload: dict[str, Any]) -> None:
        event = {
            "id": f"audit_{self.audit_path.stat().st_size if self.audit_path.exists() else 0}",
            "type": event_type,
            "createdAt": iso_now(),
            "payload": payload,
        }
        with self.audit_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True))
            handle.write("\n")

    def record_job(
        self,
        kind: str,
        status: str,
        *,
        idea_id: str | None = None,
        recording_id: str | None = None,
        workflow_template_id: str | None = None,
        object_key: str | None = None,
        detail: dict[str, Any] | None = None,
    ) -> str:
        job_id = self.next_id("job", "jobs")
        completed_at = iso_now() if status == "completed" else None
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                INSERT INTO jobs (
                    id,
                    kind,
                    status,
                    idea_id,
                    recording_id,
                    workflow_template_id,
                    object_key,
                    detail_json,
                    created_at,
                    completed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    kind,
                    status,
                    idea_id,
                    recording_id,
                    workflow_template_id,
                    object_key,
                    json.dumps(detail or {}, sort_keys=True),
                    iso_now(),
                    completed_at,
                ),
            )
        return job_id

    def read_job(self, job_id: str) -> dict[str, Any] | None:
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            row = connection.execute(
                """
                SELECT
                    id,
                    kind,
                    status,
                    idea_id,
                    recording_id,
                    workflow_template_id,
                    object_key,
                    detail_json,
                    created_at,
                    completed_at
                FROM jobs
                WHERE id = ?
                """,
                (job_id,),
            ).fetchone()
        if row is None:
            return None
        return self.job_row(row)

    def complete_job(self, job_id: str) -> None:
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                UPDATE jobs
                SET status = 'completed', completed_at = COALESCE(completed_at, ?)
                WHERE id = ?
                """,
                (iso_now(), job_id),
            )

    def write_transcription_result(self, job_id: str, transcript: dict[str, Any]) -> None:
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                INSERT OR REPLACE INTO transcription_results (
                    job_id,
                    transcript_json,
                    created_at
                ) VALUES (?, ?, ?)
                """,
                (job_id, json.dumps(transcript, sort_keys=True), iso_now()),
            )

    def read_transcription_result(self, job_id: str) -> dict[str, Any] | None:
        with sqlite3.connect(self.db_path) as connection:
            row = connection.execute(
                """
                SELECT transcript_json
                FROM transcription_results
                WHERE job_id = ?
                """,
                (job_id,),
            ).fetchone()
        if row is None:
            return None
        return json.loads(row[0])

    def write_workflow_result(self, job_id: str, artifacts: list[dict[str, Any]]) -> None:
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                INSERT OR REPLACE INTO workflow_results (
                    job_id,
                    artifacts_json,
                    created_at
                ) VALUES (?, ?, ?)
                """,
                (job_id, json.dumps(artifacts, sort_keys=True), iso_now()),
            )

    def read_workflow_result(self, job_id: str) -> list[dict[str, Any]] | None:
        with sqlite3.connect(self.db_path) as connection:
            row = connection.execute(
                """
                SELECT artifacts_json
                FROM workflow_results
                WHERE job_id = ?
                """,
                (job_id,),
            ).fetchone()
        if row is None:
            return None
        return json.loads(row[0])

    def record_usage(
        self,
        metric: str,
        quantity: float,
        *,
        idea_id: str | None = None,
        job_id: str | None = None,
    ) -> str:
        usage_id = self.next_id("usage", "usage_events")
        with sqlite3.connect(self.db_path) as connection:
            connection.execute(
                """
                INSERT INTO usage_events (
                    id,
                    metric,
                    quantity,
                    idea_id,
                    job_id,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (usage_id, metric, quantity, idea_id, job_id, iso_now()),
            )
        return usage_id

    def list_jobs(self) -> list[dict[str, Any]]:
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            rows = connection.execute(
                """
                SELECT
                    id,
                    kind,
                    status,
                    idea_id,
                    recording_id,
                    workflow_template_id,
                    object_key,
                    detail_json,
                    created_at,
                    completed_at
                FROM jobs
                ORDER BY rowid
                """
            ).fetchall()
        return [self.job_row(row) for row in rows]

    def job_row(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "kind": row["kind"],
            "status": row["status"],
            "ideaProjectID": row["idea_id"],
            "recordingID": row["recording_id"],
            "workflowTemplateID": row["workflow_template_id"],
            "objectKey": row["object_key"],
            "detail": json.loads(row["detail_json"]),
            "createdAt": row["created_at"],
            "completedAt": row["completed_at"],
        }

    def usage_summary(self) -> list[dict[str, Any]]:
        with sqlite3.connect(self.db_path) as connection:
            connection.row_factory = sqlite3.Row
            rows = connection.execute(
                """
                SELECT metric, SUM(quantity) AS quantity
                FROM usage_events
                GROUP BY metric
                ORDER BY metric
                """
            ).fetchall()
        return [{"metric": row["metric"], "quantity": row["quantity"]} for row in rows]

    def read_audit_events(self) -> list[dict[str, Any]]:
        if not self.audit_path.exists():
            return []
        events: list[dict[str, Any]] = []
        with self.audit_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if stripped:
                    events.append(json.loads(stripped))
        return events


def normalized_headers(handler: BaseHTTPRequestHandler) -> dict[str, str]:
    return {key.lower(): value for key, value in handler.headers.items()}


class IdeaForgeMockHandler(BaseHTTPRequestHandler):
    server_version = "IdeaForgeMockBackend/0.1"
    state: MockBackendState

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self.send_json(200, {"status": "ok"})
            return
        if not self.authorized():
            return
        if parsed.path == "/v1/workspace/snapshot":
            if not self.capable(CAP_SYNC_WORKSPACE):
                return
            status, payload = self.state.workspace_snapshot(parse_qs(parsed.query))
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/audit/events":
            if not self.capable(CAP_MANAGE_ACCOUNT):
                return
            status, payload = self.state.audit_events()
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/jobs":
            if not self.capable(CAP_MANAGE_ACCOUNT):
                return
            status, payload = self.state.jobs()
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/admin/status":
            if not self.capable(CAP_MANAGE_ACCOUNT):
                return
            status, payload = self.state.operations_status()
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/admin/backup-manifest":
            if not self.capable(CAP_MANAGE_ACCOUNT):
                return
            status, payload = self.state.backup_manifest()
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/admin/metrics":
            if not self.capable(CAP_MANAGE_ACCOUNT):
                return
            status, payload = self.state.operations_metrics()
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/objects/metadata":
            if not self.capable(CAP_RUN_AI_WORKFLOWS):
                return
            object_key = parse_qs(parsed.query).get("objectKey", [""])[0]
            status, payload = self.state.object_metadata(object_key)
            self.send_json(status, payload)
            return
        if parsed.path.startswith("/v1/ai/transcription-jobs/"):
            if not self.capable(CAP_RUN_AI_WORKFLOWS):
                return
            job_id = parsed.path.rsplit("/", 1)[-1]
            status, payload = self.state.transcription_job(job_id)
            self.send_json(status, payload)
            return
        if parsed.path.startswith("/v1/ai/workflow-jobs/"):
            if not self.capable(CAP_RUN_AI_WORKFLOWS):
                return
            job_id = parsed.path.rsplit("/", 1)[-1]
            status, payload = self.state.workflow_job(job_id)
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/auth/session":
            status, payload = self.state.auth_session(self.headers.get("X-IdeaForge-Workspace-ID"))
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/usage/summary":
            if not self.capable(CAP_MANAGE_ACCOUNT):
                return
            status, payload = self.state.usage_summary(self.headers.get("X-IdeaForge-Workspace-ID"))
            self.send_json(status, payload)
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        try:
            self._handle_post()
        except InvalidJSONBodyError:
            self.send_json(400, {"error": "invalid_json", "detail": "Request body must be a JSON object."})

    def _handle_post(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/v1/accounts/provision":
            if self.headers.get("Authorization") != f"Bearer {self.state.token}":
                self.send_json(401, {"error": "unauthorized", "detail": "Bootstrap bearer token is missing or invalid."})
                return
            body = self.read_body()
            status, payload = self.state.provision_account(
                self.decode_json(body),
                idempotency_key=self.headers.get("Idempotency-Key"),
            )
            self.send_json(status, payload)
            return
        if not self.authorized():
            return
        body = self.read_body()
        headers = normalized_headers(self)
        if parsed.path == "/v1/recordings/upload":
            if not self.capable(CAP_UPLOAD_RECORDINGS):
                return
            status, payload = self.state.upload_recording(headers, body)
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/ai/transcriptions":
            if not self.capable(CAP_RUN_AI_WORKFLOWS):
                return
            status, payload = self.state.transcribe(self.decode_json(body))
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/ai/workflows/run":
            if not self.capable(CAP_RUN_AI_WORKFLOWS):
                return
            status, payload = self.state.run_workflow(self.decode_json(body))
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/billing/app-store/reconcile":
            if not self.capable(CAP_RECONCILE_BILLING):
                return
            status, payload = self.state.reconcile_billing(self.decode_json(body))
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/devices/apns":
            if not self.capable(CAP_REGISTER_PUSH_NOTIFICATIONS):
                return
            status, payload = self.state.register_push_device(self.decode_json(body))
            self.send_json(status, payload)
            return
        if parsed.path == "/v1/admin/restore-drill":
            if not self.capable(CAP_MANAGE_ACCOUNT):
                return
            status, payload = self.state.restore_drill(self.decode_json(body))
            self.send_json(status, payload)
            return
        self.send_json(404, {"error": "not_found"})

    def do_PUT(self) -> None:
        try:
            self._handle_put()
        except InvalidJSONBodyError:
            self.send_json(400, {"error": "invalid_json", "detail": "Request body must be a JSON object."})

    def _handle_put(self) -> None:
        parsed = urlparse(self.path)
        if not self.authorized():
            return
        body = self.read_body()
        headers = normalized_headers(self)
        if parsed.path == "/v1/workspace/snapshot":
            if not self.capable(CAP_SYNC_WORKSPACE):
                return
            status, payload = self.state.publish_workspace_snapshot(headers, self.decode_json(body))
            self.send_json(status, payload)
            return
        self.send_json(404, {"error": "not_found"})

    def authorized(self) -> bool:
        ok, status, payload = self.state.check_authorization(
            self.headers.get("Authorization"),
            self.headers.get("X-IdeaForge-Workspace-ID"),
        )
        if ok:
            return True
        self.send_json(status, payload or {"error": "unauthorized"})
        return False

    def capable(self, capability: str) -> bool:
        ok, status, payload = self.state.check_capability(capability)
        if ok:
            return True
        self.send_json(status, payload or {"error": "capability_forbidden"})
        return False

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length > 0 else b""

    def decode_json(self, body: bytes) -> dict[str, Any]:
        if not body:
            return {}
        try:
            decoded = json.loads(body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise InvalidJSONBodyError from error
        if not isinstance(decoded, dict):
            raise InvalidJSONBodyError
        return decoded

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}")


def run_self_test() -> None:
    with TemporaryDirectory() as temporary_directory:
        storage = FileBackendStorage(Path(temporary_directory))
        fixture_jws_verifier = AppStoreTransactionJWSVerifier(mode=APP_STORE_JWS_FIXTURE_MODE)
        state = MockBackendState(DEFAULT_TOKEN, storage=storage, app_store_jws_verifier=fixture_jws_verifier)
        ok, _, _ = state.check_authorization(f"Bearer {DEFAULT_TOKEN}", DEFAULT_WORKSPACE_ID)
        assert ok
        ok, status_code, payload = state.check_authorization(f"Bearer {DEFAULT_TOKEN}", "")
        assert not ok
        assert status_code == 403
        assert payload and payload["error"] == "workspace_scope_mismatch"
        limited_state = MockBackendState(DEFAULT_TOKEN, capabilities=[CAP_SYNC_WORKSPACE], storage=storage)
        ok, status_code, payload = limited_state.check_capability(CAP_RUN_AI_WORKFLOWS)
        assert not ok
        assert status_code == 403
        assert payload and payload["error"] == "capability_forbidden"
        status, upload = state.upload_recording(
            {
                "x-ideaforge-recording-id": "rec_selftest",
                "x-ideaforge-idea-id": "idea_selftest",
                "x-ideaforge-upload-job-id": "upload_rec_selftest",
                "x-ideaforge-content-sha256": hashlib.sha256(b"audio").hexdigest(),
                "content-length": "5",
            },
            b"audio",
        )
        assert status == 200
        assert upload["objectKey"] == "audio/idea_selftest/rec_selftest.m4a"
        status, replay = state.upload_recording(
            {
                "x-ideaforge-recording-id": "rec_selftest",
                "x-ideaforge-idea-id": "idea_selftest",
                "x-ideaforge-upload-job-id": "upload_rec_selftest",
                "x-ideaforge-content-sha256": hashlib.sha256(b"audio").hexdigest(),
                "content-length": "5",
            },
            b"audio",
        )
        assert status == 200
        assert replay["objectKey"] == upload["objectKey"]
        assert replay["idempotentReplay"] is True
        status, digest_mismatch = state.upload_recording(
            {
                "x-ideaforge-recording-id": "rec_selftest_bad",
                "x-ideaforge-idea-id": "idea_selftest",
                "x-ideaforge-upload-job-id": "upload_rec_selftest_bad",
                "x-ideaforge-content-sha256": "0" * 64,
                "content-length": "5",
            },
            b"audio",
        )
        assert status == 400
        assert digest_mismatch["error"] == "content_digest_mismatch"
        assert storage.object_path(upload["objectKey"]).read_bytes() == b"audio"
        status, metadata = state.object_metadata(upload["objectKey"])
        assert status == 200
        assert metadata == {
            "objectKey": upload["objectKey"],
            "recordingID": "rec_selftest",
            "ideaProjectID": "idea_selftest",
            "byteCount": 5,
            "contentType": "application/octet-stream",
            "createdAt": iso_now(),
            "isAvailable": True,
        }
        status, missing_metadata = state.object_metadata("audio/idea_selftest/missing.m4a")
        assert status == 404
        assert missing_metadata["error"] == "audio_object_not_found"
        status, traversal_metadata = state.object_metadata("../secret.m4a")
        assert status == 404
        assert traversal_metadata["error"] == "audio_object_not_found"
        reloaded_state = MockBackendState(DEFAULT_TOKEN, storage=FileBackendStorage(Path(temporary_directory)))
        assert reloaded_state.workspace["projects"][0]["id"] == "idea_mock_backend"
        status, invalid_chunks = state.transcribe(
            {
                "recordingID": "rec_selftest",
                "ideaProjectID": "idea_selftest",
                "audioObjectKey": upload["objectKey"],
                "durationSeconds": 10,
                "markerOffsets": [3],
                "hint": "Invalid chunk transcript",
            }
        )
        assert status == 400
        assert invalid_chunks["error"] == "invalid_audio_chunks"
        status, invalid_chunks = state.transcribe(
            {
                "recordingID": "rec_selftest",
                "ideaProjectID": "idea_selftest",
                "audioObjectKey": upload["objectKey"],
                "audioChunks": [
                    {
                        "id": "rec_selftest_chunk_1",
                        "audioObjectKey": upload["objectKey"],
                        "startSeconds": 0,
                        "endSeconds": 4,
                    },
                    {
                        "id": "rec_selftest_chunk_2",
                        "audioObjectKey": upload["objectKey"],
                        "startSeconds": 5,
                        "endSeconds": 10,
                    },
                ],
                "durationSeconds": 10,
                "markerOffsets": [3],
                "hint": "Gapped chunk transcript",
            }
        )
        assert status == 400
        assert invalid_chunks["error"] == "invalid_audio_chunks"
        status, invalid_chunks = state.transcribe(
            {
                "recordingID": "rec_selftest",
                "ideaProjectID": "idea_selftest",
                "audioObjectKey": upload["objectKey"],
                "audioChunks": [
                    {
                        "id": "rec_selftest_chunk_1",
                        "audioObjectKey": "audio/other/rec_selftest.m4a",
                        "startSeconds": 0,
                        "endSeconds": 10,
                    }
                ],
                "durationSeconds": 10,
                "markerOffsets": [3],
                "hint": "Wrong object chunk transcript",
            }
        )
        assert status == 400
        assert invalid_chunks["error"] == "invalid_audio_chunks"
        status, transcript = state.transcribe(
            {
                "recordingID": "rec_selftest",
                "ideaProjectID": "idea_selftest",
                "audioObjectKey": upload["objectKey"],
                "audioChunks": [
                    {
                        "id": "rec_selftest_chunk_1",
                        "audioObjectKey": upload["objectKey"],
                        "startSeconds": 0,
                        "endSeconds": 10,
                    }
                ],
                "durationSeconds": 10,
                "markerOffsets": [3],
                "hint": "Self-test transcript",
            }
        )
        assert status == 202
        assert transcript["status"] == "queued"
        status, completed_transcript = state.transcription_job(transcript["jobID"])
        assert status == 200
        assert completed_transcript["status"] == "completed"
        assert completed_transcript["transcript"]["cleanText"] == "Self-test transcript"
        provider_storage = FileBackendStorage(Path(temporary_directory) / "provider")
        provider_state = MockBackendState(DEFAULT_TOKEN, storage=provider_storage)
        status, provider_upload = provider_state.upload_recording(
            {
                "x-ideaforge-recording-id": "rec_provider",
                "x-ideaforge-idea-id": "idea_provider",
                "x-ideaforge-upload-job-id": "upload_rec_provider",
                "x-ideaforge-content-sha256": hashlib.sha256(b"provider audio").hexdigest(),
                "content-length": "14",
            },
            b"provider audio",
        )
        assert status == 200
        provider_payload = {
            "recordingID": "rec_provider",
            "ideaProjectID": "idea_provider",
            "audioObjectKey": provider_upload["objectKey"],
            "audioChunks": [
                {
                    "id": "rec_provider_chunk_1",
                    "audioObjectKey": provider_upload["objectKey"],
                    "startSeconds": 0,
                    "endSeconds": 12,
                }
            ],
            "languageHint": "en",
            "durationSeconds": 12,
            "markerOffsets": [5],
            "hint": "Provider prompt context",
        }
        missing_provider_state = MockBackendState(
            DEFAULT_TOKEN,
            storage=provider_storage,
            transcription_provider=OpenAITranscriptionProvider(api_key=""),
        )
        status, missing_provider = missing_provider_state.transcribe(provider_payload)
        assert status == 503
        assert missing_provider["error"] == "provider_not_configured"

        def fake_openai_post(url: str, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
            assert url == OPENAI_TRANSCRIPTION_ENDPOINT
            assert headers["Authorization"] == "Bearer provider-token"
            assert headers["Accept"] == "application/json"
            assert b'name="model"\r\n\r\ngpt-4o-transcribe' in body
            assert b'name="response_format"\r\n\r\njson' in body
            assert b'name="file"; filename="rec_provider.m4a"' in body
            assert b"provider audio" in body
            assert b"Provider prompt context" in body
            return 200, {"text": "Provider transcript"}

        openai_provider_state = MockBackendState(
            DEFAULT_TOKEN,
            storage=provider_storage,
            transcription_provider=OpenAITranscriptionProvider(
                api_key="provider-token",
                http_post=fake_openai_post,
            ),
        )
        status, provider_job = openai_provider_state.transcribe(provider_payload)
        assert status == 202
        status, provider_completed = openai_provider_state.transcription_job(provider_job["jobID"])
        assert status == 200
        assert provider_completed["transcript"]["cleanText"] == "Provider transcript"
        assert provider_completed["transcript"]["segments"][0]["isMarkedImportant"] is True
        multi_chunk_payload = dict(provider_payload)
        multi_chunk_payload["audioChunks"] = [
            {
                "id": "rec_provider_chunk_1",
                "audioObjectKey": provider_upload["objectKey"],
                "startSeconds": 0,
                "endSeconds": 6,
            },
            {
                "id": "rec_provider_chunk_2",
                "audioObjectKey": provider_upload["objectKey"],
                "startSeconds": 6,
                "endSeconds": 12,
            },
        ]
        status, chunking_blocker = openai_provider_state.transcribe(multi_chunk_payload)
        assert status == 501
        assert chunking_blocker["error"] == "audio_chunk_slicing_unavailable"
        missing_workflow_provider_state = MockBackendState(
            DEFAULT_TOKEN,
            storage=provider_storage,
            workflow_provider=OpenAIWorkflowProvider(api_key=""),
        )
        status, missing_workflow_provider = missing_workflow_provider_state.run_workflow(
            {
                "template": {"id": "wf_prd", "outputKinds": ["prd"]},
                "project": {"id": "idea_provider", "title": "Provider workflow"},
                "outputContract": {
                    "version": 1,
                    "artifactOutputs": [
                        {
                            "kind": "prd",
                            "label": "PRD",
                            "schemaName": "PRDArtifact",
                            "requiredFields": [],
                        }
                    ],
                    "rubricRequirements": ["actionability", "evidence", "risk_coverage"],
                    "structuredOutput": {
                        "name": "ideaforge_workflow_output_v1",
                        "strict": True,
                        "schema": {
                            "type": "object",
                            "required": ["artifacts"],
                            "additionalProperties": False,
                            "properties": {
                                "artifacts": {
                                    "type": "array",
                                    "minItems": 1,
                                    "items": {
                                        "type": "object",
                                        "required": [
                                            "id",
                                            "kind",
                                            "title",
                                            "markdown",
                                            "version",
                                            "createdBy",
                                            "createdAt",
                                        ],
                                        "additionalProperties": False,
                                        "properties": {
                                            "id": {"type": "string"},
                                            "kind": {"type": "string", "enum": ["prd"]},
                                            "title": {"type": "string"},
                                            "markdown": {"type": "string"},
                                            "version": {"type": "integer"},
                                            "createdBy": {"type": "string"},
                                            "createdAt": {"type": "string"},
                                        },
                                    },
                                }
                            },
                        },
                    },
                },
            }
        )
        assert status == 503
        assert missing_workflow_provider["error"] == "provider_not_configured"

        def fake_openai_workflow_post(url: str, headers: dict[str, str], body: bytes) -> tuple[int, dict[str, Any]]:
            assert url == OPENAI_RESPONSES_ENDPOINT
            assert headers["Authorization"] == "Bearer provider-token"
            assert headers["Content-Type"] == "application/json"
            request_payload = json.loads(body.decode("utf-8"))
            assert request_payload["model"] == DEFAULT_OPENAI_WORKFLOW_MODEL
            assert request_payload["store"] is False
            assert "response_format" not in request_payload
            assert request_payload["text"]["format"]["type"] == "json_schema"
            assert request_payload["text"]["format"]["name"] == "ideaforge_workflow_output_v1"
            assert request_payload["text"]["format"]["strict"] is True
            assert request_payload["text"]["format"]["schema"]["properties"]["artifacts"]["type"] == "array"
            assert request_payload["input"][0]["role"] == "system"
            assert request_payload["input"][1]["role"] == "user"
            assert "Provider workflow" in request_payload["input"][1]["content"]
            return 200, {
                "status": "completed",
                "output": [
                    {
                        "type": "message",
                        "content": [
                            {
                                "type": "output_text",
                                "text": json.dumps(
                                    {
                                        "artifacts": [
                                            {
                                                "id": "artifact_provider_prd",
                                                "kind": "prd",
                                                "title": "PRD: Provider workflow",
                                                "markdown": "# PRD\n\n## Custom Signal\nProvider structured output.",
                                                "version": 1,
                                                "createdBy": "openai-responses",
                                                "createdAt": iso_now(),
                                            }
                                        ]
                                    }
                                ),
                            }
                        ],
                    }
                ],
            }

        openai_workflow_state = MockBackendState(
            DEFAULT_TOKEN,
            storage=provider_storage,
            workflow_provider=OpenAIWorkflowProvider(
                api_key="provider-token",
                http_post=fake_openai_workflow_post,
            ),
        )
        status, provider_workflow = openai_workflow_state.run_workflow(
            {
                "template": {"id": "wf_prd", "outputKinds": ["prd"]},
                "project": {"id": "idea_provider", "title": "Provider workflow"},
                "outputContract": {
                    "version": 1,
                    "artifactOutputs": [
                        {
                            "kind": "prd",
                            "label": "PRD",
                            "schemaName": "PRDArtifact",
                            "requiredFields": [
                                {
                                    "name": "custom_signal",
                                    "valueType": "string",
                                    "summary": "Provider-specific signal required by the prompt regression contract.",
                                }
                            ],
                        }
                    ],
                    "rubricRequirements": ["actionability", "evidence", "risk_coverage"],
                    "structuredOutput": {
                        "name": "ideaforge_workflow_output_v1",
                        "strict": True,
                        "schema": {
                            "type": "object",
                            "required": ["artifacts"],
                            "additionalProperties": False,
                            "properties": {
                                "artifacts": {
                                    "type": "array",
                                    "minItems": 1,
                                    "items": {
                                        "type": "object",
                                        "required": [
                                            "id",
                                            "kind",
                                            "title",
                                            "markdown",
                                            "version",
                                            "createdBy",
                                            "createdAt",
                                        ],
                                        "additionalProperties": False,
                                        "properties": {
                                            "id": {"type": "string"},
                                            "kind": {"type": "string", "enum": ["prd"]},
                                            "title": {"type": "string"},
                                            "markdown": {"type": "string"},
                                            "version": {"type": "integer"},
                                            "createdBy": {"type": "string"},
                                            "createdAt": {"type": "string"},
                                        },
                                    },
                                }
                            },
                        },
                    },
                },
            }
        )
        assert status == 202
        status, completed_provider_workflow = openai_workflow_state.workflow_job(provider_workflow["jobID"])
        assert status == 200
        assert completed_provider_workflow["artifacts"][0]["createdBy"] == "openai-responses"
        assert "Provider structured output" in completed_provider_workflow["artifacts"][0]["markdown"]
        minimal_provider_contract = {
            "structuredOutput": {
                "name": "ideaforge_workflow_output_v1",
                "schema": {"type": "object", "properties": {"artifacts": {"type": "array"}}},
            }
        }
        bad_json_provider = OpenAIWorkflowProvider(
            api_key="provider-token",
            http_post=lambda _url, _headers, _body: (
                200,
                {
                    "status": "completed",
                    "output": [
                        {
                            "type": "message",
                            "content": [{"type": "output_text", "text": "not-json"}],
                        }
                    ],
                },
            ),
        )
        status, bad_json_workflow = bad_json_provider.generate(
            {"id": "wf_prd", "outputKinds": ["prd"]},
            {"id": "idea_provider", "title": "Provider workflow"},
            minimal_provider_contract,
            ["prd"],
        )
        assert status == 502
        assert bad_json_workflow["error"] == "provider_invalid_workflow_json"
        refusing_provider = OpenAIWorkflowProvider(
            api_key="provider-token",
            http_post=lambda _url, _headers, _body: (
                200,
                {
                    "status": "completed",
                    "output": [
                        {
                            "type": "message",
                            "content": [{"type": "refusal", "refusal": "Cannot comply."}],
                        }
                    ],
                },
            ),
        )
        status, refused_workflow = refusing_provider.generate(
            {"id": "wf_prd", "outputKinds": ["prd"]},
            {"id": "idea_provider", "title": "Provider workflow"},
            minimal_provider_contract,
            ["prd"],
        )
        assert status == 403
        assert refused_workflow["error"] == "provider_refusal"
        status, workflow = state.run_workflow(
            {
                "template": {"id": "wf_prd", "outputKinds": ["prd"]},
                "project": {"id": "idea_selftest", "title": "Self-test"},
                "outputContract": {
                    "version": 1,
                    "artifactOutputs": [
                        {
                            "kind": "prd",
                            "label": "PRD",
                            "schemaName": "PRDArtifact",
                            "requiredFields": [
                                {
                                    "name": "custom_signal",
                                    "valueType": "string",
                                    "summary": "Provider-specific signal required by the prompt regression contract.",
                                }
                            ],
                        }
                    ],
                    "rubricRequirements": ["actionability", "evidence", "risk_coverage"],
                    "structuredOutput": {
                        "name": "ideaforge_workflow_output_v1",
                        "strict": True,
                        "schema": {
                            "type": "object",
                            "required": ["artifacts"],
                            "additionalProperties": False,
                            "properties": {
                                "artifacts": {
                                    "type": "array",
                                    "minItems": 1,
                                    "items": {
                                        "type": "object",
                                        "required": [
                                            "id",
                                            "kind",
                                            "title",
                                            "markdown",
                                            "version",
                                            "createdBy",
                                            "createdAt",
                                        ],
                                        "additionalProperties": False,
                                        "properties": {
                                            "id": {"type": "string"},
                                            "kind": {"type": "string", "enum": ["prd"]},
                                            "title": {"type": "string"},
                                            "markdown": {"type": "string"},
                                            "version": {"type": "integer"},
                                            "createdBy": {"type": "string"},
                                            "createdAt": {"type": "string"},
                                        },
                                    },
                                }
                            },
                        },
                    },
                },
            }
        )
        assert status == 202
        assert workflow["status"] == "queued"
        status, completed_workflow = state.workflow_job(workflow["jobID"])
        assert status == 200
        assert completed_workflow["status"] == "completed"
        assert completed_workflow["artifacts"][0]["kind"] == "prd"
        assert "## Custom Signal" in completed_workflow["artifacts"][0]["markdown"]
        status, snapshot = state.workspace_snapshot({})
        assert status == 200
        assert snapshot["projects"][0]["id"] == "idea_mock_backend"
        published_snapshot = dict(snapshot)
        published_snapshot["updatedAt"] = "2026-07-01T00:00:00Z"
        status, publish_receipt = state.publish_workspace_snapshot(
            {"x-ideaforge-base-remote-updated-at": snapshot["updatedAt"]},
            published_snapshot,
        )
        assert status == 200
        assert publish_receipt == {
            "workspaceID": DEFAULT_WORKSPACE_ID,
            "acceptedUpdatedAt": "2026-07-01T00:00:00Z",
        }
        status, stale_publish = state.publish_workspace_snapshot(
            {"x-ideaforge-base-remote-updated-at": snapshot["updatedAt"]},
            dict(published_snapshot, updatedAt="2026-07-01T00:10:00Z"),
        )
        assert status == 409
        assert stale_publish["error"] == "workspace_revision_conflict"
        status, snapshot_after_publish = state.workspace_snapshot({})
        assert status == 200
        assert snapshot_after_publish["updatedAt"] == "2026-07-01T00:00:00Z"
        status, audit = state.audit_events()
        assert status == 200
        assert [event["type"] for event in audit["events"]] == [
            "recording_uploaded",
            "transcription_completed",
            "workflow_completed",
            "workspace_snapshot_published",
        ]
        publish_audit_payload = audit["events"][-1]["payload"]
        assert publish_audit_payload == {
            "projectCount": 1,
            "uploadJobCount": 0,
            "workflowTemplateCount": 1,
            "updatedAt": "2026-07-01T00:00:00Z",
        }
        status, jobs = state.jobs()
        assert status == 200
        assert [job["kind"] for job in jobs["jobs"]] == [
            "recording_upload",
            "transcription",
            "workflow",
        ]
        assert jobs["jobs"][1]["status"] == "completed"
        assert jobs["jobs"][2]["status"] == "completed"
        assert "transcript" not in jobs["jobs"][1]["detail"]
        assert "artifacts" not in jobs["jobs"][2]["detail"]
        assert "Custom Signal" not in json.dumps(jobs["jobs"][2]["detail"])
        status, session = state.auth_session()
        assert status == 200
        assert session["userID"] == "user_local_dev"
        assert session["workspaceID"] == DEFAULT_WORKSPACE_ID
        assert session["account"]["id"] == "acct_local_dev"
        assert session["capabilities"] == [
            CAP_UPLOAD_RECORDINGS,
            CAP_SYNC_WORKSPACE,
            CAP_RUN_AI_WORKFLOWS,
            CAP_RECONCILE_BILLING,
            CAP_MANAGE_ACCOUNT,
            CAP_REGISTER_PUSH_NOTIFICATIONS,
        ]
        raw_apns_token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        status, push_receipt = state.register_push_device(
            {
                "apnsDeviceToken": raw_apns_token,
                "environment": "sandbox",
                "platform": "ios",
                "bundleID": "com.s1kor.ideaforge.ios",
                "appVersion": "1.0",
                "topics": ["workspace_sync", "recording_processing"],
            }
        )
        assert status == 200
        assert push_receipt["workspaceID"] == DEFAULT_WORKSPACE_ID
        assert push_receipt["platform"] == "ios"
        assert push_receipt["environment"] == "sandbox"
        assert push_receipt["enabledTopics"] == ["workspace_sync", "recording_processing"]
        assert push_receipt["tokenFingerprint"]
        assert raw_apns_token not in json.dumps(push_receipt)
        status, bad_push = state.register_push_device(
            {
                "apnsDeviceToken": "not-a-token",
                "environment": "sandbox",
                "platform": "ios",
                "bundleID": "com.s1kor.ideaforge.ios",
                "appVersion": "1.0",
                "topics": ["workspace_sync"],
            }
        )
        assert status == 400
        assert bad_push["error"] == "invalid_apns_device_token"
        status, provisioned = state.provision_account(
            {
                "email": "new-builder@example.test",
                "workspaceID": "workspace_beta",
                "displayName": "New Builder",
            },
            idempotency_key="idem-provision-1",
        )
        assert status == 201
        assert provisioned["created"] is True
        assert provisioned["workspaceID"] == "workspace_beta"
        assert provisioned["account"]["id"] == "acct_workspace_beta"
        assert provisioned["session"]["workspaceID"] == "workspace_beta"
        assert provisioned["session"]["capabilities"] == DEFAULT_CAPABILITIES
        assert provisioned["bearerToken"] == "token_workspace_beta"
        status, provisioned_again = state.provision_account(
            {
                "email": "new-builder@example.test",
                "workspaceID": "workspace_beta",
                "displayName": "New Builder",
            },
            idempotency_key="idem-provision-1",
        )
        assert status == 200
        assert provisioned_again["created"] is False
        assert provisioned_again["bearerToken"] == "token_workspace_beta"
        ok, _, _ = state.check_authorization("Bearer token_workspace_beta", "workspace_beta")
        assert ok
        status, scoped_publish_receipt = state.publish_workspace_snapshot(
            {
                "x-ideaforge-workspace-id": "workspace_beta",
                "x-ideaforge-base-remote-updated-at": "2026-07-01T00:00:00Z",
            },
            dict(snapshot_after_publish, updatedAt="2026-07-01T00:20:00Z"),
        )
        assert status == 200
        assert scoped_publish_receipt == {
            "workspaceID": "workspace_beta",
            "acceptedUpdatedAt": "2026-07-01T00:20:00Z",
        }
        status, beta_session = state.auth_session("workspace_beta")
        assert status == 200
        assert beta_session["account"]["planStatus"] == "trialing"
        assert beta_session["accountPortalURL"] == "https://accounts.example.test/workspaces/workspace_beta"
        provision_audit_events = [
            event for event in state.audit_events()[1]["events"] if event["type"] == "account_provisioned"
        ]
        assert provision_audit_events
        assert "email" not in provision_audit_events[0]["payload"]
        assert "bearerToken" not in provision_audit_events[0]["payload"]
        push_audit_events = [
            event for event in state.audit_events()[1]["events"] if event["type"] == "push_device_registered"
        ]
        assert push_audit_events
        assert "tokenFingerprint" in push_audit_events[0]["payload"]
        assert raw_apns_token not in json.dumps(push_audit_events[0]["payload"])
        status, operations_status = state.operations_status()
        assert status == 200
        assert operations_status["status"] == "ready"
        assert operations_status["schema"]["currentVersion"] == BACKEND_SCHEMA_VERSION
        assert operations_status["checks"] == [
            {"name": "database", "status": "ok"},
            {"name": "schema_migrations", "status": "ok"},
            {"name": "workspace", "status": "ok"},
            {"name": "object_storage", "status": "ok"},
        ]
        assert operations_status["counts"]["accounts"] == 1
        assert operations_status["counts"]["jobs"] == 4
        assert operations_status["tenants"] == [
            {
                "workspaceID": "workspace_beta",
                "accountID": "acct_workspace_beta",
                "planName": "Free",
                "planStatus": "trialing",
                "capabilitiesCount": len(DEFAULT_CAPABILITIES),
                "createdAt": iso_now(),
            }
        ]
        status, backup = state.backup_manifest()
        assert status == 200
        assert backup["schemaVersion"] == BACKEND_SCHEMA_VERSION
        assert backup["workspace"]["projectCount"] == 1
        assert backup["storage"]["objectCount"] == 2
        assert backup["operations"]["accountCount"] == 1
        assert backup["privacy"] == {
            "includesRawTranscript": False,
            "includesRawAudio": False,
            "includesBearerTokens": False,
            "includesEmailAddresses": False,
            "includesGeneratedArtifacts": False,
        }
        serialized_backup = json.dumps(backup, sort_keys=True)
        assert "new-builder@example.test" not in serialized_backup
        assert "token_workspace_beta" not in serialized_backup
        assert "Self-test transcript" not in serialized_backup
        status, metrics = state.operations_metrics()
        assert status == 200
        assert metrics["status"] == "ready"
        assert metrics["schemaVersion"] == BACKEND_SCHEMA_VERSION
        assert metrics["jobCountsByStatus"]["completed"] >= 1
        assert metrics["jobCountsByKind"]["transcription"] >= 1
        assert metrics["storage"]["objectCount"] == 2
        assert metrics["usage"]
        assert metrics["privacy"] == {
            "includesRawTranscript": False,
            "includesRawAudio": False,
            "includesBearerTokens": False,
            "includesEmailAddresses": False,
            "includesGeneratedArtifacts": False,
            "includesLocalPaths": False,
        }
        serialized_metrics = json.dumps(metrics, sort_keys=True)
        assert "new-builder@example.test" not in serialized_metrics
        assert "token_workspace_beta" not in serialized_metrics
        assert "Self-test transcript" not in serialized_metrics
        assert str(state.storage.state_dir) not in serialized_metrics
        assert str(state.storage.objects_dir) not in serialized_metrics
        status, restore = state.restore_drill(
            {
                "backupGeneratedAt": backup["generatedAt"],
                "schemaVersion": BACKEND_SCHEMA_VERSION,
            }
        )
        assert status == 200
        assert restore["status"] == "passed"
        assert restore["sourceBackupGeneratedAt"] == backup["generatedAt"]
        assert restore["schemaVersion"] == BACKEND_SCHEMA_VERSION
        assert restore["restored"]["workspace"]["projectCount"] == 1
        assert restore["restored"]["storage"]["objectCount"] == 2
        assert restore["restored"]["operations"]["accountCount"] == 1
        assert restore["privacy"] == {
            "includesRawTranscript": False,
            "includesRawAudio": False,
            "includesBearerTokens": False,
            "includesEmailAddresses": False,
            "includesGeneratedArtifacts": False,
            "includesLocalPaths": False,
        }
        assert all(check["status"] == "ok" for check in restore["checks"])
        serialized_restore = json.dumps(restore, sort_keys=True)
        assert "new-builder@example.test" not in serialized_restore
        assert "token_workspace_beta" not in serialized_restore
        assert "Self-test transcript" not in serialized_restore
        assert str(state.storage.state_dir) not in serialized_restore
        assert str(state.storage.objects_dir) not in serialized_restore
        status, usage = state.usage_summary()
        assert status == 200
        assert usage["account"] == {
            "id": "acct_local_dev",
            "planName": "Pro",
            "planStatus": "active",
        }
        assert usage["accountPortalURL"] == "https://accounts.example.test/ideaforge"
        assert usage["accountDeletionURL"] == "https://accounts.example.test/ideaforge/delete"
        assert usage["workspaceID"] == DEFAULT_WORKSPACE_ID
        assert usage["usage"] == [
            {"metric": "artifacts_generated", "quantity": 1.0},
            {"metric": "audio_bytes_stored", "quantity": 5.0},
            {"metric": "transcription_seconds", "quantity": 10.0},
            {"metric": "workflow_runs", "quantity": 1.0},
        ]
        assert usage["entitlements"] == [
            {
                "metric": "audio_bytes_stored",
                "includedQuantity": 50_000_000.0,
                "usedQuantity": 5.0,
                "remainingQuantity": 49_999_995.0,
            },
            {
                "metric": "transcription_seconds",
                "includedQuantity": 1_800.0,
                "usedQuantity": 10.0,
                "remainingQuantity": 1_790.0,
            },
            {
                "metric": "workflow_runs",
                "includedQuantity": 100.0,
                "usedQuantity": 1.0,
                "remainingQuantity": 99.0,
            },
            {
                "metric": "artifacts_generated",
                "includedQuantity": 250.0,
                "usedQuantity": 1.0,
                "remainingQuantity": 249.0,
            },
        ]
        status, billing_summary = state.reconcile_billing(
            {
                "reason": "purchase",
                "transactions": [
                    {
                        "productID": "com.s1kor.ideaforge.pro.monthly",
                        "transactionID": "123",
                        "originalTransactionID": "100",
                        "appBundleID": "com.s1kor.ideaforge.ios",
                        "purchaseDate": iso_now(),
                        "expirationDate": iso_now(),
                        "signedTransactionJWS": fixture_app_store_transaction_jws(
                            "com.s1kor.ideaforge.pro.monthly",
                            "123",
                            "100",
                            "com.s1kor.ideaforge.ios",
                        ),
                    }
                ],
            }
        )
        assert status == 200
        assert billing_summary["account"]["planStatus"] == "active"
        signed_data_state = MockBackendState(
            DEFAULT_TOKEN,
            storage=FileBackendStorage(Path(temporary_directory)),
            app_store_jws_verifier=AppStoreTransactionJWSVerifier(mode=APP_STORE_JWS_SIGNED_DATA_MODE),
        )
        status, fixture_rejected = signed_data_state.reconcile_billing(
            {
                "reason": "purchase",
                "transactions": [
                    {
                        "productID": "com.s1kor.ideaforge.pro.monthly",
                        "transactionID": "123",
                        "originalTransactionID": "100",
                        "appBundleID": "com.s1kor.ideaforge.ios",
                        "purchaseDate": iso_now(),
                        "expirationDate": iso_now(),
                        "signedTransactionJWS": fixture_app_store_transaction_jws(
                            "com.s1kor.ideaforge.pro.monthly",
                            "123",
                            "100",
                            "com.s1kor.ideaforge.ios",
                        ),
                    }
                ],
            }
        )
        assert status == 400
        assert fixture_rejected["error"] == "missing_app_store_transaction_certificate_chain"
        signed_fixture_dir = Path(temporary_directory) / "signed-app-store-fixture"
        signed_fixture_dir.mkdir()
        signed_jws, trusted_root = openssl_signed_app_store_transaction_jws(
            "com.s1kor.ideaforge.pro.monthly",
            "123",
            "100",
            "com.s1kor.ideaforge.ios",
            signed_fixture_dir,
        )
        signed_verifier_state = MockBackendState(
            DEFAULT_TOKEN,
            app_store_jws_verifier=AppStoreTransactionJWSVerifier(
                mode=APP_STORE_JWS_SIGNED_DATA_MODE,
                trusted_root_pem=str(trusted_root),
            ),
        )
        status, signed_billing_summary = signed_verifier_state.reconcile_billing(
            {
                "reason": "purchase",
                "transactions": [
                    {
                        "productID": "com.s1kor.ideaforge.pro.monthly",
                        "transactionID": "123",
                        "originalTransactionID": "100",
                        "appBundleID": "com.s1kor.ideaforge.ios",
                        "purchaseDate": iso_now(),
                        "expirationDate": iso_now(),
                        "signedTransactionJWS": signed_jws,
                    }
                ],
            }
        )
        assert status == 200
        assert signed_billing_summary["account"]["planStatus"] == "active"
        status, invalid_billing = state.reconcile_billing(
            {
                "reason": "purchase",
                "transactions": [
                    {
                        "productID": "com.s1kor.ideaforge.pro.monthly",
                        "transactionID": "123",
                    }
                ],
            }
        )
        assert status == 400
        assert invalid_billing["error"] == "incomplete_app_store_transaction_evidence"
        status, malformed_billing = state.reconcile_billing(
            {
                "reason": "purchase",
                "transactions": [
                    {
                        "productID": "com.s1kor.ideaforge.pro.monthly",
                        "transactionID": "123",
                        "originalTransactionID": "100",
                        "appBundleID": "com.s1kor.ideaforge.ios",
                        "purchaseDate": iso_now(),
                        "signedTransactionJWS": "not-jws",
                    }
                ],
            }
        )
        assert status == 400
        assert malformed_billing["error"] == "malformed_app_store_transaction_jws"
        status, mismatched_billing = state.reconcile_billing(
            {
                "reason": "purchase",
                "transactions": [
                    {
                        "productID": "com.s1kor.ideaforge.pro.monthly",
                        "transactionID": "123",
                        "originalTransactionID": "100",
                        "appBundleID": "com.s1kor.ideaforge.ios",
                        "purchaseDate": iso_now(),
                        "signedTransactionJWS": fixture_app_store_transaction_jws(
                            "com.s1kor.ideaforge.pro.yearly",
                            "123",
                            "100",
                            "com.s1kor.ideaforge.ios",
                        ),
                    }
                ],
            }
        )
        assert status == 400
        assert mismatched_billing["error"] == "app_store_transaction_claim_mismatch"
        reloaded_jobs = MockBackendState(DEFAULT_TOKEN, storage=FileBackendStorage(Path(temporary_directory))).jobs()
        assert len(reloaded_jobs[1]["jobs"]) == 5
        assert reloaded_jobs[1]["jobs"][3]["kind"] == "account_provisioning"
        assert "email" not in reloaded_jobs[1]["jobs"][3]["detail"]
        assert "bearerToken" not in reloaded_jobs[1]["jobs"][3]["detail"]
        storage.record_usage("transcription_seconds", 1_790.0, idea_id="idea_selftest")
        status, denied_transcript = state.transcribe(
            {
                "recordingID": "rec_selftest",
                "ideaProjectID": "idea_selftest",
                "audioObjectKey": upload["objectKey"],
                "audioChunks": [
                    {
                        "id": "rec_selftest_chunk_1",
                        "audioObjectKey": upload["objectKey"],
                        "startSeconds": 0,
                        "endSeconds": 1,
                    }
                ],
                "durationSeconds": 1,
                "markerOffsets": [],
                "hint": "Denied transcript",
            }
        )
        assert status == 402
        assert denied_transcript == {
            "error": "entitlement_exhausted",
            "code": "entitlement_exhausted",
            "metric": "transcription_seconds",
            "retryable": False,
            "remainingQuantity": 0.0,
        }
        storage.record_usage("workflow_runs", 99.0, idea_id="idea_selftest")
        status, denied_workflow = state.run_workflow(
            {
                "template": {"id": "wf_prd", "outputKinds": ["prd"]},
                "project": {"id": "idea_selftest", "title": "Self-test"},
            }
        )
        assert status == 402
        assert denied_workflow == {
            "error": "entitlement_exhausted",
            "code": "entitlement_exhausted",
            "metric": "workflow_runs",
            "retryable": False,
            "remainingQuantity": 0.0,
        }
    print("IdeaForge mock backend self-test passed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the IdeaForge local backend mock.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--token", default=DEFAULT_TOKEN)
    parser.add_argument("--workspace-id", default=DEFAULT_WORKSPACE_ID)
    parser.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    parser.add_argument("--transcription-provider", choices=["mock", "openai"], default="mock")
    parser.add_argument("--workflow-provider", choices=["mock", "openai"], default="mock")
    parser.add_argument(
        "--app-store-jws-verification",
        choices=[APP_STORE_JWS_SIGNED_DATA_MODE, APP_STORE_JWS_FIXTURE_MODE],
        default=APP_STORE_JWS_SIGNED_DATA_MODE,
        help="Use signed-data for production-style App Store Server JWS verification; fixture is only for deterministic local tests.",
    )
    parser.add_argument(
        "--app-store-root-ca-pem-env",
        default="APP_STORE_ROOT_CA_PEM",
        help="Environment variable containing the trusted Apple root CA PEM path for signed-data verification.",
    )
    parser.add_argument("--openai-api-key-env", default="OPENAI_API_KEY")
    parser.add_argument("--openai-transcription-model", default=DEFAULT_OPENAI_TRANSCRIPTION_MODEL)
    parser.add_argument("--openai-workflow-model", default=DEFAULT_OPENAI_WORKFLOW_MODEL)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return

    try:
        storage = FileBackendStorage(Path(args.state_dir))
    except BackendMigrationError as error:
        raise SystemExit(f"backend migration failed: {error}") from error
    transcription_provider = None
    if args.transcription_provider == "openai":
        transcription_provider = OpenAITranscriptionProvider(
            api_key=os.environ.get(args.openai_api_key_env, ""),
            model=args.openai_transcription_model,
        )
    workflow_provider = None
    if args.workflow_provider == "openai":
        workflow_provider = OpenAIWorkflowProvider(
            api_key=os.environ.get(args.openai_api_key_env, ""),
            model=args.openai_workflow_model,
        )
    IdeaForgeMockHandler.state = MockBackendState(
        args.token,
        workspace_id=args.workspace_id,
        storage=storage,
        transcription_provider=transcription_provider,
        workflow_provider=workflow_provider,
        app_store_jws_verifier=AppStoreTransactionJWSVerifier(
            mode=args.app_store_jws_verification,
            trusted_root_pem=os.environ.get(args.app_store_root_ca_pem_env, ""),
        ),
    )
    server = ThreadingHTTPServer((args.host, args.port), IdeaForgeMockHandler)
    print(f"IdeaForge mock backend listening on http://{args.host}:{args.port}", flush=True)
    print(f"Auth token fingerprint: sha256:{privacy_fingerprint(args.token)}", flush=True)
    print(f"Workspace fingerprint: sha256:{privacy_fingerprint(args.workspace_id)}", flush=True)
    print("State directory: configured", flush=True)
    print(f"Transcription provider: {args.transcription_provider}", flush=True)
    print(f"Workflow provider: {args.workflow_provider}", flush=True)
    print(f"App Store JWS verification: {args.app_store_jws_verification}", flush=True)
    if args.app_store_jws_verification == APP_STORE_JWS_SIGNED_DATA_MODE:
        configured = "configured" if os.environ.get(args.app_store_root_ca_pem_env, "").strip() else "missing"
        print(f"App Store root CA path env {args.app_store_root_ca_pem_env}: {configured}", flush=True)
    if args.transcription_provider == "openai":
        print(f"OpenAI transcription model: {args.openai_transcription_model}", flush=True)
    if args.workflow_provider == "openai":
        print(f"OpenAI workflow model: {args.openai_workflow_model}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
