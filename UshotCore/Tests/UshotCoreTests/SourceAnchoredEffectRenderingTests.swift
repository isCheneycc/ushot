import CoreGraphics
import Foundation
import XCTest
@testable import UshotCore

final class SourceAnchoredEffectRenderingTests: XCTestCase {
    @MainActor
    func testShrinkingRegionKeepsEffectsOverTheirRebasedSourcePixels() throws {
        for scale in [CGFloat(1), 2] {
            let preparation = try makePreparation(scale: scale)
            let original = preparation.displays[0].capturedImage
            let cropped = try RegionCaptureProcessor().crop(
                CGRect(x: 64, y: 16, width: 64, height: 64),
                from: preparation
            )
            for kind in [AnnotationKind.blur, .mosaic] {
                let controller = AnnotationDocumentController(document: makeDocument(baseImage: original))
                controller.add(makeEffect(kind: kind, rect: CGRect(x: 72, y: 24, width: 40, height: 40)))

                controller.rebaseCanvas(
                    baseImageReference: makeReference(cropped),
                    canvasSize: cropped.logicalSize,
                    translation: CGSize(width: -64, height: -16)
                )

                try assertRedaction(
                    document: controller.document,
                    baseImage: cropped,
                    expectedMask: CGRect(x: 8, y: 8, width: 40, height: 40),
                    message: "Shrinking \(kind.rawValue) at \(scale)x"
                )
            }
        }
    }

    @MainActor
    func testExpandingRegionSamplesCurrentBasePixelsWithoutTranslatingTheImage() throws {
        for scale in [CGFloat(1), 2] {
            let preparation = try makePreparation(scale: scale)
            let expanded = preparation.displays[0].capturedImage
            let original = try RegionCaptureProcessor().crop(
                CGRect(x: 64, y: 16, width: 64, height: 64),
                from: preparation
            )
            for kind in [AnnotationKind.blur, .mosaic] {
                let controller = AnnotationDocumentController(document: makeDocument(baseImage: original))
                controller.add(makeEffect(kind: kind, rect: CGRect(x: 8, y: 8, width: 40, height: 40)))

                controller.rebaseCanvas(
                    baseImageReference: makeReference(expanded),
                    canvasSize: expanded.logicalSize,
                    translation: CGSize(width: 64, height: 16)
                )

                try assertRedaction(
                    document: controller.document,
                    baseImage: expanded,
                    expectedMask: CGRect(x: 72, y: 24, width: 40, height: 40),
                    message: "Expanding \(kind.rawValue) at \(scale)x"
                )
            }
        }
    }

    func testLegacyScaleAndRotationTransformOnlyTheEffectMask() throws {
        let baseImage = try makePreparation(scale: 1).displays[0].capturedImage
        for kind in [AnnotationKind.blur, .mosaic] {
            var document = makeDocument(baseImage: baseImage)
            var item = makeEffect(kind: kind, rect: CGRect(x: 20, y: 20, width: 40, height: 20))
            item.transform = AnnotationTransform(
                translation: CGSize(width: 40, height: 16),
                rotationRadians: .pi / 2,
                scaleX: 1.5
            )
            document.annotations = [item]

            try assertRedaction(
                document: document,
                baseImage: baseImage,
                expectedMask: CGRect(x: 70, y: 16, width: 20, height: 60),
                message: "Legacy transformed \(kind.rawValue)"
            )
        }
    }

    @MainActor
    func testRebasedUndoAndRedoRetainRedactionAcrossRepeatedRegionChanges() throws {
        let preparation = try makePreparation(scale: 1)
        let original = preparation.displays[0].capturedImage
        let cropped = try RegionCaptureProcessor().crop(
            CGRect(x: 64, y: 16, width: 64, height: 64),
            from: preparation
        )
        for kind in [AnnotationKind.blur, .mosaic] {
            let controller = AnnotationDocumentController(document: makeDocument(baseImage: original))
            controller.add(makeEffect(kind: kind, rect: CGRect(x: 72, y: 24, width: 40, height: 40)))
            controller.undo()

            // Rebase while the effect exists only in redo history. Restoring it
            // must target the cropped source rather than translate that source.
            controller.rebaseCanvas(
                baseImageReference: makeReference(cropped),
                canvasSize: cropped.logicalSize,
                translation: CGSize(width: -64, height: -16)
            )
            controller.redo()
            try assertRedaction(
                document: controller.document,
                baseImage: cropped,
                expectedMask: CGRect(x: 8, y: 8, width: 40, height: 40),
                message: "Redo after shrinking \(kind.rawValue)"
            )

            controller.rebaseCanvas(
                baseImageReference: makeReference(original),
                canvasSize: original.logicalSize,
                translation: CGSize(width: 64, height: 16)
            )
            controller.undo()
            let unredacted = try AnnotationRenderer().render(
                document: controller.document,
                baseImage: original.image,
                scale: original.scale
            )
            XCTAssertEqual(
                try differingPixelCount(unredacted, original.image),
                0,
                "Undo must remove only the effect after expanding \(kind.rawValue)."
            )
            controller.redo()
            try assertRedaction(
                document: controller.document,
                baseImage: original,
                expectedMask: CGRect(x: 72, y: 24, width: 40, height: 40),
                message: "Redo after expanding \(kind.rawValue)"
            )
        }
    }

