"""Durable, leased background work for the local backend."""

from __future__ import annotations

import json
import random
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from .database import LocalBackendDatabase
from .workspaces import _parse_revision


class JobConflictError(RuntimeError):
    """Raised when an idempotency key is reused for different work."""


class JobLeaseError(RuntimeError):
    """Raised when a worker attempts to mutate work it does not lease."""


def _timestamp(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Timestamp must include a timezone")
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def _canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


@dataclass(frozen=True)
class JobRecord:
    job_id: str
    workspace_id: str
    kind: str
    status: str
    attempt_count: int
    available_at: datetime
    lease_owner: str | None
    lease_expires_at: datetime | None
    diagnostic_code: str | None
    request: dict[str, Any]
    result: dict[str, Any] | None


class JobQueue:
    def __init__(
        self,
        database: LocalBackendDatabase,
        *,
        maximum_attempts: int = 3,
        maximum_concurrent: int = 2,
    ) -> None:
        if maximum_attempts < 1 or maximum_concurrent < 1:
            raise ValueError("Job limits must be positive")
        self.database = database
        self.maximum_attempts = maximum_attempts
        self.maximum_concurrent = maximum_concurrent

    @staticmethod
    def _record(row: Any) -> JobRecord:
        result = json.loads(row["result_json"]) if row["result_json"] else {}
        request = json.loads(row["request_json"])
        return JobRecord(
            job_id=row["job_id"],
            workspace_id=row["workspace_id"],
            kind=row["kind"],
            status=row["status"],
            attempt_count=row["attempt_count"],
            available_at=_parse_timestamp(row["available_at"]),
            lease_owner=row["lease_owner"],
            lease_expires_at=(
                _parse_timestamp(row["lease_expires_at"])
                if row["lease_expires_at"]
                else None
            ),
            diagnostic_code=result.get("diagnosticCode"),
            request=request,
            result=result if row["result_json"] else None,
        )

    def enqueue(
        self,
        workspace_id: str,
        kind: str,
        idempotency_key: str,
        request: Any,
        now: datetime,
    ) -> JobRecord:
        request_json = _canonical_json(request)
        stamp = _timestamp(now)
        with self.database.transaction() as connection:
            existing = connection.execute(
                """
                SELECT * FROM jobs
                WHERE workspace_id = ? AND kind = ? AND idempotency_key = ?
                """,
                (workspace_id, kind, idempotency_key),
            ).fetchone()
            if existing is not None:
                if existing["request_json"] != request_json:
                    raise JobConflictError("Job idempotency key was reused for different work")
                return self._record(existing)

            job_id = f"job_{secrets.token_hex(16)}"
            connection.execute(
                """
                INSERT INTO jobs(
                    job_id, workspace_id, kind, status, idempotency_key,
                    request_json, result_json, attempt_count, available_at,
                    lease_owner, lease_expires_at, created_at, updated_at
                ) VALUES (?, ?, ?, 'queued', ?, ?, NULL, 0, ?, NULL, NULL, ?, ?)
                """,
                (job_id, workspace_id, kind, idempotency_key, request_json, stamp, stamp, stamp),
            )
            row = connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            return self._record(row)

    def claim(
        self,
        worker_id: str,
        now: datetime,
        *,
        lease_duration: timedelta = timedelta(minutes=2),
        workspace_id: str | None = None,
        kind: str | None = None,
    ) -> JobRecord | None:
        if lease_duration <= timedelta(0):
            raise ValueError("Lease duration must be positive")
        stamp = _timestamp(now)
        lease_expires_at = _timestamp(now + lease_duration)
        with self.database.transaction() as connection:
            self._release_expired(connection, stamp)
            row = connection.execute(
                """
                SELECT candidate.*
                FROM jobs AS candidate
                WHERE candidate.status = 'queued'
                  AND candidate.available_at <= ?
                  AND (? IS NULL OR candidate.workspace_id = ?)
                  AND (? IS NULL OR candidate.kind = ?)
                  AND (
                    SELECT COUNT(*) FROM jobs AS running
                    WHERE running.workspace_id = candidate.workspace_id
                      AND running.status = 'running'
                  ) < ?
                ORDER BY candidate.available_at, candidate.created_at, candidate.job_id
                LIMIT 1
                """,
                (stamp, workspace_id, workspace_id, kind, kind, self.maximum_concurrent),
            ).fetchone()
            if row is None:
                return None
            connection.execute(
                """
                UPDATE jobs
                SET status = 'running', attempt_count = attempt_count + 1,
                    lease_owner = ?, lease_expires_at = ?, updated_at = ?
                WHERE job_id = ?
                """,
                (worker_id, lease_expires_at, stamp, row["job_id"]),
            )
            claimed = connection.execute(
                "SELECT * FROM jobs WHERE job_id = ?", (row["job_id"],)
            ).fetchone()
            return self._record(claimed)

    @staticmethod
    def _release_expired(connection: Any, stamp: str) -> int:
        cursor = connection.execute(
            """
            UPDATE jobs
            SET status = 'queued', available_at = ?, lease_owner = NULL,
                lease_expires_at = NULL, updated_at = ?
            WHERE status = 'running' AND lease_expires_at <= ?
            """,
            (stamp, stamp, stamp),
        )
        return cursor.rowcount

    def release_expired(self, now: datetime) -> int:
        stamp = _timestamp(now)
        with self.database.transaction() as connection:
            return self._release_expired(connection, stamp)

    def complete(self, job_id: str, worker_id: str, result: Any, now: datetime) -> JobRecord:
        return self._finish(job_id, worker_id, "completed", result, now)

    def renew(
        self,
        job_id: str,
        worker_id: str,
        now: datetime,
        *,
        lease_duration: timedelta,
        workspace_id: str,
        kind: str,
    ) -> JobRecord:
        if lease_duration <= timedelta(0):
            raise ValueError("Lease duration must be positive")
        stamp = _timestamp(now)
        expires_at = _timestamp(now + lease_duration)
        with self.database.transaction() as connection:
            current = connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            if (
                current is None
                or current["workspace_id"] != workspace_id
                or current["kind"] != kind
                or current["status"] != "running"
                or current["lease_owner"] != worker_id
                or current["lease_expires_at"] is None
                or current["lease_expires_at"] <= stamp
            ):
                raise JobLeaseError("Job is not leased by this worker")
            connection.execute(
                "UPDATE jobs SET lease_expires_at = ?, updated_at = ? WHERE job_id = ?",
                (expires_at, stamp, job_id),
            )
            return self._record(
                connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            )

    def complete_idempotently(
        self,
        job_id: str,
        worker_id: str,
        result: dict[str, Any],
        now: datetime,
        *,
        workspace_id: str,
        kind: str,
    ) -> JobRecord:
        canonical_result = _canonical_json(result)
        with self.database.transaction() as connection:
            current = connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            if current is None or current["workspace_id"] != workspace_id or current["kind"] != kind:
                raise JobLeaseError("Job is not available to this worker")
            if current["status"] == "completed":
                if current["result_json"] != canonical_result:
                    raise JobConflictError("Completed job result does not match")
                return self._record(current)
            if (
                current["status"] != "running"
                or current["lease_owner"] != worker_id
                or current["lease_expires_at"] is None
                or current["lease_expires_at"] <= _timestamp(now)
            ):
                raise JobLeaseError("Job is not leased by this worker")
            if kind == "recording_enrichment":
                # Validate publication and completion in the same write transaction.
                # A worker's acknowledgement alone cannot prove durable enrichment.
                revision = _parse_revision(result.get("workspaceUpdatedAt"))
                workspace = connection.execute(
                    "SELECT snapshot_json, accepted_updated_at FROM workspaces WHERE workspace_id = ?",
                    (workspace_id,),
                ).fetchone()
                if workspace is None or _parse_revision(workspace["accepted_updated_at"]) < revision:
                    raise JobConflictError("Enrichment publication is not durable")
                request = json.loads(current["request_json"])
                snapshot = json.loads(workspace["snapshot_json"])
                matching_project = next((
                    project for project in snapshot.get("projects", [])
                    if isinstance(project, dict) and project.get("id") == request.get("ideaProjectID")
                ), None)
                if matching_project is None:
                    raise JobConflictError("Enriched project is not published")
                transcript = matching_project.get("transcript")
                text = transcript.get("cleanText") if isinstance(transcript, dict) else None
                recordings = matching_project.get("recordings")
                if not isinstance(text, str) or not text.strip() or not isinstance(recordings, list):
                    raise JobConflictError("Enriched transcript is not published")
                if not any(
                    isinstance(recording, dict)
                    and recording.get("id") == request.get("recordingID")
                    and recording.get("ideaProjectID") == request.get("ideaProjectID")
                    and recording.get("audioObjectKey") == request.get("objectKey")
                    and recording.get("syncStatus") == "ready"
                    for recording in recordings
                ):
                    raise JobConflictError("Enriched recording is not published")
            connection.execute(
                """
                UPDATE jobs SET status = 'completed', result_json = ?, lease_owner = NULL,
                    lease_expires_at = NULL, updated_at = ? WHERE job_id = ?
                """,
                (canonical_result, _timestamp(now), job_id),
            )
            return self._record(
                connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            )

    def _finish(
        self,
        job_id: str,
        worker_id: str,
        status: str,
        result: Any,
        now: datetime,
    ) -> JobRecord:
        with self.database.transaction() as connection:
            current = connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            if (
                current is None
                or current["status"] != "running"
                or current["lease_owner"] != worker_id
                or current["lease_expires_at"] is None
                or current["lease_expires_at"] <= _timestamp(now)
            ):
                raise JobLeaseError("Job is not leased by this worker")
            connection.execute(
                """
                UPDATE jobs SET status = ?, result_json = ?, lease_owner = NULL,
                    lease_expires_at = NULL, updated_at = ? WHERE job_id = ?
                """,
                (status, _canonical_json(result), _timestamp(now), job_id),
            )
            return self._record(connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone())

    def fail(
        self,
        job_id: str,
        worker_id: str,
        diagnostic_code: str,
        now: datetime,
        *,
        retryable: bool,
        workspace_id: str | None = None,
        kind: str | None = None,
    ) -> JobRecord:
        with self.database.transaction() as connection:
            current = connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
            if (
                current is None
                or current["status"] != "running"
                or current["lease_owner"] != worker_id
                or (workspace_id is not None and current["workspace_id"] != workspace_id)
                or (kind is not None and current["kind"] != kind)
                or current["lease_expires_at"] is None
                or current["lease_expires_at"] <= _timestamp(now)
            ):
                raise JobLeaseError("Job is not leased by this worker")
            # Missing workspace state and disabled sync are prerequisites, not
            # failed transcription attempts. Preserve the remaining retry budget.
            waiting_for_prerequisite = (
                retryable
                and current["kind"] == "recording_enrichment"
                and diagnostic_code in {"workspace_recording_missing", "workspace_sync_disabled"}
            )
            attempt_count = current["attempt_count"] - int(waiting_for_prerequisite)
            terminal = not retryable or attempt_count >= self.maximum_attempts
            if waiting_for_prerequisite:
                status = "queued"
                available_at = _timestamp(now + timedelta(seconds=30))
            elif terminal:
                status = "failed"
                available_at = current["available_at"]
            else:
                status = "queued"
                base_seconds = 2 ** max(0, current["attempt_count"] - 1)
                delay = base_seconds + random.uniform(0, base_seconds)
                available_at = _timestamp(now + timedelta(seconds=delay))
            connection.execute(
                """
                UPDATE jobs SET status = ?, result_json = ?, available_at = ?,
                    lease_owner = NULL, lease_expires_at = NULL, updated_at = ?,
                    attempt_count = ?
                WHERE job_id = ?
                """,
                (
                    status,
                    _canonical_json({"diagnosticCode": diagnostic_code}),
                    available_at,
                    _timestamp(now),
                    attempt_count,
                    job_id,
                ),
            )
            return self._record(connection.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone())

    def release_worker_leases(self, worker_id: str, now: datetime) -> int:
        stamp = _timestamp(now)
        with self.database.transaction() as connection:
            cursor = connection.execute(
                """
                UPDATE jobs SET status = 'queued', available_at = ?, lease_owner = NULL,
                    lease_expires_at = NULL, updated_at = ?
                WHERE status = 'running' AND lease_owner = ?
                """,
                (stamp, stamp, worker_id),
            )
            return cursor.rowcount
