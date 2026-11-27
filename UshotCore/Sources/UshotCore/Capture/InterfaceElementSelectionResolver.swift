import ApplicationServices
import CoreGraphics
import Foundation

public enum InterfaceElementResolution: Equatable, Sendable {
    case elementHierarchy([CGRect])
    case accessibilityPermissionRequired
    case noElement
    /// The hit element could not be proven to belong to the requested window:
    /// it lives in another (possibly invisible) window of the same process,
    /// the owning window is ambiguous, or the proof could not be read.
    /// Callers must drop every control frame.
    case ownershipUnverified(AccessibilityOwnershipFailure)
}

/// Why an Accessibility read produced no usable value. Only privacy-safe
/// integers and fixed labels; never attribute values.
public enum AccessibilityReadFailure: Equatable, Hashable, Sendable {
    /// The raw `AXError` code of a failed read.
    case status(Int32)
    /// The read succeeded, but the value had the wrong type or could not be
    /// decoded.
    case undecodableValue

    public var diagnosticLabel: String {
        switch self {
        case .status(let code): return "ax\(code)"
        case .undecodableValue: return "undecodable"
        }
    }
}

/// One Accessibility attribute read with three distinct outcomes. Only a
/// decoded value proves anything; "absent" is a definite statement that the
/// attribute does not exist, while "unreadable" means nothing is known.
public enum AccessibilityRead<Value> {
    case value(Value)
    /// The attribute has no value or is not supported by the element.
    case absent
    /// Every other error, including unknown codes, and a successful read whose
    /// value had the wrong type or could not be decoded.
    case unreadable(AccessibilityReadFailure)

    /// The single classification point for every Accessibility read.
    public init(status: AXError, decoded: Value?) {
        switch status {
        case .success:
            self = decoded.map(Self.value) ?? .unreadable(.undecodableValue)
        case .noValue, .attributeUnsupported:
            self = .absent
        default:
            self = .unreadable(.status(status.rawValue))
        }
    }
}

extension AccessibilityRead: Equatable where Value: Equatable {}
extension AccessibilityRead: Sendable where Value: Sendable {}

/// The Accessibility reads ownership proof needs. Production reads cross the
/// process boundary; tests substitute a deterministic tree.
public protocol AccessibilityHierarchyReading {
    associatedtype Element
    func role(of element: Element) -> AccessibilityRead<String>
    func parent(of element: Element) -> AccessibilityRead<Element>
    func topLevelElement(of element: Element) -> AccessibilityRead<Element>
    func windowElement(of element: Element) -> AccessibilityRead<Element>
    /// The element frame in AppKit global coordinates.
    func frame(of element: Element) -> AccessibilityRead<CGRect>
}

/// Privacy-safe reasons an Accessibility hit could not be attributed to the
/// target window.
public enum AccessibilityOwnershipRejection: String, Equatable, Sendable, CaseIterable {
    case roleUnavailable = "role-unavailable"
    case roleUnreadable = "role-unreadable"
    case parentUnreadable = "parent-unreadable"
    case proofDepthExceeded = "proof-depth-exceeded"
    case topLevelUnreadable = "top-level-unreadable"
    case windowUnavailable = "window-unavailable"
    case containerFrameUnreadable = "container-frame-unreadable"
    case frameMismatchOrAmbiguous = "frame-mismatch-or-ambiguous"
    /// The application hit test failed with an error other than "no element"
    /// or a disabled API, or succeeded without an element.
    case hitTestUnreadable = "hit-test-unreadable"
}

/// A rejection with privacy-safe diagnostics: where the proof stopped, the raw
/// read failure, and the nearest readable role as a fixed system label.
public struct AccessibilityOwnershipFailure: Equatable, Hashable, Sendable {
    public let rejection: AccessibilityOwnershipRejection
    /// Walk depth of the element whose read failed; 0 is the hit element.
    /// Nil when the failure is not tied to one walked element.
    public let depth: Int?
    public let readFailure: AccessibilityReadFailure?
    /// The last role read successfully on the walk, reduced to
    /// `AccessibilityRoleLabel`.
    public let lastReadableRole: String?

    public init(
        _ rejection: AccessibilityOwnershipRejection,
        depth: Int? = nil,
        readFailure: AccessibilityReadFailure? = nil,
        lastReadableRole: String? = nil
    ) {
        self.rejection = rejection
        self.depth = depth
        self.readFailure = readFailure
        self.lastReadableRole = lastReadableRole
    }

