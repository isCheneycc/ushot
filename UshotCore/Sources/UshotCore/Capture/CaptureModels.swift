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
    /// Committed image windows that remain capturable when the host app is excluded.
    public var includedOwnWindowIDs: Set<CGWindowID>
    /// Ordinary Ushot interface windows (currently the visible Settings
    /// window) that remain capturable when the host app is excluded. They are
    /// never Accessibility-queried and do not receive pinned-image exceptions.
    public var includedOwnInterfaceWindowIDs: Set<CGWindowID>
    public var targetDisplayID: CGDirectDisplayID?
    public var targetWindowID: CGWindowID?
    public var region: CGRect?

    public init(
        mode: CaptureMode,
        showsCursor: Bool = false,
        includesWindowShadow: Bool = true,
        excludesOwnApplication: Bool = true,
        includedOwnWindowIDs: Set<CGWindowID> = [],
        includedOwnInterfaceWindowIDs: Set<CGWindowID> = [],
        targetDisplayID: CGDirectDisplayID? = nil,
        targetWindowID: CGWindowID? = nil,
        region: CGRect? = nil
    ) {
        self.mode = mode
        self.showsCursor = showsCursor
        self.includesWindowShadow = includesWindowShadow
        self.excludesOwnApplication = excludesOwnApplication
        self.includedOwnWindowIDs = includedOwnWindowIDs
        self.includedOwnInterfaceWindowIDs = includedOwnInterfaceWindowIDs
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
    /// Set only for a host-owned image admitted by the current capture request.
    public let isPinnedImage: Bool
    /// Set only for an ordinary host-owned interface window (Settings) admitted
    /// by the current capture request.
    public let isOwnInterfaceWindow: Bool

    public init(
        id: CGWindowID,
        title: String,
        applicationName: String,
        frame: CGRect,
        layer: Int,
        processID: pid_t? = nil,
        isPinnedImage: Bool = false,
        isOwnInterfaceWindow: Bool = false
    ) {
        precondition(
            !(isPinnedImage && isOwnInterfaceWindow),
            "A host-owned window has exactly one capture admission role."
        )
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.frame = frame
        self.layer = layer
        self.processID = processID
        self.isPinnedImage = isPinnedImage
        self.isOwnInterfaceWindow = isOwnInterfaceWindow
    }

    /// Host-owned windows are window-level targets only: querying Ushot's own
    /// Accessibility tree could resolve the live selection overlay instead.
    public var isOwnApplicationWindow: Bool {
        isPinnedImage || isOwnInterfaceWindow
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
    /// Selectable windows in front-to-back order.
    public let windows: [WindowDescriptor]
    /// The complete frozen front-to-back stack used for occlusion-aware smart
    /// snapping, including surfaces that can block but never be selected.
    public let windowStack: WindowStack

    /// - Parameter windowStack: The frozen visible stack. When omitted, the
    ///   caller supplies a complete synthetic desktop: every provided window
    ///   becomes a selectable entry in the given order and the stack is
    ///   available, so uncovered points are exposed desktop. Production region
    ///   capture always passes the reconciled stack explicitly.
    public init(
        displays: [DisplayCapture],
        windows: [WindowDescriptor] = [],
        windowStack: WindowStack? = nil
    ) {
        self.displays = displays
        self.windows = windows
        self.windowStack = windowStack ?? WindowStack(
            entries: windows.map { WindowStackEntry.selectable($0) },
            primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
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
    /// Displays only; never depends on window-order discovery.
    func discoverDisplays() async throws -> [DisplayDescriptor]
    func discoverTargets(
        includingOwnWindowIDs: Set<CGWindowID>,
        includingOwnInterfaceWindowIDs: Set<CGWindowID>
    ) async throws -> CaptureTargets
    func capture(_ request: CaptureRequest) async throws -> CaptureResult
    func prepareRegionCapture(_ request: CaptureRequest) async throws -> RegionCapturePreparation
    func cropRegion(
        _ region: CGRect,
        from preparation: RegionCapturePreparation
    ) throws -> CapturedImage
}
