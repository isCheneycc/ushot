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
- The legacy `updates/appcast.xml` path used by 0.1.1 remains permanently absent. GitHub Pages may publish only the signed `updates/v1/appcast.xml` path used by the 0.1.2 hardened transition and later; release notes are not a separately hosted trust object.
- The 0.1.2 runtime pins the reviewed `isCheneycc/Sparkle` fork at immutable tag `2.9.5-ushot.2` and revision `f4d8362bf9b6231596db3a0cc8812fdca8100961`. It must set `SURequireExactUpdateVersionIdentity=true` and `SURequireEdDSAUpdateArchiveSignature=true` and accept its embedded framework only when `SUUpdateVersionIdentityHardeningVersion=1`. Before installation, that fork must compare the extracted app's `CFBundleShortVersionString` and `CFBundleVersion` exactly with the signed appcast identity and reject a missing or failed archive EdDSA signature without falling back to matching application code signing. A valid HTTPS download alone is not sufficient.
- The runtime fork does not replace the official upstream Sparkle 2.9.5 publishing tools; the protected workflow continues to use those tools for appcast and archive signing.
- The protected release pipeline independently extracts the final ZIP and binds both enclosed bundle versions to the signed appcast. That publication gate and the hardened runtime are complementary, and neither is operational evidence by itself. Production self-update remains blocked until the 0.1.2 → 0.1.3 clean-account, tamper, exact-version-mismatch and key-recovery matrix passes.
- Developer ID and notarization remain disabled while the hardened ad-hoc update path is validated. Apple Developer Program membership is not required for this stage, and notarization is not a substitute for Ushot's update signature policy.
- A release may extend an authenticated appcast only when both its stable semantic version and positive decimal build number are strictly greater than every retained item. Appcast RSS/Sparkle namespaces and direct element hierarchy are validated exactly before signing.
- The EdDSA private key, Apple signing credentials and notarization credentials must never be committed, printed in CI logs or attached to a release. The public EdDSA key is expected to be embedded in the application.
- A suspected private-key disclosure stops publication immediately. Preserve evidence, rotate credentials through a verified migration path, and do not publish a replacement feed until already-installed clients can authenticate it.

## Privacy-sensitive diagnostics

Security reports and application diagnostics may contain versions, lifecycle states and error categories. They must never contain captured pixels, annotation text, clipboard values, filenames, file contents, update keys or a system profile.