    /// For example `role-unreadable@3:ax-25202<AXGroup`.
    public var diagnosticKey: String {
        var key = rejection.rawValue
        if let depth { key += "@\(depth)" }
        if let readFailure { key += ":\(readFailure.diagnosticLabel)" }
        if let lastReadableRole { key += "<\(lastReadableRole)" }
        return key
    }
}

/// Reduces an application-supplied role string to a fixed public label so a
/// custom role can never carry arbitrary text into logs.
public enum AccessibilityRoleLabel {
    public static let systemRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXPopover",
        "AXGroup", "AXWebArea", "AXScrollArea", "AXSplitGroup", "AXSplitter",
        "AXLayoutArea", "AXLayoutItem", "AXToolbar", "AXTabGroup",
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXComboBox", "AXSlider", "AXScrollBar",
        "AXStaticText", "AXTextField", "AXTextArea", "AXImage", "AXLink",
        "AXHeading", "AXList", "AXRow", "AXColumn", "AXCell", "AXTable",
        "AXOutline", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem",
        "AXUnknown",
    ]

    public static func label(for role: String) -> String {
        systemRoles.contains(role) ? role : "custom"
    }
}

public enum AccessibilityOwnershipVerification<Element> {
    /// `path` runs from the hit element toward its ancestors, truncated to the
    /// returned hierarchy depth.
    case verified(path: [Element])
    case rejected(AccessibilityOwnershipFailure)
}

/// Pure ownership policy for Accessibility hit results. Core Graphics window
/// IDs have no supported public mapping to AX elements, so ownership is proven
/// geometrically and fails closed whenever the proof is unknown or ambiguous.
public struct AccessibilityWindowOwnership: Sendable {
    /// Container roles that own their own frame. A sheet, drawer or popover
    /// reports its host through `AXWindow`, so its own frame is the evidence.
    public static let containerRoles: Set<String> = [
        kAXWindowRole as String,
        kAXSheetRole as String,
        kAXDrawerRole as String,
        kAXPopoverRole as String,
    ]
    /// Levels returned to the user as snap candidates.
    public static let maximumHierarchyDepth = 12
    /// Ancestor reads allowed while searching for the owning container; only a
    /// cycle guard, so deep web and Electron trees still verify.
    public static let maximumProofDepth = 128

    public let tolerance: CGFloat

    public init(tolerance: CGFloat = 2) {
        self.tolerance = tolerance
    }

    /// - Parameters:
    ///   - containerFrame: The AppKit frame of the owning container.
    ///   - target: The frozen target window frame.
    ///   - siblingFrames: Every other visible window frame of the same process.
    public func isVerified(
        containerFrame: CGRect,
        target: CGRect,
        siblingFrames: [CGRect]
    ) -> Bool {
        guard matches(containerFrame, target) else { return false }
        // The container must identify the target and nothing else: when it
        // also fits a same-process sibling, or the target is itself
        // indistinguishable from one, the geometric proof is meaningless.
        return !siblingFrames.contains {
            matches(containerFrame, $0) || matches($0, target)
        }
    }

