# IdeaForge Backend Contract

The production app is backend-first. The backend owns object storage, workspace
snapshots, AI orchestration, usage limits, and future integrations. Client apps
store only the base URL, endpoint paths, and a Keychain-held bearer token.
Each configured backend request is scoped by an explicit workspace identifier.

## Local Mock

Run the dependency-free local backend:

```bash
python3 script/mock_backend.py --port 8765 --token dev-token --workspace-id local-dev-workspace --state-dir .local/backend
```

Startup logs print an auth-token fingerprint and a configured-state marker only;
they must not echo bearer tokens or local state paths. To prove the local backend
sync contract as a process-level smoke, run:

```bash
script/run_local_sync_e2e.py
```

That smoke starts the backend on an ephemeral localhost port, provisions a
workspace-scoped session, publishes a device-A workspace snapshot, fetches it
from a device-B perspective, verifies stale publish conflict handling, and scans
reviewed startup/audit output for token, email, path, object-key, transcript, or
private account URL leakage.

Backend startup runs through the same explicit SQLite migration gate exposed by:

```bash
script/migrate_backend.py --state-dir .local/backend --dry-run --report build/reports/backend-migration-dry-run.md
script/migrate_backend.py --state-dir .local/backend --report build/reports/backend-migration.md
```

The migration gate is idempotent, verifies required tables and columns, records
the applied schema contract in `schema_migrations`, writes reports using a
state-directory fingerprint instead of raw local paths, and fails closed when it
finds a migration version that is not in the local migration manifest. The
production verifier also runs `script/migrate_backend.py --self-test`, which
proves dry-run, apply, idempotent re-run, report redaction, and unknown-future
migration refusal. This is repo-side local database proof only; it is not a
deployed production database or hosted migration service.

Production launch configuration is guarded by a separate fail-closed preflight:

```bash
script/production_backend_preflight.py --dry-run-migrations --report build/reports/production-backend-preflight.md
```

The preflight requires `IDEAFORGE_BACKEND_ENV=production`, an HTTPS non-local
and non-placeholder `IDEAFORGE_BACKEND_PUBLIC_BASE_URL`, a non-development
`IDEAFORGE_BACKEND_TOKEN`, a non-local workspace ID, an absolute state
directory, OpenAI transcription/workflow providers, signed-data App Store JWS
verification, an existing `APP_STORE_ROOT_CA_PEM` PEM file, and an
`OPENAI_API_KEY`. Reports include only fingerprints and provider mode labels;
they do not print bearer tokens, API keys, local state paths, account URLs,
object keys, or transcripts. This is deployability/configuration proof only; it
does not replace hosted auth, managed database, encrypted object storage, job
queue, monitoring, or App Store Server API deployment.

Production database readiness is guarded by:

```bash
script/check_production_database.py --report build/reports/production-database-readiness.md
script/check_production_database.py --self-test
```

The database gate requires a Postgres/PostgreSQL `IDEAFORGE_DATABASE_URL` with a
non-local host, non-default username/database, password, and `sslmode=require`
or `sslmode=verify-full`; `IDEAFORGE_DATABASE_SCHEMA_VERSION` matching the
current backend migration manifest; a reviewed migration mode
(`managed-lock` or `manual-reviewed`); HTTPS backup-manifest, restore-drill, and
metrics URLs; backup retention between 7 and 3660 days; and a restore drill age
window between 1 and 720 hours. The production backend preflight consumes this
same gate, so production backend launch cannot pass without the database
contract. Reports include only fingerprints and aggregate readiness labels; they
must not include raw database URLs, credentials, endpoint URLs, transcripts, or
artifacts. This is production database configuration proof only. A managed
database instance, live migrations, backup media, restore execution, monitoring,
and operator drill evidence remain external production blockers until proven
with a credentialed deployment.

Deployed backend live proof is guarded by:

```bash
script/check_deployed_backend.py --report build/reports/deployed-backend-live.md
```

The deployed-backend checker requires the real
`IDEAFORGE_BACKEND_PUBLIC_BASE_URL`, workspace-scoped `IDEAFORGE_BACKEND_TOKEN`,
and `IDEAFORGE_BACKEND_WORKSPACE_ID`. It refuses HTTP, localhost, placeholder
hosts, local tokens, fixture workspaces, malformed endpoint paths, missing
required capabilities, degraded operations status, mismatched schema versions,
privacy-leaking backup/metrics/restore payloads, and failed restore drills. It
performs only `/health`, scoped auth/session, operations status, backup
manifest, operations metrics, and restore-drill calls, then writes a report with
host/workspace/token fingerprints and aggregate counts only. It must pass
against the deployed backend before backend hosting, monitoring, backup/restore,
or operational readiness can be called live-proven.

