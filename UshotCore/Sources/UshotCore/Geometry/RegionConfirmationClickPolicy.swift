import CoreGraphics
import Foundation

/// Shared click-pairing rules for region-confirmation double-click copy.
///
/// AppKit `clickCount` is not sufficient: a confirmation canvas may see
/// physical mouse and trackpad-press events whose clickCount stays 1, and a
/// pinch recognizer that delays mouse-down can scramble the same sequence.
/// Pairing uses the event timestamp and screen location of two completed
/// empty clicks.
public enum RegionConfirmationClickPolicy: Sendable {
    public enum DragDecision: Equatable, Sendable {
        /// Keep waiting for pointer-up; an armed second click may still copy.
        case keepPressPending
        /// Cancel any armed click action and begin the region body move.
        case beginBodyMove
    }

    /// Screen-point distance that turns a confirmation press into a body move.
    public static let bodyMoveThreshold: CGFloat = 8
    /// Screen-point slop between two empty clicks that still count as one double-click.
    public static let pairingSlop: CGFloat = 16

    public static func didCrossBodyMoveThreshold(
        from start: CGPoint,
        to current: CGPoint
    ) -> Bool {
        dragDecision(from: start, to: current) == .beginBodyMove
    }

    /// Resolves every region-body press, including an armed second click.
    ///
    /// Double-click recognition does not own the press until pointer-up. The
    /// same press must become a body move as soon as it crosses the threshold.
    public static func dragDecision(
        from start: CGPoint,
        to current: CGPoint
    ) -> DragDecision {
        distance(from: start, to: current) >= bodyMoveThreshold
            ? .beginBodyMove
            : .keepPressPending
    }

    public static func isPairedClick(
        previousTimestamp: TimeInterval,
        previousScreenPoint: CGPoint,
        currentTimestamp: TimeInterval,
        currentScreenPoint: CGPoint,
        interval: TimeInterval
    ) -> Bool {
        guard interval.isFinite, interval > 0 else { return false }
        let elapsed = currentTimestamp - previousTimestamp
        guard elapsed.isFinite, elapsed >= 0, elapsed <= interval else { return false }
        return distance(from: previousScreenPoint, to: currentScreenPoint) <= pairingSlop
    }

    private static func distance(from start: CGPoint, to current: CGPoint) -> CGFloat {
        hypot(current.x - start.x, current.y - start.y)
    }
}
