# Manual Testing

Record macOS version, hardware, display arrangement and app build before each run.

## Environment Matrix

- [ ] Apple Silicon Mac with built-in Retina display
- [ ] One external display
- [ ] Mixed 1x and 2x displays
- [ ] External display left, right, above and below the primary display
- [ ] Full-screen application, Stage Manager and multiple Spaces
- [ ] Light, dark and increased-contrast appearances
- [ ] Displays with different color profiles
- [ ] Sleep/wake and display hot-plug

## Permission and Capture

- [ ] Screen recording permission: not determined, denied, granted and revoked
- [ ] Region, window, current display, selected display and all displays
- [ ] Put unmistakable TOP/BOTTOM content on displays arranged above, below, left and right of the primary display, then capture all displays. Confirm each display remains upright, relative placement and transparent gaps are correct, and the result matches separate single-display captures on both 1x and 2x screens
- [ ] Enter region mode while something on screen is moving; confirm every display freezes before the mask appears and remains unchanged throughout selection and editing
- [ ] Before mouse-down, move the pointer over very light, very dark and detailed content and along all four display edges. Confirm the region magnifier follows without lag, keeps its rounded image clipping, soft shadow and thin dual-contrast keyline with no padded black frame, and marks the actual sampled pixel even when its crop or placement shifts at an edge. Mouse-up must hide it immediately
- [ ] Move the pointer across overlapping windows from Finder and at least two other applications before dragging. Confirm the frontmost containing app window highlights immediately, the full-screen Dock/desktop surface is never selected, and one click accepts the app window; start dragging from the same highlight and confirm the gesture switches cleanly to a manual rectangle instead of forcing the window frame
- [ ] Without Accessibility permission, confirm window snapping still works and Settings → Capture reports that only interface-control refinement is unavailable. After granting Accessibility, hover buttons, text fields, sidebars and panels in several apps and confirm the highlighted frame refines to useful child elements without ever selecting Ushot's own overlay
- [ ] After dragging a valid region, mouse-up presents the confirmation immediately with no fade/scale animation: exactly one blue eight-handle border remains, everything outside it stays masked, and the complete annotation/output toolbar appears with additional Pin and Cancel actions; Click Through, Temporarily Hide Image and Open Canvas Editor are absent, and no cropped screenshot preview or pinned image appears
- [ ] Inspect and drag every confirmation handle: each circle center must sit exactly on the blue border (including all four corners), the frame must update continuously, the opposite edge must stay fixed, no duplicate handles may overlap, and mouse-up must refresh the selected pixels from the original frozen desktop. Repeat from multiple positions between the visible points on all four border lines; every point on the line must resize with the matching cursor
- [ ] Switch to Select and drag genuinely empty canvas space. Confirm the complete selected frame, blue border, toolbar anchor and existing annotations move together without changing canvas size or annotation-local geometry; this must be distinct from border resizing
- [ ] Add a stroked Rectangle, then press and slowly resize the confirmation frame horizontally and vertically. While the mouse is still down, confirm the rectangle and its eight handles remain fixed on the same desktop pixels, only newly included/excluded area changes, and neither vertical nor horizontal strokes become thinner. After mouse-up, confirm the same position and line width remain, then use Undo/Redo and verify the edit timeline is intact
- [ ] Leave a region confirmation open and press `Control + Option + A` again. Confirm one rejection beep occurs, no error alert or second mask appears, and the existing selection, annotations and state remain unchanged; its toolbar, handles, Copy/Save/Pin and `Esc` must all still respond immediately
- [ ] Before resizing or taking any other action after mouse-up, use Rectangle inside the blue border and confirm the first gesture immediately appears. Then verify Freehand and Text too; every mouse-down must reach the canvas, visibly edit the frozen selected area, increment the annotation state and remain undoable. Neither the full-screen frozen overlay nor the transparent resize chrome may consume interior drawing input
- [ ] Click Copy and confirm the composed image reaches the clipboard, then the mask, selection border, annotation surface and toolbar all close without creating or replacing a pinned image. Repeat with a selected annotation using `Command-C`; it must copy the complete composite rather than only the annotation and close the same capture group
- [ ] While a region resize/move recrop is still committing, press `Command-C` and confirm the app rejects it without changing the clipboard or completing the selection; after the handles become active again, retry and confirm the new frame is what gets copied. Also start Copy on a heavily annotated region and immediately press `Esc` or Cancel: the capture must close without a late clipboard write, crash or delayed completion callback
- [ ] Click Save, cancel its panel and confirm selection remains active; repeat and complete the save, then confirm the entire capture UI closes only after the file is written
- [ ] Click Pin and confirm the overlay and complete toolbar disappear, the annotated result stays at the exact selected frame as a pinned image, and clicking or dragging over existing annotations cannot select, move, resize or create annotations after Pin
- [ ] Hover a read-only pinned image: its body must show an open hand; press and hold without moving and confirm it switches immediately to a closed hand, then drag and confirm that same closed hand remains uninterrupted until release without flashing back to the arrow/open hand. Every edge/corner must show the matching horizontal, vertical or diagonal resize cursor and resize proportionally when dragged
- [ ] Right-click the pinned image, use Copy Screenshot and confirm it stays pinned; choose Show Toolbar and confirm annotations become editable and Click Through, Temporarily Hide Image and Open Canvas Editor are now present, then choose Hide Toolbar and confirm editing ends and the image is read-only again
- [ ] Press `Esc` or the complete toolbar's Cancel button before Pin and confirm the draft, toolbar and selection overlay are all destroyed without leaving or replacing a pinned image
- [ ] On a Retina display, compare the selection's point/pixel label and exported PNG dimensions; a 100 × 60 pt region must produce approximately 200 × 120 physical pixels at 2x
- [ ] Disconnect a display during capture
- [ ] Close a candidate window during window selection
- [ ] Confirm overlays, toolbars and Ushot windows are absent from output

