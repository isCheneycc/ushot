# Product Decisions

## Confirmed

- Public product and application name: `Ushot`.
- Bundle identifier: `io.github.ischeneycc.ushot`.
- Canonical public repository: `https://github.com/isCheneycc/ushot`.
- Source license: Apache-2.0.
- Initial distribution: official GitHub Releases, Apple Silicon and macOS 14+.
- Initial trust model: intentional ad-hoc application signature, no Developer ID and no Apple notarization. First installation documents a quarantine-removal step limited to the official release.
- Update framework and source: Sparkle with mandatory signed-feed and archive EdDSA validation, feed at `https://ischeneycc.github.io/ushot/updates/appcast.xml`, restricted-Markdown release notes embedded in each signed item, a Pages payload containing only `updates/appcast.xml`, and immutable archives on the official GitHub Release. Links/images/raw HTML/URL-like destinations inside notes, detached release-note URLs, item links, full-release-note URLs and deltas are forbidden; only the committed zero-item first-release seed may migrate into this format. Every later version and build must each be strictly greater than every item retained in the authenticated production appcast.
- Update behavior: manual checks only; no automatic checks/downloads, telemetry, analytics or system-profile submission.
- Commercial direction: the open-source core remains Apache-2.0. Future paid capabilities may be separately distributed closed-source modules or services, without changing rights already granted for published code.

## Still needed before the first public release

- Final app icon and brand assets, including confirmation that every bundled asset may be distributed under compatible terms.
- A reviewed third-party dependency/resource notice inventory for every source and binary artifact included in the release.
- Completion and recorded results for the clean-account unsigned-update matrix in `MANUAL_TESTING.md`.
- Completion and recorded results for embedded-notes feed validation, including signed-feed status, exact XML namespaces/hierarchy, rejection of unrestricted or detached notes, no external destination and no extra release-notes request.
- A tested Sparkle EdDSA key backup and recovery procedure; the private key stays outside source control.
- The first public semantic version, release date and supported macOS patch-level test matrix.
- Enable and verify GitHub Private Vulnerability Reporting for the repository.
- Keep Developer ID distribution disabled until the updater can require archive EdDSA independently of Sparkle's matching-code-signature fallback, then rerun the full transition and tamper-rejection matrix.
- Close Sparkle 2.9.5's client-side archive-version gap: the protected workflow rejects a ZIP whose enclosed short/build versions differ from the appcast, but Sparkle exposes no public pre-install extracted-app URL and does not enforce both comparisons itself. Do not claim the production updater is release-ready until an upstream upgrade, a reviewed Sparkle hardening, or another explicit client-side mechanism enforces the product contract.

## Deferred decisions

- Whether and when to join the Apple Developer Program, after the strict archive-EdDSA blocker is resolved, and migrate later releases to Developer ID signing and notarization.
- Which post-1.0 capabilities, if any, live in a separately distributed paid module or service, and what commercial terms apply only to that separate component.
- Whether to add Intel/Universal 2 distribution after measuring demand and adding corresponding hardware validation.