Live OpenAI provider proof is guarded separately by:

```bash
script/check_live_ai_provider.py --send --report build/reports/live-ai-provider.md
```

The live provider checker requires a production-looking `OPENAI_API_KEY`, an
absolute `IDEAFORGE_LIVE_AI_TRANSCRIPTION_AUDIO_PATH` pointing at a short
approved audio fixture, and explicit `--send` before any provider traffic is
sent. It reuses the backend's OpenAI transcription and Responses workflow
adapters, posts one audio transcription request, posts one `store: false`
Responses request with a strict `text.format` JSON schema, validates the
returned transcript and workflow artifact shape, and writes only model names,
endpoint fingerprints, audio/key fingerprints, and aggregate counts. It does not
replace deployed worker/job-queue proof; it proves only live OpenAI credential
and provider response-contract readiness.

App Store Server API credential proof is guarded separately by:

```bash
script/check_app_store_server_api.py --send --report build/reports/app-store-server-api-live.md
```

The App Store Server API checker requires `APP_STORE_SERVER_ENVIRONMENT`,
`APP_STORE_ISSUER_ID`, `APP_STORE_KEY_ID`,
`APP_STORE_PRIVATE_KEY_P8_PATH`, `APP_STORE_TRANSACTION_ID`, and the release
iOS bundle ID. It signs an ES256 JWT for Apple's transaction-info API, refuses
sandbox unless `--allow-sandbox` is explicitly supplied, requires `--send`
before any Apple request is made, validates the returned signed transaction
payload against the configured transaction, original transaction, bundle,
environment, and expected Pro product IDs, and writes only fingerprints. This
proves live App Store Server API credentials and transaction lookup wiring. It
does not replace the deployed entitlement service, deployed App Store root-CA
configuration, durable usage decisions, App Store Connect product/account
setup, or physical StoreKit purchase/restore proof.

APNs sender readiness is guarded by a separate fail-closed check:

```bash
script/check_apns_delivery.py --report build/reports/apns-delivery-readiness.md
script/check_apns_delivery.py --send --report build/reports/apns-delivery-live.md
```

The APNs check requires production token-auth settings (`APNS_TEAM_ID`,
`APNS_KEY_ID`, absolute `APNS_AUTH_KEY_P8_PATH`), the release iOS bundle ID,
`APNS_ENVIRONMENT=production`, a real `APNS_DEVICE_TOKEN`, and a non-local
`IDEAFORGE_APNS_WORKSPACE_ID`. It builds the same silent
`content-available` payload shape consumed by `RemotePushNotificationPayloadParser`
and sends it with `apns-push-type: background` and priority `5` only when
`--send` is supplied. Reports include fingerprints only. APNs acceptance proves
the sender/token-auth path, not foreground device handling; the latter still
requires physical iPhone logs that show the app received and processed the push.

Set iOS/macOS backend settings to:

```text
Base URL: http://127.0.0.1:8765
Bearer token: dev-token
Workspace ID: local-dev-workspace
Auth session path: /v1/auth/session
Upload path: /v1/recordings/upload
Sync path: /v1/workspace/snapshot
Object metadata path: /v1/objects/metadata
Transcription path: /v1/ai/transcriptions
Transcription job status path: /v1/ai/transcription-jobs
Workflow path: /v1/ai/workflows/run
Workflow job status path: /v1/ai/workflow-jobs
Usage path: /v1/usage/summary
Billing reconciliation path: /v1/billing/app-store/reconcile
Operations status path: /v1/admin/status
Backup manifest path: /v1/admin/backup-manifest
Restore drill path: /v1/admin/restore-drill
Operations metrics path: /v1/admin/metrics
```

The local backend is for development smoke only. It persists a seeded
`workspace.json`, uploaded audio objects, SQLite metadata, and `audit.jsonl`
under `--state-dir`. In default mock mode it does not perform real
transcription, storage encryption, payment processing, or integrations. Billing
reconciliation is stricter: the server defaults to
`--app-store-jws-verification signed-data`, which fails closed unless submitted
transaction JWS evidence includes an Apple-style `x5c` certificate chain and the
backend can verify the ES256 signature against the trusted root certificate path
from `APP_STORE_ROOT_CA_PEM`.

