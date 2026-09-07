# IdeaForge Local Backend

The local backend keeps the canonical IdeaForge workspace, device credentials,
recording bytes, and job state on one Mac. It does not require or configure S3,
PostgreSQL, Redis, Docker, a public tunnel, or a hosted service.

Apple Speech transcription and Foundation Models title generation continue to
run in the Apple apps. OpenAI is not required for capture, transcription,
titles, or synchronization. The service starts with OpenAI disabled and the
LaunchAgent does not contain an OpenAI credential or enablement flag.

## Requirements and boundaries

- macOS with Python 3, OpenSSL, `security`, and `launchctl`.
- One operator and one workspace.
- A fixed private-LAN address for the host Mac and a `.local` hostname.
- Owner-only state under `~/Library/Application Support/IdeaForge/LocalBackend`.
- HTTPS only. Do not expose port 8765 through a router or public tunnel.

Repository tests prove the implementation and loopback transport. They do not
prove that an iPhone trusts the local CA, that the selected private address is
reachable, or that the LaunchAgent is installed on a particular Mac.

## Provision TLS

Choose the Mac's LocalHostName from `scutil --get LocalHostName` and append
`.local`. The command below creates a private CA and a 397-day server
certificate. Private keys remain inside the TLS directory with mode `0600`.

```bash
DATA_ROOT="$HOME/Library/Application Support/IdeaForge/LocalBackend"
HOST_NAME="$(scutil --get LocalHostName).local"
python3 script/setup_local_backend_tls.py \
  --tls-root "$DATA_ROOT/tls" \
  --hostname "$HOST_NAME" \
  --install-mac-trust
```

The JSON report contains the server certificate fingerprint, expiry, and path
to `ideaforge-local-ca.mobileconfig`, but no private material. Re-running with
the same hostname validates and reuses the certificate and refreshes that
key-free iPhone profile. A different hostname, incomplete files, a mismatched
key, or an invalid certificate fails closed.

Install only `ideaforge-local-ca.mobileconfig` (or `ca.cert.pem`) on the iPhone
and enable full trust for that root in iOS Certificate Trust Settings. Never export or copy `ca.key.pem` or
`server.key.pem`. Compare the displayed SHA-256 server fingerprint with the
setup report before pairing.

## Install and start

Use the Mac's actual private address, not `0.0.0.0`. Restrict the allowed CIDR
to the current private LAN. The example uses a common `/24`; replace it with the
real network.

```bash
DATA_ROOT="$HOME/Library/Application Support/IdeaForge/LocalBackend"
PLIST="$HOME/Library/LaunchAgents/com.rsitech.ideaforge.local-backend.plist"
HOST_NAME="$(scutil --get LocalHostName).local"
python3 script/install_local_backend.py install \
  --plist-path "$PLIST" \
  --data-root "$DATA_ROOT" \
  --python "$(command -v python3)" \
  --backend-script "$PWD/script/local_backend.py" \
  --workspace-id workspace_rsi \
  --bind-host 192.168.1.10 \
  --allowed-cidrs 192.168.1.0/24,127.0.0.0/8 \
  --tls-cert "$DATA_ROOT/tls/server.cert.pem" \
  --tls-key "$DATA_ROOT/tls/server.key.pem"
```

The installer is idempotent, runs a user LaunchAgent after login, bounds open
files, restarts unexpected exits, advertises `_ideaforge._tcp` on Bonjour, and
keeps logs inside the owner-only data root. It deploys a content-addressed
runtime copy below that root, so removing a source worktree does not break the
service. It never stores a provider key. Check service state and content-free
readiness with:

```bash
launchctl print "gui/$(id -u)/com.rsitech.ideaforge.local-backend"
curl --fail --cacert "$DATA_ROOT/tls/ca.cert.pem" \
  "https://$HOST_NAME:8765/health/ready"
```

After this one-time TLS and LaunchAgent setup, opening the Mac app browses for
`_ideaforge._tcp` on Bonjour when its backend settings are still pristine. A
resolved service is accepted only as a private HTTPS endpoint, saved as the
Local Backend address without enabling sync, and surfaced as ready for explicit
pairing. Existing local or remote settings are never overwritten by discovery.

