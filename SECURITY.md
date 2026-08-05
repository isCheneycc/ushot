# Security Policy

## Supported versions

Security fixes are provided for the latest published Ushot release. Untagged builds and builds taken directly from `main` are development artifacts, not a supported distribution channel.

## Reporting a vulnerability

Please do not disclose an unresolved vulnerability, signing-key concern or exploit in a public issue.

Use **Security → Report a vulnerability** in the [Ushot repository](https://github.com/isCheneycc/ushot) when GitHub Private Vulnerability Reporting is available. If that control is unavailable, contact the repository owner through the GitHub profile and ask for a private reporting channel without including exploit details in public.

Include the affected version, macOS version, reproduction conditions, impact and the smallest safe proof of concept. Do not include real screenshots, clipboard contents, credentials or other people's data.

## Release and update trust

- Only assets attached to the official [`isCheneycc/ushot` releases](https://github.com/isCheneycc/ushot/releases) are Ushot releases.
- Ushot is not currently distributed with a Developer ID signature or Apple notarization. Initial installation therefore requires an explicit Gatekeeper quarantine-removal step documented in `README.md`.
- The complete appcast, including each embedded restricted-Markdown release description, must pass Sparkle `SURequireSignedFeed` validation before any item is accepted. The client requires `signingValidationStatus == .succeeded` and keeps `shouldDownloadReleaseNotes` false. Detached release-note URLs, item links, full-release-note URLs and delta enclosures are rejected rather than fetched or rewritten; publishing also rejects links, images, raw HTML, autolinks, entities and URL/domain/network-address-like text in every retained description.
- GitHub Pages publishes only signed `updates/appcast.xml`; release notes are not a separately hosted trust object.
- In-app update archives must independently pass Sparkle EdDSA verification. A valid HTTPS download alone is not sufficient.
- Developer ID releases remain disabled until archive EdDSA can be enforced independently of Sparkle's matching-code-signature fallback; notarization is not a substitute for Ushot's update signature policy.
- The protected release pipeline extracts the final ZIP and binds both enclosed bundle versions to the signed appcast. Sparkle 2.9.5 does not expose a public pre-install hook for enforcing the same comparison in the client, so production self-update remains blocked until that gap is closed rather than treating CI as a runtime guarantee.
- A release may extend an authenticated appcast only when both its stable semantic version and positive decimal build number are strictly greater than every retained item. Appcast RSS/Sparkle namespaces and direct element hierarchy are validated exactly before signing.
- The EdDSA private key, Apple signing credentials and notarization credentials must never be committed, printed in CI logs or attached to a release. The public EdDSA key is expected to be embedded in the application.
- A suspected private-key disclosure stops publication immediately. Preserve evidence, rotate credentials through a verified migration path, and do not publish a replacement feed until already-installed clients can authenticate it.

## Privacy-sensitive diagnostics

Security reports and application diagnostics may contain versions, lifecycle states and error categories. They must never contain captured pixels, annotation text, clipboard values, filenames, file contents, update keys or a system profile.
