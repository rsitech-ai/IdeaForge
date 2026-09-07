import hashlib
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.database import LocalBackendDatabase
from local_backend.enrichment import reconcile_recording_enrichment_jobs
from local_backend.jobs import JobQueue
from local_backend.recordings import RecordingStore
from local_backend.workspaces import WorkspaceStore


WORKSPACE_ID = "workspace_rsi"
NOW = datetime(2026, 8, 28, 12, 0, tzinfo=UTC)


def _recording(recording_id: str, project_id: str, object_key: str, status: str) -> dict[str, object]:
    return {
        "id": recording_id,
        "ideaProjectID": project_id,
        "deviceName": "Apple Watch",
        "durationSeconds": 12,
        "localFileStatus": "uploaded",
        "syncStatus": status,
        "audioObjectKey": object_key,
        "languageHint": "en-US",
        "createdAt": "2026-08-28T11:30:00Z",
        "markerOffsets": [],
    }


def _project(project_id: str, recordings: list[dict[str, object]]) -> dict[str, object]:
    return {
        "id": project_id,
        "title": "Watch Idea",
        "transcript": {
            "cleanText": "Voice idea transferred from Watch.",
            "segments": [],
            "unclearFragments": [],
        },
        "recordings": recordings,
    }


class RecordingEnrichmentReconciliationTests(unittest.TestCase):
    def test_reconciles_only_exact_stored_unfinished_recordings_idempotently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"
            database = LocalBackendDatabase(data_root / "backend.sqlite3")
            database.migrate()
            workspaces = WorkspaceStore(database)
            workspaces.create(WORKSPACE_ID, NOW)
            recordings = RecordingStore(database, data_root)
            queue = JobQueue(database)

            pending_audio = b"pending-watch-audio"
            pending_receipt = recordings.commit_stream(
                WORKSPACE_ID,
                "rec_pending",
                (pending_audio,),
                NOW,
                expected_sha256=hashlib.sha256(pending_audio).hexdigest(),
            )
            ready_receipt = recordings.commit_stream(
                WORKSPACE_ID,
                "rec_ready",
                (b"ready-watch-audio",),
                NOW,
            )
            orphan_receipt = recordings.commit_stream(
                WORKSPACE_ID,
                "rec_orphan",
                (b"orphan-watch-audio",),
                NOW,
            )

            snapshot = {
                "projects": [
                    _project(
                        "idea_pending",
                        [
                            _recording(
                                "rec_pending",
                                "idea_pending",
                                str(pending_receipt.storage_relative_path),
                                "uploaded",
                            )
                        ],
                    ),
                    _project(
                        "idea_ready",
                        [
                            _recording(
                                "rec_ready",
                                "idea_ready",
                                str(ready_receipt.storage_relative_path),
                                "ready",
                            )
                        ],
                    ),
                    _project(
                        "idea_missing_audio",
                        [
                            _recording(
                                "rec_missing_audio",
                                "idea_missing_audio",
                                "recordings/not-stored.m4a",
                                "uploaded",
                            )
                        ],
                    ),
                    _project(
                        "idea_wrong_path",
                        [
                            _recording(
                                "rec_orphan",
                                "idea_wrong_path",
                                "recordings/wrong.m4a",
                                "uploaded",
                            )
                        ],
                    ),
                ],
                "workflowTemplates": [],
                "uploadJobs": [],
                "privacyMode": "privateLocal",
                "syncHealth": {"queuedUploads": 0, "failingItems": 0},
                "selectedProjectID": None,
                "updatedAt": "2026-08-28T12:00:01Z",
            }
            workspaces.publish(WORKSPACE_ID, snapshot, "publish-reconciliation-fixture", NOW)

            first = reconcile_recording_enrichment_jobs(
                workspace_id=WORKSPACE_ID,
                workspaces=workspaces,
                recordings=recordings,
                jobs=queue,
                now=NOW,
            )
            second = reconcile_recording_enrichment_jobs(
                workspace_id=WORKSPACE_ID,
                workspaces=workspaces,
                recordings=recordings,
                jobs=queue,
                now=NOW,
            )

            self.assertEqual(len(first), 1)
            self.assertEqual(second, first)
            self.assertEqual(first[0].kind, "recording_enrichment")
            self.assertEqual(
                first[0].request,
                {
                    "recordingID": "rec_pending",
                    "ideaProjectID": "idea_pending",
                    "objectKey": str(pending_receipt.storage_relative_path),
                    "byteCount": len(pending_audio),
                    "sha256": hashlib.sha256(pending_audio).hexdigest(),
                },
            )
            with database.connection() as connection:
                queued = connection.execute(
                    "SELECT COUNT(*) FROM jobs WHERE kind = 'recording_enrichment'"
                ).fetchone()[0]
            self.assertEqual(queued, 1)
            self.assertNotEqual(str(orphan_receipt.storage_relative_path), "recordings/wrong.m4a")


if __name__ == "__main__":
    unittest.main()
