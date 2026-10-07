"""Bounded HTTP transport for the production-local backend."""

from __future__ import annotations

import hashlib
import http.server
import ipaddress
import json
import ssl
import urllib.parse
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Iterable

from .auth import (
    DeviceAuthorizer,
    DeviceForbiddenError,
    DeviceUnauthorizedError,
    PairingCodeExpiredError,
    PairingCodeInvalidError,
    PairingService,
)
from .database import LocalBackendDatabase
from .jobs import JobConflictError, JobLeaseError, JobQueue
from .recordings import (
    RecordingConflictError,
    RecordingHashMismatchError,
    RecordingIntegrityError,
    RecordingNotFoundError,
    RecordingStore,
    RecordingStorageBoundaryError,
    RecordingTooLargeError,
)
from .rate_limits import PersistentRateLimiter, RateLimitPolicy
from .workspaces import (
    _canonical_json,
    IdempotencyConflictError,
    InvalidWorkspaceSnapshotError,
    WorkspaceRevisionConflictError,
    WorkspaceSnapshotTooLargeError,
    WorkspaceStore,
)


@dataclass(frozen=True)
class HTTPResult:
    status: int
    payload: dict[str, Any]


def _system_utc_now() -> datetime:
    return datetime.now(UTC)


def _timestamp(value: datetime | None) -> str | None:
    if value is None:
        return None
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Timestamp must include a timezone")
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


class LocalBackendApplication:
    def __init__(
        self,
        *,
        database: LocalBackendDatabase,
        workspace_id: str,
        pairing: PairingService,
        authorizer: DeviceAuthorizer,
        workspaces: WorkspaceStore,
        recordings: RecordingStore | None = None,
        jobs: JobQueue | None = None,
        rate_limiter: PersistentRateLimiter | None = None,
        rate_limit_policy: RateLimitPolicy = RateLimitPolicy(),
        allowed_cidrs: Iterable[str | ipaddress.IPv4Network | ipaddress.IPv6Network],
        clock: Callable[[], datetime] = _system_utc_now,
    ) -> None:
        self.database = database
        self.workspace_id = workspace_id
        self.pairing = pairing
        self.authorizer = authorizer
        self.workspaces = workspaces
        self.recordings = recordings
        self.jobs = jobs
        self.rate_limiter = rate_limiter
        self.rate_limit_policy = rate_limit_policy
        self.clock = clock
        self.allowed_networks = tuple(
            network if isinstance(network, (ipaddress.IPv4Network, ipaddress.IPv6Network))
            else ipaddress.ip_network(network, strict=False)
            for network in allowed_cidrs
        )

    def current_time(self) -> datetime:
        current = self.clock()
        if current.tzinfo is None or current.utcoffset() is None:
            raise RuntimeError("Local Backend clock must return timezone-aware UTC time")
        return current.astimezone(UTC)

    def source_is_allowed(self, source: str) -> bool:
        try:
            address = ipaddress.ip_address(source)
        except ValueError:
            return False
        return any(address.version == network.version and address in network for network in self.allowed_networks)

    def ready(self) -> bool:
        try:
            with self.database.connection() as connection:
                integrity = connection.execute("PRAGMA quick_check").fetchone()[0]
                workspace = connection.execute(
                    "SELECT COUNT(*) FROM workspaces WHERE workspace_id = ?",
                    (self.workspace_id,),
                ).fetchone()[0]
            recording_storage_ready = self.recordings is None or self.recordings.ready()
            return integrity == "ok" and workspace == 1 and recording_storage_ready
        except Exception:
            return False

    def authorize(self, headers: http.client.HTTPMessage):
        authorization = headers.get("Authorization", "")
        workspace_id = headers.get("X-IdeaForge-Workspace-ID", "").strip()
        if not authorization.startswith("Bearer "):
            raise DeviceUnauthorizedError("Device authorization failed")
        return self.authorizer.authorize(
            authorization.removeprefix("Bearer "),
            workspace_id,
            self.current_time(),
        )

    def session_payload(self, device_id: str) -> dict[str, Any]:
        return {
            "userID": "local_operator",
            "email": None,
            "workspaceID": self.workspace_id,
            "account": {
                "id": "local_account",
                "planName": "Local",
                "planStatus": "active",
            },
            "capabilities": ["sync_workspace"]
            + (["upload_recordings"] if self.recordings else [])
            + (["process_recordings"] if self.recordings and self.jobs else []),
            "accountPortalURL": None,
            "accountDeletionURL": None,
        }


