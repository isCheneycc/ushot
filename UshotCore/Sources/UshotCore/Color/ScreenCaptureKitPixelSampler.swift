import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
public final class ScreenCaptureKitPixelSamplerFactory: PixelSamplerCreating {
    private let processIdentifier: pid_t

    public init(processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.processIdentifier = processIdentifier
    }

    public func makePixelSampler() async throws -> any PixelSampling {
        try await ScreenCaptureKitPixelSampler.make(processIdentifier: processIdentifier)
    }
}

@MainActor
public final class ScreenCaptureKitPixelSampler: PixelSampling {
    public let displays: [DisplayDescriptor]

    private let contentFilters: [CGDirectDisplayID: SCContentFilter]

    private init(
        displays: [DisplayDescriptor],
        contentFilters: [CGDirectDisplayID: SCContentFilter]
    ) {
        self.displays = displays
        self.contentFilters = contentFilters
    }

    public static func make(
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) async throws -> ScreenCaptureKitPixelSampler {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            AppLog.colorPicker.error("Pixel sampler content discovery failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.pixelSamplingFailed(description: error.localizedDescription)
        }

        let transformer = CoordinateTransformer(
            primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
        let mouse = NSEvent.mouseLocation
        let screenNames: [CGDirectDisplayID: String] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let id = Self.displayID(for: screen) else { return nil }
                return (id, screen.localizedName)
            }
        )
        let descriptors = try content.displays.map { display -> DisplayDescriptor in
            let frame = transformer.appKitRect(fromScreenCaptureRect: display.frame)
            let backing = try DisplayBackingMetrics.current(
                displayID: display.displayID,
                logicalSize: frame.size
            )
            return DisplayDescriptor(
                id: display.displayID,
                name: screenNames[display.displayID] ?? "Display \(display.displayID)",
                frame: frame,
                pixelSize: backing.pixelSize,
                scale: backing.scale,
                isCurrent: frame.contains(mouse)
            )
        }
        guard !descriptors.isEmpty else { throw ScreenshotAppError.noDisplayAvailable }
        let excludedApplications = content.applications.filter {
            $0.processID == processIdentifier
        }
        let contentFilters = Dictionary(
            uniqueKeysWithValues: content.displays.map { display in
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                )
                if #available(macOS 14.2, *) {
                    filter.includeMenuBar = true
                }
                return (display.displayID, filter)
            }
        )

        return ScreenCaptureKitPixelSampler(
            displays: descriptors,
            contentFilters: contentFilters
        )
    }

    public func sampleFrame(
        at globalPoint: CGPoint,
        colorSpace: ColorSpacePreference,
        radius: Int = 5
    ) async throws -> PixelSampleFrame {
        guard radius >= 1 else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "Magnifier radius must be at least one physical pixel."
            )
        }
        guard
            let descriptor = displays.first(where: { $0.frame.contains(globalPoint) }),
            let filter = contentFilters[descriptor.id]
        else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "No display contains screen coordinate \(Int(globalPoint.x)), \(Int(globalPoint.y))."
            )
        }

        let localPixel = physicalPixel(at: globalPoint, in: descriptor)
        let geometry = try ScreenCapturePixelGeometry(
            targetPixel: localPixel,
            radius: radius,
            pixelSize: descriptor.pixelSize,
            scale: descriptor.scale
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = geometry.sourceRectInPoints
        configuration.width = Int(geometry.sourcePixelRect.width)
        configuration.height = Int(geometry.sourcePixelRect.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsDisplay = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            AppLog.colorPicker.error(
                "Live \(configuration.width, privacy: .public)x\(configuration.height, privacy: .public) pixel capture failed on display \(descriptor.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw ScreenshotAppError.pixelSamplingFailed(description: error.localizedDescription)
        }

        guard image.width == configuration.width,
              image.height == configuration.height
        else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "ScreenCaptureKit returned \(image.width)×\(image.height) pixels for a requested \(configuration.width)×\(configuration.height) sample."
            )
        }
        let components = try ColorManagedPixelReader().components(
            from: image,
            at: geometry.targetPixelInImage,
            into: colorSpace.nsColorSpace
        )
        let sample = ColorSample(
            displayID: descriptor.id,
            displayName: descriptor.name,
            globalPoint: globalPoint,
            pixelPoint: localPixel,
            colorSpace: colorSpace,
            components: components,
            sourceColorSpaceName: image.colorSpace?.name as String? ?? "Unspecified source profile"
        )
        return PixelSampleFrame(
            sample: sample,
            magnifier: PixelMagnifier(
                image: image,
                centerPixel: geometry.targetPixelInImage,
                sourcePixelRect: geometry.sourcePixelRect,
                displayScale: descriptor.scale
            )
        )
    }

    private func physicalPixel(at globalPoint: CGPoint, in display: DisplayDescriptor) -> CGPoint {
        CGPoint(
            x: min(
                max(0, floor((globalPoint.x - display.frame.minX) * display.scale)),
                display.pixelSize.width - 1
            ),
            y: min(
                max(0, floor((display.frame.maxY - globalPoint.y) * display.scale)),
                display.pixelSize.height - 1
            )
        )
    }
    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

