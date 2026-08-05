import CoreGraphics
import Foundation

public struct DisplayBackingMetrics: Equatable, Sendable {
    public let logicalSize: CGSize
    public let pixelSize: CGSize
    public let scale: CGFloat

    public init(logicalSize: CGSize, pixelSize: CGSize) throws {
        guard logicalSize.width.isFinite,
              logicalSize.height.isFinite,
              pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              logicalSize.width > 0,
              logicalSize.height > 0,
              pixelSize.width > 0,
              pixelSize.height > 0
        else {
            throw ScreenshotAppError.captureFailed(
                description: "Display geometry contains a non-positive or non-finite dimension."
            )
        }

        let horizontalScale = pixelSize.width / logicalSize.width
        let verticalScale = pixelSize.height / logicalSize.height
        let tolerance = max(0.001, max(horizontalScale, verticalScale) * 0.001)
        guard abs(horizontalScale - verticalScale) <= tolerance else {
            throw ScreenshotAppError.captureFailed(
                description: "Display backing scale is inconsistent between its horizontal and vertical axes."
            )
        }

        self.logicalSize = logicalSize
        self.pixelSize = pixelSize
        self.scale = horizontalScale
    }

    public static func current(
        displayID: CGDirectDisplayID,
        logicalSize: CGSize
    ) throws -> DisplayBackingMetrics {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            throw ScreenshotAppError.noDisplayAvailable
        }
        return try DisplayBackingMetrics(
            logicalSize: logicalSize,
            pixelSize: CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        )
    }
}

public struct DisplayGeometry: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let frame: CGRect
    public let scale: CGFloat

    public init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

public struct ScreenGeometry: Equatable, Sendable {
    public let displays: [DisplayGeometry]

    public init(displays: [DisplayGeometry]) {
        self.displays = displays
    }

    public var desktopBounds: CGRect {
        displays.reduce(.null) { partial, display in
            partial.union(display.frame)
        }
    }

    public var maximumScale: CGFloat {
        displays.map(\.scale).max() ?? 1
    }

    public func display(containing point: CGPoint) -> DisplayGeometry? {
        displays.first { $0.frame.contains(point) }
    }

    public func display(id: CGDirectDisplayID) -> DisplayGeometry? {
        displays.first { $0.id == id }
    }
}

public struct FloatingToolbarLayout: Equatable, Sendable {
    public var screenMargin: CGFloat
    public var imageSpacing: CGFloat
    public var reservedSpaceBelow: CGFloat

    public init(
        screenMargin: CGFloat = 8,
        imageSpacing: CGFloat = 8,
        reservedSpaceBelow: CGFloat = 0
    ) {
        precondition(screenMargin >= 0 && screenMargin.isFinite)
        precondition(imageSpacing >= 0 && imageSpacing.isFinite)
        precondition(reservedSpaceBelow >= 0 && reservedSpaceBelow.isFinite)
        self.screenMargin = screenMargin
        self.imageSpacing = imageSpacing
        self.reservedSpaceBelow = reservedSpaceBelow
    }

    public func toolbarOrigin(
        imageFrame: CGRect,
        toolbarSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        precondition(!imageFrame.isNull && !imageFrame.isInfinite)
        precondition(!visibleFrame.isNull && !visibleFrame.isInfinite)
        precondition(toolbarSize.width.isFinite && toolbarSize.width > 0)
        precondition(toolbarSize.height.isFinite && toolbarSize.height > 0)
        precondition(visibleFrame.width > 0 && visibleFrame.height > 0)

        let minimumX = visibleFrame.minX + screenMargin
        let maximumX = visibleFrame.maxX - screenMargin - toolbarSize.width
        let centeredX = imageFrame.midX - toolbarSize.width / 2
        let x = maximumX >= minimumX
            ? min(max(centeredX, minimumX), maximumX)
            : visibleFrame.midX - toolbarSize.width / 2

        let visibleMinimumY = visibleFrame.minY + screenMargin
        let visibleMaximumY = visibleFrame.maxY - screenMargin - toolbarSize.height
        if visibleMaximumY < visibleMinimumY {
            return CGPoint(
                x: x,
                y: visibleFrame.midY - toolbarSize.height / 2
            )
        }
        let reservedMinimumY = visibleMinimumY + reservedSpaceBelow
        let minimumY = reservedMinimumY <= visibleMaximumY
            ? reservedMinimumY
            : visibleMinimumY

        let belowImageY = imageFrame.minY - imageSpacing - toolbarSize.height
        if belowImageY >= minimumY && belowImageY <= visibleMaximumY {
            return CGPoint(x: x, y: belowImageY)
        }

        let aboveImageY = imageFrame.maxY + imageSpacing
        if aboveImageY >= minimumY && aboveImageY <= visibleMaximumY {
            return CGPoint(x: x, y: aboveImageY)
        }

        let y = min(max(belowImageY, minimumY), visibleMaximumY)
        return CGPoint(x: x, y: y)
    }
}

public struct CoordinateTransformer: Sendable {
    public let primaryDisplayHeight: CGFloat

    public init(primaryDisplayHeight: CGFloat) {
        self.primaryDisplayHeight = primaryDisplayHeight
    }

    public func appKitRect(fromScreenCaptureRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public func screenCaptureRect(fromAppKitRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public func pixelCropRect(
        for globalSelection: CGRect,
        in display: DisplayGeometry,
        imagePixelSize: CGSize
    ) -> CGRect? {
        let intersection = globalSelection.standardized.intersection(display.frame)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }

        let rawMinX = (intersection.minX - display.frame.minX) * display.scale
        let rawMaxX = (intersection.maxX - display.frame.minX) * display.scale
        let rawMinY = (display.frame.maxY - intersection.maxY) * display.scale
        let rawMaxY = (display.frame.maxY - intersection.minY) * display.scale

        let minX = max(0, floor(rawMinX))
        let minY = max(0, floor(rawMinY))
        let maxX = min(imagePixelSize.width, ceil(rawMaxX))
        let maxY = min(imagePixelSize.height, ceil(rawMaxY))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Returns a destination in the default Quartz bitmap-context coordinate
    /// system. Its origin is bottom-left, so drawing a top-to-bottom `CGImage`
    /// directly into this rectangle preserves the source pixel orientation.
    public func bitmapContextDestinationPixelRect(
        for display: DisplayGeometry,
        desktopBounds: CGRect,
        outputScale: CGFloat
    ) -> CGRect {
        CGRect(
            x: (display.frame.minX - desktopBounds.minX) * outputScale,
            y: (display.frame.minY - desktopBounds.minY) * outputScale,
            width: display.frame.width * outputScale,
            height: display.frame.height * outputScale
        ).integral
    }
}
