import CoreGraphics
import Foundation

public struct WindowSelectionResolver: Sendable {
    public init() {}

    public func topmostWindow(
        at point: CGPoint,
        candidates: [WindowDescriptor]
    ) -> WindowDescriptor? {
        candidates.first { candidate in
            // Normal application windows and registered pinned images are
            // selectable. Other layers include the menu bar and Dock; allowing them made a
            // display-sized Dock surface win every hit test before windows
            // from other applications were considered.
            (candidate.layer == 0 || candidate.isPinnedImage) && candidate.frame.contains(point)
        }
    }
}
