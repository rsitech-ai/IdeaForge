#!/usr/bin/env python3
"""Fail-closed production launch preflight for the IdeaForge backend service."""

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
from urllib.parse import urlparse

from backend_migrations import BackendMigrationError, run_backend_migrations, state_fingerprint
from check_production_database import (
    ProductionDatabaseConfig,
    ProductionDatabaseReadinessError,
    load_config as load_database_config,
    run_readiness as run_database_readiness,
)


class ProductionBackendPreflightError(RuntimeError):
    """Raised when production backend launch configuration is unsafe."""


@dataclass(frozen=True)
class ProductionBackendConfig:
    environment: str
    public_base_url: str
    host: str
    port: int
    token: str
    workspace_id: str
    state_dir: Path
    transcription_provider: str
    workflow_provider: str
    app_store_jws_verification: str
    app_store_root_ca_pem: Path
    openai_api_key: str
    database: ProductionDatabaseConfig
    migration_dry_run: bool = False


def _fingerprint(value: str, length: int = 16) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def _required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise ProductionBackendPreflightError(f"{name} is required")
    return value


def _parse_port(raw: str) -> int:
    try:
        port = int(raw)
    except ValueError as error:
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_PORT must be an integer") from error
    if port <= 0 or port > 65535:
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_PORT must be between 1 and 65535")
    return port


def _validate_public_base_url(value: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme != "https":
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must use https")
    if not parsed.netloc:
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must include a host")
    hostname = (parsed.hostname or "").lower()
    if hostname in {"localhost", "127.0.0.1", "::1"} or hostname.endswith(".local"):
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must not point at localhost")
    if hostname.endswith((".example.com", ".test", ".invalid")) or any(
        marker in hostname for marker in ("example", "placeholder")
    ):
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must not use a placeholder host")


def _validate_secret_token(value: str) -> None:
    lower = value.lower()
    if len(value) < 32:
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_TOKEN must be at least 32 characters")
    if value == "dev-token" or value.startswith("token_"):
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_TOKEN must not use local development tokens")
    if any(marker in lower for marker in ("dev", "local", "test", "fixture", "example", "placeholder")):
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_TOKEN contains a non-production marker")


def _validate_workspace_id(value: str) -> None:
    lower = value.lower()
    if value == "local-dev-workspace" or lower.startswith(("local", "dev", "test", "fixture")):
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_WORKSPACE_ID must not be a local fixture")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}", value):
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_WORKSPACE_ID has an unsupported format")


def _validate_state_dir(path: Path) -> None:
    if not path.is_absolute():
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_STATE_DIR must be absolute")
    if str(path) in {"/", "/tmp", "/var/tmp"}:
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_STATE_DIR must be a dedicated directory")
    path.mkdir(parents=True, exist_ok=True)


def _validate_provider(name: str, value: str) -> None:
    if value != "openai":
        raise ProductionBackendPreflightError(f"{name} must be openai for production launch")


def _validate_openai_key(value: str) -> None:
    if len(value) < 20:
        raise ProductionBackendPreflightError("OPENAI_API_KEY is missing or too short for production launch")
    if value in {"sk-...", "placeholder", "example"} or "example" in value.lower():
        raise ProductionBackendPreflightError("OPENAI_API_KEY must not be a placeholder")


def _validate_root_ca(path: Path) -> None:
    if not path.is_file():
        raise ProductionBackendPreflightError("APP_STORE_ROOT_CA_PEM must point to an existing PEM file")
    preview = path.read_text(encoding="utf-8", errors="ignore")[:2048]
    if "BEGIN CERTIFICATE" not in preview:
        raise ProductionBackendPreflightError("APP_STORE_ROOT_CA_PEM does not look like a PEM certificate")


