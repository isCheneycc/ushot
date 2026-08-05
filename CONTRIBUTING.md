# Contributing

Thank you for improving Ushot. The official repository is <https://github.com/isCheneycc/ushot>.

By intentionally submitting a contribution for inclusion in this repository, you agree that it may be distributed under the [Apache License 2.0](LICENSE), as described by section 5 of that license. A future separately distributed paid module may use different terms; that does not alter the license of code already published here.

## Development setup

Use an Apple Silicon Mac with macOS 14+ and a full Xcode installation. Select Xcode before building:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Build and test the shared scheme with the commands in `README.md`. Command Line Tools-only environments may use `swift build` and `scripts/test-clt.sh`, but those checks do not replace a signed `.app` run or the manual display matrix.

## Change discipline

- Preserve the one-way dependency from the `UshotApp` application target to `UshotCore`. `Ushot` is the public product and bundle name; internal target/module names may remain implementation identifiers until an intentional migration changes them.
- Keep AppKit state on `MainActor`; run PNG encoding and image processing away from repeated UI event paths.
- Route global coordinates through the shared geometry types. Never add a second ad-hoc Y flip.
- Use system color profiles and conversions. Do not copy component numbers between color spaces as a conversion.
- Surface operational failures and add privacy-safe OSLog context. Never log screenshot pixels, annotation text or clipboard contents.
- Update checks must remain user-initiated. Do not enable automatic checks, automatic downloads, system-profile submission, telemetry or another network path without an explicit product decision and simultaneous privacy/documentation review.
- Never commit or print the Sparkle EdDSA private key, Apple credentials, notarization credentials or generated secret material. The public update-verification key is not secret.
- Do not weaken, bypass or replace Sparkle signature verification to make a test update pass. Investigate the package, feed, key or build identity mismatch and fail visibly.
- Update schema versions and explicit migrations when persisted settings, annotation documents or history metadata change.
- Update `STATUS.md`, `CHANGELOG.md`, relevant architecture/privacy documentation and the manual matrix when behavior changes.

## Tests

Add focused coverage for every core behavior. Screen capture and global shortcuts must remain replaceable by protocol fakes so unit tests never require Screen Recording permission. History tests must use a unique temporary directory and clean it up.

Before submitting a change, run the smallest relevant test during development, then the full scheme build and test once the phase or change set is complete. Changes to updating or release packaging must also exercise the focused metadata/signature checks and keep the unverified old-version → new-version manual cases visibly outstanding. Do not commit DerivedData, build artifacts, signing material, screenshots or user history.

## Security reports

Use the private process in `SECURITY.md` for suspected vulnerabilities or key compromise. Do not open a public issue containing an exploit, private key, real capture or another user's data.

## Large changes

Discuss large refactors or experimental architecture changes before starting them, and use a separate branch when agreed. Keep unrelated working-tree changes intact.
