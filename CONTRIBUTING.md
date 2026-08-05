# Contributing

## Development setup

Use an Apple Silicon Mac with macOS 14+ and a full Xcode installation. Select Xcode before building:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Build and test the shared scheme with the commands in `README.md`. Command Line Tools-only environments may use `swift build` and `scripts/test-clt.sh`, but those checks do not replace a signed `.app` run or the manual display matrix.

## Change discipline

- Preserve the one-way dependency from `UshotApp` to `UshotCore`.
- Keep AppKit state on `MainActor`; run PNG encoding and image processing away from repeated UI event paths.
- Route global coordinates through the shared geometry types. Never add a second ad-hoc Y flip.
- Use system color profiles and conversions. Do not copy component numbers between color spaces as a conversion.
- Surface operational failures and add privacy-safe OSLog context. Never log screenshot pixels, annotation text or clipboard contents.
- Update schema versions and explicit migrations when persisted settings, annotation documents or history metadata change.
- Update `STATUS.md`, relevant architecture/privacy documentation and the manual matrix when behavior changes.

## Tests

Add focused coverage for every core behavior. Screen capture and global shortcuts must remain replaceable by protocol fakes so unit tests never require Screen Recording permission. History tests must use a unique temporary directory and clean it up.

Before submitting a change, run the smallest relevant test during development, then the full scheme build and test once the phase or change set is complete. Do not commit DerivedData, build artifacts, signing material, screenshots or user history.

## Large changes

Discuss large refactors or experimental architecture changes before starting them, and use a separate branch when agreed. Keep unrelated working-tree changes intact.