Use fixture billing evidence only for deterministic local development:

```bash
python3 script/mock_backend.py \
  --port 8765 \
  --token dev-token \
  --workspace-id local-dev-workspace \
  --state-dir .local/backend \
  --app-store-jws-verification fixture
```

For production-style signed-data verification, provide the trusted Apple root CA
PEM path:

```bash
APP_STORE_ROOT_CA_PEM=/path/to/AppleRootCA-G3.pem python3 script/mock_backend.py \
  --port 8765 \
  --token dev-token \
  --workspace-id local-dev-workspace \
  --state-dir .local/backend \
  --app-store-jws-verification signed-data
```

Fixture mode is never release proof. It exists so tests can exercise the client
and entitlement flow without contacting Apple or embedding real transaction
payloads.

For a credentialed provider smoke, run the same backend with OpenAI
transcription and workflow structured-output enabled:

```bash
OPENAI_API_KEY=sk-... python3 script/mock_backend.py \
  --port 8765 \
  --token dev-token \
  --workspace-id local-dev-workspace \
  --state-dir .local/backend \
  --transcription-provider openai \
  --workflow-provider openai \
  --openai-api-key-env OPENAI_API_KEY \
  --openai-transcription-model gpt-4o-transcribe \
  --openai-workflow-model gpt-5.4-mini
```

In OpenAI mode, `/v1/ai/transcriptions` reads the uploaded audio object from
backend storage and sends a multipart `POST /v1/audio/transcriptions` request
with `file`, `model`, `response_format=json`, language hint, and prompt context.
If the configured API key is missing, storage is unavailable, provider output is
empty, or the request requires multi-chunk media slicing that this local backend
does not implement, the route fails closed instead of returning a mock
transcript. API keys are read from the named environment variable only and are
not printed, persisted, or included in audit events.

With `--workflow-provider openai`, `/v1/ai/workflows/run` validates the client
output contract, then sends `POST /v1/responses` with `store: false` and
`text.format: { type: "json_schema", strict: true, schema: ... }` using the
client-generated workflow schema. The provider response must complete and return
JSON with an `artifacts` array; refusal, incomplete status, empty output,
invalid JSON, or missing artifacts fail closed before any workflow job is marked
complete. Completed artifacts still pass through the app-side
`WorkflowOutputContractValidator` before persistence. API keys are read from the
named environment variable only and are not printed, persisted, or included in
audit events. The local backend still is not a deployed worker queue or
production auth/storage service.

State layout:

```text
.local/backend/
  workspace.json
  backend.db
  audit.jsonl
  objects/
    audio/<idea-id>/<recording-id>.m4a
```

`backend.db` stores local development metadata:

```text
objects       uploaded object keys, byte counts, content types, and availability metadata
jobs          completed upload/transcription/workflow job records
usage_events usage metrics for storage bytes, transcription seconds, workflow runs, and artifacts
transcription_results completed async transcription payloads, referenced by job ID
workflow_results completed async workflow artifact payloads, referenced by job ID
accounts      workspace-bound local account rows and provisioned session metadata
schema_migrations applied local backend schema contract versions
```

## Authentication

All app endpoints require:

```text
Authorization: Bearer <token>
X-IdeaForge-Workspace-ID: <workspace-id>
```

The local mock defaults to token `dev-token` and workspace ID
`local-dev-workspace`. It returns `401` for missing/invalid bearer tokens and
`403` for missing/invalid workspace scope. Account-provisioned workspace tokens
are accepted only with their matching `X-IdeaForge-Workspace-ID`; publish
receipts return the scoped workspace ID from the request.

## `GET /v1/auth/session`

Response:

```json
{
  "userID": "user_123",
  "email": "builder@example.com",
  "workspaceID": "workspace_123",
  "account": {
    "id": "acct_123",
    "planName": "Pro",
    "planStatus": "active"
  },
  "capabilities": [
    "upload_recordings",
    "sync_workspace",
    "run_ai_workflows",
    "reconcile_billing",
    "manage_account"
  ],
  "accountPortalURL": "https://accounts.example.com/ideaforge",
  "accountDeletionURL": "https://accounts.example.com/ideaforge/delete"
}
```

