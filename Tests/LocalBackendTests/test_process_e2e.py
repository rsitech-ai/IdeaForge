"""Production CLI/TLS/persistence integration with disposable synthetic audio."""

import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.parse

ROOT = Path(__file__).resolve().parents[2]


class LocalBackendProcessE2ETests(unittest.TestCase):
    def test_tls_upload_enrichment_and_credentials_survive_process_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tls = root / "tls"
            hostname = "ideaforge-test.local"
            provision = subprocess.run([
                sys.executable, str(ROOT / "script/setup_local_backend_tls.py"),
                "--tls-root", str(tls), "--hostname", hostname,
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(provision.returncode, 0, provision.stderr)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            environment = {k: v for k, v in os.environ.items() if not k.startswith("IDEAFORGE_LOCAL_BACKEND_")}
            environment.update({
                "IDEAFORGE_LOCAL_BACKEND_DATA_ROOT": str(root / "state"),
                "IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID": "workspace_process_fixture",
                "IDEAFORGE_LOCAL_BACKEND_BIND_HOST": "127.0.0.1",
                "IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS": "127.0.0.0/8",
                "IDEAFORGE_LOCAL_BACKEND_PORT": str(port),
                "IDEAFORGE_LOCAL_BACKEND_TLS_CERT": str(tls / "server.cert.pem"),
                "IDEAFORGE_LOCAL_BACKEND_TLS_KEY": str(tls / "server.key.pem"),
            })
            context = ssl.create_default_context(cafile=str(tls / "ca.cert.pem"))
            # Enforce strict certificate verification on Python versions whose
            # default context predates VERIFY_X509_STRICT.
            context.verify_flags |= ssl.VERIFY_X509_STRICT
            command = [sys.executable, str(ROOT / "script/local_backend.py")]
            processes = []
            logs = []

            def stop(process):
                if process.poll() is None:
                    process.terminate()
                try:
                    output, errors = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    self.fail("Backend did not shut down within ten seconds")
                logs.append((output, errors))
                self.assertEqual(process.returncode, 0, errors)

            def request(method, path, payload=None, headers=None, raw=False):
                body = payload if raw else (None if payload is None else json.dumps(payload).encode())
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                connection.connect()
                connection.sock = context.wrap_socket(connection.sock, server_hostname=hostname)
                request_headers = dict(headers or {})
                if body is not None and not raw:
                    request_headers["Content-Type"] = "application/json"
                try:
                    connection.request(method, path, body=body, headers=request_headers)
                    response = connection.getresponse()
                    data = response.read()
                    return response.status, data if raw else (json.loads(data) if data else None)
                finally:
                    connection.close()

            def start():
                process = subprocess.Popen([*command, "serve"], env=environment,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                processes.append(process)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        if request("GET", "/health/ready") == (200, {"status": "ready"}):
                            return process
                    except (OSError, http.client.HTTPException):
                        pass
                    if process.poll() is not None:
                        break
                    time.sleep(.1)
                self.fail("Backend did not become ready with trusted TLS")

            try:
                process = start()
                self.assertEqual(request("GET", "/v1/workspace/snapshot")[0], 401)

                def pair(label):
                    result = subprocess.run([*command, "create-pairing-code", label], env=environment,
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0)
                    code = json.loads(result.stdout)["pairingCode"]
                    status, device = request("POST", "/v1/local/pair", {"pairingCode": code, "deviceLabel": label})
                    self.assertEqual(status, 201)
                    return {"Authorization": f"Bearer {device['bearerToken']}",
                            "X-IdeaForge-Workspace-ID": environment["IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID"]}

                phone, mac = pair("Fixture Phone"), pair("Fixture Mac")
                audio = b"synthetic-audio-protocol-fixture"
                upload_headers = {**phone,
                    "X-IdeaForge-Recording-ID": "rec_fixture",
                    "X-IdeaForge-Idea-ID": "idea_fixture",
                    "X-IdeaForge-Upload-Job-ID": "upload_fixture",
                    "X-IdeaForge-Content-SHA256": hashlib.sha256(audio).hexdigest(),
                    "Content-Type": "application/octet-stream"}
                status, receipt_bytes = request("POST", "/v1/recordings/upload", audio, upload_headers, raw=True)
                self.assertEqual(status, 201)
                receipt = json.loads(receipt_bytes)
                status, claimed = request("POST", "/v1/enrichment/jobs/claim", {"leaseDurationSeconds": 120}, mac)
                self.assertEqual(status, 200)
                job = claimed["job"]
                query = urllib.parse.urlencode({"recordingID": "rec_fixture", "objectKey": receipt["objectKey"]})
                self.assertEqual(request("GET", f"/v1/recordings/audio?{query}", headers=mac, raw=True), (200, audio))
                completion = {"jobID": job["jobID"], "workspaceUpdatedAt": "2026-10-07T12:00:00Z"}
                self.assertEqual(request("POST", "/v1/enrichment/jobs/complete", completion, mac)[0], 409)
                snapshot = {
                    "projects": [{"id": "idea_fixture", "title": "Fixture idea",
                        "transcript": {"cleanText": "Synthetic transcript fixture", "segments": [], "unclearFragments": []},
                        "recordings": [{"id": "rec_fixture", "ideaProjectID": "idea_fixture",
                                        "audioObjectKey": receipt["objectKey"], "syncStatus": "ready"}]}],
                    "workflowTemplates": [], "uploadJobs": [], "privacyMode": "standardCloud",
                    "syncHealth": {"queuedUploads": 0, "failingItems": 0},
                    "selectedProjectID": "idea_fixture", "updatedAt": completion["workspaceUpdatedAt"]}
                self.assertEqual(request("PUT", "/v1/workspace/snapshot", snapshot, mac)[0], 200)
                self.assertEqual(request("POST", "/v1/enrichment/jobs/complete", completion, mac)[0], 200)
                stop(process)
                process = start()
                self.assertEqual(request("GET", "/v1/workspace/snapshot", headers=phone), (200, snapshot))
                self.assertEqual(request("GET", f"/v1/recordings/audio?{query}", headers=mac, raw=True), (200, audio))
                self.assertEqual(request("POST", "/v1/enrichment/jobs/complete", completion, mac)[0], 200)
                self.assertIsNone(request("POST", "/v1/enrichment/jobs/claim", {"leaseDurationSeconds": 120}, mac)[1]["job"])
                stop(process)
                self.assertTrue(all(not errors for _, errors in logs), "Service stderr must remain empty")
                self.assertTrue(all('"status":"serving"' in output for output, _ in logs))
            finally:
                for process in processes:
                    if process.poll() is None:
                        stop(process)
