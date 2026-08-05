import CoreGraphics
import Foundation

public struct MultiDisplayCompositor: Sendable {
    public init() {}

    public func compose(
        _ captures: [DisplayCapture],
        canvasBounds: CGRect? = nil
    ) throws -> MultiDisplayCaptureResult {
        guard !captures.isEmpty else {
            throw ScreenshotAppError.noDisplayAvailable
        }

        let displayGeometries = captures.map {
            DisplayGeometry(id: $0.descriptor.id, frame: $0.descriptor.frame, scale: $0.descriptor.scale)
        }
        let geometry = ScreenGeometry(displays: displayGeometries)
        let desktopBounds = canvasBounds ?? geometry.desktopBounds
        guard desktopBounds.contains(geometry.desktopBounds) else {
            throw ScreenshotAppError.captureFailed(description: "The composite canvas does not contain every display crop.")
        }
        let outputScale = geometry.maximumScale
        let outputWidth = Int(ceil(desktopBounds.width * outputScale))
        let outputHeight = Int(ceil(desktopBounds.height * outputScale))
        guard outputWidth > 0, outputHeight > 0 else {
            throw ScreenshotAppError.captureFailed(description: "The composite desktop has an empty size.")
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ScreenshotAppError.captureFailed(description: "The sRGB color space is unavailable.")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ScreenshotAppError.captureFailed(description: "The composite bitmap context could not be created.")
        }

        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.interpolationQuality = .high
        let transformer = CoordinateTransformer(primaryDisplayHeight: 0)
        for capture in captures {
            let display = DisplayGeometry(
                id: capture.descriptor.id,
                frame: capture.descriptor.frame,
                scale: capture.descriptor.scale
            )
            let destination = transformer.bitmapContextDestinationPixelRect(
                for: display,
                desktopBounds: desktopBounds,
                outputScale: outputScale
            )
            AppLog.capture.debug(
                "Compositing captured display without pixel reflection: display=\(display.id, privacy: .public), sourcePixels=\(capture.capturedImage.image.width, privacy: .public)x\(capture.capturedImage.image.height, privacy: .public), destination=\(destination.debugDescription, privacy: .public)"
            )
            context.draw(capture.capturedImage.image, in: destination)
        }

        guard let image = context.makeImage() else {
            throw ScreenshotAppError.captureFailed(description: "The composite image could not be finalized.")
        }
        let capturedImage = CapturedImage(
            image: image,
            colorSpace: image.colorSpace,
            pixelSize: CGSize(width: image.width, height: image.height),
            logicalSize: desktopBounds.size,
            scale: outputScale,
            sourceMetadata: CaptureSourceMetadata(
                kind: .allDisplays,
                displayIDs: captures.map(\.descriptor.id),
                windowID: nil,
                desktopFrame: desktopBounds
            )
        )
        return MultiDisplayCaptureResult(composite: capturedImage, displays: captures)
    }
}
