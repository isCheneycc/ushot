import CoreGraphics
import Foundation

/// Shared helpers for region-capture corner radius.
///
/// Selection geometry remains an axis-aligned rectangle (`desktopFrame`).
/// This value is only a presentation and composite effect: overlay hole, blue
/// chrome, canvas clip, and `AnnotationDocument.canvasEffects.cornerRadius`.
/// The user-facing defaults live in `CaptureSettings` (`regionCornerRadius` +
/// unit); this type owns clamp math and the factory default values.
public enum RegionCaptureCornerRadius {
    /// Factory displayed value for Capture settings (paired with `defaultUnit`).
    public static let defaultDisplayedValue: Double = 12
    /// Factory unit: physical pixels (12 px at the capture backing scale).
    public static let defaultUnit: AnnotationMeasurementUnit = .pixels
    /// Approximate logical fallback when no capture scale is available (12 px at 2x).
    public static let defaultLogicalPoints: CGFloat = 6

    /// Clamps a configured logical radius so it never exceeds half the shorter side.
    public static func effective(
        for selectionSize: CGSize,
        configured: CGFloat = defaultLogicalPoints
    ) -> CGFloat {
        let width = selectionSize.width
        let height = selectionSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return 0
        }
        let limit = min(width, height) / 2
        guard limit.isFinite, limit > 0 else { return 0 }
        let requested = configured.isFinite ? max(0, configured) : 0
        return min(requested, limit)
    }
}
