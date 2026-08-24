import CoreGraphics
import Foundation

/// Canonical geometry for presenting and zooming a raster screenshot.
///
/// Every derived frame uses the immutable native aspect ratio. This prevents
/// AppKit's intermediate backing-pixel quantization from accumulating into a
/// different width/height ratio during a magnification gesture.
public struct PinnedShotPresentationGeometry: Equatable, Sendable {
    public let nativeSize: CGSize

    public init(nativeSize: CGSize) {
        precondition(Self.isValid(size: nativeSize), "A screenshot presentation requires a finite, positive native size.")
        self.nativeSize = nativeSize
    }

    public func fittedSize(within availableSize: CGSize) -> CGSize {
        precondition(Self.isValid(size: availableSize), "A screenshot presentation requires a finite, positive available size.")
        let scale = min(
            1,
            availableSize.width / nativeSize.width,
            availableSize.height / nativeSize.height
        )
        return CGSize(
            width: nativeSize.width * scale,
            height: nativeSize.height * scale
        )
    }

    /// Returns a frame derived only from the gesture's immutable begin state.
    /// `cumulativeMagnification` is the recognizer value since `.began`.
    public func zoomedFrame(
        from beginFrame: CGRect,
        anchoredAt anchor: CGPoint,
        cumulativeMagnification: CGFloat,
        widthRange: ClosedRange<CGFloat>
    ) -> CGRect {
        precondition(Self.isValid(rect: beginFrame), "A screenshot zoom requires a finite, positive begin frame.")
        precondition(
            anchor.x.isFinite && anchor.y.isFinite,
            "A screenshot zoom requires a finite anchor."
        )
        precondition(cumulativeMagnification.isFinite, "A screenshot zoom requires finite magnification.")
        precondition(
            widthRange.lowerBound.isFinite
                && widthRange.upperBound.isFinite
                && widthRange.lowerBound > 0
                && widthRange.lowerBound <= widthRange.upperBound,
            "A screenshot zoom requires a finite, positive width range."
        )

        let unitAnchor = CGPoint(
            x: (anchor.x - beginFrame.minX) / beginFrame.width,
            y: (anchor.y - beginFrame.minY) / beginFrame.height
        )
        var targetWidth = min(
            max(beginFrame.width * (1 + cumulativeMagnification), widthRange.lowerBound),
            widthRange.upperBound
        )
        let targetSize: CGSize
        if widthRange.contains(nativeSize.width),
           abs(targetWidth - nativeSize.width) <= max(8, targetWidth * 0.015) {
            // Snap both axes together. Snapping only the width would leave a
            // resampled height and make a nominal 100% preview non-uniform.
            targetSize = nativeSize
        } else {
            targetWidth = min(max(targetWidth, widthRange.lowerBound), widthRange.upperBound)
            targetSize = CGSize(
                width: targetWidth,
                height: targetWidth * nativeSize.height / nativeSize.width
            )
        }
        let origin = CGPoint(
            x: anchor.x - unitAnchor.x * targetSize.width,
            y: anchor.y - unitAnchor.y * targetSize.height
        )
        return CGRect(origin: origin, size: targetSize)
    }

    /// Keeps a frame fully inside a visible frame without changing its size.
    /// Callers must fit the size first; silently shrinking here would create a
    /// second, competing scaling policy.
    public static func clampedFrame(_ frame: CGRect, within visibleFrame: CGRect) -> CGRect {
        precondition(isValid(rect: frame), "A screenshot presentation requires a finite, positive frame.")
        precondition(isValid(rect: visibleFrame), "A screenshot presentation requires a finite, positive visible frame.")
        precondition(
            frame.width <= visibleFrame.width && frame.height <= visibleFrame.height,
            "A screenshot frame must fit before its origin can be clamped."
        )
        return CGRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }

    private static func isValid(size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }

    private static func isValid(rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && isValid(size: rect.size)
    }
}