    public func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let lhs = lhs.standardized
        let rhs = rhs.standardized
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.maxX - rhs.maxX) <= tolerance
            && abs(lhs.maxY - rhs.maxY) <= tolerance
    }

    /// Proves that `hit` belongs to `target`, reading lazily in priority order
    /// and stopping at the first decisive answer:
    ///
    /// 1. Walk ancestors. A container role ends the search and only that
    ///    container's frame is checked. An unreadable or absent role, an
    ///    unreadable parent, or exceeding the proof depth rejects.
    /// 2. Only when the chain ends naturally (parent absent) without a
    ///    container is `AXTopLevelUIElement` read; if it exists, only it is
    ///    checked. An unreadable top-level element rejects.
    /// 3. Only when the top-level element is absent is `AXWindow` read.
    public func verify<Reader: AccessibilityHierarchyReading>(
        hit: Reader.Element,
        reader: Reader,
        target: CGRect,
        siblingFrames: [CGRect]
    ) -> AccessibilityOwnershipVerification<Reader.Element> {
        var path: [Reader.Element] = []
        var current = hit
        var container: Reader.Element?
        var chainEnded = false
        var lastRole: String?
        func failure(
            _ rejection: AccessibilityOwnershipRejection,
            depth: Int? = nil,
            _ readFailure: AccessibilityReadFailure? = nil
        ) -> AccessibilityOwnershipVerification<Reader.Element> {
            .rejected(AccessibilityOwnershipFailure(
                rejection,
                depth: depth,
                readFailure: readFailure,
                lastReadableRole: lastRole.map(AccessibilityRoleLabel.label(for:))
            ))
        }
        for depth in 0..<Self.maximumProofDepth {
            path.append(current)
            switch reader.role(of: current) {
            case .value(let role):
                lastRole = role
                if Self.containerRoles.contains(role) { container = current }
            case .absent:
                return failure(.roleUnavailable, depth: depth)
            case .unreadable(let readFailure):
                return failure(.roleUnreadable, depth: depth, readFailure)
            }
            if container != nil { break }
            switch reader.parent(of: current) {
            case .value(let next):
                current = next
            case .absent:
                chainEnded = true
            case .unreadable(let readFailure):
                return failure(.parentUnreadable, depth: depth, readFailure)
            }
            if chainEnded { break }
        }
        let hierarchyPath = Array(path.prefix(Self.maximumHierarchyDepth))

        if container == nil {
            guard chainEnded else { return failure(.proofDepthExceeded) }
            switch reader.topLevelElement(of: hit) {
            case .value(let topLevel):
                container = topLevel
            case .unreadable(let readFailure):
                return failure(.topLevelUnreadable, depth: 0, readFailure)
            case .absent:
                switch reader.windowElement(of: hit) {
                case .value(let window):
                    container = window
                case .absent:
                    return failure(.windowUnavailable, depth: 0)
                case .unreadable(let readFailure):
                    return failure(.windowUnavailable, depth: 0, readFailure)
                }
            }
        }
        guard let container else { return failure(.windowUnavailable) }
        switch reader.frame(of: container) {
        case .value(let containerFrame):
            guard isVerified(containerFrame: containerFrame, target: target, siblingFrames: siblingFrames) else {
                return failure(.frameMismatchOrAmbiguous)
            }
        case .absent:
            return failure(.containerFrameUnreadable)
        case .unreadable(let readFailure):
            return failure(.containerFrameUnreadable, readFailure)
        }
        return .verified(path: hierarchyPath)
    }
}

/// Live Accessibility reads. It only performs the read, checks the decoded
/// type and classifies the status; every policy decision is in
/// `AccessibilityWindowOwnership`.
struct LiveAccessibilityReader: AccessibilityHierarchyReading {
    let transformer: CoordinateTransformer

    func role(of element: AXUIElement) -> AccessibilityRead<String> {
        let (status, value) = copy(kAXRoleAttribute, of: element)
        let decoded = value.flatMap { value -> String? in
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            return value as? String
        }
        return AccessibilityRead(status: status, decoded: decoded)
    }

    func parent(of element: AXUIElement) -> AccessibilityRead<AXUIElement> {
        elementRead(kAXParentAttribute, of: element)
    }

    func topLevelElement(of element: AXUIElement) -> AccessibilityRead<AXUIElement> {
        elementRead(kAXTopLevelUIElementAttribute, of: element)
    }

    func windowElement(of element: AXUIElement) -> AccessibilityRead<AXUIElement> {
        elementRead(kAXWindowAttribute, of: element)
    }

    func frame(of element: AXUIElement) -> AccessibilityRead<CGRect> {
        let position = pointRead(kAXPositionAttribute, of: element)
        let size = sizeRead(kAXSizeAttribute, of: element)
        switch (position, size) {
        case (.value(let origin), .value(let size)):
            guard origin.x.isFinite, origin.y.isFinite,
                  size.width.isFinite, size.height.isFinite
            else { return .unreadable(.undecodableValue) }
            let frame = transformer
                .appKitRect(fromScreenCaptureRect: CGRect(origin: origin, size: size))
                .standardized
            return .value(frame)
        case (.unreadable(let failure), _), (_, .unreadable(let failure)):
            return .unreadable(failure)
        default:
            return .absent
        }
    }

    private func copy(_ attribute: String, of element: AXUIElement) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (status, value)
    }

    private func elementRead(_ attribute: String, of element: AXUIElement) -> AccessibilityRead<AXUIElement> {
        let (status, value) = copy(attribute, of: element)
        let decoded = value.flatMap { value -> AXUIElement? in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        return AccessibilityRead(status: status, decoded: decoded)
    }

    private func axValue(_ value: CFTypeRef, of type: AXValueType) -> AXValue? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }

    private func pointRead(_ attribute: String, of element: AXUIElement) -> AccessibilityRead<CGPoint> {
        let (status, value) = copy(attribute, of: element)
        let decoded = value.flatMap { value -> CGPoint? in
            guard let axValue = axValue(value, of: .cgPoint) else { return nil }
            var point = CGPoint.zero
            return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
        }
        return AccessibilityRead(status: status, decoded: decoded)
    }

    private func sizeRead(_ attribute: String, of element: AXUIElement) -> AccessibilityRead<CGSize> {
        let (status, value) = copy(attribute, of: element)
        let decoded = value.flatMap { value -> CGSize? in
            guard let axValue = axValue(value, of: .cgSize) else { return nil }
            var size = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
        }
        return AccessibilityRead(status: status, decoded: decoded)
    }
}