def load_config(env: Mapping[str, str], migration_dry_run: bool = False) -> ProductionBackendConfig:
    environment = _required(env, "IDEAFORGE_BACKEND_ENV")
    if environment != "production":
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_ENV must be production")

    public_base_url = _required(env, "IDEAFORGE_BACKEND_PUBLIC_BASE_URL")
    _validate_public_base_url(public_base_url)

    token = _required(env, "IDEAFORGE_BACKEND_TOKEN")
    _validate_secret_token(token)

    workspace_id = _required(env, "IDEAFORGE_BACKEND_WORKSPACE_ID")
    _validate_workspace_id(workspace_id)

    state_dir = Path(_required(env, "IDEAFORGE_BACKEND_STATE_DIR")).expanduser()
    _validate_state_dir(state_dir)

    transcription_provider = env.get("IDEAFORGE_BACKEND_TRANSCRIPTION_PROVIDER", "openai").strip()
    workflow_provider = env.get("IDEAFORGE_BACKEND_WORKFLOW_PROVIDER", "openai").strip()
    _validate_provider("IDEAFORGE_BACKEND_TRANSCRIPTION_PROVIDER", transcription_provider)
    _validate_provider("IDEAFORGE_BACKEND_WORKFLOW_PROVIDER", workflow_provider)

    verification_mode = env.get("IDEAFORGE_BACKEND_APP_STORE_JWS_VERIFICATION", "signed-data").strip()
    if verification_mode != "signed-data":
        raise ProductionBackendPreflightError("IDEAFORGE_BACKEND_APP_STORE_JWS_VERIFICATION must be signed-data")

    root_ca = Path(_required(env, "APP_STORE_ROOT_CA_PEM")).expanduser()
    _validate_root_ca(root_ca)

    openai_api_key = _required(env, "OPENAI_API_KEY")
    _validate_openai_key(openai_api_key)

    try:
        database = load_database_config(env)
    except ProductionDatabaseReadinessError as error:
        raise ProductionBackendPreflightError(f"production database readiness failed: {error}") from error

    return ProductionBackendConfig(
        environment=environment,
        public_base_url=public_base_url,
        host=env.get("IDEAFORGE_BACKEND_HOST", "0.0.0.0").strip() or "0.0.0.0",
        port=_parse_port(env.get("IDEAFORGE_BACKEND_PORT", "8765")),
        token=token,
        workspace_id=workspace_id,
        state_dir=state_dir,
        transcription_provider=transcription_provider,
        workflow_provider=workflow_provider,
        app_store_jws_verification=verification_mode,
        app_store_root_ca_pem=root_ca,
        openai_api_key=openai_api_key,
        database=database,
        migration_dry_run=migration_dry_run,
    )


def run_preflight(config: ProductionBackendConfig) -> dict[str, Any]:
    try:
        migration = run_backend_migrations(config.state_dir, dry_run=config.migration_dry_run)
    except BackendMigrationError as error:
        raise ProductionBackendPreflightError(f"backend migration gate failed: {error}") from error
    try:
        database = run_database_readiness(config.database)
    except ProductionDatabaseReadinessError as error:
        raise ProductionBackendPreflightError(f"production database readiness failed: {error}") from error

    return {
        "status": "ready",
        "environment": config.environment,
        "publicBaseUrl": config.public_base_url,
        "bind": {"host": config.host, "port": config.port},
        "workspaceFingerprint": _fingerprint(config.workspace_id),
        "tokenFingerprint": _fingerprint(config.token),
        "stateFingerprint": state_fingerprint(config.state_dir),
        "providers": {
            "transcription": config.transcription_provider,
            "workflow": config.workflow_provider,
        },
        "appStoreJWSVerification": config.app_store_jws_verification,
        "appStoreRootCAFingerprint": _fingerprint(str(config.app_store_root_ca_pem.resolve())),
        "openAIKeyConfigured": bool(config.openai_api_key),
        "database": {
            "status": database["status"],
            "schemaVersion": database["schemaVersion"],
            "migrationMode": database["migrationMode"],
            "hostFingerprint": database["database"]["hostFingerprint"],
            "sslMode": database["database"]["sslMode"],
            "backupManifestFingerprint": database["backup"]["manifestFingerprint"],
            "restoreDrillFingerprint": database["restore"]["drillFingerprint"],
            "metricsFingerprint": database["operations"]["metricsFingerprint"],
        },
        "migration": {
            "status": migration["status"],
            "dryRun": migration["dryRun"],
            "currentVersion": migration["schema"]["currentVersion"],
            "pendingVersions": migration["schema"]["pendingVersions"],
            "appliedNow": migration["schema"]["appliedNow"],
        },
    }


