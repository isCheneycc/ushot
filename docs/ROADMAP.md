# Roadmap

## Implemented foundation

- Phase 0 — repository, native project, centralized configuration, app shell, dependency container, logging and test target.
- Phase 1 — menu bar, versioned settings, permission guidance, login item and conflict-safe Carbon hot keys.
- Phase 2 — current/selected/all-display, window and region capture backed by ScreenCaptureKit and tested global geometry.
- Phase 3 — one persistent current-screenshot panel with replacement semantics, copy, save, drag, resizing and an attached annotation toolbar.
- Phase 4 — versioned non-destructive annotation model, renderer, commands, undo and quick annotation tools.
- Phase 5 — multi-window Canvas Editor sharing the Phase 4 document and renderer.
- Phase 6 — managed-color pixel picker and point/pixel screen ruler across displays.
- Phase 7 — opt-in editable history, accessibility/localization work, performance validation and local release packaging.

## Phase 8 — open-source release and manual updates

Status: implementation and release-readiness validation in progress.

- Adopt the permanent `Ushot` product name, `io.github.ischeneycc.ushot` bundle identifier, `isCheneycc/ushot` repository and Apache-2.0 license.
- Integrate Sparkle behind the existing `UpdateChecking` boundary with manual checks only, an embedded EdDSA public key and the fixed GitHub Pages appcast. Generate it with `--embed-release-notes`, require one signed restricted-Markdown description per item, reject all note links/external destinations plus detached notes, item links and deltas, enforce exact RSS/Sparkle namespaces and strictly increasing versions/builds, and deploy no Pages payload other than the signed appcast.
- Produce deterministic ad-hoc arm64 DMG/ZIP/dSYM/manifest/checksum assets without Developer ID or notarization; publish immutable GitHub assets before the appcast.
- Protect and back up the EdDSA private key, add supply-chain checks and document the privacy/network boundary.
- Complete the release-blocking clean-account old-version → new-version matrix, including helper loading, tamper rejection, atomic replacement, active-work admission, quarantine and Screen Recording authorization behavior.
- Close Sparkle's client-side enclosed-app version validation gap; protected CI already rejects mismatched final ZIPs, but that is not a runtime substitute and production self-update remains blocked meanwhile.
- Publish the first public release only after every mandatory item above has recorded evidence. Build/CI success alone does not complete this phase.

## Later

- Resolve Sparkle's matching-Developer-ID fallback so archive EdDSA remains independently mandatory, then evaluate Developer ID signing and notarization. Preserve the bundle identifier and Sparkle EdDSA trust chain during any migration.
- Consider Universal 2 distribution only after Intel hardware validation and demand review.
- Post-1.0 product ideas: scrolling capture, recording, GIF, delayed capture, OCR and translation.
- Optional paid capabilities may use separately distributed closed-source modules or services behind the existing feature boundary. Ushot code already published under Apache-2.0 remains Apache-2.0 permanently.
