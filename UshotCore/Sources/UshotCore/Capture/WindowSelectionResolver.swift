import CoreGraphics
import Foundation

public struct WindowSelectionResolver: Sendable {
    public init() {}

    public func topmostWindow(
        at point: CGPoint,
        candidates: [WindowDescriptor]
    ) -> WindowDescriptor? {
        candidates.first { candidate in
            // Only normal application windows are selectable. Higher layers
            // include the menu bar and Dock; allowing them here made a
            // display-sized Dock surface win every hit test before windows
            // from other applications were considered.
            candidate.layer == 0 && candidate.frame.contains(point)
        }
    }
}
