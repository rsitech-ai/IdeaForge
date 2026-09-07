"""Atomic ordinary-file recording persistence for the local backend."""

from __future__ import annotations

import hashlib
import os
import secrets
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable

from .database import LocalBackendDatabase


class RecordingStorageError(RuntimeError):
    """Base recording persistence error."""


class RecordingStorageBoundaryError(RecordingStorageError):
    """Raised when the configured storage tree is unsafe."""


class RecordingTooLargeError(RecordingStorageError):
    """Raised when streamed recording bytes exceed the configured limit."""


class RecordingHashMismatchError(RecordingStorageError):
    """Raised when streamed recording bytes do not match the expected digest."""


class RecordingConflictError(RecordingStorageError):
    """Raised when a recording identifier is already committed."""


class RecordingNotFoundError(RecordingStorageError):
    """Raised when a recording is unavailable to the requested workspace."""


class RecordingIntegrityError(RecordingStorageError):
    """Raised when stored recording bytes no longer match committed metadata."""


@dataclass(frozen=True)
class RecordingReceipt:
    recording_id: str
    byte_count: int
    sha256: str
    storage_relative_path: Path


@dataclass(frozen=True)
class RecordingDownload:
    recording_id: str
    byte_count: int
    sha256: str
    storage_relative_path: Path
    absolute_path: Path


