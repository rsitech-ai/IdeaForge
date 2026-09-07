"""Transactional workspace snapshot persistence and conflict handling."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from .database import LocalBackendDatabase


class InvalidWorkspaceSnapshotError(ValueError):
    """Raised when a workspace snapshot violates the sync contract."""


class WorkspaceSnapshotTooLargeError(InvalidWorkspaceSnapshotError):
    """Raised when a workspace snapshot exceeds the configured byte limit."""


class WorkspaceRevisionConflictError(RuntimeError):
    """Raised when a publication is not newer than the accepted revision."""


class IdempotencyConflictError(RuntimeError):
    """Raised when an idempotency key is reused for a different request."""


@dataclass(frozen=True)
class PublishReceipt:
    workspace_id: str
    accepted_updated_at: str

    def as_dict(self) -> dict[str, str]:
        return {
            "workspaceID": self.workspace_id,
            "acceptedUpdatedAt": self.accepted_updated_at,
        }


def _timestamp(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Timestamp must include a timezone")
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse_revision(value: Any) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise InvalidWorkspaceSnapshotError("Workspace snapshot requires updatedAt")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise InvalidWorkspaceSnapshotError("Workspace updatedAt must be ISO-8601") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise InvalidWorkspaceSnapshotError("Workspace updatedAt must include a timezone")
    return parsed.astimezone(UTC)


def _validate_depth(value: object, depth: int = 0) -> None:
    if depth > 64:
        raise InvalidWorkspaceSnapshotError("Workspace snapshot nesting is too deep")
    if isinstance(value, dict):
        for child in value.values():
            _validate_depth(child, depth + 1)
    elif isinstance(value, list):
        for child in value:
            _validate_depth(child, depth + 1)


def _canonical_json(value: object) -> str:
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    except (TypeError, ValueError) as error:
        raise InvalidWorkspaceSnapshotError("Workspace snapshot must be valid JSON") from error


def _validated_snapshot(snapshot: object, body_limit_bytes: int) -> tuple[dict[str, Any], str]:
    if not isinstance(snapshot, dict):
        raise InvalidWorkspaceSnapshotError("Workspace snapshot must be a JSON object")
    _validate_depth(snapshot)
    required_types: dict[str, type | tuple[type, ...]] = {
        "projects": list,
        "workflowTemplates": list,
        "privacyMode": str,
        "syncHealth": dict,
        "updatedAt": str,
    }
    for key, expected_type in required_types.items():
        if key not in snapshot or not isinstance(snapshot[key], expected_type):
            raise InvalidWorkspaceSnapshotError(f"Workspace snapshot has invalid {key}")
    _parse_revision(snapshot["updatedAt"])
    serialized = _canonical_json(snapshot)
    if len(serialized.encode("utf-8")) > body_limit_bytes:
        raise WorkspaceSnapshotTooLargeError("Workspace snapshot exceeds the configured limit")

    sanitized = json.loads(serialized)
    sanitized["uploadJobs"] = []
    for project in sanitized["projects"]:
        if not isinstance(project, dict):
            raise InvalidWorkspaceSnapshotError("Workspace project must be a JSON object")
        recordings = project.get("recordings", [])
        if not isinstance(recordings, list):
            raise InvalidWorkspaceSnapshotError("Workspace recordings must be a JSON array")
        for recording in recordings:
            if not isinstance(recording, dict):
                raise InvalidWorkspaceSnapshotError("Workspace recording must be a JSON object")
            recording.pop("localAudioPath", None)
    return sanitized, _canonical_json(sanitized)


class WorkspaceStore:
    def __init__(self, database: LocalBackendDatabase, body_limit_bytes: int = 10 * 1024 * 1024) -> None:
        if body_limit_bytes < 1:
            raise ValueError("Workspace body limit must be positive")
        self.database = database
        self.body_limit_bytes = body_limit_bytes

    def create(self, workspace_id: str, now: datetime) -> None:
        created_at = _timestamp(now)
        seed = {
            "projects": [],
            "workflowTemplates": [],
            "uploadJobs": [],
            "privacyMode": "privateLocal",
            "syncHealth": {"queuedUploads": 0, "failingItems": 0},
            "selectedProjectID": None,
            "updatedAt": "1970-01-01T00:00:00Z",
        }
        with self.database.transaction() as connection:
            connection.execute(
                """
                INSERT OR IGNORE INTO workspaces(
                    workspace_id, snapshot_json, accepted_updated_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (
                    workspace_id,
                    _canonical_json(seed),
                    seed["updatedAt"],
                    created_at,
                    created_at,
                ),
            )

    def load(self, workspace_id: str) -> dict[str, Any] | None:
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT snapshot_json FROM workspaces WHERE workspace_id = ?",
                (workspace_id,),
            ).fetchone()
        return json.loads(row["snapshot_json"]) if row is not None else None

    def publish(
        self,
        workspace_id: str,
        snapshot: object,
        idempotency_key: str,
        now: datetime,
        base_remote_updated_at: str | None = None,
    ) -> PublishReceipt:
        if not 8 <= len(idempotency_key) <= 200:
            raise InvalidWorkspaceSnapshotError("Idempotency key must contain 8 to 200 characters")
        sanitized, serialized = _validated_snapshot(snapshot, self.body_limit_bytes)
        request_digest = hashlib.sha256(serialized.encode("utf-8")).hexdigest()
        accepted_updated_at = sanitized["updatedAt"]
        incoming_revision = _parse_revision(accepted_updated_at)

        with self.database.transaction() as connection:
            prior = connection.execute(
                """
                SELECT request_digest, response_json
                FROM idempotency_receipts
                WHERE workspace_id = ? AND operation = 'workspace_publish' AND idempotency_key = ?
                """,
                (workspace_id, idempotency_key),
            ).fetchone()
            if prior is not None:
                if prior["request_digest"] != request_digest:
                    raise IdempotencyConflictError("Idempotency key was already used")
                response = json.loads(prior["response_json"])
                return PublishReceipt(
                    workspace_id=response["workspaceID"],
                    accepted_updated_at=response["acceptedUpdatedAt"],
                )

            current = connection.execute(
                "SELECT accepted_updated_at FROM workspaces WHERE workspace_id = ?",
                (workspace_id,),
            ).fetchone()
            if current is None:
                raise InvalidWorkspaceSnapshotError("Workspace does not exist")
            if (
                base_remote_updated_at is not None
                and _parse_revision(base_remote_updated_at)
                != _parse_revision(current["accepted_updated_at"])
            ):
                raise WorkspaceRevisionConflictError("Remote workspace changed before publication")
            if incoming_revision <= _parse_revision(current["accepted_updated_at"]):
                raise WorkspaceRevisionConflictError("Workspace revision is not newer")

            receipt = PublishReceipt(workspace_id, accepted_updated_at)
            response_json = _canonical_json(receipt.as_dict())
            persisted_at = _timestamp(now)
            connection.execute(
                """
                UPDATE workspaces
                SET snapshot_json = ?, accepted_updated_at = ?, updated_at = ?
                WHERE workspace_id = ?
                """,
                (serialized, accepted_updated_at, persisted_at, workspace_id),
            )
            connection.execute(
                """
                INSERT INTO idempotency_receipts(
                    workspace_id, operation, idempotency_key,
                    request_digest, response_json, created_at
                ) VALUES (?, 'workspace_publish', ?, ?, ?, ?)
                """,
                (workspace_id, idempotency_key, request_digest, response_json, persisted_at),
            )
        return receipt