The app uses this endpoint to validate that the saved bearer token belongs to
the configured workspace and account before presenting backend readiness as
validated. Production backends should issue short-lived tokens through a real
auth provider, bind workspace access server-side, and return only capability
grants that the current account is allowed to use. Clients must not log tokens,
private account URLs, or user identifiers.

The client and mock backend both treat capability grants as route guards:

```text
upload_recordings  -> POST /v1/recordings/upload
sync_workspace     -> GET /v1/workspace/snapshot, PUT /v1/workspace/snapshot
run_ai_workflows   -> GET /v1/objects/metadata, POST /v1/ai/transcriptions, GET /v1/ai/transcription-jobs/<job-id>, POST /v1/ai/workflows/run, GET /v1/ai/workflow-jobs/<job-id>
reconcile_billing  -> POST /v1/billing/app-store/reconcile
manage_account     -> GET /v1/usage/summary, GET /v1/jobs, GET /v1/audit/events, account deletion handoff
manage_account     -> GET /v1/admin/status, GET /v1/admin/backup-manifest, GET /v1/admin/metrics
```

The local mock returns `403 capability_forbidden` when a scoped token is valid
but the session lacks the route capability. Production backends must enforce the
same checks server-side; client-side gating is a usability and safety layer, not
an authorization substitute.

## `GET /v1/workspace/snapshot`

Returns the current workspace snapshot for the configured workspace. Clients may
include `since=<iso8601-date>` for efficient production implementations, but the
mock backend currently returns the full scoped snapshot. `since` is the last
remote revision the client fetched or accepted, not the client's local workspace
clock. The app validates identifiers and relationships before applying only
newer remote snapshots. Non-overlapping local and remote projects are merged and
published in the same synchronization pass; concurrent edits to the same
project stop for explicit review.

## `PUT /v1/workspace/snapshot`

Publishes the local workspace snapshot to the configured backend. This is the
repo-side contract for making iPhone/Mac edits available to other signed-in
devices; it does not replace physical-device sync proof or a deployed backend.

Request headers:

```text
Authorization: Bearer <token>
X-IdeaForge-Workspace-ID: <workspace-id>
X-IdeaForge-Base-Remote-Updated-At: <last accepted remote WorkspaceState.updatedAt>
Content-Type: application/json
Accept: application/json
```

The request body is the shared portion of `WorkspaceState` encoded as JSON. Before
encoding, clients remove device-local audio paths and upload jobs and reset local
reachability, queue, activity, failure, conflict, and publish-receipt fields.
Recording object keys and shared processing state remain in the payload; a local
file status is represented as uploaded when an object key exists and missing
otherwise. A client applying the response restores matching audio paths, file
statuses, upload jobs, and local health fields from its own persisted state.

Clients pull before push and send `X-IdeaForge-Base-Remote-Updated-At` when they
have previously fetched or accepted a remote revision. Production backends must
compare that value to the current stored workspace revision and return `409` or
`412` when another device has published a newer snapshot. On stale-base
rejection, the app fetches the current remote snapshot and enters the same
review-before-merge conflict flow instead of silently overwriting either side.
The client records both the server's accepted revision and the local
`WorkspaceState.updatedAt` that was sent; a local edit made while the request is
in flight therefore remains eligible for a later publish even if the server
assigns a newer timestamp.

Successful response:

```json
{
  "workspaceID": "workspace_123",
  "acceptedUpdatedAt": "2026-07-02T00:00:00Z"
}
```

The local mock persists the submitted workspace and writes only aggregate audit
metadata: project count, upload-job count, workflow-template count, and
`updatedAt`. It must not copy raw transcripts, generated artifact markdown,
local audio paths, object keys, bearer tokens, or private account values into
job/audit evidence.

## `GET /v1/admin/status`

Response:

