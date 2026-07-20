#!/usr/bin/env python3
"""Process-level local sync smoke for IdeaForge cross-device workspace sync."""

from __future__ import annotations

import argparse
import copy
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_BACKEND_SCRIPT = ROOT_DIR / "script" / "mock_backend.py"
REPORTS_DIR = ROOT_DIR / "build" / "reports"


class SmokeFailure(RuntimeError):
    pass


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request_json(
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
    expected_status: int | range = range(200, 300),
    timeout: float = 10.0,
) -> tuple[int, dict[str, Any]]:
    body = None
    request_headers = dict(headers or {})
    if payload is not None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    request_headers.setdefault("Accept", "application/json")
    request = Request(url, data=body, headers=request_headers, method=method)

    try:
        with urlopen(request, timeout=timeout) as response:
            status = int(response.status)
            data = response.read()
    except HTTPError as error:
        status = int(error.code)
        data = error.read()
    except URLError as error:
        raise SmokeFailure(f"{method} {url} failed: {error}") from error

    try:
        decoded = json.loads(data.decode("utf-8")) if data else {}
    except json.JSONDecodeError as error:
        raise SmokeFailure(f"{method} {url} returned non-JSON status {status}: {data[:120]!r}") from error

    ok = status in expected_status if isinstance(expected_status, range) else status == expected_status
    if not ok:
        raise SmokeFailure(f"{method} {url} returned HTTP {status}: {decoded}")
    if not isinstance(decoded, dict):
        raise SmokeFailure(f"{method} {url} returned a non-object JSON payload.")
    return status, decoded


