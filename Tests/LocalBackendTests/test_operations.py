import hashlib
import json
import os
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.database import LocalBackendDatabase
from local_backend.operations import BackupIntegrityError, LocalBackupManager
from local_backend.recordings import RecordingStore
from local_backend.workspaces import WorkspaceStore


NOW = datetime(2026, 8, 14, 14, 0, tzinfo=UTC)
WORKSPACE_ID = "workspace_rsi"


class LocalBackendOperationsTests(unittest.TestCase):
    def make_state(self, root: Path) -> tuple[LocalBackendDatabase, RecordingStore]:
        database = LocalBackendDatabase(root / "backend.sqlite3")
        database.migrate()
        WorkspaceStore(database).create(WORKSPACE_ID, NOW)
        recordings = RecordingStore(database, root)
        recordings.commit_stream(WORKSPACE_ID, "rec_watch", (b"watch-audio",), NOW)
        return database, recordings

    def test_backup_and_fresh_restore_verify_database_and_recording_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            backup_parent = root / "backups"
            restored = root / "restored"
            database, recordings = self.make_state(source)

            backup = LocalBackupManager(source, database).create(backup_parent, NOW)
            manifest = json.loads((backup / "manifest.json").read_text())

            self.assertEqual(manifest["formatVersion"], 1)
            self.assertEqual(manifest["workspaceID"], WORKSPACE_ID)
            self.assertEqual(len(manifest["recordings"]), 1)
            self.assertEqual(manifest["recordings"][0]["sha256"], hashlib.sha256(b"watch-audio").hexdigest())
            LocalBackupManager.restore(backup, restored)
            restored_database = LocalBackendDatabase(restored / "backend.sqlite3")
            with restored_database.connection() as connection:
                self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok")
                row = connection.execute("SELECT storage_relative_path FROM recordings").fetchone()
            self.assertEqual((restored / row["storage_relative_path"]).read_bytes(), b"watch-audio")
            self.assertEqual((backup.stat().st_mode & 0o777), 0o700)
            self.assertEqual((backup / "manifest.json").stat().st_mode & 0o777, 0o600)

    def test_restore_refuses_tampering_and_nonempty_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            database, _ = self.make_state(source)
            backup = LocalBackupManager(source, database).create(root / "backups", NOW)
            recording = next((backup / "recordings").iterdir())
            recording.write_bytes(b"tampered")

            with self.assertRaises(BackupIntegrityError):
                LocalBackupManager.restore(backup, root / "restored")

            occupied = root / "occupied"
            occupied.mkdir()
            (occupied / "keep.txt").write_text("keep")
            with self.assertRaises(BackupIntegrityError):
                LocalBackupManager.restore(backup, occupied)
            self.assertEqual((occupied / "keep.txt").read_text(), "keep")

    def test_tls_setup_creates_owner_only_ca_and_server_certificate_with_san(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            tls_root = Path(temporary_directory) / "tls"
            command = [
                sys.executable,
                str(REPOSITORY_ROOT / "script" / "setup_local_backend_tls.py"),
                "--tls-root", str(tls_root),
                "--hostname", "ideaforge-test.local",
            ]

            first = subprocess.run(command, text=True, capture_output=True, check=False)
            second = subprocess.run(command, text=True, capture_output=True, check=False)
            mismatch = subprocess.run(
                [*command[:-1], "other-host.local"],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertNotEqual(mismatch.returncode, 0)
            report = json.loads(first.stdout)
            self.assertEqual(report["hostname"], "ideaforge-test.local")
            self.assertEqual(report["status"], "created")
            profile_path = Path(report["iPhoneConfigurationProfilePath"])
            decoded_profile = Path(temporary_directory) / "decoded-profile.plist"
            verification = subprocess.run(
                [
                    "openssl", "smime", "-verify", "-noverify", "-inform", "der",
                    "-in", str(profile_path), "-out", str(decoded_profile),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(verification.returncode, 0, verification.stderr)
            with decoded_profile.open("rb") as handle:
                profile = plistlib.load(handle)
            self.assertEqual(profile["PayloadType"], "Configuration")
            self.assertEqual(profile["PayloadContent"][0]["PayloadType"], "com.apple.security.root")
            self.assertIsInstance(profile["PayloadContent"][0]["PayloadContent"], bytes)
            self.assertNotIn(b"PRIVATE KEY", profile_path.read_bytes())
            self.assertEqual(profile_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(second.stdout)["status"], "existing")
            self.assertNotIn("PRIVATE KEY", first.stdout + first.stderr)
            for name in ("ca.key.pem", "server.key.pem"):
                self.assertEqual((tls_root / name).stat().st_mode & 0o777, 0o600)
            certificate_text = subprocess.run(
                ["openssl", "x509", "-in", str(tls_root / "server.cert.pem"), "-noout", "-text"],
                text=True,
                capture_output=True,
                check=True,
            ).stdout
            self.assertIn("DNS:ideaforge-test.local", certificate_text)
            self.assertRegex(report["sha256Fingerprint"], r"^[0-9A-F:]{95}$")

    def test_install_renders_bounded_launch_agent_and_uninstall_preserves_data(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            data_root = root / "state"
            data_root.mkdir()
            (data_root / "keep.txt").write_text("keep")
            plist_path = root / "LaunchAgents" / "com.rsitech.ideaforge.local-backend.plist"
            python_link = root / "bin" / "python3"
            python_link.parent.mkdir()
            python_link.symlink_to(sys.executable)
            command = [
                sys.executable,
                str(REPOSITORY_ROOT / "script" / "install_local_backend.py"),
                "install",
                "--plist-path", str(plist_path),
                "--data-root", str(data_root),
                "--python", str(python_link),
                "--backend-script", str(REPOSITORY_ROOT / "script" / "local_backend.py"),
                "--workspace-id", WORKSPACE_ID,
                "--bind-host", "127.0.0.1",
                "--allowed-cidrs", "127.0.0.0/8",
                "--tls-cert", str(root / "server.cert.pem"),
                "--tls-key", str(root / "server.key.pem"),
                "--no-activate",
            ]

            first = subprocess.run(command, text=True, capture_output=True, check=False)
            second = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            with plist_path.open("rb") as handle:
                plist = plistlib.load(handle)
            uninstall = subprocess.run(
                [
                    sys.executable,
                    str(REPOSITORY_ROOT / "script" / "install_local_backend.py"),
                    "uninstall", "--plist-path", str(plist_path), "--no-activate",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(plist["Label"], "com.rsitech.ideaforge.local-backend")
            self.assertTrue(plist["KeepAlive"])
            self.assertEqual(plist["ThrottleInterval"], 10)
            self.assertEqual(plist["SoftResourceLimits"]["NumberOfFiles"], 1024)
            self.assertEqual(Path(plist["ProgramArguments"][0]), python_link.absolute())
            self.assertNotIn("OPENAI", json.dumps(plist))
            deployed_script = Path(plist["ProgramArguments"][1])
            self.assertTrue(deployed_script.is_relative_to(data_root.resolve()))
            self.assertNotEqual(deployed_script, REPOSITORY_ROOT / "script" / "local_backend.py")
            self.assertTrue(deployed_script.is_file())
            self.assertTrue((deployed_script.parents[1] / "local_backend" / "database.py").is_file())
            self.assertEqual(deployed_script.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                len(list((data_root.resolve() / "runtime").glob("*/script/local_backend.py"))),
                1,
            )
            runtime_config = data_root / "runtime-config.json"
            self.assertEqual(runtime_config.stat().st_mode & 0o777, 0o600)
            readiness = subprocess.run(
                [
                    sys.executable,
                    str(REPOSITORY_ROOT / "script" / "local_backend.py"),
                    "--config", str(runtime_config), "check-readiness",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(readiness.returncode, 0, readiness.stderr)
            self.assertEqual(json.loads(readiness.stdout)["status"], "ready")
            self.assertEqual(uninstall.returncode, 0, uninstall.stderr)
            self.assertFalse(plist_path.exists())
            self.assertEqual((data_root / "keep.txt").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