```json
{
  "status": "ready",
  "generatedAt": "2026-07-01T00:00:00Z",
  "schema": {
    "currentVersion": "2026_07_01_002_async_workflow_jobs",
    "appliedMigrations": [
      {
        "version": "2026_07_01_002_async_workflow_jobs",
        "appliedAt": "2026-07-01T00:00:00Z"
      }
    ]
  },
  "checks": [
    {"name": "database", "status": "ok"},
    {"name": "schema_migrations", "status": "ok"},
    {"name": "workspace", "status": "ok"},
    {"name": "object_storage", "status": "ok"}
  ],
  "counts": {
    "accounts": 1,
    "auditEvents": 2,
    "jobs": 3,
    "objects": 2,
    "transcriptionResults": 1,
    "workflowResults": 1,
    "usageEvents": 4
  },
  "tenants": [
    {
      "workspaceID": "workspace_123",
      "accountID": "acct_123",
      "planName": "Free",
      "planStatus": "trialing",
      "capabilitiesCount": 5,
      "createdAt": "2026-07-01T00:00:00Z"
    }
  ]
}
```

This endpoint is an operations readiness contract, not a user data export. It
must be scoped by bearer token and workspace ID, require `manage_account`, and
must never include bearer tokens, email addresses, raw transcripts, raw audio
bytes, raw object paths, or generated artifact markdown. Production backends
should map these checks to real database migration status, object storage
health, tenant/account state, job queue state, and audit availability.

## `GET /v1/admin/metrics`

Response:

```json
{
  "status": "ready",
  "generatedAt": "2026-07-02T08:10:00Z",
  "schemaVersion": "2026_07_01_002_async_workflow_jobs",
  "jobCountsByStatus": {
    "completed": 4,
    "running": 1,
    "failed": 1
  },
  "jobCountsByKind": {
    "recording_upload": 1,
    "transcription": 3,
    "workflow": 2
  },
  "storage": {
    "objectCount": 2,
    "totalObjectBytes": 128
  },
  "usage": [
    {
      "metric": "transcription_seconds",
      "quantity": 90.5
    }
  ],
  "privacy": {
    "includesRawTranscript": false,
    "includesRawAudio": false,
    "includesBearerTokens": false,
    "includesEmailAddresses": false,
    "includesGeneratedArtifacts": false,
    "includesLocalPaths": false
  }
}
```

This endpoint is for monitoring and alerting, not analytics export. It must be
scoped by bearer token and workspace ID, require `manage_account`, and expose
only aggregate counters for jobs, storage, and usage. Production backends should
map these fields to real queue depth, worker health, object-storage totals,
provider usage, and billing/entitlement monitoring. It must not include raw
transcripts, generated artifact markdown, local paths, object keys, bearer
tokens, APNs tokens, private URLs, or email addresses.

## `GET /v1/admin/backup-manifest`

Response:

```json
{
  "generatedAt": "2026-07-01T00:01:00Z",
  "schemaVersion": "2026_07_01_002_async_workflow_jobs",
  "workspace": {
    "projectCount": 1,
    "workflowTemplateCount": 1,
    "uploadJobCount": 0,
    "updatedAt": "2026-07-01T00:00:00Z"
  },
  "storage": {
    "objectCount": 2,
    "totalObjectBytes": 128
  },
  "operations": {
    "accountCount": 1,
    "auditEventCount": 2,
    "jobCount": 3,
    "usageEventCount": 4
  },
  "tenants": [
    {
      "workspaceID": "workspace_123",
      "accountID": "acct_123",
      "planName": "Free",
      "planStatus": "trialing",
      "capabilitiesCount": 5,
      "createdAt": "2026-07-01T00:00:00Z"
    }
  ],
  "privacy": {
    "includesRawTranscript": false,
    "includesRawAudio": false,
    "includesBearerTokens": false,
    "includesEmailAddresses": false,
    "includesGeneratedArtifacts": false
  }
}
```

This manifest is deliberately inventory-only. It is useful for backup planning
and monitoring because it proves counts, schema version, tenant coverage, audit
coverage, and object-storage byte totals without exporting private content. It
does not replace a deployed backup system, deployed encrypted object storage
provider, restore drill, or offsite retention policy.

## `POST /v1/recordings/upload`

Request:

```text
Content-Type: application/octet-stream
Content-Length: <byte-count>
X-IdeaForge-Recording-ID: rec_123
X-IdeaForge-Idea-ID: idea_123
X-IdeaForge-Upload-Job-ID: upload_rec_123
X-IdeaForge-Content-SHA256: <lowercase-hex-sha256>
X-IdeaForge-Attempt: 0
X-IdeaForge-Workspace-ID: workspace_123
```

