import base64
import concurrent.futures
import hashlib
import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.auth import (
    DeviceAuthorizer,
    DeviceForbiddenError,
    DeviceUnauthorizedError,
    PairingCodeExpiredError,
    PairingCodeInvalidError,
    PairingService,
)
from local_backend.database import LocalBackendDatabase


WORKSPACE_ID = "workspace_rsi"
NOW = datetime(2026, 8, 14, 8, 0, tzinfo=UTC)


def decoded_urlsafe_bytes(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


class LocalBackendAuthTests(unittest.TestCase):
    def make_services(self, temporary_directory: str):
        database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
        database.migrate()
        with database.transaction() as connection:
            connection.execute(
                """
                INSERT INTO workspaces(
                    workspace_id, snapshot_json, accepted_updated_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                (WORKSPACE_ID, "{}", "1970-01-01T00:00:00Z", "2026-08-14T08:00:00Z", "2026-08-14T08:00:00Z"),
            )
        return database, PairingService(database, WORKSPACE_ID), DeviceAuthorizer(database)

    def test_create_and_exchange_use_high_entropy_values_and_persist_only_digests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, pairing, authorizer = self.make_services(temporary_directory)

            code = pairing.create_code("Rafal iPhone", NOW)
            issued = pairing.exchange(code.value, "Rafal iPhone", NOW + timedelta(seconds=1))

            self.assertGreaterEqual(len(decoded_urlsafe_bytes(code.value)), 16)
            self.assertEqual(code.expires_at, NOW + timedelta(minutes=5))
            self.assertGreaterEqual(len(decoded_urlsafe_bytes(issued.token)), 32)
            self.assertEqual(issued.workspace_id, WORKSPACE_ID)
            with database.connection() as connection:
                code_row = connection.execute(
                    "SELECT code_digest, consumed_at FROM pairing_codes"
                ).fetchone()
                device_row = connection.execute(
                    "SELECT token_digest, label, revoked_at FROM devices"
                ).fetchone()
            self.assertEqual(code_row["code_digest"], hashlib.sha256(code.value.encode()).hexdigest())
            self.assertIsNotNone(code_row["consumed_at"])
            self.assertEqual(device_row["token_digest"], hashlib.sha256(issued.token.encode()).hexdigest())
            self.assertEqual(device_row["label"], "Rafal iPhone")
            self.assertIsNone(device_row["revoked_at"])
            database_bytes = database.path.read_bytes()
            self.assertNotIn(code.value.encode(), database_bytes)
            self.assertNotIn(issued.token.encode(), database_bytes)
            self.assertEqual(authorizer.authorize(issued.token, WORKSPACE_ID, NOW).device_id, issued.device_id)

    def test_exchange_rejects_expired_and_consumed_codes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            _, pairing, _ = self.make_services(temporary_directory)
            expired = pairing.create_code("Expired", NOW)
            with self.assertRaises(PairingCodeExpiredError):
                pairing.exchange(expired.value, "iPhone", NOW + timedelta(minutes=5, seconds=1))

            consumed = pairing.create_code("Consumed", NOW)
            pairing.exchange(consumed.value, "Mac", NOW + timedelta(seconds=1))
            with self.assertRaises(PairingCodeInvalidError):
                pairing.exchange(consumed.value, "Second Mac", NOW + timedelta(seconds=2))

    def test_concurrent_exchange_issues_exactly_one_device(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, pairing, _ = self.make_services(temporary_directory)
            code = pairing.create_code("Concurrent", NOW)

            def exchange(index: int) -> str:
                try:
                    pairing.exchange(code.value, f"Device {index}", NOW + timedelta(seconds=1))
                    return "issued"
                except PairingCodeInvalidError:
                    return "rejected"

            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                outcomes = list(executor.map(exchange, (1, 2)))

            self.assertEqual(sorted(outcomes), ["issued", "rejected"])
            with database.connection() as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM devices").fetchone()[0], 1)

    def test_authorization_distinguishes_scope_but_not_invalid_or_revoked_token(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, pairing, authorizer = self.make_services(temporary_directory)
            code = pairing.create_code("Mac", NOW)
            issued = pairing.exchange(code.value, "Mac", NOW + timedelta(seconds=1))

            with self.assertRaisesRegex(DeviceUnauthorizedError, "Device authorization failed"):
                authorizer.authorize("not-a-token", WORKSPACE_ID, NOW + timedelta(seconds=2))
            with self.assertRaisesRegex(DeviceForbiddenError, "Workspace authorization failed"):
                authorizer.authorize(issued.token, "workspace_other", NOW + timedelta(seconds=2))

            self.assertTrue(authorizer.revoke(issued.device_id, NOW + timedelta(seconds=3)))
            self.assertFalse(authorizer.revoke(issued.device_id, NOW + timedelta(seconds=4)))
            with self.assertRaisesRegex(DeviceUnauthorizedError, "Device authorization failed"):
                authorizer.authorize(issued.token, WORKSPACE_ID, NOW + timedelta(seconds=5))
            with database.connection() as connection:
                revoked_at = connection.execute(
                    "SELECT revoked_at FROM devices WHERE device_id = ?", (issued.device_id,)
                ).fetchone()[0]
            self.assertEqual(revoked_at, "2026-08-14T08:00:03Z")

    def test_authorization_updates_last_used_only_after_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database, pairing, authorizer = self.make_services(temporary_directory)
            issued = pairing.exchange(
                pairing.create_code("iPhone", NOW).value,
                "iPhone",
                NOW + timedelta(seconds=1),
            )

            authorized = authorizer.authorize(
                issued.token,
                WORKSPACE_ID,
                NOW + timedelta(seconds=10),
            )

            self.assertEqual(authorized.label, "iPhone")
            with database.connection() as connection:
                last_used = connection.execute(
                    "SELECT last_used_at FROM devices WHERE device_id = ?", (issued.device_id,)
                ).fetchone()[0]
            self.assertEqual(last_used, "2026-08-14T08:00:10Z")


if __name__ == "__main__":
    unittest.main()
