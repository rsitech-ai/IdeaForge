# IdeaForge privacy summary

IdeaForge stores work on your device by default. A source checkout does not connect to an IdeaForge production service because this project does not ship one.

## Data handled by the apps

- Recorded audio, transcripts, ideas, questions, plans, workflow runs, artifacts, and exported packets.
- Backend address, workspace identifier, account summary, and route configuration when you enable a backend.
- Bearer tokens and local object-store encryption keys stored in Keychain.
- iPhone StoreKit transaction evidence when you buy or restore an App Store entitlement.

The Mac direct-download build does not use StoreKit. After a validated backend grants account-management capability, the Mac app can open an HTTPS plan or account-deletion URL supplied by that backend.

## Local and network behavior

Local recording, workspace persistence, review, and export work without backend credentials. The app retains local audio until it reaches a confirmed safe uploaded or transcribed state.

Backend upload, sync, account usage, provider transcription, and cloud workflows require an enabled backend, a workspace-scoped bearer token, a validated session, the required route capability, and a privacy mode that permits the request. The backend operator controls its own retention and subprocessors.

Official Mac builds contact the configured Sparkle appcast endpoint to check for updates. Sparkle receives the network metadata that accompanies an HTTPS request, such as the source IP address and user agent. The app verifies accepted updates with the embedded Sparkle EdDSA public key. Community distributors control their own update feed.

## Logs

Logs may contain counts, status values, retry state, and identifiers classified for diagnostic use.

Logs must not contain raw audio, transcript text, artifact bodies, bearer tokens, provider keys, local paths, object keys, signed StoreKit payloads, or private account URLs. Run `python3 script/review_privacy_logs.py --self-test` when changing log review rules.

## Third parties

The Mac client links Sparkle 2.9.4 for updates. Apple frameworks provide recording, Keychain storage, StoreKit on iPhone, and Watch connectivity. A backend operator may configure OpenAI or another service behind the documented backend contract. The repository contains no deployed hosted backend and sends no provider request without explicit backend configuration.

Read [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md) before operating the community backend. It has development-grade security and no multi-tenant isolation.
