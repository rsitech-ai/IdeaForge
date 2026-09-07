"""Immutable SQLite migrations for the production-local backend."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass


class LocalBackendMigrationError(RuntimeError):
    """Raised when the on-disk schema cannot be migrated safely."""


@dataclass(frozen=True)
class Migration:
    version: int
    name: str
    sql: str

    @property
    def checksum(self) -> str:
        return hashlib.sha256(self.sql.encode("utf-8")).hexdigest()


MIGRATIONS = (
    Migration(
        version=1,
        name="initial_local_backend",
        sql="""
        CREATE TABLE workspaces (
            workspace_id TEXT PRIMARY KEY,
            snapshot_json TEXT NOT NULL,
            accepted_updated_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE devices (
            device_id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            token_digest TEXT NOT NULL UNIQUE,
            label TEXT NOT NULL,
            created_at TEXT NOT NULL,
            last_used_at TEXT,
            revoked_at TEXT
        );
        CREATE INDEX devices_workspace_id_index ON devices(workspace_id);

        CREATE TABLE pairing_codes (
            code_digest TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            consumed_at TEXT
        );

        CREATE TABLE recordings (
            recording_id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            storage_relative_path TEXT NOT NULL UNIQUE,
            byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
            sha256 TEXT NOT NULL,
            created_at TEXT NOT NULL,
            deleted_at TEXT
        );
        CREATE INDEX recordings_workspace_id_index ON recordings(workspace_id);

        CREATE TABLE idempotency_receipts (
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            operation TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            request_digest TEXT NOT NULL,
            response_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(workspace_id, operation, idempotency_key)
        );

        CREATE TABLE jobs (
            job_id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            idempotency_key TEXT NOT NULL,
            request_json TEXT NOT NULL,
            result_json TEXT,
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0),
            available_at TEXT NOT NULL,
            lease_owner TEXT,
            lease_expires_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(workspace_id, kind, idempotency_key)
        );
        CREATE INDEX jobs_claim_index ON jobs(status, available_at, lease_expires_at);

        CREATE TABLE audit_events (
            event_id TEXT PRIMARY KEY,
            workspace_id TEXT REFERENCES workspaces(workspace_id) ON DELETE SET NULL,
            device_id TEXT REFERENCES devices(device_id) ON DELETE SET NULL,
            event_type TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE INDEX audit_events_occurred_at_index ON audit_events(occurred_at);
        """,
    ),
    Migration(
        version=2,
        name="persistent_rate_limits",
        sql="""
        CREATE TABLE rate_limit_events (
            event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            scope_digest TEXT NOT NULL,
            category TEXT NOT NULL,
            occurred_at REAL NOT NULL
        );
        CREATE INDEX rate_limit_window_index
            ON rate_limit_events(scope_digest, category, occurred_at);
        """,
    ),
)
