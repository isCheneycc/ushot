<p align="right">
  <strong>English</strong> · <a href="./README.zh-CN.md">简体中文</a>
</p>

<h1 align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Ushot — capture, annotate, and pin screenshots in a native, local-first macOS workflow">
</h1>

<p align="center">
  <a href="#one-capture-one-continuous-workflow">Workflow</a> ·
  <a href="#what-ushot-does">Features</a> ·
  <a href="#try-ushot-from-source">Try from source</a> ·
  <a href="#privacy-by-design">Privacy</a> ·
  <a href="#release-status-and-installation">Release status</a>
</p>

Ushot is a native screenshot and annotation utility for Apple silicon Macs running macOS 14 or later. Capture a region, window, or display; mark it up while keeping annotations editable; then copy, save, or keep it pinned across Spaces and full-screen apps.

Screenshot pixels, annotations, clipboard exports, color samples, history, and encoded files are processed locally. Ushot has no account, telemetry, analytics, advertising SDK, crash-report upload, or system-profile submission.

> [!IMPORTANT]
> Ushot 0.1.4 (build 5) is the current public release. Install it from the official GitHub Release, or use **Check for Updates…** on an installed 0.1.3 client to download and install 0.1.4 from the production v1 feed.

## One capture, one continuous workflow

<p align="center">
  <img src="./assets/readme/workflow.svg" width="100%" alt="Ushot workflow: freeze and select the desktop, annotate in place, then copy, save, or pin the result">
</p>

Region capture keeps the frozen desktop visible from selection through confirmation. Adjust any edge, annotate directly inside the selected frame, and choose the output you need—without detouring through a cropped screenshot preview.

## What Ushot does

- **Capture precisely.** Capture a region, window, current display, selected display, or every display. Region mode freezes participating displays, snaps to the topmost eligible application window, optionally refines to useful controls with Accessibility permission, and preserves native backing pixels across mixed-scale displays.
- **Annotate without flattening.** Use shapes, lines, paper-plane arrows, freehand, text, counters, highlight, mosaic, blur, Spotlight, layers, and undo/redo. Start in the quick toolbar and continue in the full Canvas Editor with the same editable document.
- **Keep a capture within reach.** Pin a movable, proportionally resizable screenshot that stays visible across Spaces and over full-screen apps. Pinned images begin read-only; show the toolbar only when you want to edit.
- **Inspect colors and dimensions.** Sample colors across displays with managed sRGB, Display P3, Generic RGB, and Adobe RGB (1998) output, or measure in logical points and physical pixels with the screen ruler.
- **Keep local history on your terms.** Editable history is optional, off by default, and stored as inspectable PNG and versioned JSON records. Export PNG, JPEG, or TIFF with optional source-profile preservation.

Implementation detail and current validation evidence live in [STATUS.md](STATUS.md) and [the architecture guide](docs/ARCHITECTURE.md), keeping this page focused on the product workflow.

## Try Ushot from source

You need:

- An Apple silicon Mac running macOS 14 or later.
- A full Xcode installation. Command Line Tools alone can run the SwiftPM checks, but cannot build the `.app` with `xcodebuild`.

Open the project and run the `ScreenshotApp` scheme:

```bash
open ScreenshotApp.xcodeproj
```

Grant Screen Recording permission when macOS asks, press `⌃⌥A`, select a region, add a mark, and choose **Copy**, **Save**, or **Pin**.

### Default global shortcuts

| Action | Shortcut |
| --- | :---: |
| Capture Region | `⌃⌥A` |
| Capture Window | `⌃⌥W` |
| Capture Current Display | `⌃⌥F` |
| Capture Selected Display | `⌃⌥D` |
| Capture All Displays | `⌃⌥M` |
| Color Picker | `⌃⌥C` |
| Screen Ruler | `⌃⌥R` |

Global shortcuts are configurable, and F1–F20 can be assigned without an additional modifier. Annotation-tool shortcuts are configurable separately and apply only while editing a screenshot.

## Privacy by design

- **Screen Recording is required** for capture, color sampling, and other pixel access. Pixels are read only after an explicit user action and are processed on the Mac.
- **Accessibility is optional.** It refines smart region snapping from an application window to a useful control. Ordinary capture and window-level snapping continue to work when permission is absent, denied, or revoked.
- **History is opt-in.** Disabling history stops new records; it does not silently delete existing ones.
- **Network access is user-initiated.** The only normal network entry is **Check for Updates…**. Those HTTPS requests expose ordinary connection metadata to GitHub Pages and GitHub Releases, but Ushot adds no screenshot, annotation, clipboard, history, advertising identifier, or system profile.

Read [PRIVACY.md](PRIVACY.md) for the complete data, permission, persistence, and network boundary.

## Release status and installation

