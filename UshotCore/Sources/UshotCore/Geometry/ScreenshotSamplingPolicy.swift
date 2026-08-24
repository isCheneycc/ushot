import CoreGraphics
import Foundation

public enum ScreenshotSamplingMode: String, Equatable, Sendable {
    case oneToOne = "one-to-one"
    case uniformDownsample = "uniform-downsample"
    case uniformUpsample = "uniform-upsample"
    case nonUniform = "non-uniform"
}

public struct ScreenshotSamplingDecision: Equatable, Sendable {
    public let mode: ScreenshotSamplingMode
    public let horizontalScale: CGFloat
    public let verticalScale: CGFloat

    public var usesNearestNeighbor: Bool { mode == .oneToOne }
}

public enum ScreenshotSamplingPolicy {
    /// Floating-point conversions between AppKit and backing coordinates can
    /// introduce tiny residuals, but half a physical pixel is visually real.
    private static let pixelEqualityTolerance: CGFloat = 0.01

    public static func decision(
        sourcePixelSize: CGSize,
        destinationPixelSize: CGSize
    ) -> ScreenshotSamplingDecision {
        precondition(isValid(size: sourcePixelSize), "Screenshot sampling requires a finite, positive source pixel size.")
        precondition(isValid(size: destinationPixelSize), "Screenshot sampling requires a finite, positive destination pixel size.")

        let horizontalScale = destinationPixelSize.width / sourcePixelSize.width
        let verticalScale = destinationPixelSize.height / sourcePixelSize.height
        let mode: ScreenshotSamplingMode
        if abs(destinationPixelSize.width - sourcePixelSize.width) <= pixelEqualityTolerance,
           abs(destinationPixelSize.height - sourcePixelSize.height) <= pixelEqualityTolerance {
            mode = .oneToOne
        } else {
            let scaleTolerance = max(
                0.000_001,
                max(abs(horizontalScale), abs(verticalScale)) * 0.000_001
            )
            if abs(horizontalScale - verticalScale) > scaleTolerance {
                mode = .nonUniform
            } else if horizontalScale < 1 {
                mode = .uniformDownsample
            } else {
                mode = .uniformUpsample
            }
        }
        return ScreenshotSamplingDecision(
            mode: mode,
            horizontalScale: horizontalScale,
            verticalScale: verticalScale
        )
    }

    /// The point size that maps every source pixel to exactly one backing
    /// pixel on the current destination display.
    public static func pixelExactPointSize(
        sourcePixelSize: CGSize,
        backingScale: CGFloat
    ) -> CGSize {
        precondition(isValid(size: sourcePixelSize), "A pixel-exact presentation requires a finite, positive source size.")
        precondition(backingScale.isFinite && backingScale > 0, "A pixel-exact presentation requires a finite, positive backing scale.")
        return CGSize(
            width: sourcePixelSize.width / backingScale,
            height: sourcePixelSize.height / backingScale
        )
    }

    private static func isValid(size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }
}
