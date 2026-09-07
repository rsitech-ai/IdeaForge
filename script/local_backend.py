#!/usr/bin/env python3
"""Administrative and service entry point for the IdeaForge local backend."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
from datetime import UTC, datetime
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.auth import DeviceAuthorizer, PairingService
from local_backend.config import LocalBackendConfig, LocalBackendConfigError
from local_backend.database import LocalBackendDatabase
from local_backend.enrichment import reconcile_recording_enrichment_jobs
from local_backend.http_service import LocalBackendApplication, create_http_server
from local_backend.jobs import JobQueue
from local_backend.recordings import RecordingStore
from local_backend.rate_limits import PersistentRateLimiter
from local_backend.workspaces import WorkspaceStore


def _json_line(payload: dict[str, object], *, stream=sys.stdout) -> None:
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")), file=stream, flush=True)


def _runtime(config: LocalBackendConfig):
    database = LocalBackendDatabase(config.database_path)
    database.migrate()
    workspaces = WorkspaceStore(database, body_limit_bytes=config.workspace_body_limit_bytes)
    workspaces.create(config.workspace_id, datetime.now(UTC))
    pairing = PairingService(database, config.workspace_id)
    recordings = RecordingStore(
        database,
        config.data_root,
        maximum_bytes=config.recording_body_limit_bytes,
    )
    jobs = JobQueue(database, maximum_concurrent=1)
    reconcile_recording_enrichment_jobs(
        workspace_id=config.workspace_id,
        workspaces=workspaces,
        recordings=recordings,
        jobs=jobs,
        now=datetime.now(UTC),
    )
    application = LocalBackendApplication(
        database=database,
        workspace_id=config.workspace_id,
        pairing=pairing,
        authorizer=DeviceAuthorizer(database),
        workspaces=workspaces,
        recordings=recordings,
        jobs=jobs,
        rate_limiter=PersistentRateLimiter(database),
        allowed_cidrs=config.allowed_cidrs,
    )
    return database, workspaces, pairing, application


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="IdeaForge production-local backend")
    parser.add_argument("--config", type=Path, help="Owner-only JSON runtime configuration")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("initialize", help="Create or migrate local backend state")
    subparsers.add_parser("check-readiness", help="Check content-free database readiness")
    pairing = subparsers.add_parser(
        "create-pairing-code",
        help="Create a single-use five-minute device pairing code",
    )
    pairing.add_argument("device_label")
    subparsers.add_parser("list-devices", help="List paired device identifiers and revocation state")
    revoke = subparsers.add_parser("revoke-device", help="Revoke one paired device")
    revoke.add_argument("device_id")
    subparsers.add_parser("serve", help="Serve the configured private-LAN HTTPS endpoint")
    return parser


def _bonjour_arguments(port: int) -> list[str]:
    return [
        "/usr/bin/dns-sd",
        "-R",
        "IdeaForge Local Backend",
        "_ideaforge._tcp",
        "local.",
        str(port),
        "version=1",
        "tls=1",
    ]


def _serve(config: LocalBackendConfig, application: LocalBackendApplication) -> int:
    server = create_http_server(
        config.bind_host,
        config.port,
        application,
        certificate_path=config.tls_certificate_path,
        private_key_path=config.tls_private_key_path,
    )
    try:
        bonjour = subprocess.Popen(
            _bonjour_arguments(server.server_address[1]),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        server.server_close()
        raise

    def stop(_signal_number: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    _json_line({"status": "serving", "port": server.server_address[1]})
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        bonjour.terminate()
        try:
            bonjour.wait(timeout=3)
        except subprocess.TimeoutExpired:
            bonjour.kill()
            bonjour.wait(timeout=3)
    return 0


def main(arguments: list[str] | None = None) -> int:
    args = _parser().parse_args(arguments)
    try:
        environment: dict[str, str] = {}
        if args.config is not None:
            config_candidate = args.config.expanduser()
            if config_candidate.is_symlink():
                raise LocalBackendConfigError("Runtime configuration is unavailable")
            config_path = config_candidate.resolve()
            if not config_path.is_file():
                raise LocalBackendConfigError("Runtime configuration is unavailable")
            payload = json.loads(config_path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict) or not all(
                isinstance(key, str) and isinstance(value, str) for key, value in payload.items()
            ):
                raise LocalBackendConfigError("Runtime configuration is invalid")
            environment.update(payload)
        environment.update(
            (key, value) for key, value in os.environ.items() if key.startswith("IDEAFORGE_LOCAL_BACKEND_")
        )
        config = LocalBackendConfig.load(environment)
        database, _, pairing, application = _runtime(config)
        if args.command == "initialize":
            _json_line({"status": "initialized"})
            return 0
        if args.command == "check-readiness":
            ready = application.ready()
            _json_line({"status": "ready" if ready else "not_ready"})
            return 0 if ready else 1
        if args.command == "create-pairing-code":
            code = pairing.create_code(args.device_label, datetime.now(UTC))
            _json_line(
                {
                    "deviceLabel": " ".join(args.device_label.split()),
                    "pairingCode": code.value,
                    "expiresAt": code.expires_at.isoformat(timespec="seconds").replace("+00:00", "Z"),
                }
            )
            return 0
        if args.command == "list-devices":
            devices = DeviceAuthorizer(database).list_devices(config.workspace_id)
            _json_line(
                {
                    "devices": [
                        {"deviceID": device.device_id, "label": device.label, "revoked": device.revoked}
                        for device in devices
                    ]
                }
            )
            return 0
        if args.command == "revoke-device":
            revoked = DeviceAuthorizer(database).revoke(args.device_id, datetime.now(UTC))
            _json_line({"status": "revoked" if revoked else "not_found"})
            return 0 if revoked else 1
        if args.command == "serve":
            return _serve(config, application)
        return 2
    except (LocalBackendConfigError, json.JSONDecodeError):
        _json_line(
            {"error": "configuration_error", "detail": "Local backend configuration is invalid."},
            stream=sys.stderr,
        )
        return 2
    except (OSError, RuntimeError, ValueError):
        _json_line(
            {"error": "runtime_error", "detail": "Local backend operation failed."},
            stream=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
