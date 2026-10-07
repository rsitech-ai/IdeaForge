import json
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.database import LocalBackendDatabase
from local_backend.jobs import JobConflictError, JobLeaseError, JobQueue
from local_backend.workspaces import WorkspaceStore


WORKSPACE_ID = "workspace_rsi"
NOW = datetime(2026, 8, 14, 12, 0, tzinfo=UTC)


class JobQueueTests(unittest.TestCase):
    def test_private_mode_deferral_preserves_last_attempt_for_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, queue = self.make_queue(directory)
            job = queue.enqueue(WORKSPACE_ID, "recording_enrichment", "privacy", {}, NOW)
            for index in range(2):
                moment = NOW + timedelta(minutes=index)
                queue.claim("worker", moment)
                queue.fail(job.job_id, "worker", "speech_processing_failed", moment, retryable=True)
            for index in range(5):
                moment = NOW + timedelta(minutes=2 + index)
                claimed = queue.claim("worker", moment)
                self.assertEqual(claimed.attempt_count, 3)
                deferred = queue.fail(
                    job.job_id, "worker", "workspace_sync_disabled", moment, retryable=True,
                )
                self.assertEqual(deferred.status, "queued")
                self.assertEqual(deferred.attempt_count, 2)
                self.assertEqual(deferred.available_at, moment + timedelta(seconds=30))
            resumed_at = NOW + timedelta(minutes=7)
            resumed = queue.claim("worker", resumed_at)
            self.assertEqual(resumed.attempt_count, 3)
            completed = queue.complete(job.job_id, "worker", {"recovered": True}, resumed_at)
            self.assertEqual(completed.status, "completed")

    def test_waiting_for_workspace_does_not_exhaust_transcription_attempts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            _, queue = self.make_queue(directory)
            queued = queue.enqueue(WORKSPACE_ID, "recording_enrichment", "waiting", {}, NOW)
            for index in range(5):
                moment = NOW + timedelta(minutes=index)
                claimed = queue.claim("worker", moment)
                self.assertIsNotNone(claimed)
                deferred = queue.fail(
                    queued.job_id, "worker", "workspace_recording_missing", moment,
                    retryable=True,
                )
                self.assertEqual(deferred.status, "queued")
                self.assertEqual(deferred.attempt_count, 0)
                self.assertEqual(deferred.available_at, moment + timedelta(seconds=30))
            for index in range(3):
                moment = NOW + timedelta(minutes=5 + index)
                queue.claim("worker", moment)
                failed = queue.fail(
                    queued.job_id, "worker", "speech_processing_failed", moment,
                    retryable=True,
                )
            self.assertEqual(failed.status, "failed")
            self.assertEqual(failed.attempt_count, 3)

    def test_expired_lease_cannot_complete_or_fail_before_reclaim(self) -> None:
        for operation in ("complete", "complete_idempotently", "fail"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as directory:
                database, queue = self.make_queue(directory)
                job = queue.enqueue(WORKSPACE_ID, "recording_enrichment", "expired", {}, NOW)
                queue.claim("worker-a", NOW, lease_duration=timedelta(seconds=30))
                expired = NOW + timedelta(seconds=30)
                with self.assertRaises(JobLeaseError):
                    if operation == "complete":
                        queue.complete(job.job_id, "worker-a", {}, expired)
                    elif operation == "complete_idempotently":
                        queue.complete_idempotently(
                            job.job_id, "worker-a", {}, expired,
                            workspace_id=WORKSPACE_ID, kind="recording_enrichment",
                        )
                    else:
                        queue.fail(job.job_id, "worker-a", "timeout", expired, retryable=True)
                with database.connection() as connection:
                    row = connection.execute("SELECT status FROM jobs WHERE job_id = ?", (job.job_id,)).fetchone()
                self.assertEqual(row["status"], "running")
                reclaimed = queue.claim("worker-b", expired)
                self.assertEqual(reclaimed.job_id, job.job_id)
                self.assertEqual(reclaimed.lease_owner, "worker-b")

    def make_queue(self, temporary_directory: str, maximum_attempts: int = 3):
        database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
        database.migrate()
        WorkspaceStore(database).create(WORKSPACE_ID, NOW)
        return database, JobQueue(database, maximum_attempts=maximum_attempts, maximum_concurrent=2)

    def test_enqueue_is_durable_and_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, queue = self.make_queue(temporary_directory)
            request = {"provider": "openai", "workflow": "prd", "projectID": "idea_watch"}

            first = queue.enqueue(WORKSPACE_ID, "workflow", "workflow-0001", request, NOW)
            replay = queue.enqueue(WORKSPACE_ID, "workflow", "workflow-0001", request, NOW)

            self.assertEqual(replay, first)
            with database.connection() as connection:
                row = connection.execute(
                    "SELECT status, request_json, attempt_count FROM jobs WHERE job_id = ?",
                    (first.job_id,),
                ).fetchone()
            self.assertEqual(row["status"], "queued")
            self.assertEqual(json.loads(row["request_json"]), request)
            self.assertEqual(row["attempt_count"], 0)
            with self.assertRaises(JobConflictError):
                queue.enqueue(
                    WORKSPACE_ID,
                    "workflow",
                    "workflow-0001",
                    {**request, "projectID": "different"},
                    NOW,
                )

    def test_claim_lease_expiry_and_reclaim_increment_attempts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, queue = self.make_queue(temporary_directory)
            queued = queue.enqueue(WORKSPACE_ID, "workflow", "workflow-0001", {}, NOW)

            first = queue.claim("worker-a", NOW, lease_duration=timedelta(seconds=30))
            before_expiry = queue.claim("worker-b", NOW + timedelta(seconds=29))
            reclaimed = queue.claim("worker-b", NOW + timedelta(seconds=31))

            self.assertEqual(first.job_id, queued.job_id)
            self.assertEqual(first.attempt_count, 1)
            self.assertIsNone(before_expiry)
            self.assertEqual(reclaimed.job_id, queued.job_id)
            self.assertEqual(reclaimed.attempt_count, 2)
            self.assertEqual(reclaimed.lease_owner, "worker-b")

    def test_claim_enforces_two_running_jobs_per_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, queue = self.make_queue(temporary_directory)
            for index in range(3):
                queue.enqueue(WORKSPACE_ID, "workflow", f"workflow-{index:04d}", {}, NOW)

            first = queue.claim("worker-a", NOW)
            second = queue.claim("worker-b", NOW)
            third = queue.claim("worker-c", NOW)

            self.assertIsNotNone(first)
            self.assertIsNotNone(second)
            self.assertIsNone(third)

    def test_complete_requires_current_lease_and_persists_terminal_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, queue = self.make_queue(temporary_directory)
            queued = queue.enqueue(WORKSPACE_ID, "workflow", "workflow-0001", {}, NOW)
            queue.claim("worker-a", NOW)

            with self.assertRaises(JobLeaseError):
                queue.complete(queued.job_id, "worker-b", {"status": "wrong"}, NOW)
            completed = queue.complete(
                queued.job_id,
                "worker-a",
                {"status": "completed", "artifactCount": 1},
                NOW + timedelta(seconds=1),
            )

            self.assertEqual(completed.status, "completed")
            with database.connection() as connection:
                row = connection.execute(
                    "SELECT status, result_json, lease_owner, lease_expires_at FROM jobs WHERE job_id = ?",
                    (queued.job_id,),
                ).fetchone()
            self.assertEqual(row["status"], "completed")
            self.assertEqual(json.loads(row["result_json"])["artifactCount"], 1)
            self.assertIsNone(row["lease_owner"])
            self.assertIsNone(row["lease_expires_at"])

    def test_retryable_failure_backs_off_then_becomes_terminal_at_attempt_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, queue = self.make_queue(temporary_directory, maximum_attempts=2)
            queued = queue.enqueue(WORKSPACE_ID, "workflow", "workflow-0001", {}, NOW)
            queue.claim("worker-a", NOW)

            retry = queue.fail(
                queued.job_id,
                "worker-a",
                "provider_unavailable",
                NOW,
                retryable=True,
            )

            self.assertEqual(retry.status, "queued")
            self.assertGreaterEqual(retry.available_at, NOW + timedelta(seconds=1))
            self.assertLessEqual(retry.available_at, NOW + timedelta(seconds=2))
            self.assertIsNone(queue.claim("worker-a", NOW))
            second = queue.claim("worker-a", retry.available_at)
            terminal = queue.fail(
                second.job_id,
                "worker-a",
                "provider_unavailable",
                retry.available_at,
                retryable=True,
            )
            self.assertEqual(terminal.status, "failed")
            self.assertEqual(terminal.diagnostic_code, "provider_unavailable")

    def test_release_worker_leases_makes_shutdown_work_immediately_retryable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, queue = self.make_queue(temporary_directory)
            queued = queue.enqueue(WORKSPACE_ID, "workflow", "workflow-0001", {}, NOW)
            queue.claim("worker-a", NOW, lease_duration=timedelta(minutes=5))

            released = queue.release_worker_leases("worker-a", NOW + timedelta(seconds=1))
            reclaimed = queue.claim("worker-b", NOW + timedelta(seconds=1))

            self.assertEqual(released, 1)
            self.assertEqual(reclaimed.job_id, queued.job_id)
            self.assertEqual(reclaimed.lease_owner, "worker-b")


if __name__ == "__main__":
    unittest.main()
