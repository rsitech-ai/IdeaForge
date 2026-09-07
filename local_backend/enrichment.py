"""Repair durable recording-enrichment work after backend upgrades or restarts."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from .jobs import JobQueue, JobRecord
from .recordings import RecordingReceipt, RecordingStore
from .workspaces import WorkspaceStore


def _nonempty_string(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    return normalized or None


def pending_recording_enrichment_requests(
    snapshot: object,
    stored_recordings: tuple[RecordingReceipt, ...],
) -> tuple[dict[str, Any], ...]:
    """Select exact stored recordings whose canonical state still awaits enrichment."""
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("projects"), list):
        return ()

    stored_by_id = {receipt.recording_id: receipt for receipt in stored_recordings}
    requests: list[dict[str, Any]] = []
    seen_recording_ids: set[str] = set()
    for project in snapshot["projects"]:
        if not isinstance(project, dict) or not isinstance(project.get("recordings"), list):
            continue
        project_id = _nonempty_string(project.get("id"))
        if project_id is None:
            continue
        for recording in project["recordings"]:
            if not isinstance(recording, dict) or recording.get("syncStatus") != "uploaded":
                continue
            recording_id = _nonempty_string(recording.get("id"))
            idea_project_id = _nonempty_string(recording.get("ideaProjectID"))
            object_key = _nonempty_string(recording.get("audioObjectKey"))
            if (
                recording_id is None
                or idea_project_id != project_id
                or object_key is None
                or recording_id in seen_recording_ids
            ):
                continue
            receipt = stored_by_id.get(recording_id)
            if receipt is None or str(receipt.storage_relative_path) != object_key:
                continue
            seen_recording_ids.add(recording_id)
            requests.append(
                {
                    "recordingID": recording_id,
                    "ideaProjectID": project_id,
                    "objectKey": object_key,
                    "byteCount": receipt.byte_count,
                    "sha256": receipt.sha256,
                }
            )
    return tuple(sorted(requests, key=lambda request: request["recordingID"]))


def reconcile_recording_enrichment_jobs(
    *,
    workspace_id: str,
    workspaces: WorkspaceStore,
    recordings: RecordingStore,
    jobs: JobQueue,
    now: datetime,
) -> tuple[JobRecord, ...]:
    """Idempotently restore missing enrichment jobs from canonical durable state."""
    snapshot = workspaces.load(workspace_id)
    requests = pending_recording_enrichment_requests(
        snapshot,
        recordings.list_receipts(workspace_id),
    )
    return tuple(
        jobs.enqueue(
            workspace_id,
            "recording_enrichment",
            request["recordingID"],
            request,
            now,
        )
        for request in requests
    )