struct ScreenCapturePixelGeometry: Equatable, Sendable {
    let sourceRectInPoints: CGRect
    let sourcePixelRect: CGRect
    let targetPixelInImage: CGPoint

    init(
        targetPixel: CGPoint,
        radius: Int,
        pixelSize: CGSize,
        scale: CGFloat
    ) throws {
        guard radius >= 1,
              scale.isFinite,
              scale > 0,
              pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width >= 1,
              pixelSize.height >= 1
        else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "Screen capture pixel geometry is invalid."
            )
        }

        let requestedLength = CGFloat(radius * 2 + 1)
        let requestedWidth = min(requestedLength, pixelSize.width)
        let requestedHeight = min(requestedLength, pixelSize.height)
        let requestedPixelRect = CGRect(
            x: min(
                max(0, targetPixel.x - CGFloat(radius)),
                pixelSize.width - requestedWidth
            ),
            y: min(
                max(0, targetPixel.y - CGFloat(radius)),
                pixelSize.height - requestedHeight
            ),
            width: requestedWidth,
            height: requestedHeight
        ).integral

        let pointAlignment = try Self.logicalPointAlignment(for: scale)
        let logicalWidth = pixelSize.width / scale
        let logicalHeight = pixelSize.height / scale
        let minimumPointX = floor(
            requestedPixelRect.minX / scale / pointAlignment
        ) * pointAlignment
        let minimumPointY = floor(
            requestedPixelRect.minY / scale / pointAlignment
        ) * pointAlignment
        let maximumPointX = min(
            ceil(requestedPixelRect.maxX / scale / pointAlignment) * pointAlignment,
            logicalWidth
        )
        let maximumPointY = min(
            ceil(requestedPixelRect.maxY / scale / pointAlignment) * pointAlignment,
            logicalHeight
        )
        let sourceRectInPoints = CGRect(
            x: minimumPointX,
            y: minimumPointY,
            width: maximumPointX - minimumPointX,
            height: maximumPointY - minimumPointY
        )

        let physicalMinimumX = try Self.exactPhysicalPixel(
            minimumPointX * scale,
            name: "horizontal source origin"
        )
        let physicalMinimumY = try Self.exactPhysicalPixel(
            minimumPointY * scale,
            name: "vertical source origin"
        )
        let physicalMaximumX = try Self.exactPhysicalPixel(
            maximumPointX * scale,
            name: "horizontal source extent"
        )
        let physicalMaximumY = try Self.exactPhysicalPixel(
            maximumPointY * scale,
            name: "vertical source extent"
        )
        let sourcePixelRect = CGRect(
            x: physicalMinimumX,
            y: physicalMinimumY,
            width: physicalMaximumX - physicalMinimumX,
            height: physicalMaximumY - physicalMinimumY
        )
        let targetPixelInImage = CGPoint(
            x: targetPixel.x - sourcePixelRect.minX,
            y: targetPixel.y - sourcePixelRect.minY
        )
        guard sourcePixelRect.width >= 1,
              sourcePixelRect.height >= 1,
              targetPixelInImage.x >= 0,
              targetPixelInImage.y >= 0,
              targetPixelInImage.x < sourcePixelRect.width,
              targetPixelInImage.y < sourcePixelRect.height
        else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "The aligned screen capture does not contain its target pixel."
            )
        }

        self.sourceRectInPoints = sourceRectInPoints
        self.sourcePixelRect = sourcePixelRect
        self.targetPixelInImage = targetPixelInImage
    }

    private static func exactPhysicalPixel(
        _ value: CGFloat,
        name: String
    ) throws -> CGFloat {
        let rounded = value.rounded()
        guard abs(value - rounded) <= 0.001 else {
            throw ScreenshotAppError.pixelSamplingFailed(
                description: "The display scale cannot map the aligned \(name) to a physical pixel."
            )
        }
        return rounded
    }

    private static func logicalPointAlignment(for scale: CGFloat) throws -> CGFloat {
        for candidate in 1...64 {
            let pointLength = CGFloat(candidate)
            let physicalLength = pointLength * scale
            if abs(physicalLength - physicalLength.rounded()) <= 0.001 {
                return pointLength
            }
        }
        throw ScreenshotAppError.pixelSamplingFailed(
            description: "The display scale cannot align logical points to physical pixels."
        )
    }
}
