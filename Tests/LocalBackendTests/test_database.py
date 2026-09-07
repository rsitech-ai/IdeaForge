import sqlite3
import stat
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

import local_backend.database as database_module
from local_backend.database import LocalBackendDatabase
from local_backend.migrations import LocalBackendMigrationError, MIGRATIONS, Migration


class LocalBackendDatabaseTests(unittest.TestCase):
    def test_migrate_creates_owner_only_wal_database_with_required_tables(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            data_root = Path(temporary_directory) / "state"
            database = LocalBackendDatabase(data_root / "backend.sqlite3")

            database.migrate()

            self.assertEqual(stat.S_IMODE(data_root.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(database.path.stat().st_mode), 0o600)
            with database.connection() as connection:
                self.assertEqual(connection.execute("PRAGMA journal_mode").fetchone()[0].lower(), "wal")
                self.assertEqual(connection.execute("PRAGMA foreign_keys").fetchone()[0], 1)
                self.assertEqual(connection.execute("PRAGMA busy_timeout").fetchone()[0], 5_000)
                tables = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type = 'table'"
                    ).fetchall()
                }
            self.assertTrue(
                {
                    "schema_migrations",
                    "workspaces",
                    "devices",
                    "pairing_codes",
                    "recordings",
                    "idempotency_receipts",
                    "jobs",
                    "audit_events",
                }.issubset(tables)
            )

    def test_transaction_rolls_back_every_write_when_body_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
            database.migrate()

            with self.assertRaisesRegex(RuntimeError, "stop"):
                with database.transaction() as connection:
                    connection.execute(
                        "INSERT INTO audit_events(event_id, event_type, occurred_at, payload_json) VALUES (?, ?, ?, ?)",
                        ("evt_1", "test", "2026-08-14T00:00:00Z", "{}"),
                    )
                    raise RuntimeError("stop")

            with database.connection() as connection:
                count = connection.execute("SELECT COUNT(*) FROM audit_events").fetchone()[0]
            self.assertEqual(count, 0)

    def test_migrate_refuses_checksum_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
            database.migrate()
            with database.transaction() as connection:
                connection.execute(
                    "UPDATE schema_migrations SET checksum = ? WHERE version = ?",
                    ("tampered", MIGRATIONS[0].version),
                )

            with self.assertRaisesRegex(LocalBackendMigrationError, "checksum"):
                database.migrate()

    def test_migrate_refuses_unknown_future_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
            database.migrate()
            with database.transaction() as connection:
                connection.execute(
                    "INSERT INTO schema_migrations(version, name, checksum, applied_at) VALUES (?, ?, ?, ?)",
                    (999, "future", "future", "2026-08-14T00:00:00Z"),
                )

            with self.assertRaisesRegex(LocalBackendMigrationError, "future schema version"):
                database.migrate()

    def test_migrate_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
            database.migrate()

            database.migrate()

            with database.connection() as connection:
                rows = connection.execute(
                    "SELECT version, name FROM schema_migrations ORDER BY version"
                ).fetchall()
            self.assertEqual([(row[0], row[1]) for row in rows], [(m.version, m.name) for m in MIGRATIONS])

    def test_failed_migration_does_not_leak_partial_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
            database.migrate()
            broken_version = max(migration.version for migration in MIGRATIONS) + 1
            broken = Migration(
                version=broken_version,
                name="broken",
                sql="CREATE TABLE leaked_state(value TEXT); INSERT INTO missing_table(value) VALUES ('x');",
            )
            original_migrations = database_module.MIGRATIONS
            database_module.MIGRATIONS = (*MIGRATIONS, broken)
            try:
                with self.assertRaises(sqlite3.OperationalError):
                    database.migrate()
            finally:
                database_module.MIGRATIONS = original_migrations

            with database.connection() as connection:
                leaked_table = connection.execute(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'leaked_state'"
                ).fetchone()[0]
                migration_row = connection.execute(
                    "SELECT COUNT(*) FROM schema_migrations WHERE version = ?",
                    (broken_version,),
                ).fetchone()[0]
            self.assertEqual(leaked_table, 0)
            self.assertEqual(migration_row, 0)


if __name__ == "__main__":
    unittest.main()