class _ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], application: LocalBackendApplication):
        self.application = application
        super().__init__(server_address, _LocalBackendRequestHandler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(30)
        return request, address

    def process_request_thread(self, request, client_address) -> None:
        # The accepting thread must stay available while a peer negotiates TLS.
        if isinstance(request, ssl.SSLSocket):
            try:
                request.do_handshake()
            except OSError:
                self.shutdown_request(request)
                return
        super().process_request_thread(request, client_address)


class _LocalBackendRequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "IdeaForgeLocalBackend"
    sys_version = ""

    def handle(self) -> None:
        try:
            super().handle()
        except (TimeoutError, ConnectionError, ssl.SSLError):
            # Incomplete requests and disconnected clients are transport
            # failures; never print a request or credential-bearing traceback.
            self.close_connection = True

    @property
    def application(self) -> LocalBackendApplication:
        return self.server.application  # type: ignore[attr-defined,no-any-return]

    def log_message(self, format: str, *args: object) -> None:
        # Structured privacy-safe logging is installed by the production entry point.
        return

    def _send_json(
        self,
        status: int,
        payload: dict[str, Any],
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _send_recording(self, download) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(download.byte_count))
        self.send_header("X-IdeaForge-Content-SHA256", download.sha256)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        with download.absolute_path.open("rb") as handle:
            while chunk := handle.read(64 * 1024):
                self.wfile.write(chunk)
        self.close_connection = True

    def _reject_disallowed_source(self) -> bool:
        if self.application.source_is_allowed(self.client_address[0]):
            return False
        self._send_json(
            403,
            {"error": "network_forbidden", "detail": "Source network is not allowed."},
        )
        return True

    def _reject_rate_limit(
        self,
        scope: str,
        category: str,
        limit: int,
        window_seconds: int,
    ) -> bool:
        limiter = self.application.rate_limiter
        if limiter is None:
            return False
        decision = limiter.consume(scope, category, limit, window_seconds, self.application.current_time())
        if decision.allowed:
            return False
        self._send_json(
            429,
            {"error": "rate_limited", "detail": "Request rate limit was exceeded."},
            {"Retry-After": str(decision.retry_after_seconds)},
        )
        return True

    def _read_json(self, maximum_bytes: int) -> object:
        if self.headers.get("Transfer-Encoding"):
            raise InvalidWorkspaceSnapshotError("Transfer encoding is not supported")
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise _UnsupportedMediaType
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise InvalidWorkspaceSnapshotError("Content-Length is required")
        try:
            content_length = int(raw_length)
        except ValueError as error:
            raise InvalidWorkspaceSnapshotError("Content-Length is invalid") from error
        if content_length < 0:
            raise InvalidWorkspaceSnapshotError("Content-Length is invalid")
        if content_length > maximum_bytes:
            raise WorkspaceSnapshotTooLargeError("Request body exceeds the configured limit")
        body = self.rfile.read(content_length)
        if len(body) != content_length:
            raise InvalidWorkspaceSnapshotError("Request body was incomplete")
        try:
            payload = json.loads(body)
            # Python's decoder accepts non-finite numbers and lone surrogates;
            # neither can be synchronized as interoperable UTF-8 JSON.
            _canonical_json(payload)
            return payload
        except (ValueError, RecursionError) as error:
            raise InvalidWorkspaceSnapshotError("Request body must be valid JSON") from error

    def _content_length(self, maximum_bytes: int) -> int:
        if self.headers.get("Transfer-Encoding"):
            raise InvalidWorkspaceSnapshotError("Transfer encoding is not supported")
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise InvalidWorkspaceSnapshotError("Content-Length is required")
        try:
            content_length = int(raw_length)
        except ValueError as error:
            raise InvalidWorkspaceSnapshotError("Content-Length is invalid") from error
        if content_length < 0:
            raise InvalidWorkspaceSnapshotError("Content-Length is invalid")
        if content_length > maximum_bytes:
            raise RecordingTooLargeError("Recording exceeds the configured limit")
        return content_length

    def _body_chunks(self, content_length: int):
        remaining = content_length
        while remaining:
            chunk = self.rfile.read(min(64 * 1024, remaining))
            if not chunk:
                raise InvalidWorkspaceSnapshotError("Request body was incomplete")
            remaining -= len(chunk)
            yield chunk

    def _authorized_device(self):
        try:
            return self.application.authorize(self.headers)
        except DeviceUnauthorizedError:
            self._send_json(
                401,
                {"error": "unauthorized", "detail": "Device authorization failed."},
            )
        except DeviceForbiddenError:
            self._send_json(
                403,
                {"error": "forbidden", "detail": "Workspace authorization failed."},
            )
        return None

    def do_GET(self) -> None:
        if self._reject_disallowed_source():
            return
        path = self.path.split("?", 1)[0]
        if path == "/health/live":
            self._send_json(200, {"status": "live"})
            return
        if path == "/health/ready":
            ready = self.application.ready()
            self._send_json(200 if ready else 503, {"status": "ready" if ready else "not_ready"})
            return
        device = self._authorized_device()
        if device is None:
            return
        if path == "/v1/auth/session":
            self._send_json(200, self.application.session_payload(device.device_id))
            return
        if path == "/v1/workspace/snapshot":
            if self._reject_rate_limit(
                device.device_id,
                "workspace_read",
                self.application.rate_limit_policy.workspace_reads_per_minute,
                60,
            ):
                return
            snapshot = self.application.workspaces.load(device.workspace_id)
            if snapshot is None:
                self._send_json(404, {"error": "workspace_not_found", "detail": "Workspace was not found."})
            else:
                self._send_json(200, snapshot)
            return
        if path == "/v1/recordings/audio":
            self._download_recording(device.workspace_id)
            return
        self._send_json(404, {"error": "not_found", "detail": "Route was not found."})

    def do_POST(self) -> None:
        if self._reject_disallowed_source():
            return
        path = self.path.split("?", 1)[0]
        if path == "/v1/recordings/upload":
            self._upload_recording()
            return
        if path == "/v1/enrichment/jobs/claim":
            self._claim_enrichment_job()
            return
        if path == "/v1/enrichment/jobs/complete":
            self._complete_enrichment_job()
            return
        if path == "/v1/enrichment/jobs/renew":
            self._renew_enrichment_job()
            return
        if path == "/v1/enrichment/jobs/fail":
            self._fail_enrichment_job()
            return
        if path != "/v1/local/pair":
            self._send_json(404, {"error": "not_found", "detail": "Route was not found."})
            return
        if self._reject_rate_limit(
            self.client_address[0],
            "pairing",
            self.application.rate_limit_policy.pairing_attempts_per_five_minutes,
            300,
        ):
            return
        try:
            payload = self._read_json(4_096)
            if not isinstance(payload, dict):
                raise PairingCodeInvalidError("Pairing request is invalid")
            issued = self.application.pairing.exchange(
                str(payload.get("pairingCode", "")),
                str(payload.get("deviceLabel", "")),
                self.application.current_time(),
            )
        except PairingCodeExpiredError:
            self._send_json(400, {"error": "pairing_expired", "detail": "Pairing code expired."})
            return
        except (PairingCodeInvalidError, ValueError, InvalidWorkspaceSnapshotError):
            self._send_json(400, {"error": "pairing_invalid", "detail": "Pairing request is invalid."})
            return
        except _UnsupportedMediaType:
            self._send_json(415, {"error": "unsupported_media_type", "detail": "Content-Type must be application/json."})
            return
        self._send_json(
            201,
            {
                "workspaceID": issued.workspace_id,
                "deviceID": issued.device_id,
                "bearerToken": issued.token,
            },
        )

    def _upload_recording(self) -> None:
        device = self._authorized_device()
        if device is None:
            return
        if self.application.recordings is None:
            self._send_json(503, {"error": "recording_storage_unavailable", "detail": "Recording storage is unavailable."})
            return
        if self._reject_rate_limit(
            device.device_id,
            "recording_upload",
            self.application.rate_limit_policy.uploads_per_hour,
            3_600,
        ):
            return
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/octet-stream":
            self._send_json(415, {"error": "unsupported_media_type", "detail": "Content-Type must be application/octet-stream."})
            return
        recording_id = self.headers.get("X-IdeaForge-Recording-ID", "").strip()
        idea_project_id = self.headers.get("X-IdeaForge-Idea-ID", "").strip()
        upload_job_id = self.headers.get("X-IdeaForge-Upload-Job-ID", "").strip()
        expected_sha256 = self.headers.get("X-IdeaForge-Content-SHA256", "").strip().lower()
        if not recording_id or not idea_project_id or not upload_job_id or len(expected_sha256) != 64 or any(
            character not in "0123456789abcdef" for character in expected_sha256
        ):
            self._send_json(400, {"error": "invalid_recording_upload", "detail": "Recording upload metadata is invalid."})
            return
        try:
            content_length = self._content_length(self.application.recordings.maximum_bytes)
            receipt = self.application.recordings.commit_stream(
                device.workspace_id,
                recording_id,
                self._body_chunks(content_length),
                self.application.current_time(),
                expected_sha256=expected_sha256,
            )
        except RecordingTooLargeError:
            self._send_json(413, {"error": "payload_too_large", "detail": "Recording is too large."})
            return
        except RecordingHashMismatchError:
            self._send_json(400, {"error": "recording_hash_mismatch", "detail": "Recording hash did not match."})
            return
        except RecordingConflictError:
            self._send_json(409, {"error": "recording_conflict", "detail": "Recording is already stored."})
            return
        except (RecordingStorageBoundaryError, OSError):
            self._send_json(503, {"error": "recording_storage_unavailable", "detail": "Recording storage is unavailable."})
            return
        except (InvalidWorkspaceSnapshotError, TypeError, ValueError):
            self._send_json(400, {"error": "invalid_recording_upload", "detail": "Recording upload is invalid."})
            return
        if self.application.jobs is not None:
            try:
                self.application.jobs.enqueue(
                    device.workspace_id,
                    "recording_enrichment",
                    recording_id,
                    {
                        "recordingID": recording_id,
                        "ideaProjectID": idea_project_id,
                        "objectKey": str(receipt.storage_relative_path),
                        "byteCount": receipt.byte_count,
                        "sha256": receipt.sha256,
                    },
                    self.application.current_time(),
                )
            except JobConflictError:
                self._send_json(409, {"error": "enrichment_job_conflict", "detail": "Recording enrichment job conflicts with stored work."})
                return
        self._send_json(201, {"objectKey": str(receipt.storage_relative_path)})

    def _download_recording(self, workspace_id: str) -> None:
        if self.application.recordings is None:
            self._send_json(503, {"error": "recording_storage_unavailable", "detail": "Recording storage is unavailable."})
            return
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query, keep_blank_values=True)
        recording_id = query.get("recordingID", [""])[0].strip()
        object_key = query.get("objectKey", [""])[0].strip()
        try:
            download = self.application.recordings.download(workspace_id, recording_id, object_key)
        except RecordingNotFoundError:
            self._send_json(404, {"error": "recording_not_found", "detail": "Recording was not found."})
            return
        except (RecordingIntegrityError, RecordingStorageBoundaryError, OSError):
            self._send_json(503, {"error": "recording_storage_unavailable", "detail": "Recording storage is unavailable."})
            return
        self._send_recording(download)

    def _claim_enrichment_job(self) -> None:
        device = self._authorized_device()
        if device is None:
            return
        if self.application.jobs is None:
            self._send_json(503, {"error": "job_queue_unavailable", "detail": "Enrichment queue is unavailable."})
            return
        try:
            payload = self._read_json(4_096)
            if not isinstance(payload, dict):
                raise ValueError("Claim request must be an object")
            lease_seconds = int(payload.get("leaseDurationSeconds", 120))
            if lease_seconds < 30 or lease_seconds > 300:
                raise ValueError("Lease duration is outside the allowed range")
            job = self.application.jobs.claim(
                device.device_id,
                self.application.current_time(),
                lease_duration=timedelta(seconds=lease_seconds),
                workspace_id=device.workspace_id,
                kind="recording_enrichment",
            )
        except (_UnsupportedMediaType, InvalidWorkspaceSnapshotError, TypeError, ValueError):
            self._send_json(400, {"error": "invalid_enrichment_claim", "detail": "Enrichment claim is invalid."})
            return
        if job is None:
            self._send_json(200, {"job": None})
            return
        self._send_json(
            200,
            {
                "job": {
                    "jobID": job.job_id,
                    "recordingID": job.request["recordingID"],
                    "ideaProjectID": job.request["ideaProjectID"],
                    "objectKey": job.request["objectKey"],
                    "byteCount": job.request["byteCount"],
                    "sha256": job.request["sha256"],
                    "attemptCount": job.attempt_count,
                    "leaseExpiresAt": _timestamp(job.lease_expires_at),
                }
            },
        )

    def _complete_enrichment_job(self) -> None:
        device = self._authorized_device()
        if device is None:
            return
        if self.application.jobs is None:
            self._send_json(503, {"error": "job_queue_unavailable", "detail": "Enrichment queue is unavailable."})
            return
        try:
            payload = self._read_json(8_192)
            if not isinstance(payload, dict):
                raise ValueError("Completion request must be an object")
            job_id = str(payload.get("jobID", "")).strip()
            workspace_updated_at = str(payload.get("workspaceUpdatedAt", "")).strip()
            if not job_id or not workspace_updated_at:
                raise ValueError("Completion metadata is required")
            completed = self.application.jobs.complete_idempotently(
                job_id,
                device.device_id,
                {"workspaceUpdatedAt": workspace_updated_at},
                self.application.current_time(),
                workspace_id=device.workspace_id,
                kind="recording_enrichment",
            )
        except (_UnsupportedMediaType, InvalidWorkspaceSnapshotError, TypeError, ValueError):
            self._send_json(400, {"error": "invalid_enrichment_completion", "detail": "Enrichment completion is invalid."})
            return
        except JobConflictError:
            self._send_json(409, {"error": "enrichment_completion_conflict", "detail": "Completed enrichment does not match."})
            return
        except JobLeaseError:
            self._send_json(409, {"error": "enrichment_lease_conflict", "detail": "Enrichment lease is no longer held by this device."})
            return
        self._send_json(200, {"jobID": completed.job_id, "status": completed.status})

    def _renew_enrichment_job(self) -> None:
        device = self._authorized_device()
        if device is None:
            return
        if self.application.jobs is None:
            self._send_json(503, {"error": "job_queue_unavailable", "detail": "Enrichment queue is unavailable."})
            return
        try:
            payload = self._read_json(4_096)
            if not isinstance(payload, dict):
                raise ValueError("Renewal request must be an object")
            job_id = str(payload.get("jobID", "")).strip()
            lease_seconds = int(payload.get("leaseDurationSeconds", 120))
            if not job_id or lease_seconds < 30 or lease_seconds > 300:
                raise ValueError("Renewal metadata is invalid")
            renewed = self.application.jobs.renew(
                job_id,
                device.device_id,
                self.application.current_time(),
                lease_duration=timedelta(seconds=lease_seconds),
                workspace_id=device.workspace_id,
                kind="recording_enrichment",
            )
        except (_UnsupportedMediaType, InvalidWorkspaceSnapshotError, TypeError, ValueError):
            self._send_json(400, {"error": "invalid_enrichment_renewal", "detail": "Enrichment renewal is invalid."})
            return
        except JobLeaseError:
            self._send_json(409, {"error": "enrichment_lease_conflict", "detail": "Enrichment lease is no longer held by this device."})
            return
        self._send_json(
            200,
            {
                "jobID": renewed.job_id,
                "status": renewed.status,
                "leaseExpiresAt": _timestamp(renewed.lease_expires_at),
            },
        )

    def _fail_enrichment_job(self) -> None:
        device = self._authorized_device()
        if device is None:
            return
        if self.application.jobs is None:
            self._send_json(503, {"error": "job_queue_unavailable", "detail": "Enrichment queue is unavailable."})
            return
        try:
            payload = self._read_json(8_192)
            if not isinstance(payload, dict):
                raise ValueError("Failure request must be an object")
            job_id = str(payload.get("jobID", "")).strip()
            diagnostic_code = str(payload.get("diagnosticCode", "")).strip()
            retryable = payload.get("retryable")
            if (
                not job_id
                or not diagnostic_code
                or len(diagnostic_code) > 64
                or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789_" for character in diagnostic_code)
                or not isinstance(retryable, bool)
            ):
                raise ValueError("Failure metadata is invalid")
            failed = self.application.jobs.fail(
                job_id,
                device.device_id,
                diagnostic_code,
                self.application.current_time(),
                retryable=retryable,
                workspace_id=device.workspace_id,
                kind="recording_enrichment",
            )
        except (_UnsupportedMediaType, InvalidWorkspaceSnapshotError, TypeError, ValueError):
            self._send_json(400, {"error": "invalid_enrichment_failure", "detail": "Enrichment failure is invalid."})
            return
        except JobLeaseError:
            self._send_json(409, {"error": "enrichment_lease_conflict", "detail": "Enrichment lease is no longer held by this device."})
            return
        self._send_json(200, {"jobID": failed.job_id, "status": failed.status})

    def do_PUT(self) -> None:
        if self._reject_disallowed_source():
            return
        path = self.path.split("?", 1)[0]
        device = self._authorized_device()
        if device is None:
            return
        if path != "/v1/workspace/snapshot":
            self._send_json(404, {"error": "not_found", "detail": "Route was not found."})
            return
        if self._reject_rate_limit(
            device.device_id,
            "workspace_write",
            self.application.rate_limit_policy.workspace_writes_per_minute,
            60,
        ):
            return
        try:
            payload = self._read_json(self.application.workspaces.body_limit_bytes)
            canonical_request = _canonical_json(payload).encode("utf-8")
            idempotency_key = self.headers.get("Idempotency-Key", "").strip()
            if not idempotency_key:
                idempotency_key = "workspace-" + hashlib.sha256(canonical_request).hexdigest()
            receipt = self.application.workspaces.publish(
                device.workspace_id,
                payload,
                idempotency_key,
                self.application.current_time(),
                base_remote_updated_at=self.headers.get("X-IdeaForge-Base-Remote-Updated-At"),
            )
        except _UnsupportedMediaType:
            self._send_json(415, {"error": "unsupported_media_type", "detail": "Content-Type must be application/json."})
            return
        except WorkspaceSnapshotTooLargeError:
            self._send_json(413, {"error": "payload_too_large", "detail": "Workspace snapshot is too large."})
            return
        except WorkspaceRevisionConflictError:
            self._send_json(409, {"error": "workspace_revision_conflict", "detail": "Remote workspace changed before publication."})
            return
        except IdempotencyConflictError:
            self._send_json(409, {"error": "idempotency_conflict", "detail": "Idempotency key was already used."})
            return
        except InvalidWorkspaceSnapshotError:
            self._send_json(400, {"error": "invalid_workspace_snapshot", "detail": "Workspace snapshot is invalid."})
            return
        self._send_json(200, receipt.as_dict())


class _UnsupportedMediaType(Exception):
    pass


def create_http_server(
    host: str,
    port: int,
    application: LocalBackendApplication,
    *,
    certificate_path: Path | None = None,
    private_key_path: Path | None = None,
) -> http.server.ThreadingHTTPServer:
    server = _ThreadingHTTPServer((host, port), application)
    if (certificate_path is None) != (private_key_path is None):
        server.server_close()
        raise ValueError("TLS certificate and key must be configured together")
    if certificate_path is not None and private_key_path is not None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(certificate_path), str(private_key_path))
        server.socket = context.wrap_socket(
            server.socket, server_side=True, do_handshake_on_connect=False
        )
    return server