def wait_for_backend(base_url: str, process: subprocess.Popen[str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stdout = process.stdout.read() if process.stdout else ""
            stderr = process.stderr.read() if process.stderr else ""
            raise SmokeFailure(
                "Mock backend exited before health check passed.\n"
                f"stdout:\n{stdout}\n"
                f"stderr:\n{stderr}"
            )
        try:
            _, payload = request_json("GET", f"{base_url}/health", timeout=1.0)
            if payload.get("status") == "ok":
                return
        except Exception as error:
            last_error = str(error)
        time.sleep(0.15)
    raise SmokeFailure(f"Mock backend did not become healthy within {timeout:.1f}s. Last error: {last_error}")


def terminate_backend(process: subprocess.Popen[str]) -> tuple[str, str]:
    if process.poll() is None:
        process.terminate()
        try:
            return process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            return process.communicate(timeout=5)
    return process.communicate(timeout=5)


def privacy_scan(label: str, payload: Any, forbidden_literals: list[str]) -> None:
    serialized = json.dumps(payload, sort_keys=True) if not isinstance(payload, str) else payload
    for literal in forbidden_literals:
        if literal and literal in serialized:
            raise SmokeFailure(f"{label} leaked forbidden literal: {literal!r}")
    forbidden_fragments = [
        "Bearer ",
        "raw transcript",
        "Sync E2E transcript",
        "audio/",
        "/Users/",
        "file://",
        "https://accounts.example.test/workspaces/",
    ]
    for fragment in forbidden_fragments:
        if fragment in serialized:
            raise SmokeFailure(f"{label} leaked forbidden fragment: {fragment!r}")


def write_report(report_path: Path, summary: dict[str, Any]) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Local Sync E2E Smoke",
        "",
        f"- Generated at: `{summary['generatedAt']}`",
        f"- Backend URL: `{summary['backendURL']}`",
        f"- Workspace: `{summary['workspaceID']}`",
        f"- Device A accepted revision: `{summary['deviceAAcceptedRevision']}`",
        f"- Device B fetched title: `{summary['deviceBFetchedTitle']}`",
        f"- Stale publish result: `{summary['stalePublishError']}`",
        f"- Audit event types: `{', '.join(summary['auditEventTypes'])}`",
        f"- Privacy scan: `{summary['privacyScan']}`",
        "",
        "## Gate",
        "",
        "Passed. This is local process-level backend sync proof only; it is not physical-device, APNs delivery, deployed backend, or App Store proof.",
        "",
    ]
    report_path.write_text("\n".join(lines), encoding="utf-8")
    report_path.with_suffix(".json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def run_smoke(args: argparse.Namespace) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    report_path = Path(args.report) if args.report else REPORTS_DIR / f"local-sync-e2e-{timestamp}.md"
    port = args.port or find_free_port()
    base_url = f"http://127.0.0.1:{port}"
    bootstrap_token = "sync-e2e-bootstrap-token"
    initial_workspace_id = "local_sync_e2e_bootstrap"
    scoped_workspace_id = "workspace_sync_e2e"
    email = "sync-e2e@example.test"

    with TemporaryDirectory(prefix="ideaforge-sync-e2e-") as temporary_directory:
        state_dir = Path(temporary_directory) / "backend-state"
        env = dict(os.environ)
        env.pop("OPENAI_API_KEY", None)
        process = subprocess.Popen(
            [
                args.python,
                str(args.backend_script),
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
                "--token",
                bootstrap_token,
                "--workspace-id",
                initial_workspace_id,
                "--state-dir",
                str(state_dir),
            ],
            cwd=ROOT_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            wait_for_backend(base_url, process, args.timeout)
            _, unauthorized = request_json(
                "GET",
                f"{base_url}/v1/workspace/snapshot",
                expected_status=401,
                timeout=args.timeout,
            )
            if unauthorized.get("error") != "unauthorized":
                raise SmokeFailure(f"Expected unauthorized fetch to fail closed, got: {unauthorized}")

            _, provisioned = request_json(
                "POST",
                f"{base_url}/v1/accounts/provision",
                headers={
                    "Authorization": f"Bearer {bootstrap_token}",
                    "Idempotency-Key": "sync-e2e-provision",
                },
                payload={
                    "email": email,
                    "workspaceID": scoped_workspace_id,
                    "displayName": "Sync E2E",
                },
                expected_status=201,
                timeout=args.timeout,
            )
            scoped_token = str(provisioned.get("bearerToken", ""))
            if not scoped_token:
                raise SmokeFailure("Provisioning did not return a scoped bearer token.")
            if provisioned.get("workspaceID") != scoped_workspace_id:
                raise SmokeFailure(f"Provisioning returned wrong workspace: {provisioned}")

            auth_headers = {
                "Authorization": f"Bearer {scoped_token}",
                "X-IdeaForge-Workspace-ID": scoped_workspace_id,
            }
            _, session = request_json("GET", f"{base_url}/v1/auth/session", headers=auth_headers, timeout=args.timeout)
            if session.get("workspaceID") != scoped_workspace_id:
                raise SmokeFailure(f"Session workspace mismatch: {session}")
            if "sync_workspace" not in session.get("capabilities", []):
                raise SmokeFailure(f"Session is missing sync capability: {session}")

            _, original_snapshot = request_json(
                "GET",
                f"{base_url}/v1/workspace/snapshot",
                headers=auth_headers,
                timeout=args.timeout,
            )
            original_revision = str(original_snapshot.get("updatedAt", ""))
            if not original_revision:
                raise SmokeFailure("Original snapshot is missing updatedAt.")

            device_a_snapshot = copy.deepcopy(original_snapshot)
            device_a_revision = "2026-07-02T12:00:00Z"
            device_a_snapshot["updatedAt"] = device_a_revision
            projects = device_a_snapshot.get("projects")
            if not isinstance(projects, list) or not projects:
                raise SmokeFailure("Original snapshot is missing projects.")
            projects[0]["title"] = "Local Sync E2E Device A"
            projects[0]["summary"] = "Device A publish must be visible to Device B."
            projects[0]["updatedAt"] = device_a_revision
            _, receipt = request_json(
                "PUT",
                f"{base_url}/v1/workspace/snapshot",
                headers={**auth_headers, "X-IdeaForge-Base-Remote-Updated-At": original_revision},
                payload=device_a_snapshot,
                timeout=args.timeout,
            )
            expected_receipt = {"workspaceID": scoped_workspace_id, "acceptedUpdatedAt": device_a_revision}
            if receipt != expected_receipt:
                raise SmokeFailure(f"Unexpected publish receipt: {receipt}")

            _, device_b_snapshot = request_json(
                "GET",
                f"{base_url}/v1/workspace/snapshot",
                headers=auth_headers,
                timeout=args.timeout,
            )
            fetched_title = device_b_snapshot["projects"][0]["title"]
            if fetched_title != "Local Sync E2E Device A":
                raise SmokeFailure(f"Device B did not fetch Device A title: {fetched_title}")
            if device_b_snapshot.get("updatedAt") != device_a_revision:
                raise SmokeFailure(f"Device B did not fetch Device A revision: {device_b_snapshot.get('updatedAt')}")

            stale_snapshot = copy.deepcopy(device_b_snapshot)
            stale_snapshot["updatedAt"] = "2026-07-02T12:05:00Z"
            stale_snapshot["projects"][0]["title"] = "Stale Device B Edit"
            _, stale_result = request_json(
                "PUT",
                f"{base_url}/v1/workspace/snapshot",
                headers={**auth_headers, "X-IdeaForge-Base-Remote-Updated-At": original_revision},
                payload=stale_snapshot,
                expected_status=409,
                timeout=args.timeout,
            )
            if stale_result.get("error") != "workspace_revision_conflict":
                raise SmokeFailure(f"Expected workspace revision conflict, got: {stale_result}")
            if stale_result.get("currentUpdatedAt") != device_a_revision:
                raise SmokeFailure(f"Conflict did not report current revision: {stale_result}")

            _, audit = request_json("GET", f"{base_url}/v1/audit/events", headers=auth_headers, timeout=args.timeout)
            event_types = [event.get("type") for event in audit.get("events", [])]
            if "account_provisioned" not in event_types or "workspace_snapshot_published" not in event_types:
                raise SmokeFailure(f"Missing expected audit events: {event_types}")
            publish_events = [event for event in audit.get("events", []) if event.get("type") == "workspace_snapshot_published"]
            publish_payload = publish_events[-1].get("payload", {}) if publish_events else {}
            if publish_payload.get("projectCount") != 1 or publish_payload.get("updatedAt") != device_a_revision:
                raise SmokeFailure(f"Publish audit payload is not aggregate-only as expected: {publish_payload}")

            stdout, stderr = terminate_backend(process)
            forbidden_literals = [bootstrap_token, scoped_token, email, str(state_dir)]
            privacy_scan("backend stdout", stdout, forbidden_literals)
            privacy_scan("backend stderr", stderr, forbidden_literals)
            privacy_scan("audit events", audit, forbidden_literals)
            privacy_scan("publish audit payload", publish_payload, forbidden_literals)

            summary = {
                "generatedAt": datetime.now(timezone.utc).isoformat(),
                "backendURL": base_url,
                "workspaceID": scoped_workspace_id,
                "deviceAAcceptedRevision": device_a_revision,
                "deviceBFetchedTitle": fetched_title,
                "stalePublishError": stale_result.get("error"),
                "auditEventTypes": event_types,
                "privacyScan": "passed",
                "reportPath": str(report_path),
            }
            write_report(report_path, summary)
            print(f"Local sync E2E smoke passed: {report_path}")
            return report_path
        finally:
            if process.poll() is None:
                terminate_backend(process)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a local process-level IdeaForge sync E2E smoke.")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--backend-script", type=Path, default=DEFAULT_BACKEND_SCRIPT)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--report", default="")
    args = parser.parse_args()
    try:
        run_smoke(args)
    except SmokeFailure as error:
        print(f"Local sync E2E smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