## Editing and Interoperability

- [ ] A second completed capture replaces the first; cancelling the second capture leaves the first intact
- [ ] Clicking the desktop or another app leaves the current screenshot and any attached quick toolbar visible
- [ ] On a newly presented window/current-display/selected-display/all-display screenshot, click toolbar Copy and repeat in a fresh capture with screenshot-level `Command-C`; after each successful clipboard write both image and toolbar must close. A failed export must stay visible for retry. After explicit region Pin, toolbar/keyboard copy must instead keep the pinned image visible, and right-click Copy Screenshot must always keep it visible
- [ ] `Esc` closes the current screenshot; when a quick toolbar is attached, its close button closes both image and toolbar
- [ ] Chinese IME text annotation: with Pinyin active, type a multi-letter syllable and confirm the complete marked spelling remains visible (not only its first letter) and the candidate window opens beside the caret, including near the screenshot's right edge
- [ ] The pinned Text tool is shown as `A`; clicking empty image space shows a single-line field around the caret with a fixed 4 px corner radius, an accent border, no background fill or placeholder, and all entered text clipped inside the field while the screenshot remains visible underneath
- [ ] While entering mixed Latin/Chinese text or replacing an existing annotation, confirm the text field frame and first-glyph baseline remain fixed from the first key through IME composition, commit and focus loss
- [ ] With text input active, one `Esc` discards any unfinished IME marked composition, ends input and keeps the screenshot and toolbar open; a second `Esc` closes both
- [ ] Enter mixed Chinese/Latin text, note its first glyph and baseline while the caret is active, then press `Esc` or click elsewhere; the committed text must stay on the same pixels without a horizontal or vertical jump
- [ ] Clicking completed text edits the same annotation in place (annotation count does not increase); dragging completed text moves it, and clicking a genuinely empty position creates a new annotation
- [ ] While a Text field is active, choose a different toolbar color and confirm the current input changes immediately. Commit it, create another Text field and confirm the new field returns to Settings → Editor → Text color; reopen the first field and confirm its edited color is preserved
- [ ] In Settings → Editor, set different defaults for Text, Rectangle and Circle, then create one of each and confirm every new annotation starts with its own configured color. Change the Text font from System Font to an installed family, verify new text uses it, then restore System Font
- [ ] In Settings → Editor, confirm each current color is shown as a swatch, localized color name and HEX value. Click the trailing blank area—not only the label—of each Text/Rectangle/Circle master row and verify the matching controls and preview switch. Open Manage Palette, add a user color, remove one of the original six and choose the new color as its replacement; every default using the removed color must switch while existing annotations remain unchanged. Use Restore Default Colors → Restore and Keep Custom Colors and confirm the factory six appear first while custom colors, custom tool defaults, font, size, line width and radius remain unchanged. Then choose Replace with Default Colors and confirm exactly the factory six remain and affected tool defaults become red. Re-select an annotation that still uses a removed color and confirm the toolbar shows it only as a disabled temporary current-value swatch
- [ ] On a 2x capture, confirm the quick toolbar defaults to `px`; switching `3 px` to `pt` displays `1.5 pt` without changing the rendered stroke, and switching back restores `3 px`
- [ ] Select the line-width field and type `1`, then `.`, then `5` as separate keystrokes. Confirm the visible intermediate value is `1.` (the caret does not jump and the field does not become `1` or `15`), then commit with Return or by leaving the field; close the screenshot and capture again, and confirm `1.5` plus the selected `px`/`pt` unit are retained
- [ ] Without drawing or switching tools, set Rectangle width to a visibly different value and immediately draw; confirm the first Rectangle uses it. While that Rectangle remains selected, type another width and confirm it previews on every valid keystroke, then Undo/Redo once and confirm only that Rectangle changes. Draw a second Rectangle immediately and confirm it uses the independent default rather than the edited first width, and that the field switches to the new selection's width. Switch to Select while that Rectangle remains selected and confirm the field stays enabled and edits it. Finally clear selection, return to Rectangle, enter a third width and draw again; confirm the older Rectangles keep their own widths, the new Rectangle uses the new default, and no tool switch is needed merely to apply a width
- [ ] Open the Rectangle/Circle/Arrow secondary menu and confirm it appears below the toolbar. Repeat with a near-full-screen capture and confirm the complete toolbar remains visible; it may overlap the capture when no outside space exists
- [ ] With the screenshot focused and no text field active, press `1`…`9`, `0`, `-`, `[` and confirm they select the corresponding toolbar tools; Spotlight uses `[`. Confirm Crop is absent from the region/pinned toolbar, Canvas Editor rail and Settings → Shortcuts, and pressing `=` does not change the active tool
- [ ] In Settings → Shortcuts, assign bare F1 and F2 to two global actions and confirm they display by name, persist after relaunch and invoke the correct actions. Confirm a bare ordinary letter is still rejected, modified ordinary keys still work, and a macOS-reserved/conflicting function key leaves the previous registration active. Replace one annotation-tool shortcut, confirm duplicate assignments are rejected visibly, then capture again and verify the new shortcut; Restore Defaults must restore both global and annotation shortcuts
- [ ] After drawing Rectangle, Ellipse, Highlight or another resizable frame annotation, confirm eight handles appear immediately even while that drawing tool remains selected, with no blue selection outline
- [ ] Draw a Freehand stroke whose path changes in both X and Y. Confirm it remains a pure brush path with zero resize handles and no Scale X/Scale Y controls in the full editor; selecting and moving the complete stroke must still work
- [ ] Draw a wide, thin Highlight, resize its height substantially from a vertical handle, then click its body and empty canvas space. Confirm the app remains open, the toolbar color stays on the highlight's palette color, the fill remains translucent, and the committed bounds do not jump merely from clicking
- [ ] Hover a movable selected annotation body and confirm an open-hand cursor; drag and confirm a closed-hand cursor plus continuous 1:1 movement of the actual annotation with no old-position ghost or mouse-up jump
- [ ] Draw Mosaic and Blur and confirm selecting either shows zero resize handles; body drag, edge drag, arrow-key nudge, alignment, distribution and the full-editor inspector must not move or resize the original effect region
- [ ] Click the toolbar color control and rapidly switch among the currently configured colors. Confirm the native menu dismisses immediately on every choice, the active text/selection follows without a visible pause, and no system color panel appears. In Settings → Editor reduce the palette to user colors only, then start another capture and switch through every annotation tool—including Highlight—without a crash or an off-palette tool default; confirm the capture toolbar itself has no add/remove action
- [ ] Draw Spotlight and confirm the drag phase keeps the whole source canvas unchanged with only an accent rectangle; after mouse-up, confirm the rectangular focus area remains unchanged while the rest of the image is dimmed in both editing and copied/saved output
- [ ] With a committed Spotlight visible, drag each of the eight outer region handles and confirm every newly revealed strip is dimmed during the drag itself; no light strip may remain until mouse-up
- [ ] Hover every frame handle and confirm the directional resize cursor; resize in each direction and confirm continuous feedback, a stable opposite edge and a sensible minimum size
- [ ] Draw Line and Solid/Tapered Arrow annotations, then drag each endpoint handle and confirm the rendered line/arrow follows the pointer continuously and its tip remains the release point. Solid arrowheads must have paper-plane-like diagonal rear edges converging into the shaft—no flat base, gap or round-cap bulge—and the live drag, committed canvas, Arrow style thumbnail and copied/saved output must match
- [ ] Move or resize one annotation, press Undo once and confirm the entire gesture is reverted as one history operation
- [ ] Keep a pinned screenshot open, open the full Canvas Editor, start text input there and press `Esc`; only Canvas text input ends, while both the Canvas window and pinned screenshot remain open
- [ ] In the full Canvas Editor, select an annotation so its inspector is visible, then Undo or delete that annotation while changing an inspector control; the selection and inspector must disappear coherently without a crash or stale-property write
- [ ] Undo/redo and layer ordering after every tool type
- [ ] In the pinned toolbar, the first drag after selecting a tool draws immediately; selected-tool, undo/redo, hide and click-through states remain visible and synchronized
- [ ] Draw an annotation and immediately Copy or Save; the exported image must contain the latest annotation at the original physical-pixel resolution
- [ ] Copy or Save while an annotation is selected; exported pixels must contain the annotation but never the selection outline or handles
- [ ] Drag to Finder, Mail, a browser and one chat application
- [ ] PNG profiles inspected for sRGB and Display P3 captures
- [ ] VoiceOver labels, keyboard navigation and Reduce Motion

## Color Picker

- [ ] Permission denied and revoked: no overlay appears; Capture settings opens with an actionable status
- [ ] Move continuously across every display; the magnifier stays responsive and never samples an Ushot overlay
- [ ] Verify center-pixel crosshair and physical-pixel coordinates at all four display edges
- [ ] On mixed 1x/2x displays, arrow keys move exactly 1 physical pixel and Shift-arrow moves 10
- [ ] Cycle sRGB, Display P3, Generic RGB and Adobe RGB (1998); relaunch and confirm the last space persists
- [ ] Compare sRGB HEX and Display P3 CSS values with Digital Color Meter; inspect Generic/Adobe labels and source profile
- [ ] Click and Command-C copy the configured representation; Esc destroys every overlay panel

## Screen Ruler

- [ ] Drag rectangle and line measurements on each display and across negative-coordinate display arrangements
- [ ] Verify point, physical-pixel and distance values on both 1x and 2x screens
- [ ] Hold Shift while dragging and confirm horizontal, vertical and 45-degree constraints
- [ ] Use arrow and Shift-arrow to nudge the endpoint; Command-C copies all coordinates and scale context
- [ ] Press Tab to switch shape, R to restart, and Esc to destroy every overlay panel
