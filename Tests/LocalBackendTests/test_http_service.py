import hashlib
import http.client
import json
import sys
import tempfile
import threading
import unittest
import urllib.parse
from datetime import UTC, datetime, timedelta
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.auth import DeviceAuthorizer, PairingService
from local_backend.database import LocalBackendDatabase
from local_backend.http_service import LocalBackendApplication, create_http_server
from local_backend.jobs import JobQueue
from local_backend.rate_limits import PersistentRateLimiter, RateLimitPolicy
from local_backend.recordings import RecordingStore
from local_backend.workspaces import WorkspaceStore


WORKSPACE_ID = "workspace_rsi"
NOW = datetime(2026, 8, 14, 10, 0, tzinfo=UTC)


class MutableClock:
    def __init__(self, current: datetime) -> None:
        self.current = current

    def __call__(self) -> datetime:
        return self.current

    def advance(self, **delta) -> None:
        self.current += timedelta(**delta)


def workspace_snapshot(updated_at: str) -> dict:
    return {
        "projects": [],
        "workflowTemplates": [],
        "uploadJobs": [],
        "privacyMode": "standardCloud",
        "syncHealth": {"queuedUploads": 0, "failingItems": 0},
        "selectedProjectID": None,
        "updatedAt": updated_at,
    }


