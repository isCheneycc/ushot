# Performance Verification

Performance claims must be measured on a Release build made with a full Xcode installation. Record the Mac model, macOS version, display count/scale/profile and capture dimensions with every result.

## Instruments templates

- **Time Profiler:** shortcut-to-overlay latency, ScreenCaptureKit callbacks, annotation render and Image I/O export.
- **Core Animation:** region selection, quick freehand drawing, canvas pan/zoom and color-picker magnifier frame pacing.
- **Allocations / Leaks:** repeated all-display captures and current-screenshot replacements, editor open/close and history browsing.
- **System Trace:** unexpected main-thread stalls during capture and export.

## Scenarios

1. Capture a region on the built-in Retina display 20 times and measure hot-key event to interactive overlay.
2. Repeat with a 1x external display positioned left, right, above and below the primary display.
3. Capture all displays, draw a continuous freehand stroke for 10 seconds, then undo/redo and export.
4. Replace the current screenshot with ten consecutive 4K captures, trigger memory pressure and verify only the current rebuildable export cache remains.
5. Move the live color picker continuously across mixed 1x/2x displays. Confirm at most one 11×11 ScreenCaptureKit request is in flight and stale mouse positions are coalesced.
6. Populate 500 history records and scroll, open, copy, export and delete without decoding every full image eagerly.
7. From a fresh Release launch, record physical footprint at idle, frozen region hover, selection, annotation, output and after closing all capture surfaces. Repeat three times with the same display layout and region size. Record allocation-logging overhead separately; a process lifetime peak alone does not identify the responsible phase.

## Acceptance observations

- Selection, drawing and scrolling should remain visually responsive without sustained main-thread work above one display frame.
- Image render generations may be discarded when superseded; thrown failures must still be surfaced and logged.
- A session has one running bitmap render, plus only the latest pending authoritative and interactive inputs. Transparent region confirmation does not render a full composite before output demand.
- Pointer movement updates frozen-region chrome and the magnifier without repainting the full frozen desktop. A retained small single-display crop must release its source IOSurface when capture preparation ends.
- PNG encoding must not occur for every mouse-move event. History encoding runs on its serialized store actor, and picker sampling is limited to a small physical-pixel region.
- Memory growth after replacing or closing the current screenshot/editor should settle after caches are released.

Store measured traces outside the repository when they contain window names or other user context. Add summarized, non-sensitive results here before a public release.