def _timestamp(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Timestamp must include a timezone")
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


class RecordingStore:
    def __init__(
        self,
        database: LocalBackendDatabase,
        data_root: Path,
        maximum_bytes: int = 200 * 1024 * 1024,
    ) -> None:
        if not data_root.is_absolute():
            raise ValueError("Recording data root must be absolute")
        if maximum_bytes < 1:
            raise ValueError("Recording byte limit must be positive")
        self.database = database
        self.data_root = data_root
        self.maximum_bytes = maximum_bytes
        self._prepare_storage()

    @property
    def recordings_root(self) -> Path:
        return self.data_root / "recordings"

    @property
    def staging_root(self) -> Path:
        return self.data_root / "staging"

    def _prepare_directory(self, path: Path) -> None:
        if path.is_symlink():
            raise RecordingStorageBoundaryError("Recording storage directory must not be a symlink")
        if path.exists() and not path.is_dir():
            raise RecordingStorageBoundaryError("Recording storage path must be a directory")
        path.mkdir(parents=False, exist_ok=True, mode=0o700)
        os.chmod(path, 0o700)

    def _prepare_storage(self) -> None:
        if self.data_root.is_symlink():
            raise RecordingStorageBoundaryError("Recording data root must not be a symlink")
        self.data_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.data_root, 0o700)
        self._prepare_directory(self.recordings_root)
        self._prepare_directory(self.staging_root)

    def _validate_storage(self) -> None:
        for path in (self.data_root, self.recordings_root, self.staging_root):
            if path.is_symlink() or not path.is_dir():
                raise RecordingStorageBoundaryError("Recording storage boundary changed")
        if self.recordings_root.resolve().parent != self.data_root.resolve():
            raise RecordingStorageBoundaryError("Recording directory escaped the data root")
        if self.staging_root.resolve().parent != self.data_root.resolve():
            raise RecordingStorageBoundaryError("Staging directory escaped the data root")

    def ready(self) -> bool:
        """Return whether the configured recording boundary is safe and writable."""
        try:
            self._validate_storage()
            return all(
                os.access(path, os.R_OK | os.W_OK | os.X_OK)
                for path in (self.data_root, self.recordings_root, self.staging_root)
            )
        except (OSError, RecordingStorageBoundaryError):
            return False

    def list_receipts(self, workspace_id: str) -> tuple[RecordingReceipt, ...]:
        """Return active recording metadata owned by one workspace."""
        with self.database.connection() as connection:
            rows = connection.execute(
                """
                SELECT recording_id, byte_count, sha256, storage_relative_path
                FROM recordings
                WHERE workspace_id = ? AND deleted_at IS NULL
                ORDER BY recording_id
                """,
                (workspace_id,),
            ).fetchall()
        return tuple(
            RecordingReceipt(
                recording_id=row["recording_id"],
                byte_count=row["byte_count"],
                sha256=row["sha256"],
                storage_relative_path=Path(row["storage_relative_path"]),
            )
            for row in rows
        )

    def commit_stream(
        self,
        workspace_id: str,
        recording_id: str,
        chunks: Iterable[bytes],
        now: datetime,
        *,
        expected_sha256: str | None = None,
    ) -> RecordingReceipt:
        if not recording_id or len(recording_id) > 256:
            raise ValueError("Recording identifier must contain 1 to 256 characters")
        self._validate_storage()
        storage_id = secrets.token_hex(16)
        staging_path = self.staging_root / f"{storage_id}.partial"
        relative_final_path = Path("recordings") / f"{storage_id}.m4a"
        final_path = self.data_root / relative_final_path
        digest = hashlib.sha256()
        byte_count = 0
        final_moved = False

        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(staging_path, flags, 0o600)
        try:
            with os.fdopen(descriptor, "wb", closefd=True) as handle:
                for chunk in chunks:
                    if not isinstance(chunk, bytes):
                        raise TypeError("Recording chunks must be bytes")
                    byte_count += len(chunk)
                    if byte_count > self.maximum_bytes:
                        raise RecordingTooLargeError("Recording exceeds the configured limit")
                    handle.write(chunk)
                    digest.update(chunk)
                handle.flush()
                os.fsync(handle.fileno())

            actual_sha256 = digest.hexdigest()
            if expected_sha256 is not None and not secrets.compare_digest(
                actual_sha256,
                expected_sha256.lower(),
            ):
                raise RecordingHashMismatchError("Recording hash did not match")

            try:
                with self.database.transaction() as connection:
                    existing = connection.execute(
                        "SELECT * FROM recordings WHERE recording_id = ?",
                        (recording_id,),
                    ).fetchone()
                    if existing is not None:
                        if (
                            existing["workspace_id"] == workspace_id
                            and existing["byte_count"] == byte_count
                            and secrets.compare_digest(existing["sha256"], actual_sha256)
                            and existing["deleted_at"] is None
                        ):
                            return RecordingReceipt(
                                recording_id=recording_id,
                                byte_count=existing["byte_count"],
                                sha256=existing["sha256"],
                                storage_relative_path=Path(existing["storage_relative_path"]),
                            )
                        raise RecordingConflictError("Recording identifier is already committed")
                    connection.execute(
                        """
                        INSERT INTO recordings(
                            recording_id, workspace_id, storage_relative_path,
                            byte_count, sha256, created_at, deleted_at
                        ) VALUES (?, ?, ?, ?, ?, ?, NULL)
                        """,
                        (
                            recording_id,
                            workspace_id,
                            str(relative_final_path),
                            byte_count,
                            actual_sha256,
                            _timestamp(now),
                        ),
                    )
                    os.replace(staging_path, final_path)
                    final_moved = True
                    os.chmod(final_path, 0o600)
                    directory_descriptor = os.open(self.recordings_root, os.O_RDONLY)
                    try:
                        os.fsync(directory_descriptor)
                    finally:
                        os.close(directory_descriptor)
            except sqlite3.IntegrityError as error:
                if final_moved:
                    final_path.unlink(missing_ok=True)
                if "recordings.recording_id" in str(error):
                    raise RecordingConflictError("Recording identifier is already committed") from error
                raise
            except BaseException:
                if final_moved:
                    final_path.unlink(missing_ok=True)
                raise

            return RecordingReceipt(
                recording_id=recording_id,
                byte_count=byte_count,
                sha256=actual_sha256,
                storage_relative_path=relative_final_path,
            )
        finally:
            staging_path.unlink(missing_ok=True)

    def download(
        self,
        workspace_id: str,
        recording_id: str,
        object_key: str,
    ) -> RecordingDownload:
        if not recording_id or not object_key:
            raise RecordingNotFoundError("Recording was not found")
        self._validate_storage()
        with self.database.connection() as connection:
            row = connection.execute(
                """
                SELECT recording_id, workspace_id, storage_relative_path,
                       byte_count, sha256, deleted_at
                FROM recordings WHERE recording_id = ?
                """,
                (recording_id,),
            ).fetchone()
        if (
            row is None
            or row["workspace_id"] != workspace_id
            or row["deleted_at"] is not None
            or row["storage_relative_path"] != object_key
        ):
            raise RecordingNotFoundError("Recording was not found")

        relative_path = Path(row["storage_relative_path"])
        if relative_path.is_absolute() or relative_path.parts[:1] != ("recordings",) or ".." in relative_path.parts:
            raise RecordingStorageBoundaryError("Recording path escaped the storage boundary")
        absolute_path = self.data_root / relative_path
        if absolute_path.is_symlink() or absolute_path.resolve().parent != self.recordings_root.resolve():
            raise RecordingStorageBoundaryError("Recording path escaped the storage boundary")

        digest = hashlib.sha256()
        byte_count = 0
        try:
            with absolute_path.open("rb") as handle:
                while chunk := handle.read(64 * 1024):
                    byte_count += len(chunk)
                    if byte_count > self.maximum_bytes:
                        raise RecordingIntegrityError("Stored recording exceeds the configured limit")
                    digest.update(chunk)
        except FileNotFoundError as error:
            raise RecordingNotFoundError("Recording was not found") from error
        if byte_count != row["byte_count"] or not secrets.compare_digest(digest.hexdigest(), row["sha256"]):
            raise RecordingIntegrityError("Stored recording integrity check failed")
        return RecordingDownload(
            recording_id=row["recording_id"],
            byte_count=byte_count,
            sha256=row["sha256"],
            storage_relative_path=relative_path,
            absolute_path=absolute_path,
        )
