import AppKit
import CoreGraphics
import Foundation

public struct RGBAComponents: Codable, Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var clamped: RGBAComponents {
        RGBAComponents(
            red: red.clampedToUnitInterval,
            green: green.clampedToUnitInterval,
            blue: blue.clampedToUnitInterval,
            alpha: alpha.clampedToUnitInterval
        )
    }
}

public struct ColorSample: Codable, Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let displayName: String
    public let globalPoint: CGPoint
    public let pixelPoint: CGPoint
    public let colorSpace: ColorSpacePreference
    public let components: RGBAComponents
    public let sourceColorSpaceName: String

    public init(
        displayID: CGDirectDisplayID,
        displayName: String,
        globalPoint: CGPoint,
        pixelPoint: CGPoint,
        colorSpace: ColorSpacePreference,
        components: RGBAComponents,
        sourceColorSpaceName: String
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.globalPoint = globalPoint
        self.pixelPoint = pixelPoint
        self.colorSpace = colorSpace
        self.components = components
        self.sourceColorSpaceName = sourceColorSpaceName
    }

    public var hexString: String {
        let value = components.clamped
        let red = Int((value.red * 255).rounded())
        let green = Int((value.green * 255).rounded())
        let blue = Int((value.blue * 255).rounded())
        let alpha = Int((value.alpha * 255).rounded())
        if alpha == 255 {
            return String(format: "#%02X%02X%02X", red, green, blue)
        }
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    public var displayP3CSSString: String? {
        guard colorSpace == .displayP3 else { return nil }
        let value = components.clamped
        return String(
            format: "color(display-p3 %.4f %.4f %.4f / %.4f)",
            locale: Locale(identifier: "en_US_POSIX"),
            value.red,
            value.green,
            value.blue,
            value.alpha
        )
    }

    public var componentString: String {
        String(
            format: "%@ R %.4f  G %.4f  B %.4f  A %.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            colorSpace.title,
            components.red,
            components.green,
            components.blue,
            components.alpha
        )
    }

    public func copyRepresentation(format: ColorCopyFormat) -> String {
        switch format {
        case .components:
            return componentString
        case .hex:
            switch colorSpace {
            case .sRGB: return hexString
            case .displayP3: return displayP3CSSString ?? componentString
            case .genericRGB, .adobeRGB1998: return componentString
            }
        case .css where colorSpace == .displayP3:
            return displayP3CSSString ?? componentString
        case .css where colorSpace == .sRGB:
            let value = components.clamped
            return String(
                format: "rgb(%.2f%% %.2f%% %.2f%% / %.4f)",
                locale: Locale(identifier: "en_US_POSIX"),
                value.red * 100,
                value.green * 100,
                value.blue * 100,
                value.alpha
            )
        case .css:
            return componentString
        }
    }
}

public struct PixelMagnifier: @unchecked Sendable {
    public let image: CGImage
    public let centerPixel: CGPoint
    public let sourcePixelRect: CGRect
    public let displayScale: CGFloat

    public init(
        image: CGImage,
        centerPixel: CGPoint,
        sourcePixelRect: CGRect,
        displayScale: CGFloat
    ) {
        self.image = image
        self.centerPixel = centerPixel
        self.sourcePixelRect = sourcePixelRect
        self.displayScale = displayScale
    }
}

public struct PixelSampleFrame: @unchecked Sendable {
    public let sample: ColorSample
    public let magnifier: PixelMagnifier

    public init(sample: ColorSample, magnifier: PixelMagnifier) {
        self.sample = sample
        self.magnifier = magnifier
    }
}

@MainActor
public protocol PixelSampling: AnyObject {
    var displays: [DisplayDescriptor] { get }
    func sampleFrame(
        at globalPoint: CGPoint,
        colorSpace: ColorSpacePreference,
        radius: Int
    ) async throws -> PixelSampleFrame
}

@MainActor
public protocol PixelSamplerCreating: AnyObject {
    func makePixelSampler() async throws -> any PixelSampling
}

public struct SystemColorSpaceConverter: Sendable {
    public init() {}

    public func convert(
        _ components: RGBAComponents,
        from sourceColorSpace: CGColorSpace,
        to destination: ColorSpacePreference
    ) throws -> RGBAComponents {
        guard sourceColorSpace.model == .rgb else {
            throw ScreenshotAppError.colorConversionFailed(
                description: "The source profile is not an RGB color space."
            )
        }
        guard let source = NSColorSpace(cgColorSpace: sourceColorSpace) else {
            throw ScreenshotAppError.colorConversionFailed(
                description: "AppKit could not create a source color space from the image profile."
            )
        }

        let color = NSColor(
            colorSpace: source,
            components: [components.red, components.green, components.blue, components.alpha],
            count: 4
        )
        guard let converted = color.usingColorSpace(destination.nsColorSpace) else {
            throw ScreenshotAppError.colorConversionFailed(
                description: "The system could not convert from \(source.localizedName ?? "the source profile") to \(destination.title)."
            )
        }
        return RGBAComponents(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }
}

@MainActor
public final class FrozenFramePixelSampler: PixelSampling {
    public let displays: [DisplayDescriptor]
    private let captures: [DisplayCapture]

