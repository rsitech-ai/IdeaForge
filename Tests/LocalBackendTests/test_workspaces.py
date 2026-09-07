import concurrent.futures
import json
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.database import LocalBackendDatabase
from local_backend.workspaces import (
    IdempotencyConflictError,
    InvalidWorkspaceSnapshotError,
    WorkspaceRevisionConflictError,
    WorkspaceSnapshotTooLargeError,
    WorkspaceStore,
)


WORKSPACE_ID = "workspace_rsi"
NOW = datetime(2026, 8, 14, 9, 0, tzinfo=UTC)


def snapshot(updated_at: str, transcript: str = "Watch transcript") -> dict:
    return {
        "projects": [
            {
                "id": "idea_watch",
                "title": "Watch title",
                "transcript": {"cleanText": transcript, "segments": []},
                "recordings": [
                    {
                        "id": "rec_watch",
                        "localAudioPath": "/private/device/recording.m4a",
                        "syncStatus": "ready",
                    }
                ],
                "updatedAt": updated_at,
            }
        ],
        "workflowTemplates": [],
        "uploadJobs": [{"id": "local_upload"}],
        "privacyMode": "standardCloud",
        "syncHealth": {"queuedUploads": 1, "failingItems": 0},
        "selectedProjectID": "idea_watch",
        "updatedAt": updated_at,
    }


class WorkspaceStoreTests(unittest.TestCase):
    def make_store(self, temporary_directory: str, body_limit: int = 10 * 1024 * 1024):
        database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
        database.migrate()
        store = WorkspaceStore(database, body_limit_bytes=body_limit)
        store.create(WORKSPACE_ID, NOW)
        return database, store

    def test_publish_persists_newer_snapshot_and_strips_device_private_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, store = self.make_store(temporary_directory)

            receipt = store.publish(
                WORKSPACE_ID,
                snapshot("2026-08-14T09:00:01Z"),
                "publish-0001",
                NOW,
            )
            loaded = store.load(WORKSPACE_ID)

            self.assertEqual(
                receipt.as_dict(),
                {"workspaceID": WORKSPACE_ID, "acceptedUpdatedAt": "2026-08-14T09:00:01Z"},
            )
            self.assertEqual(loaded["projects"][0]["transcript"]["cleanText"], "Watch transcript")
            self.assertEqual(loaded["uploadJobs"], [])
            self.assertNotIn("localAudioPath", loaded["projects"][0]["recordings"][0])

    def test_publish_rejects_equal_older_and_timezone_equivalent_revisions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, store = self.make_store(temporary_directory)
            store.publish(WORKSPACE_ID, snapshot("2026-08-14T09:00:01Z"), "publish-0001", NOW)

            for index, updated_at in enumerate(
                ("2026-08-14T09:00:01Z", "2026-08-14T09:00:00Z", "2026-08-14T11:00:01+02:00")
            ):
                with self.subTest(updated_at=updated_at):
                    with self.assertRaises(WorkspaceRevisionConflictError):
                        store.publish(
                            WORKSPACE_ID,
                            snapshot(updated_at),
                            f"publish-rejected-{index}",
                            NOW,
                        )

    def test_publish_replays_same_idempotent_request_and_rejects_key_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, store = self.make_store(temporary_directory)
            original = snapshot("2026-08-14T09:00:01Z")

            first = store.publish(WORKSPACE_ID, original, "publish-0001", NOW)
            replay = store.publish(WORKSPACE_ID, original, "publish-0001", NOW)

            self.assertEqual(replay, first)
            with self.assertRaises(IdempotencyConflictError):
                store.publish(
                    WORKSPACE_ID,
                    snapshot("2026-08-14T09:00:02Z", transcript="Different"),
                    "publish-0001",
                    NOW,
                )

    def test_publish_enforces_the_clients_base_remote_revision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, store = self.make_store(temporary_directory)
            store.publish(WORKSPACE_ID, snapshot("2026-08-14T09:00:01Z"), "publish-0001", NOW)

            with self.assertRaises(WorkspaceRevisionConflictError):
                store.publish(
                    WORKSPACE_ID,
                    snapshot("2026-08-14T09:00:02Z"),
                    "publish-0002",
                    NOW,
                    base_remote_updated_at="2026-08-14T09:00:00Z",
                )

            receipt = store.publish(
                WORKSPACE_ID,
                snapshot("2026-08-14T09:00:02Z"),
                "publish-0003",
                NOW,
                base_remote_updated_at="2026-08-14T09:00:01Z",
            )
            self.assertEqual(receipt.accepted_updated_at, "2026-08-14T09:00:02Z")

    def test_publish_rolls_back_snapshot_when_receipt_cannot_persist(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, store = self.make_store(temporary_directory)
            with database.transaction() as connection:
                connection.execute(
                    """
                    CREATE TRIGGER fail_workspace_receipt
                    BEFORE INSERT ON idempotency_receipts
                    BEGIN
                        SELECT RAISE(ABORT, 'receipt blocked');
                    END
                    """
                )

            with self.assertRaisesRegex(Exception, "receipt blocked"):
                store.publish(
                    WORKSPACE_ID,
                    snapshot("2026-08-14T09:00:01Z"),
                    "publish-0001",
                    NOW,
                )

            loaded = store.load(WORKSPACE_ID)
            self.assertEqual(loaded["projects"], [])
            self.assertEqual(loaded["updatedAt"], "1970-01-01T00:00:00Z")

    def test_publish_rejects_invalid_shape_date_depth_and_size(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, store = self.make_store(temporary_directory, body_limit=500)
            invalid_snapshots = (
                {},
                {**snapshot("not-a-date")},
                {**snapshot("2026-08-14T09:00:01"), "projects": []},
                {**snapshot("2026-08-14T09:00:01Z"), "projects": "not-an-array"},
            )
            for index, invalid in enumerate(invalid_snapshots):
                with self.subTest(index=index):
                    with self.assertRaises(InvalidWorkspaceSnapshotError):
                        store.publish(WORKSPACE_ID, invalid, f"invalid-{index:04d}", NOW)

            too_deep: object = "leaf"
            for _ in range(70):
                too_deep = [too_deep]
            deep_snapshot = snapshot("2026-08-14T09:00:01Z")
            deep_snapshot["projects"] = too_deep
            with self.assertRaises(InvalidWorkspaceSnapshotError):
                store.publish(WORKSPACE_ID, deep_snapshot, "invalid-depth", NOW)

            oversized = snapshot("2026-08-14T09:00:01Z", transcript="x" * 1_000)
            with self.assertRaises(WorkspaceSnapshotTooLargeError):
                store.publish(WORKSPACE_ID, oversized, "invalid-size", NOW)

    def test_concurrent_publish_retains_the_newest_revision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, store = self.make_store(temporary_directory)

            def publish(updated_at: str) -> str:
                try:
                    store.publish(
                        WORKSPACE_ID,
                        snapshot(updated_at, transcript=updated_at),
                        f"publish-{updated_at}",
                        NOW,
                    )
                    return "published"
                except WorkspaceRevisionConflictError:
                    return "conflict"

            revisions = ("2026-08-14T09:00:01Z", "2026-08-14T09:00:02Z")
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                outcomes = list(executor.map(publish, revisions))

            loaded = store.load(WORKSPACE_ID)
            self.assertIn("published", outcomes)
            self.assertEqual(loaded["updatedAt"], "2026-08-14T09:00:02Z")
            self.assertEqual(loaded["projects"][0]["transcript"]["cleanText"], "2026-08-14T09:00:02Z")


if __name__ == "__main__":
    unittest.main()
