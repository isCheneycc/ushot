import ApplicationServices
import CoreGraphics
import Foundation

public enum InterfaceElementResolution: Equatable, Sendable {
    case elementHierarchy([CGRect])
    case accessibilityPermissionRequired
    case noElement
}

/// Resolves the useful Accessibility hierarchy underneath an AppKit desktop
/// point, ordered from the deepest element toward its ancestors. The owning
/// application is taken from the already-frozen ScreenCaptureKit window list,
/// so Ushot's overlay never becomes the queried accessibility target.
public struct InterfaceElementSelectionResolver: Sendable {
    public init() {}

    public static var isAccessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    public func resolve(
        at appKitPoint: CGPoint,
        in window: WindowDescriptor,
        primaryDisplayHeight: CGFloat
    ) -> InterfaceElementResolution {
        guard Self.isAccessibilityAuthorized else {
            return .accessibilityPermissionRequired
        }
        guard let processID = window.processID else { return .noElement }

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
        guard status == .success, var element = hitElement else {
            return .noElement
        }

        let transformer = CoordinateTransformer(primaryDisplayHeight: primaryDisplayHeight)
        var hierarchy: [CGRect] = []
        for _ in 0..<12 {
            if let accessibilityFrame = frame(of: element) {
                let appKitFrame = transformer
                    .appKitRect(fromScreenCaptureRect: accessibilityFrame)
                    .standardized
                let clipped = appKitFrame.intersection(window.frame.standardized)
                if isUseful(frame: clipped, containing: appKitPoint) {
                    let candidate = clipped.integral
                    if !hierarchy.contains(candidate) {
                        hierarchy.append(candidate)
                    }
                }
            }
            guard let parent = parent(of: element) else { break }
            element = parent
        }
        return hierarchy.isEmpty ? .noElement : .elementHierarchy(hierarchy)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        ) == .success,
        let parentValue,
        CFGetTypeID(parentValue) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(parentValue, to: AXUIElement.self)
    }

    private func isUseful(frame: CGRect, containing point: CGPoint) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && frame.width >= 6
            && frame.height >= 6
            && frame.contains(point)
    }
}
