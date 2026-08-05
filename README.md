# UshotApp

UshotApp is a native, local-first macOS 14+ screenshot and annotation utility built with SwiftUI, AppKit, ScreenCaptureKit, Core Graphics, Core Image and Image I/O. It has no account, telemetry, advertising SDK, or network service.

> Product identity, license and signing identity are intentionally temporary. See `docs/DECISIONS_NEEDED.md`.

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

## Build and test with Xcode

```bash
xcodebuild -project ScreenshotApp.xcodeproj -scheme ScreenshotApp -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

```bash
xcodebuild -project ScreenshotApp.xcodeproj -scheme ScreenshotApp -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

If an installed `UshotApp.app` is already running, quit it before UI tests or give the test build an isolated identity by adding `APP_BUNDLE_IDENTIFIER=com.example.UshotApp.UITestsHost` to the command.

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
~/Library/Application Support/com.example.UshotApp/History/<capture-uuid>/
```

Each record contains `base.png`, `preview.png`, `document.json` and `metadata.json`. Turning history off stops new records and does not delete old records.

## Release

Installed local Release builds require a stable Apple Development signature so macOS Screen Recording authorization survives code updates. Developer ID signing and notarization use environment variables or a keychain profile; no secret belongs in the repository. See `docs/RELEASING.md`.

## Project documents

- `docs/ARCHITECTURE.md` — module and failure boundaries.
- `docs/MANUAL_TESTING.md` — required hardware and interaction matrix.
- `docs/PERFORMANCE.md` — Instruments scenarios and measurement method.
- `PRIVACY.md` — data and permission behavior.
- `CONTRIBUTING.md` — development workflow.
- `STATUS.md` — current implementation and validation state.
