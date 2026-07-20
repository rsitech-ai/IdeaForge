#!/usr/bin/env python3
"""Explicit SQLite migrations for the IdeaForge local backend."""

from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Callable


BACKEND_SCHEMA_VERSION = "2026_07_01_002_async_workflow_jobs"


class BackendMigrationError(RuntimeError):
    """Raised when the backend schema cannot be safely migrated."""


@dataclass(frozen=True)
class BackendMigration:
    version: str
    description: str
    apply: Callable[[sqlite3.Connection], None]


REQUIRED_SCHEMA: dict[str, set[str]] = {
    "schema_migrations": {"version", "applied_at"},
    "objects": {
        "object_key",
        "recording_id",
        "idea_id",
        "byte_count",
        "content_type",
        "created_at",
    },
    "jobs": {
        "id",
        "kind",
        "status",
        "idea_id",
        "recording_id",
        "workflow_template_id",
        "object_key",
        "detail_json",
        "created_at",
        "completed_at",
    },
    "usage_events": {"id", "metric", "quantity", "idea_id", "job_id", "created_at"},
    "transcription_results": {"job_id", "transcript_json", "created_at"},
    "workflow_results": {"job_id", "artifacts_json", "created_at"},
    "accounts": {
        "workspace_id",
        "account_id",
        "user_id",
        "email",
        "display_name",
        "plan_name",
        "plan_status",
        "bearer_token",
        "capabilities_json",
        "created_at",
    },
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def state_fingerprint(state_dir: Path) -> str:
    return hashlib.sha256(str(state_dir.expanduser().resolve()).encode("utf-8")).hexdigest()[:16]


def _apply_current_schema(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS objects (
            object_key TEXT PRIMARY KEY,
            recording_id TEXT NOT NULL,
            idea_id TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            content_type TEXT NOT NULL DEFAULT 'application/octet-stream',
            created_at TEXT NOT NULL
        )
        """
    )
    object_columns = {row[1] for row in connection.execute("PRAGMA table_info(objects)").fetchall()}
    if "content_type" not in object_columns:
        connection.execute(
            "ALTER TABLE objects ADD COLUMN content_type TEXT NOT NULL DEFAULT 'application/octet-stream'"
        )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            idea_id TEXT,
            recording_id TEXT,
            workflow_template_id TEXT,
            object_key TEXT,
            detail_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            completed_at TEXT
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS usage_events (
            id TEXT PRIMARY KEY,
            metric TEXT NOT NULL,
            quantity REAL NOT NULL,
            idea_id TEXT,
            job_id TEXT,
            created_at TEXT NOT NULL
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS transcription_results (
            job_id TEXT PRIMARY KEY,
            transcript_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(job_id) REFERENCES jobs(id)
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS workflow_results (
            job_id TEXT PRIMARY KEY,
            artifacts_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(job_id) REFERENCES jobs(id)
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS accounts (
            workspace_id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            email TEXT NOT NULL,
            display_name TEXT,
            plan_name TEXT NOT NULL,
            plan_status TEXT NOT NULL,
            bearer_token TEXT NOT NULL,
            capabilities_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )


MIGRATIONS: tuple[BackendMigration, ...] = (
    BackendMigration(
        version=BACKEND_SCHEMA_VERSION,
        description="current local backend objects, jobs, usage, workflow, and account schema",
        apply=_apply_current_schema,
    ),
)


def migration_versions() -> list[str]:
    return [migration.version for migration in MIGRATIONS]


def _connect_readonly(db_path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)


def _schema_migrations_table_exists(connection: sqlite3.Connection) -> bool:
    row = connection.execute(
        """
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = 'schema_migrations'
        """
    ).fetchone()
    return row is not None


def _ensure_schema_migrations(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version TEXT PRIMARY KEY,
            applied_at TEXT NOT NULL
        )
        """
    )


def read_applied_migrations(db_path: Path) -> list[dict[str, str]]:
    if not db_path.exists():
        return []
    with _connect_readonly(db_path) as connection:
        if not _schema_migrations_table_exists(connection):
            return []
        rows = connection.execute(
            """
            SELECT version, applied_at
            FROM schema_migrations
            ORDER BY applied_at, version
            """
        ).fetchall()
    return [{"version": str(row[0]), "appliedAt": str(row[1])} for row in rows]


def verify_backend_schema(db_path: Path) -> list[dict[str, str]]:
    checks: list[dict[str, str]] = []
    if not db_path.exists():
        return [{"name": "database", "status": "missing"}]
    with _connect_readonly(db_path) as connection:
        for table_name, required_columns in REQUIRED_SCHEMA.items():
            table_row = connection.execute(
                """
                SELECT 1
                FROM sqlite_master
                WHERE type = 'table' AND name = ?
                """,
                (table_name,),
            ).fetchone()
            if table_row is None:
                checks.append({"name": table_name, "status": "missing_table"})
                continue
            columns = {row[1] for row in connection.execute(f"PRAGMA table_info({table_name})").fetchall()}
            missing_columns = sorted(required_columns - columns)
            checks.append(
                {
                    "name": table_name,
                    "status": "ok" if not missing_columns else "missing_columns",
                    "detail": ",".join(missing_columns),
                }
            )
        applied_versions = {item["version"] for item in read_applied_migrations(db_path)}
        checks.append(
            {
                "name": "current_migration",
                "status": "ok" if BACKEND_SCHEMA_VERSION in applied_versions else "missing",
            }
        )
    return checks


def _validate_known_migrations(applied: list[dict[str, str]]) -> None:
    known = set(migration_versions())
    unknown = sorted(item["version"] for item in applied if item["version"] not in known)
    if unknown:
        raise BackendMigrationError(f"unknown backend migration version(s): {', '.join(unknown)}")


def run_backend_migrations(state_dir: Path, dry_run: bool = False) -> dict[str, Any]:
    db_path = state_dir / "backend.db"
    applied_before = read_applied_migrations(db_path)
    _validate_known_migrations(applied_before)
    applied_versions = {item["version"] for item in applied_before}
    pending = [migration for migration in MIGRATIONS if migration.version not in applied_versions]

    if not dry_run:
        state_dir.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(db_path) as connection:
            _ensure_schema_migrations(connection)
            for migration in pending:
                migration.apply(connection)
                connection.execute(
                    """
                    INSERT INTO schema_migrations (version, applied_at)
                    VALUES (?, ?)
                    """,
                    (migration.version, utc_now()),
                )
        applied_after = read_applied_migrations(db_path)
        _validate_known_migrations(applied_after)
        checks = verify_backend_schema(db_path)
    else:
        applied_after = applied_before
        checks = [{"name": "dry_run", "status": "planned"}]
        # Fail closed on a database that claims the current schema but is broken;
        # a dry run must not report ready for a state dir that cannot serve traffic.
        if db_path.exists() and not pending:
            checks.extend(verify_backend_schema(db_path))

    ok = all(check["status"] in {"ok", "planned"} for check in checks)
    report = {
        "status": "ready" if ok else "blocked",
        "databaseExists": db_path.exists(),
        "stateFingerprint": state_fingerprint(state_dir),
        "schema": {
            "currentVersion": BACKEND_SCHEMA_VERSION,
            "knownVersions": migration_versions(),
            "appliedBefore": applied_before,
            "appliedAfter": applied_after,
            "pendingVersions": [migration.version for migration in pending],
            "appliedNow": [] if dry_run else [migration.version for migration in pending],
        },
        "checks": checks,
        "dryRun": dry_run,
    }
    if not dry_run and not ok:
        failures = ", ".join(
            f"{check['name']}={check['status']}"
            for check in checks
            if check["status"] not in {"ok", "planned"}
        )
        raise BackendMigrationError(f"backend schema verification failed: {failures}")
    return report


def render_report(report: dict[str, Any]) -> str:
    lines = [
        "# IdeaForge Backend Migration Report",
        "",
        f"- Status: {report['status']}",
        f"- Dry run: {str(report['dryRun']).lower()}",
        f"- Database exists: {str(report['databaseExists']).lower()}",
        f"- State fingerprint: {report['stateFingerprint']}",
        f"- Current version: {report['schema']['currentVersion']}",
        f"- Pending versions: {', '.join(report['schema']['pendingVersions']) or 'none'}",
        f"- Applied now: {', '.join(report['schema']['appliedNow']) or 'none'}",
        "",
        "## Checks",
    ]
    for check in report["checks"]:
        detail = check.get("detail") or ""
        suffix = f" ({detail})" if detail else ""
        lines.append(f"- {check['name']}: {check['status']}{suffix}")
    lines.append("")
    return "\n".join(lines)


def write_report(report: dict[str, Any], report_path: Path) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    if report_path.suffix == ".json":
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        report_path.write_text(render_report(report), encoding="utf-8")


def run_self_test() -> None:
    with TemporaryDirectory() as temp_root:
        root = Path(temp_root)
        state_dir = root / "backend-state"
        dry_run_report = run_backend_migrations(state_dir, dry_run=True)
        assert dry_run_report["dryRun"] is True
        assert dry_run_report["databaseExists"] is False
        assert dry_run_report["schema"]["pendingVersions"] == [BACKEND_SCHEMA_VERSION]
        assert not (state_dir / "backend.db").exists()

        apply_report = run_backend_migrations(state_dir)
        assert apply_report["status"] == "ready"
        assert apply_report["schema"]["appliedNow"] == [BACKEND_SCHEMA_VERSION]
        assert all(check["status"] == "ok" for check in apply_report["checks"])

        idempotent_report = run_backend_migrations(state_dir)
        assert idempotent_report["schema"]["pendingVersions"] == []
        assert idempotent_report["schema"]["appliedNow"] == []
        assert all(check["status"] == "ok" for check in idempotent_report["checks"])

        report_path = root / "migration-report.md"
        write_report(idempotent_report, report_path)
        serialized_report = report_path.read_text(encoding="utf-8")
        assert str(state_dir) not in serialized_report
        assert "dev-token" not in serialized_report
        assert "Bearer " not in serialized_report

        with sqlite3.connect(state_dir / "backend.db") as connection:
            connection.execute(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                ("2999_01_01_999_future", utc_now()),
            )
        try:
            run_backend_migrations(state_dir)
        except BackendMigrationError as error:
            assert "2999_01_01_999_future" in str(error)
        else:
            raise AssertionError("unknown future migration did not fail closed")

        broken_state_dir = root / "broken-backend-state"
        broken_state_dir.mkdir()
        with sqlite3.connect(broken_state_dir / "backend.db") as connection:
            _ensure_schema_migrations(connection)
            connection.execute(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)",
                (BACKEND_SCHEMA_VERSION, utc_now()),
            )
        try:
            run_backend_migrations(broken_state_dir)
        except BackendMigrationError as error:
            assert "backend schema verification failed" in str(error)
        else:
            raise AssertionError("broken current-version schema did not fail closed")

        broken_dry_run_report = run_backend_migrations(broken_state_dir, dry_run=True)
        assert broken_dry_run_report["status"] == "blocked", "dry run must not report ready for a broken schema"

        healthy_state_dir = root / "healthy-backend-state"
        run_backend_migrations(healthy_state_dir)
        healthy_dry_run_report = run_backend_migrations(healthy_state_dir, dry_run=True)
        assert healthy_dry_run_report["status"] == "ready"
        assert healthy_dry_run_report["schema"]["pendingVersions"] == []


def main() -> None:
    parser = argparse.ArgumentParser(description="Run IdeaForge local backend migrations.")
    parser.add_argument("--state-dir", default=".local/backend")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        print("IdeaForge backend migration self-test passed.")
        return

    try:
        report = run_backend_migrations(Path(args.state_dir), dry_run=args.dry_run)
    except BackendMigrationError as error:
        raise SystemExit(f"backend migration failed: {error}") from error
    if args.report:
        write_report(report, Path(args.report))
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
