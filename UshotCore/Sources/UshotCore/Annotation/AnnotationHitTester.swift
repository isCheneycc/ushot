import CoreGraphics
import Foundation

public protocol AnnotationHitTesting: Sendable {
    func contains(_ point: CGPoint, in item: AnnotationItem, tolerance: CGFloat) -> Bool
}

public struct AnnotationHitTester: AnnotationHitTesting {
    public init() {}

    public func contains(
        _ point: CGPoint,
        in item: AnnotationItem,
        tolerance: CGFloat = 6
    ) -> Bool {
        guard item.isVisible else { return false }

        if item.kind == .arrow {
            guard case .line(let start, let end) = item.geometry else { return false }
            // The renderer transforms the endpoints before constructing a
            // constant-width arrowhead. Build and test that same presentation-
            // space geometry instead of inverse-transforming the pointer.
            return containsArrow(
                point,
                from: start,
                to: end,
                in: item,
                tolerance: tolerance
            )
        }

        let localPoint = inverseTransformed(point, for: item)
        let effectiveTolerance = tolerance + item.style.lineWidth / 2

        switch item.geometry {
        case .rect(let rect):
            let rect = rect.standardized
            switch item.kind {
            case .ellipse:
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radiusX = max(1, rect.width / 2 + effectiveTolerance)
                let radiusY = max(1, rect.height / 2 + effectiveTolerance)
                let dx = (localPoint.x - center.x) / radiusX
                let dy = (localPoint.y - center.y) / radiusY
                return dx * dx + dy * dy <= 1
            default:
                return rect.insetBy(dx: -effectiveTolerance, dy: -effectiveTolerance).contains(localPoint)
            }
        case .line(let start, let end):
            return distance(from: localPoint, toSegmentFrom: start, to: end) <= effectiveTolerance
        case .path(let points):
            guard points.count > 1 else {
                return points.first.map { hypot(localPoint.x - $0.x, localPoint.y - $0.y) <= effectiveTolerance } ?? false
            }
            return zip(points, points.dropFirst()).contains { start, end in
                distance(from: localPoint, toSegmentFrom: start, to: end) <= effectiveTolerance
            }
        }
    }

    private func containsArrow(
        _ point: CGPoint,
        from start: CGPoint,
        to end: CGPoint,
        in item: AnnotationItem,
        tolerance: CGFloat
    ) -> Bool {
        let transform = presentationTransform(for: item)
        let lineWidth = max(0.5, item.style.lineWidth)
        guard let geometry = ArrowVectorGeometry(
            start: start.applying(transform),
            tip: end.applying(transform),
            lineWidth: lineWidth
        ) else {
            return false
        }

        let fillTolerance = max(0, tolerance)
        let strokeTolerance = fillTolerance + lineWidth / 2

        switch item.style.arrowHeadStyle {
        case .open:
            return containsStrokedSegment(
                point,
                from: geometry.start,
                to: geometry.tip,
                tolerance: strokeTolerance
            ) || containsStrokedSegment(
                point,
                from: geometry.headLeft,
                to: geometry.tip,
                tolerance: strokeTolerance
            ) || containsStrokedSegment(
                point,
                from: geometry.tip,
                to: geometry.headRight,
                tolerance: strokeTolerance
            )
        case .filled:
            return geometry.filledShaft.contains(
                point,
                tolerance: fillTolerance
            ) || contains(
                point,
                inFilledPolygon: filledHeadPolygon(for: geometry),
                tolerance: fillTolerance
            )
        case .tapered:
            return contains(
                point,
                inFilledPolygon: [
                    geometry.taperedTailLeft,
                    geometry.taperedNeckLeft,
                    geometry.headLeft,
                    geometry.tip,
                    geometry.headRight,
                    geometry.taperedNeckRight,
                    geometry.taperedTailRight
                ],
                tolerance: fillTolerance
            )
        case .double:
            guard let reverse = ArrowVectorGeometry(
                start: geometry.tip,
                tip: geometry.start,
                lineWidth: lineWidth
            ) else {
                return false
            }
            return geometry.doubleShaft(with: reverse).contains(
                point,
                tolerance: fillTolerance
            ) || contains(
                point,
                inFilledPolygon: filledHeadPolygon(for: geometry),
                tolerance: fillTolerance
            ) || contains(
                point,
                inFilledPolygon: filledHeadPolygon(for: reverse),
                tolerance: fillTolerance
            )
        }
    }

    private func filledHeadPolygon(for geometry: ArrowVectorGeometry) -> [CGPoint] {
        // The shaft join preserves the rendered head's concave rear V. A
        // triangle or convex hull would make empty pixels selectable.
        [
            geometry.headLeft,
            geometry.tip,
            geometry.headRight,
            geometry.headShaftJoin
        ]
    }

