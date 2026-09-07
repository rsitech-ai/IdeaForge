import hashlib
import io
import os
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.database import LocalBackendDatabase
from local_backend.recordings import (
    RecordingConflictError,
    RecordingHashMismatchError,
    RecordingStorageBoundaryError,
    RecordingStore,
    RecordingTooLargeError,
)
from local_backend.workspaces import WorkspaceStore


WORKSPACE_ID = "workspace_rsi"
NOW = datetime(2026, 8, 14, 11, 0, tzinfo=UTC)


class RecordingStoreTests(unittest.TestCase):
    def make_store(self, temporary_directory: str, limit: int = 1024):
        data_root = Path(temporary_directory) / "state"
        database = LocalBackendDatabase(data_root / "backend.sqlite3")
        database.migrate()
        WorkspaceStore(database).create(WORKSPACE_ID, NOW)
        return database, RecordingStore(database, data_root, maximum_bytes=limit)

    def test_commit_stream_uses_generated_owner_only_path_and_persists_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, store = self.make_store(temporary_directory)
            audio = b"real-watch-audio"

            receipt = store.commit_stream(
                WORKSPACE_ID,
                "../user/controlled/recording-id",
                (audio[:4], audio[4:]),
                NOW,
                expected_sha256=hashlib.sha256(audio).hexdigest(),
            )

            self.assertEqual(receipt.recording_id, "../user/controlled/recording-id")
            self.assertEqual(receipt.byte_count, len(audio))
            self.assertEqual(receipt.sha256, hashlib.sha256(audio).hexdigest())
            self.assertNotIn("..", receipt.storage_relative_path.parts)
            self.assertNotIn("user", receipt.storage_relative_path.parts)
            stored = store.data_root / receipt.storage_relative_path
            self.assertEqual(stored.read_bytes(), audio)
            self.assertEqual(stored.stat().st_mode & 0o777, 0o600)
            with database.connection() as connection:
                row = connection.execute(
                    "SELECT storage_relative_path, byte_count, sha256 FROM recordings WHERE recording_id = ?",
                    (receipt.recording_id,),
                ).fetchone()
            self.assertEqual(Path(row["storage_relative_path"]), receipt.storage_relative_path)
            self.assertEqual(row["byte_count"], len(audio))
            self.assertEqual(row["sha256"], receipt.sha256)

    def test_commit_stream_rejects_oversize_and_hash_mismatch_without_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, store = self.make_store(temporary_directory, limit=5)

            with self.assertRaises(RecordingTooLargeError):
                store.commit_stream(WORKSPACE_ID, "rec_large", (b"1234", b"56"), NOW)
            with self.assertRaises(RecordingHashMismatchError):
                store.commit_stream(
                    WORKSPACE_ID,
                    "rec_hash",
                    (b"1234",),
                    NOW,
                    expected_sha256="0" * 64,
                )

            self.assertEqual(list((store.data_root / "staging").iterdir()), [])
            self.assertEqual(list((store.data_root / "recordings").iterdir()), [])
            with database.connection() as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM recordings").fetchone()[0], 0)

    def test_commit_stream_removes_final_file_when_metadata_transaction_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, store = self.make_store(temporary_directory)
            with database.transaction() as connection:
                connection.execute(
                    """
                    CREATE TRIGGER fail_recording_metadata
                    BEFORE INSERT ON recordings
                    BEGIN
                        SELECT RAISE(ABORT, 'metadata blocked');
                    END
                    """
                )

            with self.assertRaisesRegex(Exception, "metadata blocked"):
                store.commit_stream(WORKSPACE_ID, "rec_fail", (b"audio",), NOW)

            self.assertEqual(list((store.data_root / "staging").iterdir()), [])
            self.assertEqual(list((store.data_root / "recordings").iterdir()), [])

    def test_commit_stream_replays_matching_recording_and_rejects_changed_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, store = self.make_store(temporary_directory)
            first = store.commit_stream(WORKSPACE_ID, "rec_same", (b"first",), NOW)
            replay = store.commit_stream(WORKSPACE_ID, "rec_same", (b"first",), NOW)

            with self.assertRaises(RecordingConflictError):
                store.commit_stream(WORKSPACE_ID, "rec_same", (b"second",), NOW)

            self.assertEqual(replay, first)
            stored_files = list((store.data_root / "recordings").iterdir())
            self.assertEqual(len(stored_files), 1)
            self.assertEqual(stored_files[0].read_bytes(), b"first")

    def test_commit_stream_refuses_symlinked_storage_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, store = self.make_store(temporary_directory)
            outside = Path(temporary_directory) / "outside"
            outside.mkdir()
            recordings = store.data_root / "recordings"
            recordings.rmdir()
            recordings.symlink_to(outside, target_is_directory=True)

            with self.assertRaises(RecordingStorageBoundaryError):
                store.commit_stream(WORKSPACE_ID, "rec_symlink", (b"audio",), NOW)

            self.assertEqual(list(outside.iterdir()), [])
            with database.connection() as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM recordings").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
