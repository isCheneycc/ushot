#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
import CoreGraphics
@testable import UshotCore

#if canImport(XCTest)
final class RegionConfirmationClickPolicyTests: XCTestCase {
    func testBodyMoveWaitsForThreshold() {
        let start = CGPoint(x: 100, y: 200)
        XCTAssertFalse(
            RegionConfirmationClickPolicy.didCrossBodyMoveThreshold(
                from: start,
                to: CGPoint(x: 104, y: 203)
            )
        )
        XCTAssertTrue(
            RegionConfirmationClickPolicy.didCrossBodyMoveThreshold(
                from: start,
                to: CGPoint(x: 108, y: 200)
            )
        )
    }

    func testArmedSecondClickBecomesBodyMoveAfterThreshold() {
        let secondClickDown = CGPoint(x: 300, y: 180)
        XCTAssertEqual(
            RegionConfirmationClickPolicy.dragDecision(
                from: secondClickDown,
                to: CGPoint(x: 307.9, y: 180)
            ),
            .keepPressPending,
            "Subthreshold movement must keep the double-click copy candidate armed until pointer-up."
        )
        XCTAssertEqual(
            RegionConfirmationClickPolicy.dragDecision(
                from: secondClickDown,
                to: CGPoint(x: 308, y: 180)
            ),
            .beginBodyMove,
            "Crossing the threshold on the second press must enter region movement instead of copying."
        )
    }

    func testPairingAcceptsPhysicalClickJitterInsideSlop() {
        XCTAssertTrue(
            RegionConfirmationClickPolicy.isPairedClick(
                previousTimestamp: 1.0,
                previousScreenPoint: CGPoint(x: 400, y: 300),
                currentTimestamp: 1.2,
                currentScreenPoint: CGPoint(x: 410, y: 305),
                interval: 0.5
            )
        )
    }

    func testPairingRejectsExpiredOrMovedOrInvertedClicks() {
        let origin = CGPoint(x: 400, y: 300)
        XCTAssertFalse(
            RegionConfirmationClickPolicy.isPairedClick(
                previousTimestamp: 1.0,
                previousScreenPoint: origin,
                currentTimestamp: 1.8,
                currentScreenPoint: origin,
                interval: 0.5
            )
        )
        XCTAssertFalse(
            RegionConfirmationClickPolicy.isPairedClick(
                previousTimestamp: 1.0,
                previousScreenPoint: origin,
                currentTimestamp: 1.1,
                currentScreenPoint: CGPoint(x: 430, y: 300),
                interval: 0.5
            )
        )
        XCTAssertFalse(
            RegionConfirmationClickPolicy.isPairedClick(
                previousTimestamp: 1.2,
                previousScreenPoint: origin,
                currentTimestamp: 1.0,
                currentScreenPoint: origin,
                interval: 0.5
            ),
            "A delayed mouse-down must not pair with a later mouse-up of the same click."
        )
        XCTAssertFalse(
            RegionConfirmationClickPolicy.isPairedClick(
                previousTimestamp: 1.0,
                previousScreenPoint: origin,
                currentTimestamp: 1.1,
                currentScreenPoint: origin,
                interval: 0
            )
        )
    }
}
#else
@Test
func bodyMoveWaitsForThreshold() {
    let start = CGPoint(x: 100, y: 200)
    #expect(
        !RegionConfirmationClickPolicy.didCrossBodyMoveThreshold(
            from: start,
            to: CGPoint(x: 104, y: 203)
        )
    )
    #expect(
        RegionConfirmationClickPolicy.didCrossBodyMoveThreshold(
            from: start,
            to: CGPoint(x: 108, y: 200)
        )
    )
}

@Test
func armedSecondClickBecomesBodyMoveAfterThreshold() {
    let secondClickDown = CGPoint(x: 300, y: 180)
    #expect(
        RegionConfirmationClickPolicy.dragDecision(
            from: secondClickDown,
            to: CGPoint(x: 307.9, y: 180)
        ) == .keepPressPending
    )
    #expect(
        RegionConfirmationClickPolicy.dragDecision(
            from: secondClickDown,
            to: CGPoint(x: 308, y: 180)
        ) == .beginBodyMove
    )
}

@Test
func pairingAcceptsPhysicalClickJitterInsideSlop() {
    #expect(
        RegionConfirmationClickPolicy.isPairedClick(
            previousTimestamp: 1.0,
            previousScreenPoint: CGPoint(x: 400, y: 300),
            currentTimestamp: 1.2,
            currentScreenPoint: CGPoint(x: 410, y: 305),
            interval: 0.5
        )
    )
}

@Test
func pairingRejectsExpiredOrMovedOrInvertedClicks() {
    let origin = CGPoint(x: 400, y: 300)
    #expect(
        !RegionConfirmationClickPolicy.isPairedClick(
            previousTimestamp: 1.0,
            previousScreenPoint: origin,
            currentTimestamp: 1.8,
            currentScreenPoint: origin,
            interval: 0.5
        )
    )
    #expect(
        !RegionConfirmationClickPolicy.isPairedClick(
            previousTimestamp: 1.0,
            previousScreenPoint: origin,
            currentTimestamp: 1.1,
            currentScreenPoint: CGPoint(x: 430, y: 300),
            interval: 0.5
        )
    )
    #expect(
        !RegionConfirmationClickPolicy.isPairedClick(
            previousTimestamp: 1.2,
            previousScreenPoint: origin,
            currentTimestamp: 1.0,
            currentScreenPoint: origin,
            interval: 0.5
        )
    )
    #expect(
        !RegionConfirmationClickPolicy.isPairedClick(
            previousTimestamp: 1.0,
            previousScreenPoint: origin,
            currentTimestamp: 1.1,
            currentScreenPoint: origin,
            interval: 0
        )
    )
}
#endif
