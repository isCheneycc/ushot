#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
import CoreGraphics
@testable import UshotCore

#if canImport(XCTest)
final class RegionCaptureCornerRadiusTests: XCTestCase {
    func testDefaultFactoryRadiusIsTwelvePixels() {
        XCTAssertEqual(RegionCaptureCornerRadius.defaultDisplayedValue, 12)
        XCTAssertEqual(RegionCaptureCornerRadius.defaultUnit, .pixels)
        XCTAssertEqual(RegionCaptureCornerRadius.defaultLogicalPoints, 6)
    }

    func testCaptureSettingsDefaultMatchesFactoryRadius() {
        let capture = CaptureSettings()
        XCTAssertEqual(capture.regionCornerRadius, 12)
        XCTAssertEqual(capture.regionCornerRadiusUnit, .pixels)
        XCTAssertEqual(capture.logicalRegionCornerRadius(backingScale: 2), 6, accuracy: 0.0001)
        XCTAssertEqual(
            RegionCaptureCornerRadius.effective(
                for: CGSize(width: 200, height: 100),
                configured: capture.logicalRegionCornerRadius(backingScale: 2)
            ),
            6,
            accuracy: 0.0001
        )
    }

    func testAppLanguagePreferenceDefaultsToSimplifiedChinese() {
        XCTAssertEqual(AppLanguagePreference.default, .simplifiedChinese)
        XCTAssertEqual(AdvancedSettings().language, .simplifiedChinese)
    }

    func testCaptureSettingsPixelUnitConvertsWithBackingScale() {
        var capture = CaptureSettings(
            regionCornerRadius: 24,
            regionCornerRadiusUnit: .pixels
        )
        XCTAssertEqual(capture.logicalRegionCornerRadius(backingScale: 2), 12, accuracy: 0.0001)
        capture.setRegionCornerRadiusUnit(.points, backingScale: 2)
        XCTAssertEqual(capture.regionCornerRadiusUnit, .points)
        XCTAssertEqual(capture.regionCornerRadius, 12, accuracy: 0.0001)
    }

    func testEffectiveUsesConfiguredRadiusWhenSelectionIsLargeEnough() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(
            RegionCaptureCornerRadius.effective(for: size, configured: 12),
            12
        )
    }

    func testEffectiveClampsToHalfTheShorterSide() {
        let size = CGSize(width: 20, height: 40)
        XCTAssertEqual(
            RegionCaptureCornerRadius.effective(for: size, configured: 12),
            10
        )
    }

    func testEffectiveRejectsNonPositiveAndNonFiniteSizes() {
        XCTAssertEqual(
            RegionCaptureCornerRadius.effective(for: .zero, configured: 12),
            0
        )
        XCTAssertEqual(
            RegionCaptureCornerRadius.effective(
                for: CGSize(width: -4, height: 40),
                configured: 12
            ),
            0
        )
        XCTAssertEqual(
            RegionCaptureCornerRadius.effective(
                for: CGSize(width: CGFloat.nan, height: 40),
                configured: 12
            ),
            0
        )
    }

    func testEffectiveRejectsNegativeConfiguredRadius() {
        XCTAssertEqual(
            RegionCaptureCornerRadius.effective(
                for: CGSize(width: 100, height: 100),
                configured: -8
            ),
            0
        )
    }

    func testRendererAppliesTransparentRoundedCorners() throws {
        let width = 40
        let height = 40
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let solidBase = try makeSolidImage(
            width: width,
            height: height,
            rgba: (0, 0, 255, 255),
            colorSpace: colorSpace
        )
        let document = AnnotationDocument(
            baseImageReference: ImageReference(pixelSize: CGSize(width: width, height: height)),
            canvasSize: CGSize(width: width, height: height),
            canvasEffects: CanvasEffects(cornerRadius: 12)
        )

        let rendered = try AnnotationRenderer().render(
            document: document,
            baseImage: solidBase,
            scale: 1
        )
        XCTAssertEqual(rendered.width, width)
        XCTAssertEqual(rendered.height, height)

        let bytes = rgbaBytes(for: rendered)
        // Outside the rounded corner (top-left pixel) must be fully transparent.
        XCTAssertEqual(bytes[3], 0, "Rounded corner pixel must be transparent")
        // Center pixel must remain opaque blue-ish content.
        let centerOffset = ((height / 2) * width + (width / 2)) * 4
        XCTAssertEqual(bytes[centerOffset + 3], 255, "Center pixel must stay opaque")
        XCTAssertGreaterThan(bytes[centerOffset + 2], 200, "Center should keep blue base content")
    }

    private func makeSolidImage(
        width: Int,
        height: Int,
        rgba: (UInt8, UInt8, UInt8, UInt8),
        colorSpace: CGColorSpace
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = rgba.0
            bytes[index + 1] = rgba.1
            bytes[index + 2] = rgba.2
            bytes[index + 3] = rgba.3
        }
        return try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else {
                struct SolidImageError: Error {}
                throw SolidImageError()
            }
            return image
        }
    }

    private func rgbaBytes(for image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
#endif
