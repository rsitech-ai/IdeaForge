# Contributing to IdeaForge

Thank you for helping improve IdeaForge. Contributions are accepted under the
Apache License 2.0 and must follow the Developer Certificate of Origin (DCO).

## Developer Certificate of Origin

Every commit must include a `Signed-off-by` trailer certifying the Developer
Certificate of Origin 1.1 at <https://developercertificate.org/>. Add it with:

```sh
git commit --signoff
```

By signing off, you certify that you have the right to submit the contribution
under this repository's license. The sign-off is a legal certification; it is
not a GPG or SSH signature. Pull requests containing unsigned commits will not
be merged until their commits are corrected.

## Before opening a pull request

1. Keep changes focused and include tests for changed behavior.
2. Generate the Xcode project and run the repository checks:

   ```sh
   xcodegen generate
   swift test
   python3 script/test_audit_public_source.py
   python3 script/test_create_public_source_snapshot.py
   python3 script/test_ci_release_config.py
   python3 script/test_sparkle_configuration.py
   ./script/test_release_macos.sh
   ./script/test_verify_production.sh
   ```

3. Run the public-source audit with absent output paths:

   ```sh
   mkdir -p .build/reports
   python3 script/audit_public_source.py . \
     --profile public \
     --json-out .build/reports/public-source-audit.json \
     --markdown-out .build/reports/public-source-audit.md
   ```

   Do not include credentials, personal paths,
   device identifiers, private reports, or unprovenanced images.
4. Describe the user-visible behavior, verification performed, and remaining
   limitations in the pull request.

Please report security vulnerabilities privately as described in SECURITY.md,
not in a public issue.

The repository policy requires DCO sign-off, but it becomes enforceable only
when the maintainer enables the documented default-branch ruleset and required
DCO status check. Until then, maintainers must verify sign-offs during review.
