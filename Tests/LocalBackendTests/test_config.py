import os
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.config import LocalBackendConfig, LocalBackendConfigError


class LocalBackendConfigTests(unittest.TestCase):
    def valid_environment(self, data_root: Path) -> dict[str, str]:
        return {
            "IDEAFORGE_LOCAL_BACKEND_DATA_ROOT": str(data_root),
            "IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID": "workspace_rsi",
            "IDEAFORGE_LOCAL_BACKEND_BIND_HOST": "192.168.50.4",
            "IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS": "127.0.0.0/8,192.168.50.0/24",
            "IDEAFORGE_LOCAL_BACKEND_TLS_CERT": str(data_root / "tls" / "server.pem"),
            "IDEAFORGE_LOCAL_BACKEND_TLS_KEY": str(data_root / "tls" / "server-key.pem"),
        }

    def test_load_returns_immutable_validated_configuration_without_creating_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"

            config = LocalBackendConfig.load(self.valid_environment(data_root))

            self.assertEqual(config.data_root, data_root)
            self.assertEqual(config.database_path, data_root / "backend.sqlite3")
            self.assertEqual(config.workspace_id, "workspace_rsi")
            self.assertEqual(config.bind_host, "192.168.50.4")
            self.assertEqual(config.port, 8765)
            self.assertEqual(config.workspace_body_limit_bytes, 10 * 1024 * 1024)
            self.assertEqual(config.recording_body_limit_bytes, 200 * 1024 * 1024)
            self.assertFalse(config.openai_enabled)
            self.assertFalse(data_root.exists())
            with self.assertRaises((AttributeError, TypeError)):
                config.port = 9999  # type: ignore[misc]

    def test_load_rejects_broad_or_temporary_data_roots(self) -> None:
        for unsafe_root in ("relative/path", "/", "/tmp", "/var/tmp"):
            with self.subTest(unsafe_root=unsafe_root):
                environment = self.valid_environment(Path("/safe/placeholder"))
                environment["IDEAFORGE_LOCAL_BACKEND_DATA_ROOT"] = unsafe_root

                with self.assertRaisesRegex(LocalBackendConfigError, "dedicated absolute directory"):
                    LocalBackendConfig.load(environment)

    def test_load_rejects_wildcard_or_public_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            for unsafe_host in ("0.0.0.0", "::", "8.8.8.8"):
                with self.subTest(unsafe_host=unsafe_host):
                    environment = self.valid_environment(Path(temporary_directory) / "state")
                    environment["IDEAFORGE_LOCAL_BACKEND_BIND_HOST"] = unsafe_host

                    with self.assertRaisesRegex(LocalBackendConfigError, "private or loopback"):
                        LocalBackendConfig.load(environment)

    def test_load_rejects_invalid_workspace_cidrs_ports_and_tls_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"
            invalid_cases = {
                "IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID": "../workspace",
                "IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS": "0.0.0.0/0",
                "IDEAFORGE_LOCAL_BACKEND_PORT": "70000",
                "IDEAFORGE_LOCAL_BACKEND_TLS_CERT": "relative/server.pem",
            }
            for key, value in invalid_cases.items():
                with self.subTest(key=key):
                    environment = self.valid_environment(data_root)
                    environment[key] = value

                    with self.assertRaises(LocalBackendConfigError):
                        LocalBackendConfig.load(environment)

    def test_load_accepts_loopback_for_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"
            environment = self.valid_environment(data_root)
            environment["IDEAFORGE_LOCAL_BACKEND_BIND_HOST"] = "127.0.0.1"
            environment["IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS"] = "127.0.0.0/8"

            config = LocalBackendConfig.load(environment)

            self.assertEqual(config.bind_host, "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
