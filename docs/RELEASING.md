# Releasing UshotApp

Release tooling requires a full Xcode installation. No signing identity, Team ID, Apple ID, app-specific password or notary credential is stored in this repository.

## 1. Preflight

1. Resolve the product name, bundle identifier, version, icon and license decisions in `DECISIONS_NEEDED.md`.
2. Select Xcode and accept its license.
3. Run the Debug build, tests and `MANUAL_TESTING.md` matrix.
4. Review `PRIVACY.md`, localized strings and history schema compatibility.

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcodebuild -project ScreenshotApp.xcodeproj -scheme ScreenshotApp -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -project ScreenshotApp.xcodeproj -scheme ScreenshotApp -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

## 2. Stable local development signing

Screen Recording authorization is attached to the app's code identity. Never install an
unsigned or ad-hoc build over the copy in `/Applications`, because every changed binary
then looks like a different app to macOS.

Create an Apple Development certificate in Xcode → Settings → Accounts → Manage
Certificates. Copy the example configuration and replace the team placeholder:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

`Config/Local.xcconfig` is intentionally ignored by Git. Build, validate and install with:

```bash
scripts/build-release.sh
scripts/package-dmg.sh
scripts/install-local.sh
```

The build and install scripts reject missing Team IDs, ad-hoc signatures and missing
designated requirements. The installer also rejects an incompatible replacement identity.
For the one intentional migration from an old ad-hoc install, use
`ALLOW_SIGNING_IDENTITY_MIGRATION=YES scripts/install-local.sh`; do not use that override
for routine updates.

Artifacts are written below `build/release/artifacts` unless `BUILD_ROOT` is set. For an
isolated diagnostic artifact that will never be installed, unsigned output remains an
explicit opt-in with `ALLOW_UNSTABLE_LOCAL_SIGNING=YES`.

## 3. Developer ID distribution signing

Export non-secret identity metadata for the current shell. The certificate and private key remain in the login keychain.

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example Company (TEAMID)'
export DEVELOPMENT_TEAM='TEAMID'
scripts/build-release.sh
scripts/package-dmg.sh
```

The project enables Hardened Runtime. Both scripts verify signatures and fail on signing errors.

## 4. Notarization and stapling

The preferred method stores credentials in the keychain:

```bash
xcrun notarytool store-credentials 'ushot-notary' --apple-id 'developer@example.com' --team-id 'TEAMID'
export NOTARYTOOL_KEYCHAIN_PROFILE='ushot-notary'
scripts/notarize.sh build/release/artifacts/UshotApp-0.1.0.dmg
```

CI may instead inject `APPLE_ID`, `APPLE_TEAM_ID` and `APP_SPECIFIC_PASSWORD` as protected environment variables. The script submits with `--wait`, staples the accepted ticket, validates stapling and runs Gatekeeper assessment. Never echo or commit those values.

## 5. Final verification

Test the stapled DMG on a clean macOS 14+ account: drag to Applications, launch through Finder, grant/deny Screen Recording, verify all capture modes, history, login item, multiple displays and offline operation. Archive the notarization request ID and checksums outside the repository.