Ushot 0.1.4 (build 5) is the current published release and the first production feed item. The protected workflow published its immutable five-asset GitHub Release and deployed the signed v1 appcast. Users of 0.1.3 can install 0.1.4 manually or through **Check for Updates…**. Builds taken directly from `main` remain development artifacts rather than a supported distribution channel.

Download [Ushot-0.1.4-arm64.dmg](https://github.com/isCheneycc/ushot/releases/download/v0.1.4/Ushot-0.1.4-arm64.dmg) from the immutable [Ushot v0.1.4 Release](https://github.com/isCheneycc/ushot/releases/tag/v0.1.4) and install it manually. Public artifacts are intentionally ad-hoc signed, have no Developer ID signature or Apple notarization, and are not sandboxed.

1. Open the DMG and drag `Ushot.app` into **Applications**.
2. Remove only the downloaded-file quarantine attribute, then open Ushot:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Ushot.app"
   open "/Applications/Ushot.app"
   ```

Use this procedure only for a versioned Ushot DMG that is actually published on the official [Ushot Releases](https://github.com/isCheneycc/ushot/releases) page. Do not use an unversioned or third-party download as release evidence, replace the command with `xattr -cr`, or run it against a broader directory. A later install or update may require Screen Recording or Accessibility permission to be granted again.

The app bundle includes the applicable [third-party license notices](UshotApp/Resources/ThirdPartyNotices.txt), including Sparkle and its bundled components.

## Updates and trust

Update checks are manual only. Ushot does not check at launch or on a schedule, download automatically, or submit a system profile.

The 0.1.1 client remains pinned to the legacy `/updates/appcast.xml` endpoint, which stays permanently unavailable (HTTP 404). Ushot 0.1.2 and later point at the v1 feed. The first production feed item is 0.1.4 (build 5): an installed 0.1.3 client can use **Check for Updates…** to download and install it. A 0.1.1 or 0.1.2 install cannot self-update through that path and should install a current release manually from GitHub.

- Ushot 0.1.2 and later are pinned to `https://ischeneycc.github.io/ushot/updates/v1/appcast.xml`; the legacy endpoint remains HTTP 404.
- Restricted-Markdown release notes are embedded in that signed feed, so showing them does not make a detached notes request.
- Accepted archives may come only from the official GitHub Release download path.
- The hardened runtime requires an exact match between the appcast and the extracted app's display/build versions, and requires every archive to pass EdDSA even if its application code signature matches. Starting with 0.1.3, the exact authenticated XML is also validated before Sparkle parses items, rejecting duplicate, misplaced, wrong-namespace, DTD and entity input that parsed item objects could conceal. The complete appcast is signed separately. HTTPS or a matching checksum is not a substitute.

Update checks remain user-initiated only: no check at launch, no schedule, no automatic download, and no system profile. Public distribution remains ad-hoc signed GitHub Releases; Apple Developer Program membership is not required for this channel. Developer ID and notarization remain a separate future track.

See [SECURITY.md](SECURITY.md), [PRIVACY.md](PRIVACY.md), and [the release guide](docs/RELEASING.md) for the complete trust model and release procedure.

## Build, test, and contribute

The Xcode project and Swift package compile the same implementation. Use focused checks during development and the complete scheme plus manual matrix for release work.

```bash
xcodebuild -project ScreenshotApp.xcodeproj \
  -scheme ScreenshotApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

```bash
swift build --configuration debug
scripts/test-clt.sh
```

If an installed `Ushot.app` is already running, quit it before UI tests or give the test build an isolated identity with `APP_BUNDLE_IDENTIFIER=io.github.ischeneycc.ushot.uitests`.

Start with [CONTRIBUTING.md](CONTRIBUTING.md) and complete the relevant checks in [docs/MANUAL_TESTING.md](docs/MANUAL_TESTING.md).

## Project documentation

- [Privacy](PRIVACY.md) — local processing, permissions, persistence, and update-network boundaries.
- [Security](SECURITY.md) — vulnerability reporting and update trust.
- [Current status](STATUS.md) — implementation state, validation evidence, and known gaps.
- [Roadmap](docs/ROADMAP.md) — completed phases and release-readiness work.
- [Contributing](CONTRIBUTING.md) — development workflow and review expectations.
- [Architecture](docs/ARCHITECTURE.md) — module, lifecycle, and failure boundaries.
- [Manual testing](docs/MANUAL_TESTING.md) — required hardware and interaction matrix.
- [Releasing](docs/RELEASING.md) — signing, packaging, validation, and publication sequence.
- [Performance](docs/PERFORMANCE.md) — Instruments scenarios and measurement method.
- [Changelog](CHANGELOG.md) — user-visible changes by release.

## License

Ushot is available under the [Apache License 2.0](LICENSE). Future separately distributed paid modules or services do not revoke or narrow the rights already granted for published source.