    private func containsStrokedSegment(
        _ point: CGPoint,
        from start: CGPoint,
        to end: CGPoint,
        tolerance: CGFloat
    ) -> Bool {
        distance(from: point, toSegmentFrom: start, to: end) <= tolerance
    }

    private func contains(
        _ point: CGPoint,
        inFilledPolygon vertices: [CGPoint],
        tolerance: CGFloat
    ) -> Bool {
        guard vertices.count >= 3 else { return false }

        for (start, end) in zip(vertices, vertices.dropFirst() + [vertices[0]]) {
            if distance(from: point, toSegmentFrom: start, to: end) <= tolerance {
                return true
            }
        }

        var isInside = false
        var previous = vertices[vertices.count - 1]
        for current in vertices {
            let crossesHorizontalRay = (current.y > point.y) != (previous.y > point.y)
            if crossesHorizontalRay {
                let intersectionX = current.x
                    + (point.y - current.y) * (previous.x - current.x)
                    / (previous.y - current.y)
                if point.x < intersectionX {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside
    }

    private func inverseTransformed(_ point: CGPoint, for item: AnnotationItem) -> CGPoint {
        let transform = presentationTransform(for: item)
        guard !transform.isIdentity, let inverse = transform.invertedIfPossible else { return point }
        return point.applying(inverse)
    }

    private func presentationTransform(for item: AnnotationItem) -> CGAffineTransform {
        let center = item.geometry.boundingBox.center
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(
            x: center.x + item.transform.translation.width,
            y: center.y + item.transform.translation.height
        )
        transform = transform.rotated(by: item.transform.rotationRadians)
        transform = transform.scaledBy(x: item.transform.scaleX, y: item.transform.scaleY)
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        return transform
    }

    private func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }
}

public enum AnnotationSelectionHandle: String, CaseIterable, Sendable {
    case northWest
    case north
    case northEast
    case east
    case southEast
    case south
    case southWest
    case west
    case lineStart
    case lineEnd

    public var horizontalDirection: CGFloat {
        switch self {
        case .northWest, .southWest, .west: return -1
        case .northEast, .southEast, .east: return 1
        case .north, .south, .lineStart, .lineEnd: return 0
        }
    }

    public var verticalDirection: CGFloat {
        switch self {
        case .northWest, .north, .northEast: return 1
        case .southEast, .south, .southWest: return -1
        case .east, .west, .lineStart, .lineEnd: return 0
        }
    }
}

public struct AnnotationSelectionHandlePoint: Equatable, Sendable {
    public let handle: AnnotationSelectionHandle
    public let point: CGPoint

    public init(handle: AnnotationSelectionHandle, point: CGPoint) {
        self.handle = handle
        self.point = point
    }
}

public struct AnnotationSelectionGeometry: Sendable {
    public init() {}

    public func transformedPoint(_ point: CGPoint, for item: AnnotationItem) -> CGPoint {
        point.applying(transform(for: item))
    }

    public func transformedBounds(for item: AnnotationItem) -> CGRect {
        let points = outlinePoints(for: item)
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { bounds, point in
            bounds.union(CGRect(origin: point, size: .zero))
        }
    }

    public func outlinePoints(for item: AnnotationItem) -> [CGPoint] {
        switch item.geometry {
        case .line(let start, let end):
            return [transformedPoint(start, for: item), transformedPoint(end, for: item)]
        case .rect, .path:
            let bounds = item.geometry.boundingBox.standardized
            return [
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.minY)
            ].map { transformedPoint($0, for: item) }
        }
    }

    public func handlePoints(for item: AnnotationItem) -> [AnnotationSelectionHandlePoint] {
        guard item.kind.usesStandardSelectionResizeHandles else { return [] }
        if case .line(let start, let end) = item.geometry {
            return [
                AnnotationSelectionHandlePoint(
                    handle: .lineStart,
                    point: transformedPoint(start, for: item)
                ),
                AnnotationSelectionHandlePoint(
                    handle: .lineEnd,
                    point: transformedPoint(end, for: item)
                )
            ]
        }

        let bounds = item.geometry.boundingBox.standardized
        guard bounds.width > .ulpOfOne, bounds.height > .ulpOfOne else {
            return []
        }
        let localPoints: [(AnnotationSelectionHandle, CGPoint)] = [
            (.northWest, CGPoint(x: bounds.minX, y: bounds.maxY)),
            (.north, CGPoint(x: bounds.midX, y: bounds.maxY)),
            (.northEast, CGPoint(x: bounds.maxX, y: bounds.maxY)),
            (.east, CGPoint(x: bounds.maxX, y: bounds.midY)),
            (.southEast, CGPoint(x: bounds.maxX, y: bounds.minY)),
            (.south, CGPoint(x: bounds.midX, y: bounds.minY)),
            (.southWest, CGPoint(x: bounds.minX, y: bounds.minY)),
            (.west, CGPoint(x: bounds.minX, y: bounds.midY))
        ]
        return localPoints.map { handle, point in
            AnnotationSelectionHandlePoint(
                handle: handle,
                point: transformedPoint(point, for: item)
            )
        }
    }

    public func moved(_ item: AnnotationItem, by offset: CGSize) -> AnnotationItem {
        var moved = item
        moved.transform.translation.width += offset.width
        moved.transform.translation.height += offset.height
        return moved
    }

    public func resized(
        _ item: AnnotationItem,
        using handle: AnnotationSelectionHandle,
        to pointer: CGPoint,
        minimumDimension: CGFloat
    ) -> AnnotationItem {
        precondition(
            item.kind.usesStandardSelectionResizeHandles,
            "This annotation does not use standard selection resize handles."
        )
        if case .line(let start, let end) = item.geometry {
            precondition(
                handle == .lineStart || handle == .lineEnd,
                "A line annotation can only be resized from an endpoint."
            )
            let transformedStart = transformedPoint(start, for: item)
            let transformedEnd = transformedPoint(end, for: item)
            var resized = item
            resized.geometry = handle == .lineStart
                ? .line(start: pointer, end: transformedEnd)
                : .line(start: transformedStart, end: pointer)
            resized.transform = AnnotationTransform()
            return resized
        }

        precondition(
            handle != .lineStart && handle != .lineEnd,
            "A frame annotation cannot be resized from a line endpoint."
        )
        let bounds = item.geometry.boundingBox.standardized
        precondition(
            bounds.width > 0 && bounds.height > 0,
            "A frame annotation must have non-zero geometry before it can be resized."
        )
        precondition(
            item.transform.scaleX > 0 && item.transform.scaleY > 0,
            "Interactive frame resizing requires positive annotation scale values."
        )

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let worldCenter = CGPoint(
            x: center.x + item.transform.translation.width,
            y: center.y + item.transform.translation.height
        )
        let cosine = cos(item.transform.rotationRadians)
        let sine = sin(item.transform.rotationRadians)
        let xAxis = CGPoint(x: cosine, y: sine)
        let yAxis = CGPoint(x: -sine, y: cosine)
        let pointerVector = CGPoint(x: pointer.x - worldCenter.x, y: pointer.y - worldCenter.y)
        let pointerX = pointerVector.x * xAxis.x + pointerVector.y * xAxis.y
        let pointerY = pointerVector.x * yAxis.x + pointerVector.y * yAxis.y

        var scaleX = item.transform.scaleX
        var scaleY = item.transform.scaleY
        var centerOffsetX: CGFloat = 0
        var centerOffsetY: CGFloat = 0

        let horizontal = handle.horizontalDirection
        if horizontal != 0 {
            let fixedX = -horizontal * bounds.width * item.transform.scaleX / 2
            let resizedWidth = max(
                max(0.5, minimumDimension),
                horizontal * (pointerX - fixedX)
            )
            scaleX = resizedWidth / bounds.width
            let clampedPointerX = fixedX + horizontal * resizedWidth
            centerOffsetX = (clampedPointerX + fixedX) / 2
        }

        let vertical = handle.verticalDirection
        if vertical != 0 {
            let fixedY = -vertical * bounds.height * item.transform.scaleY / 2
            let resizedHeight = max(
                max(0.5, minimumDimension),
                vertical * (pointerY - fixedY)
            )
            scaleY = resizedHeight / bounds.height
            let clampedPointerY = fixedY + vertical * resizedHeight
            centerOffsetY = (clampedPointerY + fixedY) / 2
        }

        let resizedCenter = CGPoint(
            x: worldCenter.x + xAxis.x * centerOffsetX + yAxis.x * centerOffsetY,
            y: worldCenter.y + xAxis.y * centerOffsetX + yAxis.y * centerOffsetY
        )
        var resized = item
        resized.transform.scaleX = scaleX
        resized.transform.scaleY = scaleY
        resized.transform.translation = CGSize(
            width: resizedCenter.x - center.x,
            height: resizedCenter.y - center.y
        )
        return resized
    }

    private func transform(for item: AnnotationItem) -> CGAffineTransform {
        let center = item.geometry.boundingBox.center
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(
            x: center.x + item.transform.translation.width,
            y: center.y + item.transform.translation.height
        )
        transform = transform.rotated(by: item.transform.rotationRadians)
        transform = transform.scaledBy(x: item.transform.scaleX, y: item.transform.scaleY)
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        return transform
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension CGAffineTransform {
    var invertedIfPossible: CGAffineTransform? {
        let determinant = a * d - b * c
        guard abs(determinant) > .ulpOfOne else { return nil }
        return inverted()
    }
}
