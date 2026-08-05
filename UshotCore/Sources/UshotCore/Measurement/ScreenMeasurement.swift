import CoreGraphics
import Foundation

public enum MeasurementShape: String, Codable, CaseIterable, Sendable {
    case rectangle
    case line
}

public struct ScreenMeasurement: Codable, Equatable, Sendable {
    public let shape: MeasurementShape
    public let start: CGPoint
    public let end: CGPoint
    public let displayID: CGDirectDisplayID
    public let displayName: String
    public let displayScale: CGFloat

    public init(
        shape: MeasurementShape,
        start: CGPoint,
        end: CGPoint,
        displayID: CGDirectDisplayID,
        displayName: String,
        displayScale: CGFloat
    ) {
        self.shape = shape
        self.start = start
        self.end = end
        self.displayID = displayID
        self.displayName = displayName
        self.displayScale = displayScale
    }

    public var widthInPoints: CGFloat { abs(end.x - start.x) }
    public var heightInPoints: CGFloat { abs(end.y - start.y) }
    public var distanceInPoints: CGFloat { hypot(end.x - start.x, end.y - start.y) }
    public var widthInPixels: CGFloat { widthInPoints * displayScale }
    public var heightInPixels: CGFloat { heightInPoints * displayScale }
    public var distanceInPixels: CGFloat { distanceInPoints * displayScale }

    public var copyRepresentation: String {
        String(
            format: "%@ — %.1f × %.1f pt (%.0f × %.0f px), distance %.1f pt (%.1f px), start (%.1f, %.1f), end (%.1f, %.1f), scale %.2fx",
            locale: Locale(identifier: "en_US_POSIX"),
            displayName,
            widthInPoints,
            heightInPoints,
            widthInPixels,
            heightInPixels,
            distanceInPoints,
            distanceInPixels,
            start.x,
            start.y,
            end.x,
            end.y,
            displayScale
        )
    }
}

public struct ScreenMeasurementCalculator: Sendable {
    public let displays: [DisplayDescriptor]

    public init(displays: [DisplayDescriptor]) {
        self.displays = displays
    }

    public func measurement(
        shape: MeasurementShape,
        start: CGPoint,
        end: CGPoint
    ) throws -> ScreenMeasurement {
        guard let display = displays.first(where: { $0.frame.contains(end) })
            ?? displays.first(where: { $0.frame.contains(start) })
        else {
            throw ScreenshotAppError.noDisplayAvailable
        }
        return ScreenMeasurement(
            shape: shape,
            start: start,
            end: end,
            displayID: display.id,
            displayName: display.name,
            displayScale: display.scale
        )
    }

    public func constrainedEnd(start: CGPoint, proposedEnd: CGPoint) -> CGPoint {
        let deltaX = proposedEnd.x - start.x
        let deltaY = proposedEnd.y - start.y
        let distance = hypot(deltaX, deltaY)
        guard distance > 0 else { return proposedEnd }
        let angle = atan2(deltaY, deltaX)
        let increment = CGFloat.pi / 4
        let constrainedAngle = (angle / increment).rounded() * increment
        return CGPoint(
            x: start.x + cos(constrainedAngle) * distance,
            y: start.y + sin(constrainedAngle) * distance
        )
    }
}
