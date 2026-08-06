# Changelog

All notable changes to Ushot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and released versions will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Advance source identity to Ushot 0.1.4 (build 5), the first permitted production feed item, while the public release and update feed remain at the published 0.1.3 direct-download state until the evidence gate closes.
- Add hash-bound 0.1.3 → 0.1.4 update-transition fixture, loopback HTTPS and operator evidence tooling for the clean-account matrix.
- Harden release-asset ZIP extraction with write-confined `sandbox-exec` validation workspaces.

### Security

- Keep production self-update blocked until the recovered-key drill and complete 0.1.3 → 0.1.4 matrix are recorded; do not deploy `/updates/v1/appcast.xml` or use `publish_update_feed=true` before that evidence.

## [0.1.3] - 2026-08-06

### Changed

- Publish Ushot 0.1.3 (build 4) as the second manual GitHub-only transition with `publish_update_feed=false`; its five immutable assets passed anonymous download verification while both appcast endpoints remained HTTP 404, and the first production feed item and online update moves to 0.1.4 (build 5).
- Pin published Ushot 0.1.3 to the Sparkle hardening fork `2.9.5-ushot.4` at immutable revision `3d81360ff115ffb80222c2723d72cb4cfa802774` and SwiftPM ZIP SHA-256 `d8d36e5b5ee9e97b17babc1beeb26795b96558cafe5450130aafa5b169d5c829`; `.3` remains the historical authenticated-XML-hook predecessor.
- Keep Sparkle private-key plaintext in process memory and standard input in the backup, recovery-drill and protected-signing paths instead of creating plaintext key files.
- Validate encrypted-backup headers through one shared fixed-path hexadecimal probe. The previous backup helper called nonexistent macOS path `/usr/bin/dd`, hid that command failure and misreported a valid LibreSSL ciphertext as missing `Salted__`; the corrected path distinguishes tool failure from malformed ciphertext and is covered with real nonsecret LibreSSL output.
- Split release building, opaque signing-input preparation, secret-free approval, feed-only signing, immutable-feed validation, clean Pages packaging, GitHub publication, deployment admission and pure Pages deployment into separate capability boundaries. The no-feed path still requires approval without starting the signing environment or reading the update key.
- Rotate the then-unpublished update trust root at the 0.1.3 manual-install boundary, using the dedicated Sparkle Keychain account `io.github.ischeneycc.ushot.20260806`; published 0.1.1/0.1.2 artifact gates retain their historical public-key identity.

### Security

- Validate the exact authenticated appcast XML after signed-feed verification and before Sparkle parses item metadata, rejecting duplicate or misplaced fields, wrong namespaces, DTDs and entities that parsed `SUAppcastItem` values could conceal.
- Require the host opt-in `SURequireHostSignedAppcastValidation=true`, `SUMaximumSignedAppcastContentLength=1048576`, and framework capability markers `SUHostSignedAppcastValidationVersion=1` plus `SUFeedDownloadSizeLimitVersion=1` before the 0.1.3 updater can make a request.
- Keep fetched production-feed bytes opaque and capped until EdDSA verification succeeds. Reject oversized declared and chunked/streamed responses against the 1 MiB authenticated-prefix plus 512-byte trailer wire bound without applying that feed cap to ZIP/archive downloads; use freshly downloaded checksum-pinned and code-signature-verified Sparkle tools instead of a writable cache; compile and ad-hoc sign the fixed-source authenticated-XML validator plus public-key deriver on a credential-free runner, preserve them as an exact two-file artifact and bind each by independent SHA-256 and code signature; prohibit compilers on the secret-bearing runner; reject noncanonical signed history before Sparkle can normalize it; pin the repository shell scripts allowed to see the in-memory key by reviewed SHA-256; immediately preserve accepted signed bytes by immutable artifact ID before mutable runtime validation; reuse the same immutable helper artifact for that later no-key pass instead of invoking an implicit SwiftPM build; and isolate the private key and Pages/OIDC authority from build, validation and publication runners.
- Treat the existing same-disk encrypted old-key copy as retired staging evidence. The rotated key now has a recovery-checked, archived private GitHub ciphertext at root commit `9fe3d07a31bad91c6b75142955f31d1c30816ec1` with SHA-256 `f308c694d6597a52a700ab4f9b97386ee17bd5332ad7725655fd13ab666155d0`; a fresh clone passed exact-file/header/digest checks before the protected signing Secret was replaced through stdin without exposing plaintext.
- Record the owner's explicit single-provider recovery exception: the rotated-key ciphertext may live only in the feature-restricted private `isCheneycc/ushot-signing-key-backup` repository with its new high-entropy password outside GitHub. This removes workstation dependence but knowingly leaves GitHub account loss as a shared failure mode for both backup and signing Secret.

## [0.1.2] - 2026-08-06

### Changed

- Prepared the first manual direct-install transition to the versioned production update-feed endpoint used by later releases.
- Replaced the stock Sparkle runtime with a source-auditable hardened build while keeping the official Sparkle 2.9.5 publishing tools.

### Security

- Require the extracted application's semantic version and build number to match the authenticated appcast item before installation.
- Require every update archive to pass EdDSA verification independently; a matching Developer ID signature cannot replace a failed archive signature.
- Keep the legacy 0.1.1 feed URL permanently inactive so the previously published updater cannot install future releases.

## [0.1.1] - 2026-08-05

### Added

- Apache-2.0 project license, contribution guidance and security reporting policy.
- Product contracts for manual update checks, EdDSA-signed update archives, privacy-safe update diagnostics and release validation.
- Installation, privacy and manual-test documentation for the initial non-notarized GitHub distribution.

### Changed

- Adopted the official product name `Ushot`, bundle identifier `io.github.ischeneycc.ushot` and repository `https://github.com/isCheneycc/ushot`.
- Documented that future paid, closed-source modules do not revoke or alter the Apache-2.0 license on code already published in this repository.

### Security

- Limited the manual Gatekeeper workaround to removing `com.apple.quarantine` from an official Ushot release instead of clearing every extended attribute.
- Defined the Sparkle EdDSA private key as release-critical secret material requiring protected storage, an independent encrypted backup and an exercised recovery process.

[Unreleased]: https://github.com/isCheneycc/ushot/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/isCheneycc/ushot/releases/tag/v0.1.3
[0.1.2]: https://github.com/isCheneycc/ushot/releases/tag/v0.1.2
[0.1.1]: https://github.com/isCheneycc/ushot/releases/tag/v0.1.1
