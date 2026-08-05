# Product Decisions

## Confirmed

- Public product and application name: `Ushot`.
- Bundle identifier: `io.github.ischeneycc.ushot`.
- Canonical public repository: `https://github.com/isCheneycc/ushot`.
- Source license: Apache-2.0.
- Initial distribution: official GitHub Releases, Apple Silicon and macOS 14+.
- Initial trust model: intentional ad-hoc application signature, no Developer ID and no Apple notarization. First installation documents a quarantine-removal step limited to the official release.
- Release readiness is split: a direct-download GitHub Release may be published without a production appcast, while production self-update remains independently blocked. The protected workflow defaults to direct-download mode and requires an explicit `publish_update_feed=true` decision to sign and deploy the feed.
- Update framework and source: Sparkle with mandatory signed-feed and archive EdDSA validation, feed at `https://ischeneycc.github.io/ushot/updates/appcast.xml`, restricted-Markdown release notes embedded in each signed item, a Pages payload containing only `updates/appcast.xml`, and immutable archives on the official GitHub Release. Links/images/raw HTML/URL-like destinations inside notes, detached release-note URLs, item links, full-release-note URLs and deltas are forbidden; only the committed zero-item first-release seed may migrate into this format. Every later version and build must each be strictly greater than every item retained in the authenticated production appcast.
- Update behavior: manual checks only; no automatic checks/downloads, telemetry, analytics or system-profile submission.
- Commercial direction: the open-source core remains Apache-2.0. Future paid capabilities may be separately distributed closed-source modules or services, without changing rights already granted for published code.

## Confirmed for the first direct-download release

- The repository owner accepts the current project-native app icon, menu icon and README graphics for distribution with 0.1.1 under the repository's Apache-2.0 terms.
- The runtime dependency inventory contains Sparkle 2.9.5 only. Its license and bundled external-license notices are reproduced in `ThirdPartyNotices.txt`, and the Release build embeds that file unchanged.
- GitHub Private Vulnerability Reporting is enabled.

The 0.1.1 preview uses the direct-download path. **Check for Updates…** remains visible and fails visibly while the production feed is absent; that state is called out in the Release notes and must not be described as updater readiness.

## Still needed before a broader compatibility claim

- Complete the supported macOS patch-level clean-standard-account installation matrix and record Gatekeeper plus Screen Recording behavior. Publication as a clearly labeled initial preview does not count as completion of that matrix.

## Still needed before the first production update feed

- Completion and recorded results for the clean-account unsigned-update matrix in `MANUAL_TESTING.md`.
- Completion and recorded results for embedded-notes feed validation, including signed-feed status, exact XML namespaces/hierarchy, rejection of unrestricted or detached notes, no external destination and no extra release-notes request.
- A tested Sparkle EdDSA key backup and recovery procedure; the private key stays outside source control.
- Keep Developer ID distribution disabled until the updater can require archive EdDSA independently of Sparkle's matching-code-signature fallback, then rerun the full transition and tamper-rejection matrix.
- Close Sparkle 2.9.5's client-side archive-version gap: the protected workflow rejects a ZIP whose enclosed short/build versions differ from the appcast, but Sparkle exposes no public pre-install extracted-app URL and does not enforce both comparisons itself. Do not claim the production updater is release-ready until an upstream upgrade, a reviewed Sparkle hardening, or another explicit client-side mechanism enforces the product contract.

## Deferred decisions

- Whether and when to join the Apple Developer Program, after the strict archive-EdDSA blocker is resolved, and migrate later releases to Developer ID signing and notarization.
- Which post-1.0 capabilities, if any, live in a separately distributed paid module or service, and what commercial terms apply only to that separate component.
- Whether to add Intel/Universal 2 distribution after measuring demand and adding corresponding hardware validation.
