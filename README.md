# Ushot

Ushot is a native, local-first macOS 14+ screenshot and annotation utility built with SwiftUI, AppKit, ScreenCaptureKit, Core Graphics, Core Image and Image I/O. Screenshot pixels, annotations, history and exports stay on the Mac. Ushot has no account, telemetry, advertising SDK or system-profile reporting.

The official repository is [`isCheneycc/ushot`](https://github.com/isCheneycc/ushot), the application bundle identifier is `io.github.ischeneycc.ushot`, and the source in this repository is available under the [Apache License 2.0](LICENSE).

## Implemented features

- Region, window, current-display, selected-display and all-display capture. Region mode freezes the desktop before showing its overlay; hovering snaps across applications to the topmost normal app window while excluding Dock/desktop/system surfaces and, with optional Accessibility permission, refines to useful controls inside it. Mouse-up keeps that frozen selection and outside mask instead of opening a cropped screenshot preview. One blue border with eight exactly aligned handle centers surrounds a transparent, fully interactive editing surface with the complete annotation/output toolbar plus Pin/Cancel. Any point on the border can resize it, while Select-dragging empty canvas space moves the whole selected frame. Live resizing clips or reveals a 1:1 global-desktop annotation viewport, so existing marks and stroke widths remain visually fixed while an edge is held. Pinned-window-only Click Through, Hide Image and Open Canvas Editor controls appear only after Pin. Copy or Save composes the current selection and closes capture; Pin composes it into a movable, proportionally resizable, read-only floating image with stable grab and directional edge/corner cursors. Physical backing pixels are preserved across Retina and mixed 1x/2x layouts.
- One floating screenshot across Spaces and full-screen apps, with copy, save, Finder-compatible file-promise drag, opacity and click-through controls. Toolbar Copy or screenshot-level `Command-C` closes a newly presented window/display capture after the clipboard write succeeds, while an explicitly pinned region and context-menu Copy Screenshot stay persistent. A pinned image starts read-only; its context menu can copy it or show/hide the toolbar, and editing is enabled only while that toolbar is visible. A completed pinned capture replaces the previous screenshot; clicking another app never dismisses it.
- Shared non-destructive quick annotation and canvas editor: shapes, lines, paper-plane-style solid arrows, freehand, text, counters, highlight, fixed source-anchored mosaic/blur regions, a rectangular Spotlight mask that stays unobtrusive while its focus region is dragged, rotation, layers and undo/redo. Crop is no longer exposed in either toolbar or shortcut settings; legacy documents that already contain crop state remain readable and exportable. Solid arrowheads converge diagonally into the shaft instead of ending in a flat triangle base, with the same geometry used by interaction and export. The quick toolbar uses a responsive settings-owned color menu whose six factory colors can all be removed, re-added or replaced with user colors instead of opening the system color panel, and its numeric line-width field preserves intermediate decimal input such as `1.` while typing `1.5`. Line-width editing is selection-aware: a selected stroked annotation previews and commits its own width without changing defaults, while an empty selection changes the independent creation default used by the very next shape without a tool switch. Text preserves the screenshot underneath with a clear input fill, accent border and caret; during input and after reselecting it, the same three corner handles resize font size and the top-right close button deletes the text box—text never uses the generic eight-point transform. TextKit fallback-font baselines are reconciled to the saved Core Text anchor so committing focus does not shift the line. Quick inline editing preserves axis-aligned, uniformly scaled legacy text and explicitly leaves rotated or non-uniformly scaled text selected for Canvas Editor editing instead of discarding its transform. Text, Rectangle and Circle have independent default colors; active text can be recolored without changing the next Text annotation's default, and Text defaults to the system font with an installed-font choice in Settings.
- Editor settings use a compact native master-detail layout: color choices always pair a swatch, semantic name and HEX value; the entire Text/Rectangle/Circle master row is clickable; font search and the live preview show the actual configured result. The complete nonempty toolbar palette is managed in a separate sheet, where any color can be added or removed, deletion requires a surviving replacement for affected defaults, and restoration can either replace the palette with the factory six or add those six while preserving custom colors. Font size, line width and rectangle radius default to physical pixels and each independently supports `px`/`pt`; switching units preserves the current visual size. Rectangle radius defaults to 4 px.
- Live multi-display color picker with sRGB, Display P3, Generic RGB and Adobe RGB (1998), system color management and physical-pixel nudging.
- Multi-display screen ruler with point/pixel measurements, line/rectangle modes and 45-degree constraints.
- Optional editable history stored as inspectable PNG/JSON records with retention limits and corrupt-record isolation.
- Configurable PNG, JPEG and TIFF export with optional source-profile preservation.
- Menu-bar operation, configurable global shortcuts—including standalone F1–F20 keys—configurable in-editor tool shortcuts (defaulting across the number row), Screen Recording guidance, launch at login, optional Dock presence and English/Simplified Chinese UI resources.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- A full Xcode installation for `.app` builds, tests, signing and distribution. Command Line Tools alone can run the SwiftPM checks described below but cannot execute `xcodebuild`.

## Install an official release

Ushot does not currently have a Developer ID signature or Apple notarization. Only use this procedure for `Ushot-<version>-arm64.dmg` downloaded from the official [Ushot Releases](https://github.com/isCheneycc/ushot/releases) page:

1. Open the release DMG and drag `Ushot.app` into **Applications**.
2. In Terminal, remove only the downloaded-file quarantine attribute and open Ushot:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Ushot.app"
   open "/Applications/Ushot.app"
   ```

Do not use this command on a copy obtained from another repository, mirror or third party. Do not replace it with `xattr -cr`: clearing every extended attribute is broader than the installation requires.

macOS will ask for Screen Recording permission when capture access is first needed. Because this distribution is not Developer ID signed, a later application update may require that permission to be granted again.

The application bundle includes the applicable [third-party license notices](UshotApp/Resources/ThirdPartyNotices.txt), including Sparkle and its bundled components.

## Check for updates

**Check for Updates…** is located in the menu-bar menu after **Settings…** and before **About Ushot**. Ushot does not check automatically, download updates automatically or send a system profile. Only choosing this command starts an update request.

The request reads the signed appcast at `https://ischeneycc.github.io/ushot/updates/appcast.xml`. Release notes are restricted Markdown embedded in that appcast, so displaying them does not make a separate notes request; release publishing rejects links, images, raw HTML and URL-like destinations. An accepted update is downloaded from the official GitHub Release. Sparkle must verify both the complete appcast and every update archive with the EdDSA public key embedded in Ushot before installation. Captures and other user content are never included in these requests. See [PRIVACY.md](PRIVACY.md) for the complete network boundary.

The non-Developer-ID update path is not considered release-ready until the old-version → new-version test matrix has verified Sparkle helper loading, EdDSA rejection, application replacement and Screen Recording permission behavior. The protected workflow also extracts the final ZIP and binds its internal short/build versions to the appcast; Sparkle 2.9.5 has no public client-side pre-install hook for the equivalent check, so that framework gap must be closed before production self-update is declared ready. An appcast or release asset existing on GitHub is not, by itself, evidence that this validation passed.

## Build and test with Xcode

```bash
xcodebuild -project ScreenshotApp.xcodeproj -scheme ScreenshotApp -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

```bash
xcodebuild -project ScreenshotApp.xcodeproj -scheme ScreenshotApp -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

If an installed `Ushot.app` is already running, quit it before UI tests or give the test build an isolated identity by adding `APP_BUNDLE_IDENTIFIER=io.github.ischeneycc.ushot.uitests` to the command.

Open `ScreenshotApp.xcodeproj` and run the `ScreenshotApp` scheme to grant Screen Recording permission and complete the checks in `docs/MANUAL_TESTING.md`.

## Command Line Tools validation

The package compiles the same source files as the Xcode project:

```bash
swift build --configuration debug
scripts/test-clt.sh
```

The helper adds the CLT-shipped Swift Testing framework search paths; a full Xcode installation uses XCTest normally.

## Local data

Settings are stored as one versioned Codable document in UserDefaults. Optional history is stored under:

```text
~/Library/Application Support/io.github.ischeneycc.ushot/History/<capture-uuid>/
```

Each record contains `base.png`, `preview.png`, `document.json` and `metadata.json`. Turning history off stops new records and does not delete old records.

## Release

Local development installations use a stable Apple Development identity when one is available. Public GitHub releases currently have no Developer ID signature or notarization and instead rely on Sparkle EdDSA for update-archive authenticity. Signing keys and notarization credentials never belong in the repository or logs. See `docs/RELEASING.md` for the release procedure and `SECURITY.md` for the trust and reporting policy.

The EdDSA private key is release-critical: it must be stored in the protected release environment, backed up independently in encrypted form and tested through a recovery drill before the first update is published. A feed must never be published before all immutable release assets and signatures are available.

## Licensing and future paid features

Code published in this repository remains available under Apache-2.0. A future commercial edition may add separately distributed closed-source modules or services, but that does not revoke or change the license already granted for any published Ushot code.

## Project documents

- `docs/ARCHITECTURE.md` — module and failure boundaries.
- `docs/MANUAL_TESTING.md` — required hardware and interaction matrix.
- `docs/PERFORMANCE.md` — Instruments scenarios and measurement method.
- `docs/ROADMAP.md` — completed phases and release-readiness work.
- `PRIVACY.md` — data and permission behavior.
- `SECURITY.md` — vulnerability reporting and update trust.
- `CHANGELOG.md` — user-visible changes by release.
- `CONTRIBUTING.md` — development workflow.
- `STATUS.md` — current implementation and validation state.