    private func assertRedaction(
        document: AnnotationDocument,
        baseImage: CapturedImage,
        expectedMask: CGRect,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var expectedDocument = document
        let expectedItem = try XCTUnwrap(document.annotations.first, file: file, line: line)
        expectedDocument.annotations = [makeEffect(kind: expectedItem.kind, rect: expectedMask)]
        let renderer = AnnotationRenderer()
        let actual = try renderer.render(
            document: document,
            baseImage: baseImage.image,
            scale: baseImage.scale
        )
        let expected = try renderer.render(
            document: expectedDocument,
            baseImage: baseImage.image,
            scale: baseImage.scale
        )

        XCTAssertEqual(
            try differingPixelCount(actual, expected),
            0,
            "\(message): every output pixel must match a fresh effect over the current source.",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            try differingPixelCount(actual, baseImage.image),
            0,
            "\(message): an effect must not silently leave the entire base image exposed.",
            file: file,
            line: line
        )
    }

    private func makeEffect(kind: AnnotationKind, rect: CGRect) -> AnnotationItem {
        AnnotationItem(
            kind: kind,
            zIndex: 0,
            geometry: .rect(rect),
            style: AnnotationStyle(blurRadius: 2, mosaicBlockSize: 8)
        )
    }

    private func makeDocument(baseImage: CapturedImage) -> AnnotationDocument {
        AnnotationDocument(
            baseImageReference: makeReference(baseImage),
            canvasSize: baseImage.logicalSize
        )
    }

    private func makeReference(_ image: CapturedImage) -> ImageReference {
        ImageReference(pixelSize: image.pixelSize, colorSpaceName: image.colorSpace?.name as String?)
    }

    private func makePreparation(scale: CGFloat) throws -> RegionCapturePreparation {
        let logicalSize = CGSize(width: 128, height: 96)
        let width = Int(logicalSize.width * scale)
        let height = Int(logicalSize.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8((x * 17 + y * 3) % 256)
                bytes[offset + 1] = x.isMultiple(of: 2) ? 0 : 255
                bytes[offset + 2] = UInt8((x * 5 + y * 19) % 256)
                bytes[offset + 3] = 255
            }
        }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let frame = CGRect(origin: .zero, size: logicalSize)
        let captured = CapturedImage(
            image: image,
            colorSpace: colorSpace,
            pixelSize: CGSize(width: width, height: height),
            logicalSize: logicalSize,
            scale: scale,
            sourceMetadata: CaptureSourceMetadata(
                kind: .display,
                displayIDs: [1],
                windowID: nil,
                desktopFrame: frame
            )
        )
        return RegionCapturePreparation(displays: [DisplayCapture(
            descriptor: DisplayDescriptor(
                id: 1,
                name: "Synthetic Source",
                frame: frame,
                pixelSize: captured.pixelSize,
                scale: scale,
                isCurrent: true
            ),
            capturedImage: captured
        )])
    }

    private func differingPixelCount(_ first: CGImage, _ second: CGImage) throws -> Int {
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
        let firstBytes = try normalizedPixels(first)
        let secondBytes = try normalizedPixels(second)
        guard firstBytes.count == secondBytes.count else { return Int.max }
        return stride(from: 0, to: firstBytes.count, by: 4).reduce(into: 0) { count, offset in
            if firstBytes[offset..<(offset + 4)] != secondBytes[offset..<(offset + 4)] {
                count += 1
            }
        }
    }

    private func normalizedPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }
}
