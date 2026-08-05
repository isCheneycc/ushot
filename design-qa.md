# Editor Settings Design QA

- Source visual truth: `/var/folders/w5/z61k9dxj333dgyyqs38hlsdm0000gn/T/codex-clipboard-28958409-4044-4bfb-a9cc-63de77d6d159.png`, together with the user's explicit annotations for the obstructed Rectangle summary, editable toolbar-default color, Circle terminology, pixel units, 4 px Rectangle radius and tooltip removal.
- Implementation screenshot: `/Users/cheney/Documents/ai/ushot/build/design-qa/editor-settings-defaults/implementation-dark.png`
- Combined comparison: `/Users/cheney/Documents/ai/ushot/build/design-qa/editor-settings-defaults/comparison-dark.png`
- Viewport: native macOS settings window captured by Computer Use at 720 × 562 px.
- Normalization: the 1440 × 1124 px source was downsampled exactly to 720 × 562 px before side-by-side comparison.
- State: Simplified Chinese, dark appearance, Editor tab, Text defaults selected, same saved palette and content state.

## Full-view comparison evidence

The side-by-side comparison preserves the approved palette → progressive tool defaults → effect preview hierarchy and the same native density. The revised Rectangle summary now displays `3 px · 圆角 4 px` without an ellipsis or collision at the master/detail divider. `圆形` replaces the former `椭圆`, and the Text size is shown as `18 px`. The toolbar-default color value remains in the same position and gains only the disclosure affordance needed to make it interactive.

## Focused-region evidence

The accessibility tree was inspected because the complete color menu is not visible in the closed full-view state. At the time of this captured comparison, opening `settings.editor.defaultAnnotationColor` exposed the then-configured factory six plus saved color `#FF2D55`; selecting that value updated both the menu value and selected palette ring immediately. The current palette manager treats every configured entry uniformly, so factory and user colors can now all be removed, re-added or replaced. The tree also exposed the complete Rectangle summary, Circle title, `18 px` font-size value and `4 px` corner-radius value without truncation.

## Comparison history

### Iteration 1 findings

- [P2] The fixed-width sidebar attempted to fit color name, line width and corner radius on one line, truncating the Rectangle value.
- [P2] The toolbar-default color summary was a static value display, so custom palette additions could not be chosen from that control.
- [P2] The user-facing tool name still said Ellipse, and font size/corner radius still presented logical-point units.
- [P2] The annotation canvas installed an AppKit tooltip that obscured the selected image after hover.

### Fixes made

- The sidebar uses a compact, value-preserving summary when the full color-name variant does not fit, while its accessibility label retains the complete name and measurements.
- The static color summary was replaced with the existing native full-palette menu, making every configured color eligible as the toolbar default; the complete palette can now be customized and restored to its factory six independently.
- User-facing terminology is now Circle/圆形. Font size, line width and Rectangle radius default to physical pixels, independently support `px`/`pt`, and apply their persisted unit through the capture backing scale; Rectangle radius defaults to 4 px.
- The canvas tooltip assignment and its obsolete localized string were removed.

### Post-fix visual evidence

The final same-state comparison contains no actionable P0, P1 or P2 mismatch. The smaller preview sample is intentional: `18 px` now represents 18 physical backing pixels instead of the former 18 logical points. The requested layout, terminology and interaction changes remain within the approved native structure.

## Interaction and regression coverage

- Computer Use verified the complete default-color menu, selected custom `#FF2D55`, observed the persisted value and restored red.
- Computer Use verified Rectangle `3 px · 圆角 4 px`, Circle/圆形 and Text `18 px` in the live accessibility tree and final dark-mode capture.
- Four focused Core tests passed: product defaults, v1 migration, v2 migration and 2x pixel-to-logical conversion for line width, font size and Rectangle radius.
- A targeted `UshotApp` compile and the stable signed Release build both completed successfully.

## Remaining checklist

- None for this pass.

final result: passed