Body is the compressed audio bytes. Production backends must treat
`X-IdeaForge-Upload-Job-ID` as an idempotency key for interrupted app or
background upload retries. Replays with the same recording ID, idea ID, byte
count, and SHA-256 digest should return the original object key without creating
duplicate storage objects or audit rows; replays with the same upload job ID but
different content must fail closed with a conflict. The client also recovers
stale in-flight `.uploading` jobs after its interrupted-upload timeout and makes
them immediately retryable without deleting local audio.

Response:

```json
{
  "objectKey": "audio/idea_123/rec_123.m4a"
}
```

## `GET /v1/objects/metadata`

Query:

```text
objectKey=audio/idea_123/rec_123.m4a
```

Response:

```json
{
  "objectKey": "audio/idea_123/rec_123.m4a",
  "recordingID": "rec_123",
  "ideaProjectID": "idea_123",
  "byteCount": 123456,
  "contentType": "audio/mp4",
  "createdAt": "2026-06-29T20:00:00Z",
  "isAvailable": true
}
```

Before starting backend transcription, clients fetch metadata for the uploaded
audio object and fail closed unless the object key matches, the object belongs
to the expected recording/project when those fields are present, `byteCount` is
positive, `isAvailable` is true, and the content type is audio-like or
`application/octet-stream`. This prevents provider workers from accepting stale,
empty, unavailable, or cross-project object keys.

## `GET /v1/workspace/snapshot`

Optional query:

```text
since=2026-06-29T20:00:00Z
```

Response is a complete `WorkspaceState` JSON document using the shared Swift
model encoding.

## `POST /v1/ai/transcriptions`

Request:

```json
{
  "recordingID": "rec_123",
  "ideaProjectID": "idea_123",
  "audioObjectKey": "audio/idea_123/rec_123.m4a",
  "audioChunks": [
    {
      "id": "rec_123_chunk_1",
      "audioObjectKey": "audio/idea_123/rec_123.m4a",
      "startSeconds": 0,
      "endSeconds": 42
    }
  ],
  "languageHint": "en",
  "durationSeconds": 42,
  "markerOffsets": [12],
  "hint": "Optional project context"
}
```

`audioChunks` is required even when the uploaded object fits in one chunk. The
client creates bounded chunk windows for long recordings using the uploaded
object key and time offsets, so deployable backends can run provider
transcription in smaller calls without receiving raw local file paths. The local
mock returns `400 invalid_audio_chunks` when chunks are missing, reference a
different object key, leave gaps, are out of order, or do not cover the full
recording duration.

Synchronous response is a `Transcript` JSON document. Long-running backends may
instead return `202 Accepted`:

```json
{
  "jobID": "job_123",
  "status": "queued"
}
```

Clients then poll `GET /v1/ai/transcription-jobs/<job-id>` until the job is
`completed`, `failed`, or the bounded poll limit is reached. Completed responses
include a transcript:

```json
{
  "jobID": "job_123",
  "status": "completed",
  "transcript": {
    "cleanText": "Reviewed transcript text.",
    "segments": [
      {
        "id": "seg_1",
        "startSeconds": 0,
        "endSeconds": 42,
        "text": "Reviewed transcript text.",
        "isMarkedImportant": false
      }
    ],
    "unclearFragments": []
  }
}
```

Failed job responses use structural provider diagnostics:

```json
{
  "jobID": "job_123",
  "status": "failed",
  "code": "provider_timeout",
  "retryable": true
}
```

Clients reject successful synchronous or completed-job transcripts before
persisting them when the transcript has blank clean text, no segments, blank
segment text, invalid segment timing, segment bounds outside the recording
duration, or overlapping/out-of-order segments. Validation messages are
structural and must not echo raw transcript text.

## `POST /v1/ai/workflows/run`

Request:

```json
{
  "template": "<WorkflowTemplate JSON>",
  "project": "<IdeaProject JSON>",
  "outputContract": {
    "version": 1,
    "artifactOutputs": [
      {
        "kind": "prd",
        "label": "PRD",
        "schemaName": "PRDArtifact",
        "requiredFields": [
          {"name": "goals", "valueType": "list", "summary": "Product goals."}
        ]
      }
    ],
    "rubricRequirements": ["actionability", "evidence", "risk_coverage"],
    "structuredOutput": {
      "name": "ideaforge_workflow_output_v1",
      "strict": true,
      "schema": {
        "type": "object",
        "required": ["artifacts"],
        "additionalProperties": false,
        "properties": {
          "artifacts": {
            "type": "array",
            "minItems": 1,
            "items": {
              "type": "object",
              "required": ["id", "kind", "title", "markdown", "version", "createdBy", "createdAt"],
              "additionalProperties": false,
              "properties": {
                "id": {"type": "string"},
                "kind": {"type": "string", "enum": ["prd"]},
                "title": {"type": "string"},
                "markdown": {"type": "string"},
                "version": {"type": "integer"},
                "createdBy": {"type": "string"},
                "createdAt": {"type": "string"}
              }
            }
          }
        }
      }
    }
  }
}
```