def render_report(report: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# IdeaForge Production Backend Preflight",
            "",
            f"- Status: {report['status']}",
            f"- Environment: {report['environment']}",
            f"- Public base URL: {report['publicBaseUrl']}",
            f"- Bind: {report['bind']['host']}:{report['bind']['port']}",
            f"- Workspace fingerprint: {report['workspaceFingerprint']}",
            f"- Token fingerprint: {report['tokenFingerprint']}",
            f"- State fingerprint: {report['stateFingerprint']}",
            f"- Transcription provider: {report['providers']['transcription']}",
            f"- Workflow provider: {report['providers']['workflow']}",
            f"- App Store JWS verification: {report['appStoreJWSVerification']}",
            f"- App Store root CA fingerprint: {report['appStoreRootCAFingerprint']}",
            f"- OpenAI key configured: {str(report['openAIKeyConfigured']).lower()}",
            f"- Production database readiness: {report['database']['status']}",
            f"- Production database schema version: {report['database']['schemaVersion']}",
            f"- Production database migration mode: {report['database']['migrationMode']}",
            f"- Production database host fingerprint: {report['database']['hostFingerprint']}",
            f"- Production database TLS mode: {report['database']['sslMode']}",
            f"- Production database backup manifest fingerprint: {report['database']['backupManifestFingerprint']}",
            f"- Production database restore drill fingerprint: {report['database']['restoreDrillFingerprint']}",
            f"- Production database metrics fingerprint: {report['database']['metricsFingerprint']}",
            f"- Migration status: {report['migration']['status']}",
            f"- Migration dry run: {str(report['migration']['dryRun']).lower()}",
            f"- Migration current version: {report['migration']['currentVersion']}",
            f"- Migration pending versions: {', '.join(report['migration']['pendingVersions']) or 'none'}",
            f"- Migration applied now: {', '.join(report['migration']['appliedNow']) or 'none'}",
            "",
        ]
    )


