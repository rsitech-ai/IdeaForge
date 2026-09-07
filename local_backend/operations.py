"""Backup and restore operations for local-only backend state."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .database import LocalBackendDatabase


class BackupIntegrityError(RuntimeError):
    """Raised when a backup cannot be created or restored without data risk."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _write_json(path: Path, payload: Any) -> None:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _safe_recording_path(relative_value: str) -> Path:
    relative = Path(relative_value)
    if relative.is_absolute() or relative.parts[:1] != ("recordings",) or ".." in relative.parts:
        raise BackupIntegrityError("Backup contains an unsafe recording path")
    return relative


class LocalBackupManager:
    def __init__(self, data_root: Path, database: LocalBackendDatabase) -> None:
        if not data_root.is_absolute():
            raise ValueError("Data root must be absolute")
        self.data_root = data_root
        self.database = database

    def create(self, backup_parent: Path, now: datetime) -> Path:
        if not backup_parent.is_absolute():
            raise ValueError("Backup parent must be absolute")
        backup_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(backup_parent, 0o700)
        staging = Path(tempfile.mkdtemp(prefix=".ideaforge-backup-", dir=backup_parent))
        os.chmod(staging, 0o700)
        try:
            database_copy = staging / "backend.sqlite3"
            with self.database.connection() as source, sqlite3.connect(database_copy) as destination:
                source.backup(destination)
            os.chmod(database_copy, 0o600)

            with sqlite3.connect(database_copy) as connection:
                connection.row_factory = sqlite3.Row
                workspace_rows = connection.execute("SELECT workspace_id FROM workspaces").fetchall()
                recording_rows = connection.execute(
                    """
                    SELECT recording_id, storage_relative_path, byte_count, sha256
                    FROM recordings WHERE deleted_at IS NULL ORDER BY recording_id
                    """
                ).fetchall()
            if len(workspace_rows) != 1:
                raise BackupIntegrityError("Backup requires exactly one workspace")

            recording_manifest = []
            for row in recording_rows:
                relative = _safe_recording_path(row["storage_relative_path"])
                source_path = self.data_root / relative
                if source_path.is_symlink() or not source_path.is_file():
                    raise BackupIntegrityError("A referenced recording is unavailable")
                actual_hash = _sha256(source_path)
                if actual_hash != row["sha256"] or source_path.stat().st_size != row["byte_count"]:
                    raise BackupIntegrityError("A referenced recording failed integrity verification")
                destination_path = staging / relative
                destination_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                os.chmod(destination_path.parent, 0o700)
                shutil.copyfile(source_path, destination_path, follow_symlinks=False)
                os.chmod(destination_path, 0o600)
                recording_manifest.append(
                    {
                        "recordingID": row["recording_id"],
                        "path": str(relative),
                        "byteCount": row["byte_count"],
                        "sha256": actual_hash,
                    }
                )

            manifest = {
                "formatVersion": 1,
                "createdAt": now.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
                "workspaceID": workspace_rows[0]["workspace_id"],
                "database": {"path": "backend.sqlite3", "sha256": _sha256(database_copy)},
                "recordings": recording_manifest,
            }
            _write_json(staging / "manifest.json", manifest)
            _fsync_directory(staging)
            suffix = now.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ")
            destination = backup_parent / f"ideaforge-{suffix}"
            if destination.exists():
                raise BackupIntegrityError("Backup destination already exists")
            os.replace(staging, destination)
            _fsync_directory(backup_parent)
            return destination
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise

    @classmethod
    def restore(cls, backup: Path, destination: Path) -> None:
        if not backup.is_absolute() or not destination.is_absolute():
            raise ValueError("Backup and destination paths must be absolute")
        if destination.exists() and any(destination.iterdir()):
            raise BackupIntegrityError("Restore destination must be empty")
        try:
            manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise BackupIntegrityError("Backup manifest is unavailable") from error
        if manifest.get("formatVersion") != 1:
            raise BackupIntegrityError("Backup format is unsupported")
        database_source = backup / "backend.sqlite3"
        if _sha256(database_source) != manifest.get("database", {}).get("sha256"):
            raise BackupIntegrityError("Backup database hash did not match")
        for recording in manifest.get("recordings", []):
            relative = _safe_recording_path(recording.get("path", ""))
            source = backup / relative
            if source.is_symlink() or not source.is_file():
                raise BackupIntegrityError("Backup recording is unavailable")
            if source.stat().st_size != recording.get("byteCount") or _sha256(source) != recording.get("sha256"):
                raise BackupIntegrityError("Backup recording hash did not match")

        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        staging = Path(tempfile.mkdtemp(prefix=".ideaforge-restore-", dir=destination.parent))
        os.chmod(staging, 0o700)
        try:
            shutil.copyfile(database_source, staging / "backend.sqlite3", follow_symlinks=False)
            os.chmod(staging / "backend.sqlite3", 0o600)
            for recording in manifest.get("recordings", []):
                relative = _safe_recording_path(recording["path"])
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                os.chmod(target.parent, 0o700)
                shutil.copyfile(backup / relative, target, follow_symlinks=False)
                os.chmod(target, 0o600)

            with sqlite3.connect(staging / "backend.sqlite3") as connection:
                if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise BackupIntegrityError("Restored database failed integrity check")
                if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                    raise BackupIntegrityError("Restored database failed foreign-key check")
                rows = connection.execute(
                    "SELECT storage_relative_path, byte_count, sha256 FROM recordings WHERE deleted_at IS NULL"
                ).fetchall()
            for relative_value, byte_count, expected_hash in rows:
                relative = _safe_recording_path(relative_value)
                path = staging / relative
                if not path.is_file() or path.stat().st_size != byte_count or _sha256(path) != expected_hash:
                    raise BackupIntegrityError("Restored recording metadata did not match")

            if destination.exists():
                destination.rmdir()
            os.replace(staging, destination)
            _fsync_directory(destination.parent)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
