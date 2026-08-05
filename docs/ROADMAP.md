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

Status: direct-download publication and production-updater readiness are tracked independently.

- Adopt the permanent `Ushot` product name, `io.github.ischeneycc.ushot` bundle identifier, `isCheneycc/ushot` repository and Apache-2.0 license.
- Integrate Sparkle behind the existing `UpdateChecking` boundary with manual checks only and an embedded EdDSA public key. Keep the 0.1.1 legacy `/updates/appcast.xml` permanently absent; pin 0.1.2 and later to `/updates/v1/appcast.xml`. Generate that feed with the official upstream Sparkle 2.9.5 `--embed-release-notes` tool, require one signed restricted-Markdown description per item, reject all note links/external destinations plus detached notes, item links and deltas, enforce exact RSS/Sparkle namespaces and strictly increasing versions/builds, and deploy no Pages payload other than the signed v1 appcast.
- Produce deterministic ad-hoc arm64 DMG/ZIP/dSYM/manifest/checksum assets without Developer ID or notarization. The protected workflow's default direct-download path publishes and anonymously verifies all five GitHub assets without reading an update key or creating a Pages payload.
- Preserve 0.1.1 as the published direct-download preview whose manual update command reaches the permanently absent legacy endpoint.
- Prepare 0.1.2 (build 3) as the one-time manually installed hardened transition. Its runtime fork must require `SURequireExactUpdateVersionIdentity=true`, `SURequireEdDSAUpdateArchiveSignature=true` and framework capability marker `SUUpdateVersionIdentityHardeningVersion=1`, then reject extracted short/build mismatch and archive EdDSA failure without a code-signing fallback. Publish 0.1.2 with `publish_update_feed=false`; it remains pending until the real immutable Release exists.
- Protect and back up the EdDSA private key, add supply-chain checks and document the privacy/network boundary.
- Complete the release-blocking clean-account 0.1.2 → 0.1.3 matrix, including framework capability admission, helper loading, exact short/build mismatch rejection, independent archive EdDSA/tamper rejection, atomic replacement, active-work admission, quarantine, Screen Recording authorization and key recovery.
- Activate `publish_update_feed=true` for the first permitted item, 0.1.3 (build 4), only after that complete matrix has recorded evidence. A successful hardened build, direct-download Release or CI run does not complete the updater track.

## Later

- After the hardened ad-hoc update path passes its matrix, separately evaluate Apple Developer Program membership, Developer ID signing and notarization. Preserve the bundle identifier and Sparkle EdDSA trust chain during any migration; membership is not required for the current rollout.
- Consider Universal 2 distribution only after Intel hardware validation and demand review.
- Post-1.0 product ideas: scrolling capture, recording, GIF, delayed capture, OCR and translation.
- Optional paid capabilities may use separately distributed closed-source modules or services behind the existing feature boundary. Ushot code already published under Apache-2.0 remains Apache-2.0 permanently.