For a paired configuration, the LaunchAgent owns process start and crash
recovery through `RunAtLoad` and `KeepAlive`. The sandboxed app checks
`/health/ready`; on a connectivity failure or timeout it allows one bounded
LaunchAgent recovery window, checks readiness again, and then runs the normal
workspace synchronization. It does not wait and retry for certificate-trust or
malformed-response failures, because those need corrective setup rather than a
blind retry. The toolbar status opens the same Local Backend settings used for
pairing and diagnostics.

The app revisits unsuccessful supervision every 30 seconds while open. A failed
worker session check clears the ready state and resumes readiness checks; it must
not leave the toolbar claiming the backend is ready during an outage.

Audio can arrive before its canonical recording metadata. Enrichment workers
defer `workspace_recording_missing` for 30 seconds without consuming the three
processing-failure attempts. Actual processing failures retain bounded retries.
Expired leases cannot complete or fail a job, and successful enrichment completion
requires an already-persisted ready recording and transcript at the acknowledged
workspace revision or newer.

### Return synchronization and current limits

While active, the iPhone checks for Mac enrichment every 15 seconds and also
checks on returning to the foreground. Background scheduling is controlled by
iOS; it is not an immediate-delivery guarantee. The iPhone publishes compact
title/status context to the Watch without transcript text. The current context
contains the latest 24 Watch recording updates; older history after a long
disconnection is not yet covered by an incremental catch-up protocol.

New generated titles persist a provider identifier, source recording, SHA-256
of the full source transcript, generation time, and the generated title value.
This describes the generation event, not later manual title edits. Older records
decode without provenance; their origin is not reconstructed or invented.
For long transcripts, only a UTF-8-bounded beginning/end excerpt is sent to the
title model. The complete stored and synchronized transcript is unchanged.
Model availability and output accuracy remain platform-dependent.

The sandboxed Mac app does not install certificates, create the LaunchAgent, or
embed the Python service in its UI process. Those remain explicit one-time
operator actions. It also cannot invoke `launchctl` from the App Sandbox; the
installed LaunchAgent is deliberately responsible for that lifecycle. The
steady-state launch, recovery, readiness, and synchronization path is automatic.
Docker is intentionally unnecessary for this single-Mac service.

Create each device's separate five-minute pairing code locally:

```bash
python3 script/local_backend.py --config "$DATA_ROOT/runtime-config.json" \
  create-pairing-code "Rafal iPhone"
python3 script/local_backend.py --config "$DATA_ROOT/runtime-config.json" \
  create-pairing-code "Rafal Mac"
```

The clear code is printed once. Device bearer tokens are returned once by the
HTTPS pairing route; the backend persists only SHA-256 token digests.

List and revoke a device locally on the host Mac:

```bash
python3 script/local_backend.py --config "$DATA_ROOT/runtime-config.json" list-devices
python3 script/local_backend.py --config "$DATA_ROOT/runtime-config.json" \
  revoke-device device_0123456789abcdef
```

Revocation takes effect on the next request. The rejected app clears its stale
Keychain token when session validation returns `401` and asks to pair again.

## Backup and restore

Create a consistent online SQLite backup plus verified copies of every active
recording:

```bash
python3 script/backup_local_backend.py \
  --data-root "$DATA_ROOT" \
  --backup-parent "$DATA_ROOT/backups"
```

The backup is published atomically with an owner-only manifest containing
content hashes. A restore refuses a changed database, changed recording,
unsafe relative path, broken SQLite integrity/foreign keys, or a non-empty
destination.

Always restore into a fresh directory and inspect it before changing the
LaunchAgent's data root:

```bash
python3 script/restore_local_backend.py \
  --backup "/absolute/path/to/ideaforge-YYYYMMDDTHHMMSSZ" \
  --destination "/absolute/path/to/fresh-restored-state"
```

Backups remain local files. Copying them elsewhere is an explicit operator
action; this project does not upload them to object storage.

## Stop or uninstall

```bash
python3 script/install_local_backend.py uninstall \
  --plist-path "$HOME/Library/LaunchAgents/com.rsitech.ideaforge.local-backend.plist"
```

Uninstalling removes the LaunchAgent only. It deliberately preserves the data
root, recordings, certificates, logs, and backups. Delete or archive those
separately only after a verified restore drill.

## Optional OpenAI

No OpenAI request is made by the current local-backend runtime. The provider
policy is disabled by default and rejects automatic provider selection. A
future explicit workflow may enable OpenAI only when the user chooses that
action and a usable key is present in the Mac Keychain. Local sync and Apple
on-device enrichment must stay healthy when the key is absent or removed.