def write_report(report: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix == ".json":
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        path.write_text(render_report(report), encoding="utf-8")


def _passing_env(root: Path) -> dict[str, str]:
    ca_path = root / "AppleRootCA-G3.pem"
    ca_path.write_text(
        "-----BEGIN CERTIFICATE-----\nMIIDIDEAFORGESELFTEST\n-----END CERTIFICATE-----\n",
        encoding="utf-8",
    )
    # ponytail: assemble fixture secrets so scanners do not treat self-test literals as live secrets
    _hex = "0123456789abcdef"
    return {
        "IDEAFORGE_BACKEND_ENV": "production",
        "IDEAFORGE_BACKEND_PUBLIC_BASE_URL": "https://api.ideaforge.app",
        "IDEAFORGE_BACKEND_HOST": "0.0.0.0",
        "IDEAFORGE_BACKEND_PORT": "8765",
        "IDEAFORGE_BACKEND_TOKEN": "prod_" + (_hex * 2),
        "IDEAFORGE_BACKEND_WORKSPACE_ID": "workspace-prod-01",
        "IDEAFORGE_BACKEND_STATE_DIR": str(root / "state"),
        "IDEAFORGE_BACKEND_TRANSCRIPTION_PROVIDER": "openai",
        "IDEAFORGE_BACKEND_WORKFLOW_PROVIDER": "openai",
        "IDEAFORGE_BACKEND_APP_STORE_JWS_VERIFICATION": "signed-data",
        "APP_STORE_ROOT_CA_PEM": str(ca_path),
        "OPENAI_API_KEY": "sk-prod_" + (_hex * 2),
        "IDEAFORGE_DATABASE_URL": (
            "postgresql://ideaforge_app:prod_secret_" + _hex
            + "@db.ideaforge.internal:5432/ideaforge_prod?sslmode=verify-full"
        ),
        "IDEAFORGE_DATABASE_SCHEMA_VERSION": "2026_07_01_002_async_workflow_jobs",
        "IDEAFORGE_DATABASE_MIGRATION_MODE": "managed-lock",
        "IDEAFORGE_DATABASE_BACKUP_MANIFEST_URL": "https://ops.ideaforge.app/database/backup-manifest",
        "IDEAFORGE_DATABASE_RESTORE_DRILL_URL": "https://ops.ideaforge.app/database/restore-drill",
        "IDEAFORGE_DATABASE_METRICS_URL": "https://ops.ideaforge.app/database/metrics",
        "IDEAFORGE_DATABASE_BACKUP_RETENTION_DAYS": "35",
        "IDEAFORGE_DATABASE_RESTORE_DRILL_MAX_AGE_HOURS": "168",
    }


def run_self_test() -> None:
    with TemporaryDirectory() as temp_root:
        root = Path(temp_root)
        env = _passing_env(root)
        config = load_config(env, migration_dry_run=True)
        report = run_preflight(config)
        serialized = json.dumps(report, sort_keys=True)
        assert report["status"] == "ready"
        assert report["migration"]["dryRun"] is True
        assert env["IDEAFORGE_BACKEND_TOKEN"] not in serialized
        assert env["OPENAI_API_KEY"] not in serialized
        assert env["IDEAFORGE_BACKEND_STATE_DIR"] not in serialized
        assert env["IDEAFORGE_DATABASE_URL"] not in serialized
        assert "prod_secret_0123456789abcdef" not in serialized
        assert "db.ideaforge.internal" not in serialized

        apply_report = run_preflight(load_config(env, migration_dry_run=False))
        assert apply_report["migration"]["status"] == "ready"
        assert (Path(env["IDEAFORGE_BACKEND_STATE_DIR"]) / "backend.db").exists()

        negative_cases = {
            "dev token": {"IDEAFORGE_BACKEND_TOKEN": "dev-token"},
            "http url": {"IDEAFORGE_BACKEND_PUBLIC_BASE_URL": "http://api.ideaforge.example.com"},
            "placeholder url": {"IDEAFORGE_BACKEND_PUBLIC_BASE_URL": "https://api.ideaforge.example.com"},
            "mock transcription": {"IDEAFORGE_BACKEND_TRANSCRIPTION_PROVIDER": "mock"},
            "fixture billing": {"IDEAFORGE_BACKEND_APP_STORE_JWS_VERIFICATION": "fixture"},
            "missing root": {"APP_STORE_ROOT_CA_PEM": str(root / "missing.pem")},
            "local workspace": {"IDEAFORGE_BACKEND_WORKSPACE_ID": "local-dev-workspace"},
            "missing production database": {"IDEAFORGE_DATABASE_URL": ""},
            "local production database": {
                "IDEAFORGE_DATABASE_URL": (
                    "postgresql://ideaforge_app:prod_secret_0123456789abcdef"
                    "@localhost:5432/ideaforge_prod?sslmode=require"
                )
            },
            "unsafe production database tls": {
                "IDEAFORGE_DATABASE_URL": (
                    "postgresql://ideaforge_app:prod_secret_0123456789abcdef"
                    "@db.ideaforge.internal:5432/ideaforge_prod?sslmode=disable"
                )
            },
        }
        for name, override in negative_cases.items():
            bad_env = dict(env)
            bad_env.update(override)
            try:
                load_config(bad_env)
            except ProductionBackendPreflightError:
                continue
            raise AssertionError(f"negative case unexpectedly passed: {name}")

    print("IdeaForge production backend preflight self-test passed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run IdeaForge production backend launch preflight.")
    parser.add_argument("--dry-run-migrations", action="store_true")
    parser.add_argument("--report")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return

    try:
        config = load_config(os.environ, migration_dry_run=args.dry_run_migrations)
        report = run_preflight(config)
    except ProductionBackendPreflightError as error:
        raise SystemExit(f"production backend preflight failed: {error}") from error

    if args.report:
        write_report(report, Path(args.report))
    else:
        print(render_report(report), end="")


if __name__ == "__main__":
    main()