class RunningService:
    def __init__(
        self,
        temporary_directory: str,
        allowed_cidrs=("127.0.0.0/8",),
        rate_limit_policy: RateLimitPolicy | None = None,
        clock=None,
    ) -> None:
        self.clock = clock or MutableClock(NOW)
        self.database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
        self.database.migrate()
        self.workspaces = WorkspaceStore(self.database)
        self.workspaces.create(WORKSPACE_ID, NOW)
        self.pairing = PairingService(self.database, WORKSPACE_ID)
        self.recordings = RecordingStore(self.database, Path(temporary_directory) / "state")
        self.jobs = JobQueue(self.database, maximum_concurrent=1)
        application = LocalBackendApplication(
            database=self.database,
            workspace_id=WORKSPACE_ID,
            pairing=self.pairing,
            authorizer=DeviceAuthorizer(self.database),
            workspaces=self.workspaces,
            recordings=self.recordings,
            jobs=self.jobs,
            rate_limiter=PersistentRateLimiter(self.database) if rate_limit_policy else None,
            rate_limit_policy=rate_limit_policy or RateLimitPolicy(),
            allowed_cidrs=allowed_cidrs,
            clock=self.clock,
        )
        self.server = create_http_server("127.0.0.1", 0, application)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def port(self) -> int:
        return self.server.server_address[1]

    def request(self, method: str, path: str, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        encoded = None if body is None else json.dumps(body).encode("utf-8")
        request_headers = dict(headers or {})
        if encoded is not None:
            request_headers.setdefault("Content-Type", "application/json")
        connection.request(method, path, body=encoded, headers=request_headers)
        response = connection.getresponse()
        payload = response.read()
        response_headers = dict(response.getheaders())
        connection.close()
        decoded = json.loads(payload) if payload else None
        return response.status, response_headers, decoded

    def request_bytes(self, method: str, path: str, body: bytes, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        request_headers = dict(headers or {})
        request_headers.setdefault("Content-Length", str(len(body)))
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        payload = response.read()
        connection.close()
        return response.status, json.loads(payload) if payload else None

    def request_raw(self, method: str, path: str, body: bytes | None = None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        request_headers = dict(headers or {})
        if body is not None:
            request_headers.setdefault("Content-Length", str(len(body)))
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        payload = response.read()
        response_headers = dict(response.getheaders())
        connection.close()
        return response.status, response_headers, payload

    def pair(self, label="iPhone") -> dict:
        code = self.pairing.create_code(label, self.clock())
        status, _, payload = self.request(
            "POST",
            "/v1/local/pair",
            {"pairingCode": code.value, "deviceLabel": label},
        )
        if status != 201:
            raise AssertionError(payload)
        return payload

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            raise AssertionError("Local backend server did not stop")


class LocalBackendHTTPServiceTests(unittest.TestCase):
    def test_health_routes_are_content_free_and_ready(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)

            live_status, _, live = service.request("GET", "/health/live")
            ready_status, _, ready = service.request("GET", "/health/ready")

            self.assertEqual((live_status, live), (200, {"status": "live"}))
            self.assertEqual((ready_status, ready), (200, {"status": "ready"}))
            self.assertNotIn(WORKSPACE_ID, json.dumps(ready))

    def test_readiness_fails_when_recording_storage_boundary_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)
            service.recordings.staging_root.rmdir()
            service.recordings.staging_root.symlink_to(service.recordings.recordings_root)

            status, _, payload = service.request("GET", "/health/ready")

            self.assertEqual(status, 503)
            self.assertEqual(payload, {"status": "not_ready"})

    def test_pairing_returns_one_token_and_session_requires_its_workspace_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)
            paired = service.pair()
            headers = {
                "Authorization": f"Bearer {paired['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }

            status, _, session = service.request("GET", "/v1/auth/session", headers=headers)

            self.assertEqual(status, 200)
            self.assertEqual(session["workspaceID"], WORKSPACE_ID)
            self.assertEqual(session["userID"], "local_operator")
            self.assertEqual(
                session["capabilities"],
                ["sync_workspace", "upload_recordings", "process_recordings"],
            )
            self.assertNotIn("bearerToken", session)

            bad_status, _, bad = service.request(
                "GET",
                "/v1/auth/session",
                headers={**headers, "X-IdeaForge-Workspace-ID": "workspace_other"},
            )
            self.assertEqual(bad_status, 403)
            self.assertEqual(bad, {"error": "forbidden", "detail": "Workspace authorization failed."})

    def test_invalid_token_error_does_not_echo_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)
            secret = "invalid-secret-token"

            status, _, payload = service.request(
                "GET",
                "/v1/workspace/snapshot",
                headers={
                    "Authorization": f"Bearer {secret}",
                    "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                },
            )

            self.assertEqual(status, 401)
            self.assertEqual(payload, {"error": "unauthorized", "detail": "Device authorization failed."})
            self.assertNotIn(secret, json.dumps(payload))

    def test_paired_devices_publish_pull_and_restart_exact_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            phone = service.pair("iPhone")
            mac = service.pair("Mac")
            phone_headers = {
                "Authorization": f"Bearer {phone['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                "Idempotency-Key": "phone-publish-0001",
            }
            mac_headers = {
                "Authorization": f"Bearer {mac['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }

            put_status, _, receipt = service.request(
                "PUT",
                "/v1/workspace/snapshot",
                workspace_snapshot("2026-08-14T10:00:01Z"),
                phone_headers,
            )
            get_status, _, pulled = service.request(
                "GET", "/v1/workspace/snapshot", headers=mac_headers
            )
            service.close()

            restarted = RunningService.__new__(RunningService)
            restarted.database = LocalBackendDatabase(
                Path(temporary_directory) / "state" / "backend.sqlite3"
            )
            restarted.database.migrate()
            restarted.workspaces = WorkspaceStore(restarted.database)
            restarted.pairing = PairingService(restarted.database, WORKSPACE_ID)
            restarted.recordings = RecordingStore(
                restarted.database,
                Path(temporary_directory) / "state",
            )
            restarted.jobs = JobQueue(restarted.database, maximum_concurrent=1)
            restarted.server = create_http_server(
                "127.0.0.1",
                0,
                LocalBackendApplication(
                    database=restarted.database,
                    workspace_id=WORKSPACE_ID,
                    pairing=restarted.pairing,
                    authorizer=DeviceAuthorizer(restarted.database),
                    workspaces=restarted.workspaces,
                    recordings=restarted.recordings,
                    jobs=restarted.jobs,
                    allowed_cidrs=("127.0.0.0/8",),
                    clock=MutableClock(NOW),
                ),
            )
            restarted.thread = threading.Thread(target=restarted.server.serve_forever, daemon=True)
            restarted.thread.start()
            self.addCleanup(restarted.close)
            restart_status, _, restart_pull = restarted.request(
                "GET", "/v1/workspace/snapshot", headers=mac_headers
            )

            self.assertEqual(put_status, 200)
            self.assertEqual(
                receipt,
                {"workspaceID": WORKSPACE_ID, "acceptedUpdatedAt": "2026-08-14T10:00:01Z"},
            )
            self.assertEqual(get_status, 200)
            self.assertEqual(pulled, workspace_snapshot("2026-08-14T10:00:01Z"))
            self.assertEqual(restart_status, 200)
            self.assertEqual(restart_pull, pulled)

    def test_publish_rejects_wrong_content_type_and_stale_precondition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)
            paired = service.pair()
            headers = {
                "Authorization": f"Bearer {paired['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                "Idempotency-Key": "phone-publish-0001",
            }

            wrong_status, _, wrong = service.request(
                "PUT",
                "/v1/workspace/snapshot",
                workspace_snapshot("2026-08-14T10:00:01Z"),
                {**headers, "Content-Type": "text/plain"},
            )
            good_status, _, _ = service.request(
                "PUT",
                "/v1/workspace/snapshot",
                workspace_snapshot("2026-08-14T10:00:01Z"),
                headers,
            )
            stale_status, _, stale = service.request(
                "PUT",
                "/v1/workspace/snapshot",
                workspace_snapshot("2026-08-14T10:00:02Z"),
                {
                    **headers,
                    "Idempotency-Key": "phone-publish-0002",
                    "X-IdeaForge-Base-Remote-Updated-At": "1970-01-01T00:00:00Z",
                },
            )

            self.assertEqual(wrong_status, 415)
            self.assertEqual(wrong["error"], "unsupported_media_type")
            self.assertEqual(good_status, 200)
            self.assertEqual(stale_status, 409)
            self.assertEqual(stale["error"], "workspace_revision_conflict")

    def test_recording_upload_streams_to_local_file_and_returns_relative_object_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)
            paired = service.pair()
            audio = b"watch-audio"
            headers = {
                "Authorization": f"Bearer {paired['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                "X-IdeaForge-Recording-ID": "rec_watch",
                "X-IdeaForge-Idea-ID": "idea_watch",
                "X-IdeaForge-Upload-Job-ID": "upload_rec_watch",
                "X-IdeaForge-Content-SHA256": hashlib.sha256(audio).hexdigest(),
                "Content-Type": "application/octet-stream",
            }

            status, receipt = service.request_bytes(
                "POST", "/v1/recordings/upload", audio, headers
            )

            self.assertEqual(status, 201)
            self.assertTrue(receipt["objectKey"].startswith("recordings/"))
            stored_path = Path(temporary_directory) / "state" / receipt["objectKey"]
            self.assertEqual(stored_path.read_bytes(), audio)

            replay_status, replay = service.request_bytes(
                "POST", "/v1/recordings/upload", audio, headers
            )
            self.assertEqual(replay_status, 201)
            self.assertEqual(replay["objectKey"], receipt["objectKey"])

            duplicate_status, duplicate = service.request_bytes(
                "POST", "/v1/recordings/upload", b"second", {
                    **headers,
                    "X-IdeaForge-Content-SHA256": hashlib.sha256(b"second").hexdigest(),
                }
            )
            self.assertEqual(duplicate_status, 409)
            self.assertEqual(duplicate["error"], "recording_conflict")

    def test_uploaded_recording_is_exclusively_claimed_downloaded_and_completed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)
            phone = service.pair("iPhone")
            mac = service.pair("Mac")
            second_mac = service.pair("Second Mac")
            phone_headers = {
                "Authorization": f"Bearer {phone['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                "X-IdeaForge-Recording-ID": "rec_watch_enrichment",
                "X-IdeaForge-Idea-ID": "idea_watch_enrichment",
                "X-IdeaForge-Upload-Job-ID": "upload_watch_enrichment",
                "X-IdeaForge-Content-SHA256": hashlib.sha256(b"watch-enrichment-audio").hexdigest(),
                "Content-Type": "application/octet-stream",
            }
            mac_headers = {
                "Authorization": f"Bearer {mac['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }
            second_mac_headers = {
                "Authorization": f"Bearer {second_mac['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }

            upload_status, upload_receipt = service.request_bytes(
                "POST",
                "/v1/recordings/upload",
                b"watch-enrichment-audio",
                phone_headers,
            )
            claim_status, _, claim_payload = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 120},
                mac_headers,
            )
            competing_status, _, competing_payload = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 120},
                second_mac_headers,
            )

            self.assertEqual(upload_status, 201)
            self.assertEqual(claim_status, 200)
            job = claim_payload["job"]
            self.assertEqual(job["recordingID"], "rec_watch_enrichment")
            self.assertEqual(job["ideaProjectID"], "idea_watch_enrichment")
            self.assertEqual(job["objectKey"], upload_receipt["objectKey"])
            self.assertEqual(job["byteCount"], len(b"watch-enrichment-audio"))
            self.assertEqual(
                job["sha256"],
                hashlib.sha256(b"watch-enrichment-audio").hexdigest(),
            )
            self.assertEqual(competing_status, 200)
            self.assertIsNone(competing_payload["job"])

            query = urllib.parse.urlencode(
                {
                    "recordingID": job["recordingID"],
                    "objectKey": job["objectKey"],
                }
            )
            audio_status, audio_headers, downloaded = service.request_raw(
                "GET",
                f"/v1/recordings/audio?{query}",
                headers=mac_headers,
            )
            self.assertEqual(audio_status, 200)
            self.assertEqual(downloaded, b"watch-enrichment-audio")
            self.assertEqual(audio_headers["Content-Type"], "application/octet-stream")
            self.assertEqual(audio_headers["X-IdeaForge-Content-SHA256"], job["sha256"])
            self.assertEqual(audio_headers["Cache-Control"], "no-store")

            completion = {
                "jobID": job["jobID"],
                "workspaceUpdatedAt": "2026-08-14T10:01:00Z",
            }
            premature_status, _, _ = service.request(
                "POST", "/v1/enrichment/jobs/complete", completion, mac_headers
            )
            self.assertEqual(premature_status, 409)
            snapshot = workspace_snapshot(completion["workspaceUpdatedAt"])
            snapshot["projects"] = [{
                "id": job["ideaProjectID"],
                "title": "Recorded idea",
                "transcript": {"cleanText": "A real transcript", "segments": [], "unclearFragments": []},
                "recordings": [{
                    "id": job["recordingID"],
                    "ideaProjectID": job["ideaProjectID"],
                    "audioObjectKey": job["objectKey"],
                    "syncStatus": "ready",
                }],
            }]
            publish_status, _, _ = service.request(
                "PUT", "/v1/workspace/snapshot", snapshot, mac_headers
            )
            self.assertEqual(publish_status, 200)
            complete_status, _, completed = service.request(
                "POST",
                "/v1/enrichment/jobs/complete",
                completion,
                mac_headers,
            )
            replay_status, _, replayed = service.request(
                "POST",
                "/v1/enrichment/jobs/complete",
                completion,
                mac_headers,
            )
            self.assertEqual(complete_status, 200)
            self.assertEqual(completed["status"], "completed")
            self.assertEqual(replay_status, 200)
            self.assertEqual(replayed, completed)

    def test_expired_enrichment_lease_is_reclaimable_by_another_mac(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            clock = MutableClock(NOW)
            service = RunningService(temporary_directory, clock=clock)
            self.addCleanup(service.close)
            phone = service.pair("iPhone")
            first_mac = service.pair("First Mac")
            second_mac = service.pair("Second Mac")
            audio = b"lease-expiry-audio"
            upload_headers = {
                "Authorization": f"Bearer {phone['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                "X-IdeaForge-Recording-ID": "rec_lease_expiry",
                "X-IdeaForge-Idea-ID": "idea_lease_expiry",
                "X-IdeaForge-Upload-Job-ID": "upload_lease_expiry",
                "X-IdeaForge-Content-SHA256": hashlib.sha256(audio).hexdigest(),
                "Content-Type": "application/octet-stream",
            }
            service.request_bytes("POST", "/v1/recordings/upload", audio, upload_headers)

            first_status, _, first = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 30},
                {
                    "Authorization": f"Bearer {first_mac['bearerToken']}",
                    "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                },
            )
            clock.advance(seconds=31)
            second_status, _, second = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 30},
                {
                    "Authorization": f"Bearer {second_mac['bearerToken']}",
                    "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                },
            )

            self.assertEqual(first_status, 200)
            self.assertEqual(second_status, 200)
            self.assertEqual(second["job"]["jobID"], first["job"]["jobID"])
            self.assertEqual(second["job"]["attemptCount"], 2)

    def test_enrichment_worker_can_renew_its_lease_during_long_transcription(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            clock = MutableClock(NOW)
            service = RunningService(temporary_directory, clock=clock)
            self.addCleanup(service.close)
            phone = service.pair("iPhone")
            mac = service.pair("Mac")
            other_mac = service.pair("Other Mac")
            audio = b"long-transcription-audio"
            upload_headers = {
                "Authorization": f"Bearer {phone['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                "X-IdeaForge-Recording-ID": "rec_long_transcription",
                "X-IdeaForge-Idea-ID": "idea_long_transcription",
                "X-IdeaForge-Upload-Job-ID": "upload_long_transcription",
                "X-IdeaForge-Content-SHA256": hashlib.sha256(audio).hexdigest(),
                "Content-Type": "application/octet-stream",
            }
            mac_headers = {
                "Authorization": f"Bearer {mac['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }
            other_headers = {
                "Authorization": f"Bearer {other_mac['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }
            service.request_bytes("POST", "/v1/recordings/upload", audio, upload_headers)
            _, _, claimed = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 30},
                mac_headers,
            )
            clock.advance(seconds=20)

            renew_status, _, renewed = service.request(
                "POST",
                "/v1/enrichment/jobs/renew",
                {"jobID": claimed["job"]["jobID"], "leaseDurationSeconds": 30},
                mac_headers,
            )
            clock.advance(seconds=11)
            _, _, blocked = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 30},
                other_headers,
            )
            clock.advance(seconds=20)
            _, _, reclaimed = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 30},
                other_headers,
            )

            self.assertEqual(renew_status, 200)
            self.assertEqual(renewed["jobID"], claimed["job"]["jobID"])
            self.assertIsNone(blocked["job"])
            self.assertEqual(reclaimed["job"]["jobID"], claimed["job"]["jobID"])

    def test_retryable_enrichment_failure_requeues_without_exposing_detail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            clock = MutableClock(NOW)
            service = RunningService(temporary_directory, clock=clock)
            self.addCleanup(service.close)
            phone = service.pair("iPhone")
            mac = service.pair("Mac")
            audio = b"retryable-enrichment"
            upload_headers = {
                "Authorization": f"Bearer {phone['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
                "X-IdeaForge-Recording-ID": "rec_retry_enrichment",
                "X-IdeaForge-Idea-ID": "idea_retry_enrichment",
                "X-IdeaForge-Upload-Job-ID": "upload_retry_enrichment",
                "X-IdeaForge-Content-SHA256": hashlib.sha256(audio).hexdigest(),
                "Content-Type": "application/octet-stream",
            }
            mac_headers = {
                "Authorization": f"Bearer {mac['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }
            service.request_bytes("POST", "/v1/recordings/upload", audio, upload_headers)
            _, _, claimed = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 120},
                mac_headers,
            )

            fail_status, _, failed = service.request(
                "POST",
                "/v1/enrichment/jobs/fail",
                {
                    "jobID": claimed["job"]["jobID"],
                    "diagnosticCode": "speech_permission_required",
                    "retryable": True,
                },
                mac_headers,
            )
            clock.advance(seconds=3)
            reclaim_status, _, reclaimed = service.request(
                "POST",
                "/v1/enrichment/jobs/claim",
                {"leaseDurationSeconds": 120},
                mac_headers,
            )

            self.assertEqual(fail_status, 200)
            self.assertEqual(failed, {"jobID": claimed["job"]["jobID"], "status": "queued"})
            self.assertNotIn("permission", json.dumps(failed))
            self.assertEqual(reclaim_status, 200)
            self.assertEqual(reclaimed["job"]["attemptCount"], 2)

    def test_audio_download_fails_closed_for_mismatched_object_or_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory)
            self.addCleanup(service.close)
            paired = service.pair("Mac")
            headers = {
                "Authorization": f"Bearer {paired['bearerToken']}",
                "X-IdeaForge-Workspace-ID": WORKSPACE_ID,
            }
            service.workspaces.create("workspace_other", NOW)
            service.recordings.commit_stream(
                "workspace_other",
                "rec_other_workspace",
                [b"private-other-audio"],
                NOW,
                expected_sha256=hashlib.sha256(b"private-other-audio").hexdigest(),
            )
            cross_query = urllib.parse.urlencode(
                {
                    "recordingID": "rec_other_workspace",
                    "objectKey": "recordings/not-the-object.m4a",
                }
            )
            cross_status, _, cross_payload = service.request_raw(
                "GET",
                f"/v1/recordings/audio?{cross_query}",
                headers=headers,
            )

            self.assertEqual(cross_status, 404)
            self.assertNotIn(b"private-other-audio", cross_payload)

    def test_source_outside_allowlist_is_rejected_before_route_handling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(temporary_directory, allowed_cidrs=("10.0.0.0/8",))
            self.addCleanup(service.close)

            status, _, payload = service.request("GET", "/health/live")

            self.assertEqual(status, 403)
            self.assertEqual(payload, {"error": "network_forbidden", "detail": "Source network is not allowed."})

    def test_pairing_rate_limit_returns_bounded_retry_after(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            service = RunningService(
                temporary_directory,
                rate_limit_policy=RateLimitPolicy(pairing_attempts_per_five_minutes=1),
            )
            self.addCleanup(service.close)
            first_code = service.pairing.create_code("First", NOW)
            second_code = service.pairing.create_code("Second", NOW)

            first_status, _, _ = service.request(
                "POST",
                "/v1/local/pair",
                {"pairingCode": first_code.value, "deviceLabel": "First"},
            )
            second_status, headers, payload = service.request(
                "POST",
                "/v1/local/pair",
                {"pairingCode": second_code.value, "deviceLabel": "Second"},
            )

            self.assertEqual(first_status, 201)
            self.assertEqual(second_status, 429)
            self.assertEqual(payload["error"], "rate_limited")
            self.assertGreaterEqual(int(headers["Retry-After"]), 1)
            self.assertLessEqual(int(headers["Retry-After"]), 300)

    def test_pairing_expiry_uses_injected_request_clock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            clock = MutableClock(NOW)
            service = RunningService(temporary_directory, clock=clock)
            self.addCleanup(service.close)
            code = service.pairing.create_code("Expired iPhone", clock())
            clock.advance(minutes=6)

            status, _, payload = service.request(
                "POST",
                "/v1/local/pair",
                {"pairingCode": code.value, "deviceLabel": "Expired iPhone"},
            )

            self.assertEqual(status, 400)
            self.assertEqual(payload["error"], "pairing_expired")


if __name__ == "__main__":
    unittest.main()
