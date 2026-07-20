# IdeaForge support

Use [GitHub Issues](https://github.com/rsitech-ai/IdeaForge/issues) for reproducible, non-sensitive bugs in the public source or an official release. Fork publishers support their own builds and services.

Report suspected vulnerabilities through the private channel in [SECURITY.md](SECURITY.md). Do not disclose exploit details in an issue.

RSI Tech maintains the public project. For public or confidential project
contact, email [info@rsitech.ai](mailto:info@rsitech.ai); confidential material
must follow the handling rules in [SECURITY.md](SECURITY.md).

## Before filing an issue

- Record the platform, app version, build number, and macOS, iOS, or watchOS version.
- State whether you built from source or installed an official Developer ID release.
- For recording failures, check microphone permission in System Settings or Settings.
- For Watch transfer failures, confirm the Watch saved the recording and can reconnect to its paired iPhone.
- For backend failures, identify the backend implementation and confirm its base URL, workspace ID, session validation, and required capability. Do not include the token or URL query data.
- For Mac update failures, include the Sparkle error category and release version. Do not paste signed appcast data that contains private fork URLs.

## Safe diagnostic material

You may include status labels, redacted steps, aggregate counts, and short logs that you inspected for private data.

Do not send audio, transcripts, artifacts, bearer tokens, provider keys, StoreKit transaction payloads, full private URLs, device identifiers, account data, or local file paths.

Account plans and deletion are backend-operated features. The Mac app opens links supplied by that backend; this repository does not operate an account service. Contact your backend operator for account or billing disputes.
