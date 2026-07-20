#!/usr/bin/env python3
"""Fail-closed live deployment smoke for the IdeaForge backend contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


REQUIRED_CAPABILITIES = (
    "upload_recordings",
    "sync_workspace",
    "run_ai_workflows",
    "reconcile_billing",
    "manage_account",
    "register_push_notifications",
)


class DeployedBackendSmokeError(RuntimeError):
    """Raised when deployed backend proof is missing or unsafe."""


@dataclass(frozen=True)
class DeployedBackendConfig:
    base_url: str
    host_fingerprint: str
    bearer_token: str
    workspace_id: str
    auth_session_path: str
    operations_status_path: str
    backup_manifest_path: str
    restore_drill_path: str
    operations_metrics_path: str
    timeout_seconds: float
    required_capabilities: tuple[str, ...]


RequestJSON = Callable[[str, str, dict[str, str], dict[str, Any] | None, float], tuple[int, dict[str, Any]]]


def _fingerprint(value: str, length: int = 16) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def _required(env: Mapping[str, str], name: str) -> str:
    value = env.get(name, "").strip()
    if not value:
        raise DeployedBackendSmokeError(f"{name} is required")
    return value


def _validate_base_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme != "https":
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must use https")
    if parsed.username or parsed.password:
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must not include credentials")
    hostname = (parsed.hostname or "").lower()
    if not hostname:
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must include a host")
    if hostname in {"localhost", "127.0.0.1", "::1"} or hostname.endswith(".local"):
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must not point at localhost")
    if hostname.endswith((".example.com", ".example.test", ".test", ".invalid")):
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must not use a placeholder host")
    if any(marker in hostname for marker in ("example", "placeholder", "localhost")):
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_PUBLIC_BASE_URL must not use a placeholder host")
    return value.rstrip("/")


def _validate_secret_token(value: str) -> None:
    lower = value.lower()
    if len(value) < 32:
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_TOKEN must be at least 32 characters")
    if value == "dev-token" or value.startswith("token_"):
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_TOKEN must not use local development tokens")
    if any(marker in lower for marker in ("dev", "local", "test", "fixture", "example", "placeholder")):
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_TOKEN contains a non-production marker")


def _validate_workspace_id(value: str) -> None:
    lower = value.lower()
    if value == "local-dev-workspace" or lower.startswith(("local", "dev", "test", "fixture")):
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_WORKSPACE_ID must not be a local fixture")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}", value):
        raise DeployedBackendSmokeError("IDEAFORGE_BACKEND_WORKSPACE_ID has an unsupported format")


def _path(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name, default).strip() or default
    if not value.startswith("/"):
        raise DeployedBackendSmokeError(f"{name} must start with /")
    if "://" in value or " " in value or "\n" in value or "\r" in value:
        raise DeployedBackendSmokeError(f"{name} must be a clean absolute path, not a URL")
    return value


def _timeout(env: Mapping[str, str]) -> float:
    raw = env.get("IDEAFORGE_DEPLOYED_BACKEND_TIMEOUT_SECONDS", "15").strip()
    try:
        value = float(raw)
    except ValueError as error:
        raise DeployedBackendSmokeError("IDEAFORGE_DEPLOYED_BACKEND_TIMEOUT_SECONDS must be numeric") from error
    if value < 1 or value > 120:
        raise DeployedBackendSmokeError("IDEAFORGE_DEPLOYED_BACKEND_TIMEOUT_SECONDS must be between 1 and 120")
    return value


def _capabilities(env: Mapping[str, str]) -> tuple[str, ...]:
    raw = env.get("IDEAFORGE_DEPLOYED_BACKEND_REQUIRED_CAPABILITIES", "").strip()
    if not raw:
        return REQUIRED_CAPABILITIES
    capabilities = tuple(item.strip() for item in raw.split(",") if item.strip())
    unknown = sorted(set(capabilities) - set(REQUIRED_CAPABILITIES))
    if unknown:
        raise DeployedBackendSmokeError(
            "IDEAFORGE_DEPLOYED_BACKEND_REQUIRED_CAPABILITIES contains unsupported capabilities: "
            + ", ".join(unknown)
        )
    return capabilities


def load_config(env: Mapping[str, str]) -> DeployedBackendConfig:
    base_url = _validate_base_url(_required(env, "IDEAFORGE_BACKEND_PUBLIC_BASE_URL"))
    token = _required(env, "IDEAFORGE_BACKEND_TOKEN")
    _validate_secret_token(token)
    workspace_id = _required(env, "IDEAFORGE_BACKEND_WORKSPACE_ID")
    _validate_workspace_id(workspace_id)
    hostname = urlparse(base_url).hostname or ""
    return DeployedBackendConfig(
        base_url=base_url,
        host_fingerprint=_fingerprint(hostname),
        bearer_token=token,
        workspace_id=workspace_id,
        auth_session_path=_path(env, "IDEAFORGE_BACKEND_AUTH_SESSION_PATH", "/v1/auth/session"),
        operations_status_path=_path(env, "IDEAFORGE_BACKEND_OPERATIONS_STATUS_PATH", "/v1/admin/status"),
        backup_manifest_path=_path(env, "IDEAFORGE_BACKEND_BACKUP_MANIFEST_PATH", "/v1/admin/backup-manifest"),
        restore_drill_path=_path(env, "IDEAFORGE_BACKEND_RESTORE_DRILL_PATH", "/v1/admin/restore-drill"),
        operations_metrics_path=_path(env, "IDEAFORGE_BACKEND_OPERATIONS_METRICS_PATH", "/v1/admin/metrics"),
        timeout_seconds=_timeout(env),
        required_capabilities=_capabilities(env),
    )


def _url(config: DeployedBackendConfig, path: str) -> str:
    return config.base_url + path


def request_json(
    method: str,
    url: str,
    headers: dict[str, str],
    payload: dict[str, Any] | None,
    timeout_seconds: float,
) -> tuple[int, dict[str, Any]]:
    body = None
    request_headers = dict(headers)
    if payload is not None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    request_headers.setdefault("Accept", "application/json")
    request = Request(url, data=body, headers=request_headers, method=method)
    try:
        with urlopen(request, timeout=timeout_seconds) as response:
            status = int(response.status)
            data = response.read()
    except HTTPError as error:
        status = int(error.code)
        data = error.read()
    except URLError as error:
        raise DeployedBackendSmokeError(f"{method} request failed: {error.reason}") from error

    try:
        decoded = json.loads(data.decode("utf-8")) if data else {}
    except json.JSONDecodeError as error:
        raise DeployedBackendSmokeError(f"{method} request returned non-JSON status {status}") from error
    if not isinstance(decoded, dict):
        raise DeployedBackendSmokeError(f"{method} request returned a non-object JSON payload")
    return status, decoded


def _require_2xx(label: str, status: int, payload: dict[str, Any]) -> None:
    if not (200 <= status < 300):
        reason = payload.get("error") or payload.get("status") or "unknown"
        raise DeployedBackendSmokeError(f"{label} returned HTTP {status}: {reason}")


def _authed_headers(config: DeployedBackendConfig) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {config.bearer_token}",
        "X-IdeaForge-Workspace-ID": config.workspace_id,
        "Accept": "application/json",
    }


def _require_false_privacy(label: str, privacy: Any, keys: tuple[str, ...]) -> None:
    if not isinstance(privacy, dict):
        raise DeployedBackendSmokeError(f"{label} is missing privacy flags")
    leaking = [key for key in keys if privacy.get(key) is not False]
    if leaking:
        raise DeployedBackendSmokeError(f"{label} privacy flags are not all false: {', '.join(leaking)}")


def _require_non_negative_int(label: str, payload: Mapping[str, Any], key: str) -> int:
    value = payload.get(key)
    if not isinstance(value, int) or value < 0:
        raise DeployedBackendSmokeError(f"{label}.{key} must be a non-negative integer")
    return value


def _validate_session(config: DeployedBackendConfig, payload: dict[str, Any]) -> list[str]:
    if payload.get("workspaceID") != config.workspace_id:
        raise DeployedBackendSmokeError("auth session belongs to a different workspace")
    capabilities = payload.get("capabilities")
    if not isinstance(capabilities, list) or not all(isinstance(item, str) for item in capabilities):
        raise DeployedBackendSmokeError("auth session is missing capabilities")
    missing = [capability for capability in config.required_capabilities if capability not in capabilities]
    if missing:
        raise DeployedBackendSmokeError("auth session is missing capabilities: " + ", ".join(missing))
    account = payload.get("account")
    if not isinstance(account, dict):
        raise DeployedBackendSmokeError("auth session is missing account summary")
    if not str(account.get("planName") or "").strip():
        raise DeployedBackendSmokeError("auth session account is missing planName")
    if not str(account.get("planStatus") or "").strip():
        raise DeployedBackendSmokeError("auth session account is missing planStatus")
    return capabilities


def _validate_status(config: DeployedBackendConfig, payload: dict[str, Any]) -> tuple[str, dict[str, int], list[str]]:
    if payload.get("status") != "ready":
        raise DeployedBackendSmokeError("operations status is not ready")
    schema = payload.get("schema")
    if not isinstance(schema, dict) or not str(schema.get("currentVersion") or "").strip():
        raise DeployedBackendSmokeError("operations status is missing schema.currentVersion")
    checks = payload.get("checks")
    if not isinstance(checks, list) or not checks:
        raise DeployedBackendSmokeError("operations status is missing checks")
    failing = [
        str(check.get("name") or "unknown")
        for check in checks
        if not isinstance(check, dict) or check.get("status") != "ok"
    ]
    if failing:
        raise DeployedBackendSmokeError("operations status checks are not ok: " + ", ".join(failing))
    counts = payload.get("counts")
    if not isinstance(counts, dict):
        raise DeployedBackendSmokeError("operations status is missing counts")
    count_summary = {
        "accounts": _require_non_negative_int("counts", counts, "accounts"),
        "jobs": _require_non_negative_int("counts", counts, "jobs"),
        "objects": _require_non_negative_int("counts", counts, "objects"),
        "auditEvents": _require_non_negative_int("counts", counts, "auditEvents"),
    }
    tenants = payload.get("tenants")
    if not isinstance(tenants, list) or not tenants:
        raise DeployedBackendSmokeError("operations status is missing tenants")
    if not any(isinstance(tenant, dict) and tenant.get("workspaceID") == config.workspace_id for tenant in tenants):
        raise DeployedBackendSmokeError("operations status does not include the scoped workspace tenant")
    return str(schema["currentVersion"]), count_summary, [str(check["name"]) for check in checks]


def _validate_backup(schema_version: str, payload: dict[str, Any]) -> dict[str, int]:
    if payload.get("schemaVersion") != schema_version:
        raise DeployedBackendSmokeError("backup manifest schemaVersion does not match operations status")
    if not str(payload.get("generatedAt") or "").strip():
        raise DeployedBackendSmokeError("backup manifest is missing generatedAt")
    workspace = payload.get("workspace")
    storage = payload.get("storage")
    operations = payload.get("operations")
    if not isinstance(workspace, dict) or not isinstance(storage, dict) or not isinstance(operations, dict):
        raise DeployedBackendSmokeError("backup manifest is missing workspace/storage/operations sections")
    _require_false_privacy(
        "backup manifest",
        payload.get("privacy"),
        (
            "includesRawTranscript",
            "includesRawAudio",
            "includesBearerTokens",
            "includesEmailAddresses",
            "includesGeneratedArtifacts",
        ),
    )
    return {
        "projectCount": _require_non_negative_int("backup.workspace", workspace, "projectCount"),
        "objectCount": _require_non_negative_int("backup.storage", storage, "objectCount"),
        "accountCount": _require_non_negative_int("backup.operations", operations, "accountCount"),
        "jobCount": _require_non_negative_int("backup.operations", operations, "jobCount"),
    }


def _validate_metrics(schema_version: str, payload: dict[str, Any]) -> dict[str, int]:
    if payload.get("status") != "ready":
        raise DeployedBackendSmokeError("operations metrics status is not ready")
    if payload.get("schemaVersion") != schema_version:
        raise DeployedBackendSmokeError("operations metrics schemaVersion does not match operations status")
    _require_false_privacy(
        "operations metrics",
        payload.get("privacy"),
        (
            "includesRawTranscript",
            "includesRawAudio",
            "includesBearerTokens",
            "includesEmailAddresses",
            "includesGeneratedArtifacts",
            "includesLocalPaths",
        ),
    )
    storage = payload.get("storage")
    if not isinstance(storage, dict):
        raise DeployedBackendSmokeError("operations metrics is missing storage")
    job_statuses = payload.get("jobCountsByStatus")
    job_kinds = payload.get("jobCountsByKind")
    if not isinstance(job_statuses, dict) or not isinstance(job_kinds, dict):
        raise DeployedBackendSmokeError("operations metrics is missing job count maps")
    return {
        "objectCount": _require_non_negative_int("metrics.storage", storage, "objectCount"),
        "statusBucketCount": len(job_statuses),
        "kindBucketCount": len(job_kinds),
    }


def _validate_restore(schema_version: str, backup_generated_at: str, payload: dict[str, Any]) -> list[str]:
    if payload.get("status") != "passed":
        raise DeployedBackendSmokeError("restore drill did not pass")
    if payload.get("schemaVersion") != schema_version:
        raise DeployedBackendSmokeError("restore drill schemaVersion does not match operations status")
    if payload.get("sourceBackupGeneratedAt") != backup_generated_at:
        raise DeployedBackendSmokeError("restore drill did not use the current backup manifest")
    checks = payload.get("checks")
    if not isinstance(checks, list) or not checks:
        raise DeployedBackendSmokeError("restore drill is missing checks")
    failing = [
        str(check.get("name") or "unknown")
        for check in checks
        if not isinstance(check, dict) or check.get("status") != "ok"
    ]
    if failing:
        raise DeployedBackendSmokeError("restore drill checks are not ok: " + ", ".join(failing))
    _require_false_privacy(
        "restore drill",
        payload.get("privacy"),
        (
            "includesRawTranscript",
            "includesRawAudio",
            "includesBearerTokens",
            "includesEmailAddresses",
            "includesGeneratedArtifacts",
            "includesLocalPaths",
        ),
    )
    return [str(check["name"]) for check in checks]


def _assert_report_redacted(report: dict[str, Any], config: DeployedBackendConfig) -> None:
    serialized = json.dumps(report, sort_keys=True)
    forbidden = [
        config.bearer_token,
        config.workspace_id,
        config.base_url,
    ]
    leaked = [item for item in forbidden if item and item in serialized]
    if leaked:
        raise DeployedBackendSmokeError("deployed backend report contains a raw secret, workspace, or endpoint")
    if re.search(r"https?://", serialized):
        raise DeployedBackendSmokeError("deployed backend report contains a raw URL")


def run_deployed_smoke(config: DeployedBackendConfig, requester: RequestJSON = request_json) -> dict[str, Any]:
    health_status, health = requester(
        "GET",
        _url(config, "/health"),
        {"Accept": "application/json"},
        None,
        config.timeout_seconds,
    )
    _require_2xx("health", health_status, health)
    if health.get("status") not in {"ok", "ready"}:
        raise DeployedBackendSmokeError("health endpoint did not report ok/ready")

    headers = _authed_headers(config)

    session_status, session = requester(
        "GET",
        _url(config, config.auth_session_path),
        headers,
        None,
        config.timeout_seconds,
    )
    _require_2xx("auth session", session_status, session)
    capabilities = _validate_session(config, session)

    operations_status, operations = requester(
        "GET",
        _url(config, config.operations_status_path),
        headers,
        None,
        config.timeout_seconds,
    )
    _require_2xx("operations status", operations_status, operations)
    schema_version, count_summary, operations_checks = _validate_status(config, operations)

    backup_status, backup = requester(
        "GET",
        _url(config, config.backup_manifest_path),
        headers,
        None,
        config.timeout_seconds,
    )
    _require_2xx("backup manifest", backup_status, backup)
    backup_counts = _validate_backup(schema_version, backup)
    backup_generated_at = str(backup["generatedAt"])

    metrics_status, metrics = requester(
        "GET",
        _url(config, config.operations_metrics_path),
        headers,
        None,
        config.timeout_seconds,
    )
    _require_2xx("operations metrics", metrics_status, metrics)
    metrics_summary = _validate_metrics(schema_version, metrics)

    restore_payload = {
        "backupGeneratedAt": backup_generated_at,
        "schemaVersion": schema_version,
    }
    restore_status, restore = requester(
        "POST",
        _url(config, config.restore_drill_path),
        headers,
        restore_payload,
        config.timeout_seconds,
    )
    _require_2xx("restore drill", restore_status, restore)
    restore_checks = _validate_restore(schema_version, backup_generated_at, restore)

    report = {
        "status": "ready",
        "hostFingerprint": config.host_fingerprint,
        "workspaceFingerprint": _fingerprint(config.workspace_id),
        "tokenFingerprint": _fingerprint(config.bearer_token),
        "schemaVersion": schema_version,
        "capabilities": sorted(capabilities),
        "requiredCapabilities": list(config.required_capabilities),
        "operationsChecks": operations_checks,
        "operationsCounts": count_summary,
        "backupCounts": backup_counts,
        "metricsSummary": metrics_summary,
        "restoreChecks": restore_checks,
        "privacy": {
            "reportsRawURL": False,
            "reportsBearerToken": False,
            "reportsWorkspaceID": False,
            "reportsEmail": False,
            "reportsTranscriptOrArtifact": False,
        },
        "endpointPaths": {
            "authSession": config.auth_session_path,
            "operationsStatus": config.operations_status_path,
            "backupManifest": config.backup_manifest_path,
            "restoreDrill": config.restore_drill_path,
            "operationsMetrics": config.operations_metrics_path,
        },
    }
    _assert_report_redacted(report, config)
    return report


def render_report(report: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# IdeaForge Deployed Backend Live Smoke",
            "",
            f"- Status: {report['status']}",
            f"- Host fingerprint: {report['hostFingerprint']}",
            f"- Workspace fingerprint: {report['workspaceFingerprint']}",
            f"- Token fingerprint: {report['tokenFingerprint']}",
            f"- Schema version: {report['schemaVersion']}",
            f"- Required capabilities: {', '.join(report['requiredCapabilities'])}",
            f"- Session capabilities: {', '.join(report['capabilities'])}",
            f"- Operations checks: {', '.join(report['operationsChecks'])}",
            f"- Restore checks: {', '.join(report['restoreChecks'])}",
            f"- Operations accounts: {report['operationsCounts']['accounts']}",
            f"- Operations jobs: {report['operationsCounts']['jobs']}",
            f"- Operations objects: {report['operationsCounts']['objects']}",
            f"- Backup projects: {report['backupCounts']['projectCount']}",
            f"- Backup objects: {report['backupCounts']['objectCount']}",
            f"- Metrics status buckets: {report['metricsSummary']['statusBucketCount']}",
            f"- Metrics kind buckets: {report['metricsSummary']['kindBucketCount']}",
            "- Report redaction: raw URL/token/workspace/email/transcript/artifact omitted",
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
        "IDEAFORGE_BACKEND_PUBLIC_BASE_URL": "https://api.ideaforge.app",
        "IDEAFORGE_BACKEND_TOKEN": "prod_live_0123456789abcdef0123456789abcdef",
        "IDEAFORGE_BACKEND_WORKSPACE_ID": "workspace-prod-01",
    }


def _fake_payloads(config: DeployedBackendConfig) -> dict[tuple[str, str], dict[str, Any]]:
    schema_version = "2026_07_01_002_async_workflow_jobs"
    backup_generated_at = "2026-07-02T17:00:00Z"
    return {
        ("GET", "/health"): {"status": "ok"},
        (
            "GET",
            config.auth_session_path,
        ): {
            "userID": "user_prod_01",
            "email": "builder@example.invalid",
            "workspaceID": config.workspace_id,
            "account": {
                "planName": "Pro",
                "planStatus": "active",
            },
            "capabilities": list(REQUIRED_CAPABILITIES),
        },
        (
            "GET",
            config.operations_status_path,
        ): {
            "status": "ready",
            "generatedAt": "2026-07-02T17:00:01Z",
            "schema": {
                "currentVersion": schema_version,
                "appliedMigrations": [{"version": schema_version, "appliedAt": "2026-07-02T17:00:00Z"}],
            },
            "checks": [
                {"name": "database", "status": "ok"},
                {"name": "schema_migrations", "status": "ok"},
                {"name": "workspace", "status": "ok"},
                {"name": "object_storage", "status": "ok"},
            ],
            "counts": {
                "accounts": 1,
                "auditEvents": 2,
                "jobs": 3,
                "objects": 2,
                "transcriptionResults": 1,
                "workflowResults": 1,
                "usageEvents": 4,
            },
            "tenants": [
                {
                    "workspaceID": config.workspace_id,
                    "accountID": "acct_prod_01",
                    "planName": "Pro",
                    "planStatus": "active",
                    "capabilitiesCount": len(REQUIRED_CAPABILITIES),
                    "createdAt": "2026-07-02T17:00:00Z",
                }
            ],
        },
        (
            "GET",
            config.backup_manifest_path,
        ): {
            "generatedAt": backup_generated_at,
            "schemaVersion": schema_version,
            "workspace": {
                "projectCount": 1,
                "workflowTemplateCount": 3,
                "uploadJobCount": 0,
                "updatedAt": "2026-07-02T17:00:00Z",
            },
            "storage": {"objectCount": 2, "totalObjectBytes": 128},
            "operations": {"accountCount": 1, "auditEventCount": 2, "jobCount": 3, "usageEventCount": 4},
            "tenants": [],
            "privacy": {
                "includesRawTranscript": False,
                "includesRawAudio": False,
                "includesBearerTokens": False,
                "includesEmailAddresses": False,
                "includesGeneratedArtifacts": False,
            },
        },
        (
            "GET",
            config.operations_metrics_path,
        ): {
            "status": "ready",
            "generatedAt": "2026-07-02T17:00:02Z",
            "schemaVersion": schema_version,
            "jobCountsByStatus": {"completed": 2, "running": 1},
            "jobCountsByKind": {"transcription": 1, "workflow": 1, "recording_upload": 1},
            "storage": {"objectCount": 2, "totalObjectBytes": 128},
            "usage": [{"metric": "workflow_runs", "quantity": 2}],
            "privacy": {
                "includesRawTranscript": False,
                "includesRawAudio": False,
                "includesBearerTokens": False,
                "includesEmailAddresses": False,
                "includesGeneratedArtifacts": False,
                "includesLocalPaths": False,
            },
        },
        (
            "POST",
            config.restore_drill_path,
        ): {
            "status": "passed",
            "generatedAt": "2026-07-02T17:00:03Z",
            "sourceBackupGeneratedAt": backup_generated_at,
            "schemaVersion": schema_version,
            "checks": [
                {"name": "schema_version", "status": "ok"},
                {"name": "backup_reference", "status": "ok"},
                {"name": "workspace_snapshot", "status": "ok"},
                {"name": "object_inventory", "status": "ok"},
                {"name": "operations_tables", "status": "ok"},
                {"name": "privacy_redaction", "status": "ok"},
            ],
            "restored": {
                "workspace": {"projectCount": 1, "workflowTemplateCount": 3, "uploadJobCount": 0},
                "storage": {"objectCount": 2, "totalObjectBytes": 128},
                "operations": {"accountCount": 1, "auditEventCount": 2, "jobCount": 3, "usageEventCount": 4},
            },
            "privacy": {
                "includesRawTranscript": False,
                "includesRawAudio": False,
                "includesBearerTokens": False,
                "includesEmailAddresses": False,
                "includesGeneratedArtifacts": False,
                "includesLocalPaths": False,
            },
        },
    }


def run_self_test() -> None:
    env = _passing_env()
    config = load_config(env)
    calls: list[tuple[str, str, dict[str, str], dict[str, Any] | None]] = []
    payloads = _fake_payloads(config)

    def fake_request(
        method: str,
        url: str,
        headers: dict[str, str],
        payload: dict[str, Any] | None,
        timeout_seconds: float,
    ) -> tuple[int, dict[str, Any]]:
        parsed = urlparse(url)
        assert parsed.scheme == "https"
        assert parsed.hostname == "api.ideaforge.app"
        assert timeout_seconds == config.timeout_seconds
        if parsed.path != "/health":
            assert headers.get("Authorization") == f"Bearer {config.bearer_token}"
            assert headers.get("X-IdeaForge-Workspace-ID") == config.workspace_id
        calls.append((method, parsed.path, headers, payload))
        response = payloads[(method, parsed.path)]
        if method == "POST":
            assert payload == {
                "backupGeneratedAt": "2026-07-02T17:00:00Z",
                "schemaVersion": "2026_07_01_002_async_workflow_jobs",
            }
        return 200, response

    report = run_deployed_smoke(config, requester=fake_request)
    assert report["status"] == "ready"
    assert len(calls) == 6
    serialized = json.dumps(report, sort_keys=True)
    assert config.bearer_token not in serialized
    assert config.workspace_id not in serialized
    assert config.base_url not in serialized
    assert "builder@example.invalid" not in serialized
    assert "https://" not in serialized

    negative_env_cases = {
        "http": {"IDEAFORGE_BACKEND_PUBLIC_BASE_URL": "http://api.ideaforge.app"},
        "localhost": {"IDEAFORGE_BACKEND_PUBLIC_BASE_URL": "https://localhost"},
        "placeholder": {"IDEAFORGE_BACKEND_PUBLIC_BASE_URL": "https://api.example.com"},
        "dev token": {"IDEAFORGE_BACKEND_TOKEN": "dev-token"},
        "local workspace": {"IDEAFORGE_BACKEND_WORKSPACE_ID": "local-dev-workspace"},
        "bad path": {"IDEAFORGE_BACKEND_OPERATIONS_STATUS_PATH": "https://api.ideaforge.app/v1/admin/status"},
        "unknown capability": {"IDEAFORGE_DEPLOYED_BACKEND_REQUIRED_CAPABILITIES": "manage_account,root"},
    }
    for name, override in negative_env_cases.items():
        bad_env = dict(env)
        bad_env.update(override)
        try:
            load_config(bad_env)
        except DeployedBackendSmokeError:
            continue
        raise AssertionError(f"negative env case unexpectedly passed: {name}")

    bad_session = dict(payloads[("GET", config.auth_session_path)])
    bad_session["capabilities"] = ["manage_account"]
    try:
        _validate_session(config, bad_session)
    except DeployedBackendSmokeError:
        pass
    else:
        raise AssertionError("missing session capability unexpectedly passed")

    bad_status = dict(payloads[("GET", config.operations_status_path)])
    bad_status["status"] = "degraded"
    try:
        _validate_status(config, bad_status)
    except DeployedBackendSmokeError:
        pass
    else:
        raise AssertionError("degraded status unexpectedly passed")

    bad_backup = dict(payloads[("GET", config.backup_manifest_path)])
    bad_backup["privacy"] = dict(bad_backup["privacy"])
    bad_backup["privacy"]["includesBearerTokens"] = True
    try:
        _validate_backup("2026_07_01_002_async_workflow_jobs", bad_backup)
    except DeployedBackendSmokeError:
        pass
    else:
        raise AssertionError("leaking backup manifest unexpectedly passed")

    bad_restore = dict(payloads[("POST", config.restore_drill_path)])
    bad_restore["status"] = "failed"
    try:
        _validate_restore("2026_07_01_002_async_workflow_jobs", "2026-07-02T17:00:00Z", bad_restore)
    except DeployedBackendSmokeError:
        pass
    else:
        raise AssertionError("failed restore drill unexpectedly passed")

    print("IdeaForge deployed backend live-smoke self-test passed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a fail-closed IdeaForge deployed backend live smoke.")
    parser.add_argument("--report")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return

    try:
        config = load_config(os.environ)
        report = run_deployed_smoke(config)
    except DeployedBackendSmokeError as error:
        raise SystemExit(f"deployed backend live smoke failed: {error}") from error

    if args.report:
        write_report(report, Path(args.report))
    else:
        print(render_report(report), end="")


if __name__ == "__main__":
    main()
