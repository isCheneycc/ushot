import CoreGraphics
import Foundation

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case region
    case window
    case currentDisplay
    case selectedDisplay
    case allDisplays
}

public struct CaptureRequest: Sendable {
    public var mode: CaptureMode
    public var showsCursor: Bool
    public var includesWindowShadow: Bool
    public var excludesOwnApplication: Bool
    public var targetDisplayID: CGDirectDisplayID?
    public var targetWindowID: CGWindowID?
    public var region: CGRect?

    public init(
        mode: CaptureMode,
        showsCursor: Bool = false,
        includesWindowShadow: Bool = true,
        excludesOwnApplication: Bool = true,
        targetDisplayID: CGDirectDisplayID? = nil,
        targetWindowID: CGWindowID? = nil,
        region: CGRect? = nil
    ) {
        self.mode = mode
        self.showsCursor = showsCursor
        self.includesWindowShadow = includesWindowShadow
        self.excludesOwnApplication = excludesOwnApplication
        self.targetDisplayID = targetDisplayID
        self.targetWindowID = targetWindowID
        self.region = region
    }
}

public struct CaptureSourceMetadata: Sendable {
    public enum SourceKind: String, Sendable {
        case display
        case window
        case region
        case allDisplays
    }

    public var kind: SourceKind
    public var displayIDs: [CGDirectDisplayID]
    public var windowID: CGWindowID?
    public var desktopFrame: CGRect
    public var capturedAt: Date

    public init(
        kind: SourceKind,
        displayIDs: [CGDirectDisplayID],
        windowID: CGWindowID?,
        desktopFrame: CGRect,
        capturedAt: Date = Date()
    ) {
        self.kind = kind
        self.displayIDs = displayIDs
        self.windowID = windowID
        self.desktopFrame = desktopFrame
        self.capturedAt = capturedAt
    }
}

public struct CapturedImage: @unchecked Sendable {
    public let image: CGImage
    public let colorSpace: CGColorSpace?
    public let pixelSize: CGSize
    public let logicalSize: CGSize
    public let scale: CGFloat
    public let sourceMetadata: CaptureSourceMetadata

    public init(
        image: CGImage,
        colorSpace: CGColorSpace?,
        pixelSize: CGSize,
        logicalSize: CGSize,
        scale: CGFloat,
        sourceMetadata: CaptureSourceMetadata
    ) {
        self.image = image
        self.colorSpace = colorSpace
        self.pixelSize = pixelSize
        self.logicalSize = logicalSize
        self.scale = scale
        self.sourceMetadata = sourceMetadata
    }
}

public struct DisplayDescriptor: Identifiable, Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let pixelSize: CGSize
    public let scale: CGFloat
    public let isCurrent: Bool

    public init(
        id: CGDirectDisplayID,
        name: String,
        frame: CGRect,
        pixelSize: CGSize,
        scale: CGFloat,
        isCurrent: Bool
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.pixelSize = pixelSize
        self.scale = scale
        self.isCurrent = isCurrent
    }
}

public struct WindowDescriptor: Identifiable, Equatable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let applicationName: String
    public let frame: CGRect
    public let layer: Int
    public let processID: pid_t?

    public init(
        id: CGWindowID,
        title: String,
        applicationName: String,
        frame: CGRect,
        layer: Int,
        processID: pid_t? = nil
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.frame = frame
        self.layer = layer
        self.processID = processID
    }
}

public struct CaptureTargets: Sendable {
    public let displays: [DisplayDescriptor]
    public let windows: [WindowDescriptor]

    public init(displays: [DisplayDescriptor], windows: [WindowDescriptor]) {
        self.displays = displays
        self.windows = windows
    }
}

public struct DisplayCapture: @unchecked Sendable {
    public let descriptor: DisplayDescriptor
    public let capturedImage: CapturedImage

    public init(descriptor: DisplayDescriptor, capturedImage: CapturedImage) {
        self.descriptor = descriptor
        self.capturedImage = capturedImage
    }
}

public struct MultiDisplayCaptureResult: @unchecked Sendable {
    public let composite: CapturedImage
    public let displays: [DisplayCapture]

    public init(composite: CapturedImage, displays: [DisplayCapture]) {
        self.composite = composite
        self.displays = displays
    }
}

public struct RegionCapturePreparation: @unchecked Sendable {
    public let displays: [DisplayCapture]
    public let windows: [WindowDescriptor]

    public init(
        displays: [DisplayCapture],
        windows: [WindowDescriptor] = []
    ) {
        self.displays = displays
        self.windows = windows
    }

    public var geometry: ScreenGeometry {
        ScreenGeometry(displays: displays.map {
            DisplayGeometry(id: $0.descriptor.id, frame: $0.descriptor.frame, scale: $0.descriptor.scale)
        })
    }
}

public enum CaptureResult: @unchecked Sendable {
    case image(CapturedImage)
    case multiDisplay(MultiDisplayCaptureResult)

    public var presentationImage: CapturedImage {
        switch self {
        case .image(let image): return image
        case .multiDisplay(let result): return result.composite
        }
    }
}

@MainActor
public protocol ScreenCapturing: AnyObject {
    func discoverTargets() async throws -> CaptureTargets
    func capture(_ request: CaptureRequest) async throws -> CaptureResult
    func prepareRegionCapture(_ request: CaptureRequest) async throws -> RegionCapturePreparation
    func cropRegion(
        _ region: CGRect,
        from preparation: RegionCapturePreparation
    ) throws -> CapturedImage
}

public protocol FrameStreaming: Sendable {}
