# Changelog

All notable changes to Ushot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and released versions will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-08-06

### Changed

- Prepared a one-time direct-install transition to the versioned production update feed used by future releases.
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

[Unreleased]: https://github.com/isCheneycc/ushot/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/isCheneycc/ushot/releases/tag/v0.1.2
[0.1.1]: https://github.com/isCheneycc/ushot/releases/tag/v0.1.1
