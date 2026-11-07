import CoreGraphics
import Foundation

public struct RegionCaptureProcessor: Sendable {
    public init() {}

    public func crop(
        _ requestedRegion: CGRect,
        from preparation: RegionCapturePreparation
    ) throws -> CapturedImage {
        let geometry = preparation.geometry
        let effectiveRegion = requestedRegion.standardized.intersection(geometry.desktopBounds)
        guard
            !effectiveRegion.isNull,
            effectiveRegion.width >= 2,
            effectiveRegion.height >= 2
        else {
            throw ScreenshotAppError.captureFailed(description: "The selected region is too small or outside every display.")
        }

        let transformer = CoordinateTransformer(primaryDisplayHeight: 0)
        var crops: [DisplayCapture] = []
        for displayCapture in preparation.displays {
            let descriptor = displayCapture.descriptor
            let displayGeometry = DisplayGeometry(
                id: descriptor.id,
                frame: descriptor.frame,
                scale: descriptor.scale
            )
            guard
                let pixelRect = transformer.pixelCropRect(
                    for: effectiveRegion,
                    in: displayGeometry,
                    imagePixelSize: displayCapture.capturedImage.pixelSize
                ),
                let croppedCGImage = displayCapture.capturedImage.image.cropping(to: pixelRect)
            else { continue }

            let logicalIntersection = effectiveRegion.intersection(descriptor.frame)
            let croppedImage = CapturedImage(
                image: croppedCGImage,
                colorSpace: croppedCGImage.colorSpace ?? displayCapture.capturedImage.colorSpace,
                pixelSize: CGSize(width: croppedCGImage.width, height: croppedCGImage.height),
                logicalSize: logicalIntersection.size,
                scale: descriptor.scale,
                sourceMetadata: CaptureSourceMetadata(
                    kind: .region,
                    displayIDs: [descriptor.id],
                    windowID: nil,
                    desktopFrame: logicalIntersection
                )
            )
            let croppedDescriptor = DisplayDescriptor(
                id: descriptor.id,
                name: descriptor.name,
                frame: logicalIntersection,
                pixelSize: croppedImage.pixelSize,
                scale: descriptor.scale,
                isCurrent: descriptor.isCurrent
            )
            crops.append(DisplayCapture(descriptor: croppedDescriptor, capturedImage: croppedImage))
        }

        guard !crops.isEmpty else {
            throw ScreenshotAppError.contentUnavailable
        }

        if crops.count == 1, crops[0].descriptor.frame == effectiveRegion {
            let captured = crops[0].capturedImage
            let source = captured.image
            guard let colorSpace = source.colorSpace ?? captured.colorSpace else {
                throw ScreenshotAppError.captureFailed(description: "The selected region has no bitmap color space.")
            }
            // ScreenCaptureKit subimages retain their entire source IOSurface.
            // Only the final single-display crop needs independent storage;
            // the multi-display compositor already creates its own bitmap.
            guard let context = CGContext(
                data: nil,
                width: source.width,
                height: source.height,
                bitsPerComponent: source.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: source.bitmapInfo.rawValue
            ) else {
                throw ScreenshotAppError.captureFailed(description: "The selected region bitmap could not be created.")
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard let image = context.makeImage() else {
                throw ScreenshotAppError.captureFailed(description: "The selected region bitmap could not be finalized.")
            }
            return CapturedImage(
                image: image,
                colorSpace: image.colorSpace,
                pixelSize: captured.pixelSize,
                logicalSize: captured.logicalSize,
                scale: captured.scale,
                sourceMetadata: captured.sourceMetadata
            )
        }

        let composite = try MultiDisplayCompositor().compose(crops, canvasBounds: effectiveRegion).composite
        return CapturedImage(
            image: composite.image,
            colorSpace: composite.colorSpace,
            pixelSize: composite.pixelSize,
            logicalSize: effectiveRegion.size,
            scale: composite.scale,
            sourceMetadata: CaptureSourceMetadata(
                kind: .region,
                displayIDs: crops.map(\.descriptor.id),
                windowID: nil,
                desktopFrame: effectiveRegion
            )
        )
    }
}
