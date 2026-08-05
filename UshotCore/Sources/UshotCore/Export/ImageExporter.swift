import CoreGraphics
import Foundation
import ImageIO

public protocol ImageExporting: Sendable {
    func imageData(
        for image: CGImage,
        format: ExportFormat,
        preservesColorProfile: Bool
    ) throws -> Data
    func write(
        _ image: CGImage,
        format: ExportFormat,
        preservesColorProfile: Bool,
        to url: URL
    ) throws
}

public extension ImageExporting {
    func pngData(for image: CGImage) throws -> Data {
        try imageData(for: image, format: .png, preservesColorProfile: true)
    }

    func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, format: .png, preservesColorProfile: true, to: url)
    }
}

public struct SystemImageExporter: ImageExporting {
    public init() {}

    public func imageData(
        for image: CGImage,
        format: ExportFormat,
        preservesColorProfile: Bool
    ) throws -> Data {
        let prepared = try preparedImage(
            image,
            format: format,
            preservesColorProfile: preservesColorProfile
        )
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            format.contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotAppError.exportFailed(
                description: "Image I/O could not create a \(format.rawValue.uppercased()) destination."
            )
        }

        let properties: CFDictionary?
        if format == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        } else {
            properties = nil
        }
        CGImageDestinationAddImage(destination, prepared, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotAppError.exportFailed(
                description: "Image I/O could not finalize the \(format.rawValue.uppercased()) image."
            )
        }
        return data as Data
    }

    public func write(
        _ image: CGImage,
        format: ExportFormat,
        preservesColorProfile: Bool,
        to url: URL
    ) throws {
        do {
            try imageData(
                for: image,
                format: format,
                preservesColorProfile: preservesColorProfile
            ).write(to: url, options: .atomic)
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            AppLog.export.error(
                "\(format.rawValue.uppercased(), privacy: .public) write failed: \(error.localizedDescription, privacy: .public)"
            )
            throw ScreenshotAppError.exportFailed(description: error.localizedDescription)
        }
    }

    private func preparedImage(
        _ image: CGImage,
        format: ExportFormat,
        preservesColorProfile: Bool
    ) throws -> CGImage {
        let removesAlpha = format == .jpeg
        if preservesColorProfile, !removesAlpha {
            return image
        }

        let targetColorSpace: CGColorSpace
        if preservesColorProfile, let source = image.colorSpace {
            guard source.model == .rgb else {
                throw ScreenshotAppError.colorConversionFailed(
                    description: "JPEG export requires an RGB source profile."
                )
            }
            targetColorSpace = source
        } else {
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw ScreenshotAppError.colorConversionFailed(
                    description: "The system sRGB profile is unavailable."
                )
            }
            targetColorSpace = sRGB
        }

        let alphaInfo: CGImageAlphaInfo = removesAlpha ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: targetColorSpace,
            bitmapInfo: alphaInfo.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw ScreenshotAppError.exportFailed(
                description: "A color-managed \(format.rawValue.uppercased()) render context could not be created."
            )
        }
        context.setBlendMode(.copy)
        if removesAlpha {
            guard let white = CGColor(
                colorSpace: targetColorSpace,
                components: [1, 1, 1, 1]
            ) else {
                throw ScreenshotAppError.colorConversionFailed(
                    description: "The target RGB profile could not represent the JPEG background color."
                )
            }
            context.setFillColor(white)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.setBlendMode(.normal)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rendered = context.makeImage() else {
            throw ScreenshotAppError.exportFailed(
                description: "The color-managed \(format.rawValue.uppercased()) image could not be finalized."
            )
        }
        return rendered
    }
}