/// Resolves the useful Accessibility hierarchy underneath an AppKit desktop
/// point, ordered from the deepest element toward its ancestors. The owning
/// application is taken from the already-frozen window stack, so Ushot's
/// overlay never becomes the queried accessibility target, and every result
/// must prove it belongs to the requested window.
public struct InterfaceElementSelectionResolver: Sendable {
    private let ownProcessID: pid_t
    private let ownership: AccessibilityWindowOwnership

    public init(
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        ownership: AccessibilityWindowOwnership = AccessibilityWindowOwnership()
    ) {
        self.ownProcessID = ownProcessID
        self.ownership = ownership
    }

    public static var isAccessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    public func resolve(
        at appKitPoint: CGPoint,
        in window: WindowDescriptor,
        primaryDisplayHeight: CGFloat,
        siblingWindowFrames: [CGRect] = []
    ) -> InterfaceElementResolution {
        // Ushot's own windows (pinned images, Settings) are complete
        // window-level targets. Querying our own process here could resolve
        // the live selection overlay instead.
        guard !window.isOwnApplicationWindow else { return .noElement }
        guard let processID = window.processID, processID != ownProcessID else {
            return .noElement
        }
        guard Self.isAccessibilityAuthorized else {
            return .accessibilityPermissionRequired
        }

        let application = AXUIElementCreateApplication(processID)
        let accessibilityPoint = CGPoint(
            x: appKitPoint.x,
            y: primaryDisplayHeight - appKitPoint.y
        )
        var hitElement: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            application,
            Float(accessibilityPoint.x),
            Float(accessibilityPoint.y),
            &hitElement
        )
        if let unresolved = Self.hitTestFailure(status: status, hasElement: hitElement != nil) {
            return unresolved
        }
        guard let hitElement else { return .noElement }

        let reader = LiveAccessibilityReader(
            transformer: CoordinateTransformer(primaryDisplayHeight: primaryDisplayHeight)
        )
        let targetFrame = window.frame.standardized
        let path: [AXUIElement]
        switch ownership.verify(
            hit: hitElement,
            reader: reader,
            target: targetFrame,
            siblingFrames: siblingWindowFrames
        ) {
        case .verified(let verifiedPath):
            path = verifiedPath
        case .rejected(let failure):
            return .ownershipUnverified(failure)
        }

        // The returned levels reuse the verified walk; no second traversal.
        var hierarchy: [CGRect] = []
        for element in path {
            guard case .value(let appKitFrame) = reader.frame(of: element) else { continue }
            let clipped = appKitFrame.intersection(targetFrame)
            if isUseful(frame: clipped, containing: appKitPoint) {
                let candidate = clipped.integral
                if !hierarchy.contains(candidate) {
                    hierarchy.append(candidate)
                }
            }
        }
        return hierarchy.isEmpty ? .noElement : .elementHierarchy(hierarchy)
    }

    /// Classifies the application hit test. Returns nil only for a hit that
    /// produced an element to prove. "No element here" keeps the caller's
    /// ordinary miss handling, a disabled API is a permission failure, and
    /// every other outcome is unknown: it must drop the previous control
    /// instead of letting it survive as if nothing were there.
    static func hitTestFailure(status: AXError, hasElement: Bool) -> InterfaceElementResolution? {
        switch status {
        case .success:
            guard hasElement else {
                return .ownershipUnverified(AccessibilityOwnershipFailure(
                    .hitTestUnreadable,
                    readFailure: .undecodableValue
                ))
            }
            return nil
        case .noValue:
            return .noElement
        case .apiDisabled:
            // Trust was revoked after the preflight check.
            return .accessibilityPermissionRequired
        default:
            return .ownershipUnverified(AccessibilityOwnershipFailure(
                .hitTestUnreadable,
                readFailure: .status(status.rawValue)
            ))
        }
    }

    private func isUseful(frame: CGRect, containing point: CGPoint) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && frame.width >= 6
            && frame.height >= 6
            && frame.contains(point)
    }
}
