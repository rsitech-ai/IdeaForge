import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "script" / "local_backend.py"

from local_backend.auth import PairingService
from local_backend.database import LocalBackendDatabase
from local_backend.workspaces import WorkspaceStore
from script.local_backend import _bonjour_arguments


class LocalBackendCLITests(unittest.TestCase):
    def test_bonjour_advertisement_is_private_service_without_workspace_content(self) -> None:
        arguments = _bonjour_arguments(8765)

        self.assertEqual(arguments[:5], [
            "/usr/bin/dns-sd", "-R", "IdeaForge Local Backend", "_ideaforge._tcp", "local."
        ])
        self.assertEqual(arguments[5:], ["8765", "version=1", "tls=1"])
        self.assertNotIn("workspace_rsi", " ".join(arguments))

    def environment(self, data_root: Path) -> dict[str, str]:
        return {
            **os.environ,
            "IDEAFORGE_LOCAL_BACKEND_DATA_ROOT": str(data_root),
            "IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID": "workspace_rsi",
            "IDEAFORGE_LOCAL_BACKEND_BIND_HOST": "127.0.0.1",
            "IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS": "127.0.0.0/8",
            "IDEAFORGE_LOCAL_BACKEND_TLS_CERT": str(data_root / "tls" / "server.pem"),
            "IDEAFORGE_LOCAL_BACKEND_TLS_KEY": str(data_root / "tls" / "server-key.pem"),
        }

    def run_cli(self, data_root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            cwd=REPOSITORY_ROOT,
            env=self.environment(data_root),
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    def test_initialize_and_readiness_are_idempotent_and_content_free(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"

            first = self.run_cli(data_root, "initialize")
            second = self.run_cli(data_root, "initialize")
            readiness = self.run_cli(data_root, "check-readiness")

            self.assertEqual((first.returncode, second.returncode, readiness.returncode), (0, 0, 0))
            self.assertEqual(json.loads(first.stdout), {"status": "initialized"})
            self.assertEqual(json.loads(second.stdout), {"status": "initialized"})
            self.assertEqual(json.loads(readiness.stdout), {"status": "ready"})
            self.assertNotIn("workspace_rsi", readiness.stdout)
            self.assertEqual(first.stderr, "")

    def test_create_pairing_code_outputs_once_without_putting_it_in_stderr(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"

            result = self.run_cli(data_root, "create-pairing-code", "Rafal iPhone")

            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["deviceLabel"], "Rafal iPhone")
            self.assertGreaterEqual(len(payload["pairingCode"]), 20)
            self.assertTrue(payload["expiresAt"].endswith("Z"))
            self.assertEqual(result.stderr, "")
            database_bytes = (data_root / "backend.sqlite3").read_bytes()
            self.assertNotIn(payload["pairingCode"].encode(), database_bytes)

    def test_invalid_configuration_fails_without_traceback_or_secret_echo(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"
            environment = self.environment(data_root)
            environment["IDEAFORGE_LOCAL_BACKEND_DATA_ROOT"] = "/tmp"
            secret = "must-not-be-printed"
            environment["OPENAI_API_KEY"] = secret

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "initialize"],
                cwd=REPOSITORY_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("configuration_error", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertNotIn(secret, result.stderr)

    def test_list_and_revoke_device_are_local_explicit_and_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"
            database = LocalBackendDatabase(data_root / "backend.sqlite3")
            database.migrate()
            now = datetime(2026, 8, 14, 15, 0, tzinfo=UTC)
            WorkspaceStore(database).create("workspace_rsi", now)
            pairing = PairingService(database, "workspace_rsi")
            code = pairing.create_code("Rafal iPhone", now)
            issued = pairing.exchange(code.value, "Rafal iPhone", now)

            listed = self.run_cli(data_root, "list-devices")
            revoked = self.run_cli(data_root, "revoke-device", issued.device_id)
            repeated = self.run_cli(data_root, "revoke-device", issued.device_id)

            self.assertEqual(listed.returncode, 0, listed.stderr)
            self.assertEqual(json.loads(listed.stdout)["devices"], [
                {"deviceID": issued.device_id, "label": "Rafal iPhone", "revoked": False}
            ])
            self.assertEqual((revoked.returncode, json.loads(revoked.stdout)["status"]), (0, "revoked"))
            self.assertEqual((repeated.returncode, json.loads(repeated.stdout)["status"]), (1, "not_found"))


if __name__ == "__main__":
    unittest.main()
