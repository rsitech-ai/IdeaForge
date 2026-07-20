#!/usr/bin/env python3
"""Fail-closed production database readiness gate for IdeaForge."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, Mapping
from urllib.parse import parse_qs, urlparse

from backend_migrations import BACKEND_SCHEMA_VERSION


class ProductionDatabaseReadinessError(RuntimeError):
    """Raised when production database configuration is unsafe or incomplete."""


@dataclass(frozen=True)
class ProductionDatabaseConfig:
    database_url: str
    host: str
    port: int | None
    username: str
    database_name: str
    ssl_mode: str
    schema_version: str
    migration_mode: str
    backup_manifest_url: str
    restore_drill_url: str
    metrics_url: str
    backup_retention_days: int
    restore_drill_max_age_hours: int


def _fingerprint(value: str, length: int = 16) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def _required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise ProductionDatabaseReadinessError(f"{name} is required")
    return value


def _reject_placeholder(label: str, value: str) -> None:
    lower = value.lower()
    if any(marker in lower for marker in ("example", "placeholder", "changeme", "todo", "fixture")):
        raise ProductionDatabaseReadinessError(f"{label} must not use placeholder values")


def _validate_database_url(value: str) -> tuple[str, int | None, str, str, str]:
    _reject_placeholder("IDEAFORGE_DATABASE_URL", value)
    parsed = urlparse(value)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must use postgres/postgresql")
    if parsed.username is None or parsed.password is None:
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must include username and password")
    hostname = (parsed.hostname or "").lower()
    if not hostname:
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must include a host")
    if hostname in {"localhost", "127.0.0.1", "::1"} or hostname.endswith(".local"):
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must not point at localhost")
    if hostname.endswith((".example.com", ".test", ".invalid")):
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must not use a placeholder host")
    username = parsed.username.strip()
    if username.lower() in {"postgres", "root", "admin"}:
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must not use a default superuser")
    database_name = parsed.path.lstrip("/").strip()
    if not database_name:
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must include a database name")
    if database_name.lower() in {"postgres", "template1", "default", "local", "dev", "test"}:
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must not use a default/local database")
    ssl_modes = parse_qs(parsed.query).get("sslmode", [])
    ssl_mode = ssl_modes[-1].strip().lower() if ssl_modes else ""
    if ssl_mode not in {"require", "verify-full"}:
        raise ProductionDatabaseReadinessError("IDEAFORGE_DATABASE_URL must set sslmode=require or sslmode=verify-full")
    return hostname, parsed.port, username, database_name, ssl_mode


def _validate_schema_version(value: str) -> None:
    if value != BACKEND_SCHEMA_VERSION:
        raise ProductionDatabaseReadinessError(
            "IDEAFORGE_DATABASE_SCHEMA_VERSION must match the backend migration manifest"
        )


def _validate_migration_mode(value: str) -> None:
    if value not in {"managed-lock", "manual-reviewed"}:
        raise ProductionDatabaseReadinessError(
            "IDEAFORGE_DATABASE_MIGRATION_MODE must be managed-lock or manual-reviewed"
        )


def _validate_https_url(env_name: str, value: str) -> str:
    _reject_placeholder(env_name, value)
    parsed = urlparse(value)
    if parsed.scheme != "https":
        raise ProductionDatabaseReadinessError(f"{env_name} must use https")
    if parsed.username or parsed.password:
        raise ProductionDatabaseReadinessError(f"{env_name} must not include credentials")
    hostname = (parsed.hostname or "").lower()
    if not hostname:
        raise ProductionDatabaseReadinessError(f"{env_name} must include a host")
    if hostname in {"localhost", "127.0.0.1", "::1"} or hostname.endswith(".local"):
        raise ProductionDatabaseReadinessError(f"{env_name} must not point at localhost")
    if hostname.endswith((".example.com", ".test", ".invalid")):
        raise ProductionDatabaseReadinessError(f"{env_name} must not use a placeholder host")
    return value.rstrip("/")


def _parse_int(env: Mapping[str, str], name: str, minimum: int, maximum: int) -> int:
    raw = _required(env, name)
    try:
        value = int(raw)
    except ValueError as error:
        raise ProductionDatabaseReadinessError(f"{name} must be an integer") from error
    if value < minimum or value > maximum:
        raise ProductionDatabaseReadinessError(f"{name} must be between {minimum} and {maximum}")
    return value


def load_config(env: Mapping[str, str]) -> ProductionDatabaseConfig:
    database_url = _required(env, "IDEAFORGE_DATABASE_URL")
    host, port, username, database_name, ssl_mode = _validate_database_url(database_url)

    schema_version = _required(env, "IDEAFORGE_DATABASE_SCHEMA_VERSION")
    _validate_schema_version(schema_version)

    migration_mode = _required(env, "IDEAFORGE_DATABASE_MIGRATION_MODE")
    _validate_migration_mode(migration_mode)

    backup_manifest_url = _validate_https_url(
        "IDEAFORGE_DATABASE_BACKUP_MANIFEST_URL",
        _required(env, "IDEAFORGE_DATABASE_BACKUP_MANIFEST_URL"),
    )
    restore_drill_url = _validate_https_url(
        "IDEAFORGE_DATABASE_RESTORE_DRILL_URL",
        _required(env, "IDEAFORGE_DATABASE_RESTORE_DRILL_URL"),
    )
    metrics_url = _validate_https_url(
        "IDEAFORGE_DATABASE_METRICS_URL",
        _required(env, "IDEAFORGE_DATABASE_METRICS_URL"),
    )

    return ProductionDatabaseConfig(
        database_url=database_url,
        host=host,
        port=port,
        username=username,
        database_name=database_name,
        ssl_mode=ssl_mode,
        schema_version=schema_version,
        migration_mode=migration_mode,
        backup_manifest_url=backup_manifest_url,
        restore_drill_url=restore_drill_url,
        metrics_url=metrics_url,
        backup_retention_days=_parse_int(env, "IDEAFORGE_DATABASE_BACKUP_RETENTION_DAYS", 7, 3660),
        restore_drill_max_age_hours=_parse_int(env, "IDEAFORGE_DATABASE_RESTORE_DRILL_MAX_AGE_HOURS", 1, 720),
    )


def run_readiness(config: ProductionDatabaseConfig) -> dict[str, Any]:
    report = {
        "status": "ready",
        "schemaVersion": config.schema_version,
        "migrationMode": config.migration_mode,
        "database": {
            "engine": "postgresql",
            "hostFingerprint": _fingerprint(config.host),
            "portConfigured": config.port is not None,
            "usernameFingerprint": _fingerprint(config.username),
            "databaseNameFingerprint": _fingerprint(config.database_name),
            "sslMode": config.ssl_mode,
        },
        "backup": {
            "manifestFingerprint": _fingerprint(config.backup_manifest_url),
            "retentionDays": config.backup_retention_days,
        },
        "restore": {
            "drillFingerprint": _fingerprint(config.restore_drill_url),
            "maxAgeHours": config.restore_drill_max_age_hours,
        },
        "operations": {
            "metricsFingerprint": _fingerprint(config.metrics_url),
        },
        "privacy": {
            "reportsRawDatabaseURL": False,
            "reportsCredentials": False,
            "reportsRawEndpointURLs": False,
            "reportsTranscriptOrArtifact": False,
        },
    }
    _assert_report_redacted(report, config)
    return report


def _assert_report_redacted(report: dict[str, Any], config: ProductionDatabaseConfig) -> None:
    serialized = json.dumps(report, sort_keys=True)
    forbidden = [
        config.database_url,
        config.host,
        config.username,
        config.database_name,
        config.backup_manifest_url,
        config.restore_drill_url,
        config.metrics_url,
    ]
    leaked = [item for item in forbidden if item and item in serialized]
    if leaked:
        raise ProductionDatabaseReadinessError("production database report contains raw DB config")
    if re.search(r"postgres(?:ql)?://|https?://", serialized):
        raise ProductionDatabaseReadinessError("production database report contains a raw URL")


def render_report(report: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# IdeaForge Production Database Readiness",
            "",
            f"- Status: {report['status']}",
            f"- Schema version: {report['schemaVersion']}",
            f"- Migration mode: {report['migrationMode']}",
            f"- Engine: {report['database']['engine']}",
            f"- Host fingerprint: {report['database']['hostFingerprint']}",
            f"- Port configured: {str(report['database']['portConfigured']).lower()}",
            f"- Username fingerprint: {report['database']['usernameFingerprint']}",
            f"- Database fingerprint: {report['database']['databaseNameFingerprint']}",
            f"- TLS mode: {report['database']['sslMode']}",
            f"- Backup manifest fingerprint: {report['backup']['manifestFingerprint']}",
            f"- Backup retention days: {report['backup']['retentionDays']}",
            f"- Restore drill fingerprint: {report['restore']['drillFingerprint']}",
            f"- Restore drill max age hours: {report['restore']['maxAgeHours']}",
            f"- Metrics endpoint fingerprint: {report['operations']['metricsFingerprint']}",
            "- Report redaction: raw DB URL/credentials/endpoints/transcript/artifact omitted",
            "",
        ]
    )


def write_report(report: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix == ".json":
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        path.write_text(render_report(report), encoding="utf-8")


def _passing_env() -> dict[str, str]:
    return {
        "IDEAFORGE_DATABASE_URL": (
            "postgresql://ideaforge_app:prod_secret_0123456789abcdef"
            "@db.ideaforge.internal:5432/ideaforge_prod?sslmode=verify-full"
        ),
        "IDEAFORGE_DATABASE_SCHEMA_VERSION": BACKEND_SCHEMA_VERSION,
        "IDEAFORGE_DATABASE_MIGRATION_MODE": "managed-lock",
        "IDEAFORGE_DATABASE_BACKUP_MANIFEST_URL": "https://ops.ideaforge.app/database/backup-manifest",
        "IDEAFORGE_DATABASE_RESTORE_DRILL_URL": "https://ops.ideaforge.app/database/restore-drill",
        "IDEAFORGE_DATABASE_METRICS_URL": "https://ops.ideaforge.app/database/metrics",
        "IDEAFORGE_DATABASE_BACKUP_RETENTION_DAYS": "35",
        "IDEAFORGE_DATABASE_RESTORE_DRILL_MAX_AGE_HOURS": "168",
    }


def run_self_test() -> None:
    env = _passing_env()
    config = load_config(env)
    report = run_readiness(config)
    assert report["status"] == "ready"
    assert report["schemaVersion"] == BACKEND_SCHEMA_VERSION
    assert report["database"]["sslMode"] == "verify-full"
    serialized = json.dumps(report, sort_keys=True)
    for secret in (
        env["IDEAFORGE_DATABASE_URL"],
        "prod_secret_0123456789abcdef",
        "db.ideaforge.internal",
        "ideaforge_app",
        "ideaforge_prod",
        env["IDEAFORGE_DATABASE_BACKUP_MANIFEST_URL"],
        env["IDEAFORGE_DATABASE_RESTORE_DRILL_URL"],
        env["IDEAFORGE_DATABASE_METRICS_URL"],
    ):
        assert secret not in serialized

    with TemporaryDirectory() as temp_root:
        report_path = Path(temp_root) / "production-database-readiness.md"
        write_report(report, report_path)
        rendered = report_path.read_text(encoding="utf-8")
        assert "postgresql://" not in rendered
        assert "https://" not in rendered
        assert "prod_secret_0123456789abcdef" not in rendered

    negative_cases = {
        "missing database url": {"IDEAFORGE_DATABASE_URL": ""},
        "sqlite database": {"IDEAFORGE_DATABASE_URL": "sqlite:///tmp/backend.db"},
        "localhost database": {
            "IDEAFORGE_DATABASE_URL": (
                "postgresql://ideaforge_app:prod_secret_0123456789abcdef"
                "@localhost:5432/ideaforge_prod?sslmode=require"
            )
        },
        "missing tls": {
            "IDEAFORGE_DATABASE_URL": (
                "postgresql://ideaforge_app:prod_secret_0123456789abcdef"
                "@db.ideaforge.internal:5432/ideaforge_prod"
            )
        },
        "disabled tls": {
            "IDEAFORGE_DATABASE_URL": (
                "postgresql://ideaforge_app:prod_secret_0123456789abcdef"
                "@db.ideaforge.internal:5432/ideaforge_prod?sslmode=disable"
            )
        },
        "default user": {
            "IDEAFORGE_DATABASE_URL": (
                "postgresql://postgres:prod_secret_0123456789abcdef"
                "@db.ideaforge.internal:5432/ideaforge_prod?sslmode=require"
            )
        },
        "default database": {
            "IDEAFORGE_DATABASE_URL": (
                "postgresql://ideaforge_app:prod_secret_0123456789abcdef"
                "@db.ideaforge.internal:5432/postgres?sslmode=require"
            )
        },
        "schema drift": {"IDEAFORGE_DATABASE_SCHEMA_VERSION": "2999_01_01_999_future"},
        "unsafe migration mode": {"IDEAFORGE_DATABASE_MIGRATION_MODE": "auto"},
        "placeholder backup": {
            "IDEAFORGE_DATABASE_BACKUP_MANIFEST_URL": "https://example.com/database/backup-manifest"
        },
        "http metrics": {"IDEAFORGE_DATABASE_METRICS_URL": "http://ops.ideaforge.app/database/metrics"},
        "short retention": {"IDEAFORGE_DATABASE_BACKUP_RETENTION_DAYS": "1"},
        "stale restore drill": {"IDEAFORGE_DATABASE_RESTORE_DRILL_MAX_AGE_HOURS": "9999"},
    }
    for name, override in negative_cases.items():
        bad_env = dict(env)
        bad_env.update(override)
        try:
            load_config(bad_env)
        except ProductionDatabaseReadinessError:
            continue
        raise AssertionError(f"negative case unexpectedly passed: {name}")

    print("IdeaForge production database readiness self-test passed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run IdeaForge production database readiness gate.")
    parser.add_argument("--report")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return

    try:
        config = load_config(os.environ)
        report = run_readiness(config)
    except ProductionDatabaseReadinessError as error:
        raise SystemExit(f"production database readiness failed: {error}") from error

    if args.report:
        write_report(report, Path(args.report))
    else:
        print(render_report(report), end="")


if __name__ == "__main__":
    main()
