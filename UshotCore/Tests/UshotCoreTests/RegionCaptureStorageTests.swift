import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox
import XCTest
@testable import UshotCore

final class RegionCaptureStorageTests: XCTestCase {
    private final class WeakBuffer {
        weak var value: CVPixelBuffer?
    }

    func testSingleDisplayCropReleasesItsSourceSurface() throws {
        let source = WeakBuffer()
        let result = try autoreleasepool {
            var optionalBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(
                kCFAllocatorDefault, 256, 128, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &optionalBuffer
            ), kCVReturnSuccess)
            let buffer = try XCTUnwrap(optionalBuffer)
            source.value = buffer
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
                .assumingMemoryBound(to: UInt8.self)
            fillPixels(bytes, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), width: 256, height: 128)
            XCTAssertEqual(CVPixelBufferUnlockBaseAddress(buffer, []), kCVReturnSuccess)
            var optionalImage: CGImage?
            XCTAssertEqual(VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &optionalImage), noErr)
            let image = try XCTUnwrap(optionalImage)
            return try RegionCaptureProcessor().crop(
                CGRect(x: -40, y: 30, width: 20, height: 14),
                from: preparation(image: image, frame: CGRect(x: -50, y: 20, width: 128, height: 64), scale: 2)
            )
        }

        try withExtendedLifetime(result) {
            XCTAssertTrue(source.value == nil, "A small region must not retain the full frozen display's IOSurface.")
            XCTAssertEqual(result.pixelSize, CGSize(width: 40, height: 28))
            XCTAssertEqual(result.logicalSize, CGSize(width: 20, height: 14))
            XCTAssertEqual(result.scale, 2)
            XCTAssertEqual(try pixel(result.image, x: 0, y: 0), [20, 80, 64, 255])
            XCTAssertEqual(try pixel(result.image, x: 39, y: 27), [59, 107, 64, 255])
        }
    }

    func testSingleDisplayCropPreservesProfileAlphaAndPixelOrientation() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        fillPixels(bytes, bytesPerRow: context.bytesPerRow, width: 8, height: 6, alpha: 128)
        let image = try XCTUnwrap(context.makeImage())
        let frame = CGRect(x: 100, y: 200, width: 8, height: 6)
        let selection = CGRect(x: 102, y: 201, width: 3, height: 2)
        let result = try RegionCaptureProcessor().crop(selection, from: preparation(image: image, frame: frame, scale: 1))

        XCTAssertTrue(CFEqual(try XCTUnwrap(result.image.colorSpace), space))
        XCTAssertEqual(result.image.bitsPerComponent, image.bitsPerComponent)
        XCTAssertEqual(result.image.bitmapInfo, image.bitmapInfo)
        XCTAssertEqual(result.sourceMetadata.desktopFrame, selection)
        XCTAssertEqual(try pixel(result.image, x: 0, y: 0), [2, 3, 64, 128])
        XCTAssertEqual(try pixel(result.image, x: 2, y: 1), [4, 4, 64, 128])
    }

    func testFractionalRegionKeepsOutwardRoundedNativePixelDimensions() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let selection = CGRect(x: 101.25, y: -48.75, width: 2, height: 2)
        let result = try RegionCaptureProcessor().crop(
            selection,
            from: preparation(image: image, frame: CGRect(x: 100, y: -50, width: 8, height: 6), scale: 2)
        )

        XCTAssertEqual(result.pixelSize, CGSize(width: 5, height: 5))
        XCTAssertEqual(result.logicalSize, selection.size)
        XCTAssertEqual(result.sourceMetadata.desktopFrame, selection)
        XCTAssertEqual(result.sourceMetadata.displayIDs, [1])
        XCTAssertEqual(result.scale, 2)
    }

    private func preparation(image: CGImage, frame: CGRect, scale: CGFloat) -> RegionCapturePreparation {
        let pixels = CGSize(width: image.width, height: image.height)
        let capture = CapturedImage(
            image: image, colorSpace: image.colorSpace, pixelSize: pixels,
            logicalSize: frame.size, scale: scale,
            sourceMetadata: CaptureSourceMetadata(kind: .display, displayIDs: [1], windowID: nil, desktopFrame: frame)
        )
        return RegionCapturePreparation(displays: [DisplayCapture(
            descriptor: DisplayDescriptor(id: 1, name: "Synthetic", frame: frame, pixelSize: pixels, scale: scale, isCurrent: true),
            capturedImage: capture
        )])
    }

    private func fillPixels(_ bytes: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, width: Int, height: Int, alpha: UInt8 = 255) {
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = UInt8(x)
                bytes[offset + 1] = UInt8(y)
                bytes[offset + 2] = 64
                bytes[offset + 3] = alpha
            }
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}