The output contract is generated by the client from the workflow template and is included so the backend can configure provider-native structured output, prompt constraints, and validation before returning artifacts. It contains both semantic artifact requirements and a strict JSON-schema-shaped `structuredOutput` contract that constrains the root response, minimum artifact count, and allowed artifact kinds. Codex/tool-handoff workflows also include `handoff_safety` in `rubricRequirements`. The local mock backend rejects missing, non-strict, or mismatched structured-output contracts, reads `artifactOutputs.requiredFields`, and adds missing required sections to generated fixture artifacts, so custom schemas can be smoke-tested without live provider calls. In OpenAI workflow mode, the local backend passes the same strict schema to the Responses API through `text.format` and rejects provider refusal, incomplete status, empty output, invalid JSON, or missing artifacts before creating a completed workflow job. A deployed backend must still run this through a real worker queue and keep client-side validation before persistence.

Synchronous response:

```json
{
  "artifacts": ["<Artifact JSON>"]
}
```

Long-running backends may instead return `202 Accepted`:

```json
{
  "jobID": "job_workflow_123",
  "status": "queued"
}
```

Clients then poll `GET /v1/ai/workflow-jobs/<job-id>` until the job is
`completed`, `failed`, or the bounded poll limit is reached. Completed
responses include artifacts:

```json
{
  "jobID": "job_workflow_123",
  "status": "completed",
  "artifacts": ["<Artifact JSON>"]
}
```

Failed workflow job responses use structural provider diagnostics:

```json
{
  "jobID": "job_workflow_123",
  "status": "failed",
  "code": "provider_timeout",
  "retryable": true
}
```

Client acceptance rule: returned synchronous artifacts and completed-job
artifacts must satisfy the submitted workflow template before they are written
into the app state. The client rejects responses that omit expected artifact
kinds, omit required schema-field headings for the relevant output contracts,
complete without artifacts, time out before completion, or fail the workflow AI
rubric for actionability, evidence, risk coverage, and handoff safety. Rejection
errors contain only contract issue labels, not raw generated artifact content.
The local mock stores completed workflow artifacts in `workflow_results` and
keeps job details/audit events limited to template IDs, project IDs, counts,
artifact kinds, and job IDs.

Prompt regression fixtures live in `Tests/IdeaForgeCoreTests/Fixtures/workflow_prompt_regressions.json`. `swift test` validates those provider-shaped outputs through `WorkflowOutputContractValidator`, giving the repo a deterministic pre-live-AI gate for PRD and Codex handoff prompts.

Non-2xx AI responses may include:

```json
{
  "error": "rate_limit_exceeded",
  "code": "provider_rate_limit",
  "retryable": true
}
```

The client maps AI endpoint failures to status code, normalized error code, and retryability. Raw provider text is not required and should not include user content.

## `GET /v1/audit/events`

Response:

```json
{
  "events": [
    {
      "id": "audit_0",
      "type": "recording_uploaded",
      "createdAt": "2026-06-29T20:00:00Z",
      "payload": {}
    }
  ]
}
```

The local backend appends audit events for recording uploads, transcription
completion, and workflow completion.

## `GET /v1/jobs`

Response:

```json
{
  "jobs": [
    {
      "id": "job_1",
      "kind": "transcription",
      "status": "completed",
      "ideaProjectID": "idea_123",
      "recordingID": "rec_123",
      "workflowTemplateID": null,
      "objectKey": "audio/idea_123/rec_123.m4a",
      "detail": {"durationSeconds": 42},
      "createdAt": "2026-06-29T20:00:00Z",
      "completedAt": "2026-06-29T20:00:00Z"
    }
  ]
}
```

The local backend records completed jobs for uploads, transcriptions, workflow
runs, and App Store billing reconciliation requests. This is a development
stand-in for the production job queue.

## `GET /v1/usage/summary`

Response:

