# Community backend self-hosting

`script/mock_backend.py` is a dependency-free integration server for one operator and one workspace. It supports the client contract, persistent local state, mock AI responses, optional OpenAI calls, scoped capabilities, usage responses, and development billing fixtures.

It is not a production hosted backend.

## Security boundary

The server defaults to `127.0.0.1`. Keep that default unless a trusted private network supplies TLS and access control. The server uses one configured bearer token and workspace identifier. It does not provide tenant isolation, user accounts, password reset, rate limiting, abuse controls, secret rotation, TLS, a durable worker queue, managed database operations, or high availability.

Do not place it behind a public DNS name or use it for unrelated users. The production preflight scripts document required contracts; passing those checks does not add the missing infrastructure.

## Start a local instance

Choose a random token and a dedicated state directory outside the repository when retaining real data:

```bash
python3 script/mock_backend.py \
  --host 127.0.0.1 \
  --port 8765 \
  --token 'replace-with-a-random-local-token' \
  --workspace-id 'personal-workspace' \
  --state-dir "$PWD/.local/backend"
```

The development defaults shown in the README are public fixtures. Do not reuse `dev-token` for private data.

Configure the clients with the base URL, matching workspace ID, bearer token, and endpoint paths listed in [backend-contract.md](backend-contract.md). Store the token through the app settings so the client writes it to Keychain.

## State and backups

The server writes:

```text
<state-dir>/
  workspace.json
  backend.db
  audit.jsonl
  objects/
```

`workspace.json` contains workspace content. `objects/` may contain uploaded audio. `backend.db` contains jobs, usage, and migration state. `audit.jsonl` contains redacted audit events.

Stop the process before copying the state directory. Encrypt backup media, restrict file permissions, and test restoration into a separate directory. A filesystem copy taken during writes may contain mismatched files. The community server supplies no backup scheduler, encryption-at-rest service, retention engine, or remote restore procedure.

Run the migration gate before starting a copied or upgraded state directory:

```bash
script/migrate_backend.py --state-dir .local/backend --dry-run
script/migrate_backend.py --state-dir .local/backend
```

The migration tool refuses an unknown future schema version.

## Optional OpenAI provider

You may bring your own OpenAI API key for transcription and workflow execution:

```bash
OPENAI_API_KEY='your-key' python3 script/mock_backend.py \
  --host 127.0.0.1 \
  --token 'replace-with-a-random-local-token' \
  --workspace-id 'personal-workspace' \
  --state-dir "$PWD/.local/backend" \
  --transcription-provider openai \
  --workflow-provider openai \
  --openai-api-key-env OPENAI_API_KEY
```

The backend sends uploaded audio and workflow inputs to the configured provider. Review the provider's retention, regional processing, and account terms. The process reads the key from the named environment variable and must not log or persist it. Use a scoped key and rotate it after suspected exposure.

## Billing and account routes

Fixture billing exists for deterministic tests. It is not a payment system. The iPhone app's production StoreKit path requires a service that validates Apple transaction evidence, owns entitlement state, and handles account lifecycle. The direct-download Mac app expects the backend to return HTTPS plan-management and deletion URLs after session validation.

Do not claim paid accounts, production entitlements, or an account portal from this community server. Operators who add those features become responsible for authentication, authorization, privacy notices, deletion, billing support, taxes, and regional law.

## Production replacement checklist

A service for multiple users needs separate, reviewed infrastructure for:

- User and service authentication, workspace authorization, tenant isolation, and audit access.
- TLS, managed secrets, encrypted object storage, a production database, migrations, queues, rate limits, monitoring, backups, restore drills, and incident response.
- Provider policy, data deletion, account management, billing validation, and support.

The repository includes fail-closed preflight and live-check scripts for some of these contracts. They report evidence; they do not deploy or operate the service.
