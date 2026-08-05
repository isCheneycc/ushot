# Changelog

All notable changes to Ushot will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and released versions will follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/isCheneycc/ushot/commits/main