```json
{
  "account": {
    "id": "acct_local_dev",
    "planName": "Pro",
    "planStatus": "active"
  },
  "accountPortalURL": "https://accounts.example.test/ideaforge",
  "accountDeletionURL": "https://accounts.example.test/ideaforge/delete",
  "workspaceID": "local-dev-workspace",
  "usage": [
    {"metric": "audio_bytes_stored", "quantity": 13.0},
    {"metric": "transcription_seconds", "quantity": 17.0},
    {"metric": "workflow_runs", "quantity": 1.0},
    {"metric": "artifacts_generated", "quantity": 2.0}
  ],
  "entitlements": [
    {
      "metric": "transcription_seconds",
      "includedQuantity": 1800.0,
      "usedQuantity": 17.0,
      "remainingQuantity": 1783.0
    }
  ]
}
```

Usage records and entitlements are local development counters only. The app now
fetches and displays this backend-owned account summary, uses the explicit
`accountDeletionURL` for account deletion handoff, and the client plus local mock
both deny exhausted AI entitlements before accepting transcription or workflow
work. Exhausted backend AI requests return a non-retryable `402` response:

```json
{
  "error": "entitlement_exhausted",
  "code": "entitlement_exhausted",
  "metric": "transcription_seconds",
  "retryable": false,
  "remainingQuantity": 0.0
}
```

## `POST /v1/billing/app-store/reconcile`

Request:

```json
{
  "reason": "purchase",
  "transactions": [
    {
      "productID": "com.s1kor.ideaforge.pro.monthly",
      "transactionID": "123",
      "originalTransactionID": "100",
      "appBundleID": "com.s1kor.ideaforge.ios",
      "purchaseDate": "2026-06-29T20:00:00Z",
      "expirationDate": "2026-07-29T20:00:00Z",
      "signedTransactionJWS": "base64url-header.base64url-payload.base64url-signature"
    }
  ]
}
```

`reason` is one of `purchase`, `restore`, or `refresh`. The app builds this
payload from verified StoreKit current-entitlement transactions and sends the
StoreKit/App Store Server API-compatible signed transaction JWS. Before network
submission, the client validates required IDs, bundle ID, sane expiration date,
JWS Compact Serialization shape, ES256 header, and payload claims matching the
transaction metadata. Submission uses the same bearer-token plus
`X-IdeaForge-Workspace-ID` scope as the other backend account calls.

The local backend defaults this route to signed-data verification, not fixture
acceptance. It rejects:

- missing transaction evidence
- malformed JWS compact serialization
- non-ES256 headers
- product, transaction, original transaction, or bundle claim mismatches
- signed-data mode evidence without an Apple-style three-certificate `x5c` chain
- signed-data mode evidence without `APP_STORE_ROOT_CA_PEM`
- unavailable trusted root certificate files
- invalid certificate chains
- invalid ES256 signatures

Only `--app-store-jws-verification fixture` accepts deterministic local fixture
JWS strings after structural/claim checks. Production deployments must run
signed-data mode, configure the trusted Apple root CA path, use real App Store
Connect products, and keep durable entitlement decisions in a deployed account
service. The client and local backend do not log transaction IDs, signed
transaction JWS payloads, bearer tokens, or account URLs; logs/audit rows only
report reconciliation reason, product IDs, transaction counts, and status.

Production still needs real auth/account provisioning, configured App Store
Connect products, durable usage metering, deployed account lifecycle management,
deployed account deletion portal proof, a captured live App Store Server API
`--send` report, and tenant administration before these metrics can drive
commercial quotas outside the local contract. The app code uses StoreKit to load
products, start purchases, restore purchases, refresh active entitlements,
submit transaction evidence for backend reconciliation, open native iOS
subscription management, and open backend-provided account deletion URLs.

## Production Requirements Still Outside The Mock

- deployed encrypted backend object storage
- deployed production database migrations and hosting
- background job queue and retries
- deployed OpenAI transcription worker proof, multi-chunk audio slicing, and deployed structured-output orchestration
- auth/account provisioning
- production launch orchestration around the strict preflight and runtime process
- App Store Connect product setup plus deployed subscription/account lifecycle proof
- captured `script/check_app_store_server_api.py --send` proof, then deployable subscription entitlement service with App Store Server API validation
- production account/workspace-scoped audit and usage meters
- GitHub/Codex/Linear/Notion integrations
