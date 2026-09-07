"""SQLite lifecycle and transaction boundary for the production-local backend."""

from __future__ import annotations

import os
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterator

from .migrations import LocalBackendMigrationError, MIGRATIONS


def _migration_statements(script: str) -> Iterator[str]:
    pending = ""
    for character in script:
        pending += character
        if character == ";" and sqlite3.complete_statement(pending):
            statement = pending.strip()
            if statement:
                yield statement
            pending = ""
    if pending.strip():
        raise LocalBackendMigrationError("Migration contains an incomplete SQL statement")


class LocalBackendDatabase:
    def __init__(self, path: Path, busy_timeout_ms: int = 5_000) -> None:
        if not path.is_absolute():
            raise ValueError("Local backend database path must be absolute")
        self.path = path
        self.busy_timeout_ms = busy_timeout_ms

    def _prepare_filesystem(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.path.parent, 0o700)

    def _open(self) -> sqlite3.Connection:
        self._prepare_filesystem()
        connection = sqlite3.connect(self.path, timeout=self.busy_timeout_ms / 1_000)
        os.chmod(self.path, 0o600)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute(f"PRAGMA busy_timeout = {self.busy_timeout_ms}")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    @contextmanager
    def connection(self) -> Iterator[sqlite3.Connection]:
        connection = self._open()
        try:
            yield connection
        finally:
            connection.close()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
            except BaseException:
                connection.rollback()
                raise
            else:
                connection.commit()

    def migrate(self) -> None:
        with self.transaction() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    checksum TEXT NOT NULL,
                    applied_at TEXT NOT NULL
                )
                """
            )
            applied_rows = connection.execute(
                "SELECT version, name, checksum FROM schema_migrations ORDER BY version"
            ).fetchall()
            known_by_version = {migration.version: migration for migration in MIGRATIONS}
            for row in applied_rows:
                migration = known_by_version.get(row["version"])
                if migration is None:
                    raise LocalBackendMigrationError(
                        f"Database contains unknown future schema version {row['version']}"
                    )
                if row["name"] != migration.name or row["checksum"] != migration.checksum:
                    raise LocalBackendMigrationError(
                        f"Migration checksum mismatch for version {row['version']}"
                    )

            applied_versions = {row["version"] for row in applied_rows}
            now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
            for migration in MIGRATIONS:
                if migration.version in applied_versions:
                    continue
                for statement in _migration_statements(migration.sql):
                    connection.execute(statement)
                connection.execute(
                    "INSERT INTO schema_migrations(version, name, checksum, applied_at) VALUES (?, ?, ?, ?)",
                    (migration.version, migration.name, migration.checksum, now),
                )
