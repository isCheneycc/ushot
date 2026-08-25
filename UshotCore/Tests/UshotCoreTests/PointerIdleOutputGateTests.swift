#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import UshotCore

#if canImport(XCTest)
final class PointerIdleOutputGateTests: XCTestCase {
    func testZeroMaskAdmitsAndRunsOutputExactlyOnce() {
        let gate = PointerIdleOutputGate(pressedMouseButtonsProvider: { 0 })
        var outputWriteCount = 0

        let attempt = gate.performIfIdle {
            outputWriteCount += 1
            return "written"
        }

        guard case .admitted(let value) = attempt else {
            return XCTFail("A zero pressed-button mask must admit output.")
        }
        XCTAssertEqual(value, "written")
        XCTAssertEqual(outputWriteCount, 1)
    }

    func testEveryNonzeroButtonBitRejectsWithoutWritingOutput() {
        let masks = (0..<UInt.bitWidth).map { UInt(1) << $0 } + [UInt.max]

        for mask in masks {
            let gate = PointerIdleOutputGate(
                pressedMouseButtonsProvider: { mask }
            )
            var outputWriteCount = 0

            let attempt = gate.performIfIdle {
                outputWriteCount += 1
            }

            guard case .rejected(let reportedMask) = attempt else {
                XCTFail("Pressed-button mask \(mask) must reject output.")
                continue
            }
            XCTAssertEqual(reportedMask, mask)
            XCTAssertEqual(
                outputWriteCount,
                0,
                "Rejected pressed-button mask \(mask) must not run the output write."
            )
        }
    }
}
#else
@Test
func zeroMaskAdmitsAndRunsOutputExactlyOnce() {
    let gate = PointerIdleOutputGate(pressedMouseButtonsProvider: { 0 })
    var outputWriteCount = 0

    let attempt = gate.performIfIdle {
        outputWriteCount += 1
        return "written"
    }

    switch attempt {
    case .admitted(let value):
        #expect(value == "written")
    case .rejected:
        Issue.record("A zero pressed-button mask must admit output.")
    }
    #expect(outputWriteCount == 1)
}

@Test
func everyNonzeroButtonBitRejectsWithoutWritingOutput() {
    let masks = (0..<UInt.bitWidth).map { UInt(1) << $0 } + [UInt.max]

    for mask in masks {
        let gate = PointerIdleOutputGate(
            pressedMouseButtonsProvider: { mask }
        )
        var outputWriteCount = 0

        let attempt = gate.performIfIdle {
            outputWriteCount += 1
        }

        switch attempt {
        case .admitted:
            Issue.record("Pressed-button mask \(mask) must reject output.")
        case .rejected(let reportedMask):
            #expect(reportedMask == mask)
        }
        #expect(outputWriteCount == 0)
    }
}
#endif
