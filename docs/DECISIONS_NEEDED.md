# Product Decisions

## Confirmed

- Public product and application name: `Ushot`.
- Bundle identifier: `io.github.ischeneycc.ushot`.
- Canonical public repository: `https://github.com/isCheneycc/ushot`.
- Source license: Apache-2.0.
- Initial distribution: official GitHub Releases, Apple Silicon and macOS 14+.
- Initial trust model: intentional ad-hoc application signature, no Developer ID and no Apple notarization. First installation documents a quarantine-removal step limited to the official release.
- Release readiness is split: a direct-download GitHub Release may be published without a production appcast, while production self-update remains independently blocked. The protected workflow defaults to direct-download mode and requires an explicit `publish_update_feed=true` decision to sign and deploy the feed.
- Update rollout: the 0.1.1 client remains on the legacy `https://ischeneycc.github.io/ushot/updates/appcast.xml`, which stays permanently absent. Ushot 0.1.2 (build 3) is a one-time manual-install hardened transition and uses `https://ischeneycc.github.io/ushot/updates/v1/appcast.xml`; it is not published until the immutable `v0.1.2` GitHub Release exists. The first permitted feed item is 0.1.3 (build 4), and Pages may expose only `updates/v1/appcast.xml` after the complete 0.1.2 → 0.1.3 evidence gate passes.
- Update framework and source: the runtime must use a reviewed Ushot Sparkle fork with mandatory signed-feed validation, exact extracted short/build identity and independent archive EdDSA validation. The host requires `SURequireExactUpdateVersionIdentity=true`, `SURequireEdDSAUpdateArchiveSignature=true` and framework capability marker `SUUpdateVersionIdentityHardeningVersion=1`. Official upstream Sparkle 2.9.5 publishing tools continue to generate and sign the appcast. Restricted-Markdown release notes are embedded in each signed item, and immutable archives live on the official GitHub Release. Links/images/raw HTML/URL-like destinations inside notes, detached release-note URLs, item links, full-release-note URLs and deltas are forbidden; only the committed zero-item `updates/v1/appcast.xml` seed may bootstrap exact 0.1.3 (build 4). Every later version and build must each be strictly greater than every item retained in the authenticated production appcast.
- Update behavior: manual checks only; no automatic checks/downloads, telemetry, analytics or system-profile submission.
- Commercial direction: the open-source core remains Apache-2.0. Future paid capabilities may be separately distributed closed-source modules or services, without changing rights already granted for published code.

## Confirmed for the first direct-download release

- The repository owner accepts the current project-native app icon, menu icon and README graphics for distribution with 0.1.1 under the repository's Apache-2.0 terms.
- The approved runtime dependency is the reviewed `isCheneycc/Sparkle` hardening fork at exact immutable tag `2.9.5-ushot.2` and revision `f4d8362bf9b6231596db3a0cc8812fdca8100961`; official upstream 2.9.5 tools remain the publisher. Its license and bundled external-license notices are reproduced in `ThirdPartyNotices.txt`, and the Release build must embed that file unchanged.
- GitHub Private Vulnerability Reporting is enabled.

The 0.1.1 preview uses the direct-download path. **Check for Updates…** remains visible and fails visibly against its permanently absent legacy endpoint. The pending 0.1.2 transition also uses the direct-download path and must be installed manually once; its new feed remains absent until the 0.1.3 gate passes. Neither state may be described as updater readiness.

## Still needed before a broader compatibility claim

- Complete the supported macOS patch-level clean-standard-account installation matrix and record Gatekeeper plus Screen Recording behavior. Publication as a clearly labeled initial preview does not count as completion of that matrix.

## Still needed before the first production update feed

- Completion and recorded results for the 0.1.2 → 0.1.3 clean-account ad-hoc update matrix in `MANUAL_TESTING.md`, including helper loading, exact short/build mismatch rejection, strict archive EdDSA, replacement and active-work admission.
- Completion and recorded results for embedded-notes feed validation, including signed-feed status, exact XML namespaces/hierarchy, rejection of unrestricted or detached notes, no external destination and no extra release-notes request.
- A tested Sparkle EdDSA key backup and recovery procedure; the private key stays outside source control.
- Complete and review the runtime fork integration: host policy keys must be true, framework marker version 1 must be present, a missing/wrong marker must prevent any network request, post-extraction short/build mismatch must fail closed, and archive EdDSA failure must never fall back to a matching application code signature. Source presence or CI publication checks are not runtime evidence.
- Keep Developer ID distribution disabled until the hardened runtime passes the full transition and tamper-rejection matrix. Joining the Apple Developer Program is not needed for the current ad-hoc rollout.

## Deferred decisions

- Whether and when to join the Apple Developer Program and migrate a later release to Developer ID signing and notarization after the hardened ad-hoc update path has recorded evidence. Membership is not a prerequisite for 0.1.2 or the first v1 feed.
- Which post-1.0 capabilities, if any, live in a separately distributed paid module or service, and what commercial terms apply only to that separate component.
- Whether to add Intel/Universal 2 distribution after measuring demand and adding corresponding hardware validation.