    public init(preparation: RegionCapturePreparation) throws {
        guard !preparation.displays.isEmpty else {
            throw ScreenshotAppError.noDisplayAvailable
        }
        captures = preparation.displays
        displays = preparation.displays.map(\.descriptor)
    }

    public func sample(
        at globalPoint: CGPoint,
        colorSpace: ColorSpacePreference
    ) throws -> ColorSample {
        let resolved = try resolve(globalPoint)
        let components = try ColorManagedPixelReader().components(
            from: resolved.capture.capturedImage.image,
            at: resolved.pixelPoint,
            into: colorSpace.nsColorSpace
        )
        let sourceName = resolved.capture.capturedImage.colorSpace?.name as String?
            ?? "Unspecified source profile"
        return ColorSample(
            displayID: resolved.capture.descriptor.id,
            displayName: resolved.capture.descriptor.name,
            globalPoint: globalPoint,
            pixelPoint: resolved.pixelPoint,
            colorSpace: colorSpace,
            components: components,
            sourceColorSpaceName: sourceName
        )
    }

    public func magnifier(at globalPoint: CGPoint, radius: Int = 5) throws -> PixelMagnifier {
        guard radius >= 1 else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "Magnifier radius must be at least one physical pixel."
            )
        }
        let resolved = try resolve(globalPoint)
        let image = resolved.capture.capturedImage.image
        let requested = CGRect(
            x: resolved.pixelPoint.x - CGFloat(radius),
            y: resolved.pixelPoint.y - CGFloat(radius),
            width: CGFloat(radius * 2 + 1),
            height: CGFloat(radius * 2 + 1)
        )
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = requested.intersection(imageBounds).integral
        guard !cropRect.isNull, let cropped = image.cropping(to: cropRect) else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "The magnifier crop is outside the captured display image."
            )
        }
        return PixelMagnifier(
            image: cropped,
            centerPixel: CGPoint(
                x: resolved.pixelPoint.x - cropRect.minX,
                y: resolved.pixelPoint.y - cropRect.minY
            ),
            sourcePixelRect: cropRect,
            displayScale: resolved.capture.descriptor.scale
        )
    }

    public func sampleFrame(
        at globalPoint: CGPoint,
        colorSpace: ColorSpacePreference,
        radius: Int = 5
    ) async throws -> PixelSampleFrame {
        PixelSampleFrame(
            sample: try sample(at: globalPoint, colorSpace: colorSpace),
            magnifier: try magnifier(at: globalPoint, radius: radius)
        )
    }

    private func resolve(_ globalPoint: CGPoint) throws -> (capture: DisplayCapture, pixelPoint: CGPoint) {
        guard let capture = captures.first(where: { $0.descriptor.frame.contains(globalPoint) }) else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "No display contains screen coordinate \(Int(globalPoint.x)), \(Int(globalPoint.y))."
            )
        }
        let descriptor = capture.descriptor
        let image = capture.capturedImage.image
        let pixelX = floor((globalPoint.x - descriptor.frame.minX) * descriptor.scale)
        let pixelY = floor((descriptor.frame.maxY - globalPoint.y) * descriptor.scale)
        let point = CGPoint(
            x: min(max(0, pixelX), CGFloat(image.width - 1)),
            y: min(max(0, pixelY), CGFloat(image.height - 1))
        )
        return (capture, point)
    }

}

public struct ColorManagedPixelReader: Sendable {
    public init() {}

    public func components(
        from image: CGImage,
        at point: CGPoint,
        into destination: NSColorSpace
    ) throws -> RGBAComponents {
        guard let destinationColorSpace = destination.cgColorSpace else {
            throw ScreenshotAppError.colorConversionFailed(
                description: "\(destination.localizedName ?? "The selected color space") has no Core Graphics profile."
            )
        }
        guard let cropped = image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))) else {
            throw ScreenshotAppError.pixelSamplingFailed(description: "The selected physical pixel could not be cropped.")
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: destinationColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "A one-pixel color-managed bitmap context could not be created."
            )
        }

        let alpha = CGFloat(bytes[3]) / 255
        let divisor = alpha > 0 ? alpha : 1
        return RGBAComponents(
            red: min(1, CGFloat(bytes[0]) / 255 / divisor),
            green: min(1, CGFloat(bytes[1]) / 255 / divisor),
            blue: min(1, CGFloat(bytes[2]) / 255 / divisor),
            alpha: alpha
        )
    }
}

public extension ColorSpacePreference {
    var nsColorSpace: NSColorSpace {
        switch self {
        case .sRGB: return .sRGB
        case .displayP3: return .displayP3
        case .genericRGB: return .genericRGB
        case .adobeRGB1998: return .adobeRGB1998
        }
    }
}

private extension CGFloat {
    var clampedToUnitInterval: CGFloat { Swift.min(1, Swift.max(0, self)) }
}
