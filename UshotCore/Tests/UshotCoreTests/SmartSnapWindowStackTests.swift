#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
import CoreGraphics
import Foundation
@testable import UshotCore

// Dual-display fixture measured on a real machine: a 2048x1152 primary display
// at the Core Graphics origin and a 1728x1117 display placed below it, so the
// secondary display has negative AppKit Y coordinates.
private enum Fixture {
    static let primaryHeight: CGFloat = 1152
    static let transformer = CoordinateTransformer(primaryDisplayHeight: primaryHeight)
    static let ownPID: pid_t = 100
    static let dockPID: pid_t = 200
    static let windowServerPID: pid_t = 300
    static let activePID: pid_t = 400
    static let otherPID: pid_t = 500
    static let floatingPID: pid_t = 600
    static let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
    static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

    static let primaryDisplay = CGRect(x: 0, y: 0, width: 2048, height: 1152)
    static let secondaryDisplay = CGRect(x: 280, y: 1152, width: 1728, height: 1117)

    static func builder() -> WindowStackBuilder {
        WindowStackBuilder(
            ownProcessID: ownPID,
            dockProcessIDs: [dockPID],
            displayBounds: [primaryDisplay, secondaryDisplay]
        )
    }

    static func record(
        _ id: CGWindowID,
        pid: pid_t,
        owner: String? = nil,
        layer: Int = 0,
        alpha: Double = 1,
        cg bounds: CGRect
    ) -> WindowServerRecord {
        WindowServerRecord(
            windowID: id,
            processID: pid,
            ownerName: owner,
            layer: layer,
            alpha: alpha,
            bounds: bounds
        )
    }

    static var activeScope: SmartSnapScope {
        .resolve(frontmostProcessID: activePID, ownProcessID: ownPID, previousApplicationProcessID: nil)
    }

    static func stack(
        _ records: [WindowServerRecord],
        _ windows: [WindowDescriptor],
        primaryHeight height: CGFloat = primaryHeight
    ) -> WindowStack {
        builder().build(
            records: records,
            selectableWindows: byID(windows),
            transformer: CoordinateTransformer(primaryDisplayHeight: height)
        ).stack
    }

    static func window(
        _ id: CGWindowID,
        pid: pid_t,
        cg bounds: CGRect,
        layer: Int = 0,
        isPinnedImage: Bool = false,
        isOwnInterfaceWindow: Bool = false
    ) -> WindowDescriptor {
        WindowDescriptor(
            id: id,
            title: "Window \(id)",
            applicationName: "App \(pid)",
            frame: transformer.appKitRect(fromScreenCaptureRect: bounds),
            layer: layer,
            processID: pid,
            isPinnedImage: isPinnedImage,
            isOwnInterfaceWindow: isOwnInterfaceWindow
        )
    }

    static func byID(_ windows: [WindowDescriptor]) -> [CGWindowID: WindowDescriptor] {
        Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
    }

    /// AppKit point for a Core Graphics global point.
    static func point(cgX x: CGFloat, cgY y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: primaryHeight - y)
    }
}

private func verify(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
#if canImport(XCTest)
    XCTAssertTrue(condition, message(), file: file, line: line)
#else
    #expect(condition, Comment(rawValue: message()))
#endif
}


private struct FakeNode {
    var role: AccessibilityRead<String>
    var parent: AccessibilityRead<Int>
    var topLevel: AccessibilityRead<Int> = .absent
    var window: AccessibilityRead<Int> = .absent
    var frame: AccessibilityRead<CGRect> = .absent
}

/// A deterministic Accessibility tree that records every read it serves.
private final class FakeAccessibilityTree: AccessibilityHierarchyReading {
    typealias Element = Int
    private let nodes: [Int: FakeNode]
    private(set) var calls: [String] = []

    init(_ nodes: [Int: FakeNode]) {
        self.nodes = nodes
    }

    func role(of element: Int) -> AccessibilityRead<String> {
        calls.append("role:\(element)")
        return nodes[element]?.role ?? .unreadable(.status(AXError.failure.rawValue))
    }

    func parent(of element: Int) -> AccessibilityRead<Int> {
        calls.append("parent:\(element)")
        return nodes[element]?.parent ?? .unreadable(.status(AXError.failure.rawValue))
    }

    func topLevelElement(of element: Int) -> AccessibilityRead<Int> {
        calls.append("topLevel:\(element)")
        return nodes[element]?.topLevel ?? .unreadable(.status(AXError.failure.rawValue))
    }

    func windowElement(of element: Int) -> AccessibilityRead<Int> {
        calls.append("window:\(element)")
        return nodes[element]?.window ?? .unreadable(.status(AXError.failure.rawValue))
    }

    func frame(of element: Int) -> AccessibilityRead<CGRect> {
        calls.append("frame:\(element)")
        return nodes[element]?.frame ?? .unreadable(.status(AXError.failure.rawValue))
    }
}

/// SplitMix64, so the property test is reproducible.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upTo bound: Int) -> Int {
        Int(next() % UInt64(max(bound, 1)))
    }
}

private enum SmartSnapScenarios {
    static func dockAndMenuBarSurfacesNeverOccludeButThirdPartyFullScreenFloatsDo() {
        let appBounds = CGRect(x: 66, y: 44, width: 1894, height: 1067)
        let app = Fixture.window(1, pid: Fixture.activePID, cg: appBounds)
        let records = [
            Fixture.record(10, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                           cg: CGRect(x: 0, y: 0, width: 2048, height: 30)),
            Fixture.record(11, pid: Fixture.dockPID, layer: Fixture.dockLevel,
                           cg: CGRect(x: 0, y: 0, width: 2048, height: 1152)),
            Fixture.record(1, pid: Fixture.activePID, cg: appBounds),
        ]
        let (stack, statistics) = Fixture.builder().build(
            records: records,
            selectableWindows: Fixture.byID([app]),
            transformer: Fixture.transformer
        )
        verify(stack.entries.map(\.windowID) == [1], "Only the app window remains: \(stack.entries)")
        verify(statistics.skippedMenuBar == 1 && statistics.skippedDockSurface == 1, "\(statistics)")

        // The same display-sized geometry from a third-party process is a real
        // overlay and must block everything beneath it.
        let overlay = Fixture.record(12, pid: Fixture.floatingPID, layer: Fixture.dockLevel,
                                     cg: CGRect(x: 0, y: 0, width: 2048, height: 1152))
        let (blocked, _) = Fixture.builder().build(
            records: [overlay] + records,
            selectableWindows: Fixture.byID([app]),
            transformer: Fixture.transformer
        )
        let scope = SmartSnapScope.resolve(
            frontmostProcessID: Fixture.activePID,
            ownProcessID: Fixture.ownPID,
            previousApplicationProcessID: nil
        )
        let hit = SmartSnapWindowResolver().resolve(
            at: Fixture.point(cgX: 500, cgY: 500),
            in: blocked,
            scope: scope
        )
        verify(hit == .blocked(.occluded), "A third-party full-display float must occlude: \(hit)")
    }

    static func transparentAndDesktopLevelSurfacesAreSkipped() {
        let app = Fixture.window(1, pid: Fixture.activePID, cg: CGRect(x: 717, y: 1356, width: 946, height: 643))
        let records = [
            // An invisible same-app helper window like the one measured on WeChat.
            Fixture.record(2, pid: Fixture.activePID, layer: 8, alpha: 0,
                           cg: CGRect(x: 1049, y: 1700, width: 187, height: 51)),
            Fixture.record(1, pid: Fixture.activePID, cg: CGRect(x: 717, y: 1356, width: 946, height: 643)),
            Fixture.record(3, pid: Fixture.windowServerPID, layer: -2_147_483_626,
                           cg: CGRect(x: 280, y: 1152, width: 1728, height: 1117)),
        ]
        let (stack, statistics) = Fixture.builder().build(
            records: records,
            selectableWindows: Fixture.byID([app]),
            transformer: Fixture.transformer
        )
        verify(stack.entries.map(\.windowID) == [1], "\(stack.entries)")
        verify(statistics.skippedTransparent == 1 && statistics.skippedDesktopLevel == 1, "\(statistics)")
        let hit = SmartSnapWindowResolver().resolve(
            at: Fixture.point(cgX: 1100, cgY: 1720),
            in: stack,
            scope: .resolve(frontmostProcessID: Fixture.activePID, ownProcessID: Fixture.ownPID, previousApplicationProcessID: nil)
        )
        verify(hit == .target(app), "An alpha-zero window must not block its visible owner: \(hit)")
    }

    static func secondaryDisplayFramesUseFrozenPrimaryHeight() {
        let bounds = CGRect(x: 544, y: 1298, width: 1320, height: 868)
        let app = Fixture.window(7, pid: Fixture.activePID, cg: bounds)
        let (stack, _) = Fixture.builder().build(
            records: [Fixture.record(7, pid: Fixture.activePID, cg: bounds)],
            selectableWindows: Fixture.byID([app]),
            transformer: Fixture.transformer
        )
        let expected = CGRect(x: 544, y: 1152 - (1298 + 868), width: 1320, height: 868)
        verify(stack.entries.first?.frame == expected, "\(String(describing: stack.entries.first?.frame))")
        verify(stack.primaryDisplayHeight == Fixture.primaryHeight, "The stack retains its coordinate basis")

        // A display to the left of the primary display has negative X.
        let leftBounds = CGRect(x: -1440, y: 100, width: 800, height: 600)
        let leftWindow = Fixture.window(8, pid: Fixture.activePID, cg: leftBounds)
        let (leftStack, _) = Fixture.builder().build(
            records: [Fixture.record(8, pid: Fixture.activePID, cg: leftBounds)],
            selectableWindows: Fixture.byID([leftWindow]),
            transformer: Fixture.transformer
        )
        let hit = SmartSnapWindowResolver().resolve(
            at: Fixture.point(cgX: -1000, cgY: 300),
            in: leftStack,
            scope: .resolve(frontmostProcessID: Fixture.activePID, ownProcessID: Fixture.ownPID, previousApplicationProcessID: nil)
        )
        verify(hit == .target(leftWindow), "\(hit)")
    }

    static func activeWindowCoveredByAnotherAppNeverPassesThrough() {
        // On the secondary display another app's ordinary window and a
        // floating panel overlap the active app's window.
        let activeBounds = CGRect(x: 300, y: 1200, width: 1200, height: 800)
        let otherBounds = CGRect(x: 900, y: 1500, width: 800, height: 600)
        let floatBounds = CGRect(x: 400, y: 1250, width: 200, height: 150)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let other = Fixture.window(2, pid: Fixture.otherPID, cg: otherBounds)
        let records = [
            Fixture.record(3, pid: Fixture.floatingPID, layer: 3, cg: floatBounds),
            Fixture.record(2, pid: Fixture.otherPID, cg: otherBounds),
            Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
        ]
        let (stack, _) = Fixture.builder().build(
            records: records,
            selectableWindows: Fixture.byID([active, other]),
            transformer: Fixture.transformer
        )
        let scope = SmartSnapScope.resolve(
            frontmostProcessID: Fixture.activePID,
            ownProcessID: Fixture.ownPID,
            previousApplicationProcessID: Fixture.otherPID
        )
        let resolver = SmartSnapWindowResolver()
        let underFloat = resolver.resolve(at: Fixture.point(cgX: 450, cgY: 1300), in: stack, scope: scope)
        verify(underFloat == .blocked(.occluded), "\(underFloat)")
        let underOther = resolver.resolve(at: Fixture.point(cgX: 1000, cgY: 1600), in: stack, scope: scope)
        verify(underOther == .blocked(.outOfScope), "\(underOther)")
        let exposed = resolver.resolve(at: Fixture.point(cgX: 350, cgY: 1900), in: stack, scope: scope)
        verify(exposed == .target(active), "\(exposed)")
        let outside = resolver.resolve(at: Fixture.point(cgX: 1900, cgY: 2200), in: stack, scope: scope)
        verify(outside == .desktop, "\(outside)")
    }

    static func activeApplicationFloatingWindowsOccludeInsteadOfSnapping() {
        let mainBounds = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let paletteBounds = CGRect(x: 200, y: 200, width: 300, height: 300)
        let main = Fixture.window(1, pid: Fixture.activePID, cg: mainBounds)
        // ScreenCaptureKit discovery admits only layer zero, but a
        // conflicting descriptor must still not make an elevated record a target.
        let palette = Fixture.window(2, pid: Fixture.activePID, cg: paletteBounds)
        let (stack, _) = Fixture.builder().build(
            records: [
                Fixture.record(2, pid: Fixture.activePID, layer: 3, cg: paletteBounds),
                Fixture.record(1, pid: Fixture.activePID, cg: mainBounds),
            ],
            selectableWindows: Fixture.byID([main, palette]),
            transformer: Fixture.transformer
        )
        verify(stack.entries.first?.kind == .occluder, "\(stack.entries)")
        let hit = SmartSnapWindowResolver().resolve(
            at: Fixture.point(cgX: 250, cgY: 250),
            in: stack,
            scope: .resolve(frontmostProcessID: Fixture.activePID, ownProcessID: Fixture.ownPID, previousApplicationProcessID: nil)
        )
        verify(hit == .blocked(.occluded), "\(hit)")
        verify(
            stack.siblingFrames(of: main) == [Fixture.transformer.appKitRect(fromScreenCaptureRect: paletteBounds)],
            "Same-process surfaces are exposed for AX ambiguity checks"
        )
    }

    static func ownWindowsRequireExplicitAdmission() {
        let pinnedBounds = CGRect(x: 400, y: 400, width: 20, height: 16)
        let settingsBounds = CGRect(x: 300, y: 300, width: 860, height: 580)
        let appBounds = CGRect(x: 0, y: 30, width: 1600, height: 1000)
        let pinned = Fixture.window(20, pid: Fixture.ownPID, cg: pinnedBounds, layer: 3, isPinnedImage: true)
        let settings = Fixture.window(21, pid: Fixture.ownPID, cg: settingsBounds, isOwnInterfaceWindow: true)
        let app = Fixture.window(1, pid: Fixture.otherPID, cg: appBounds)
        let records = [
            Fixture.record(22, pid: Fixture.ownPID, layer: 3, cg: CGRect(x: 0, y: 0, width: 2048, height: 1152)),
            Fixture.record(20, pid: Fixture.ownPID, layer: 3, cg: pinnedBounds),
            Fixture.record(21, pid: Fixture.ownPID, cg: settingsBounds),
            Fixture.record(1, pid: Fixture.otherPID, cg: appBounds),
        ]
        let (stack, statistics) = Fixture.builder().build(
            records: records,
            selectableWindows: Fixture.byID([pinned, settings, app]),
            transformer: Fixture.transformer
        )
        verify(stack.entries.map(\.windowID) == [20, 21, 1], "Unadmitted Ushot surfaces are not in the frozen pixels: \(stack.entries)")
        verify(statistics.skippedOwnApplication == 1, "\(statistics)")

        let resolver = SmartSnapWindowResolver()
        let otherFrontmost = SmartSnapScope.resolve(
            frontmostProcessID: Fixture.otherPID,
            ownProcessID: Fixture.ownPID,
            previousApplicationProcessID: nil
        )
        verify(resolver.resolve(at: Fixture.point(cgX: 405, cgY: 405), in: stack, scope: otherFrontmost) == .target(pinned),
               "Pinned images are always in scope")
        verify(resolver.resolve(at: Fixture.point(cgX: 350, cgY: 350), in: stack, scope: otherFrontmost) == .blocked(.outOfScope),
               "A background Settings window blocks but is not a target")
        verify(resolver.resolve(at: Fixture.point(cgX: 1500, cgY: 900), in: stack, scope: otherFrontmost) == .target(app),
               "The frontmost app remains snappable")

        let ushotFrontmost = SmartSnapScope.resolve(
            frontmostProcessID: Fixture.ownPID,
            ownProcessID: Fixture.ownPID,
            previousApplicationProcessID: Fixture.otherPID
        )
        verify(resolver.resolve(at: Fixture.point(cgX: 350, cgY: 350), in: stack, scope: ushotFrontmost) == .target(settings),
               "Settings is snappable while Ushot is frontmost")
        verify(resolver.resolve(at: Fixture.point(cgX: 1500, cgY: 900), in: stack, scope: ushotFrontmost) == .target(app),
               "The previous app stays in scope after Pin activates Ushot")
    }

    static func windowServerOrderIsTheOnlyOrderingAuthority() {
        let aBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let bBounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let conflictBounds = CGRect(x: 1000, y: 100, width: 400, height: 400)
        let a = Fixture.window(1, pid: Fixture.activePID, cg: aBounds)
        let b = Fixture.window(2, pid: Fixture.activePID, cg: bBounds)
        let scOnly = Fixture.window(3, pid: Fixture.activePID, cg: CGRect(x: 1500, y: 500, width: 300, height: 300))
        let moved = Fixture.window(4, pid: Fixture.activePID, cg: conflictBounds)
        let (stack, statistics) = Fixture.builder().build(
            records: [
                Fixture.record(2, pid: Fixture.activePID, cg: bBounds),
                Fixture.record(9, pid: Fixture.otherPID, cg: CGRect(x: 700, y: 500, width: 100, height: 100)),
                Fixture.record(4, pid: Fixture.activePID, cg: conflictBounds.offsetBy(dx: 40, dy: 0)),
                Fixture.record(1, pid: Fixture.activePID, cg: aBounds),
            ],
            // Dictionary order is irrelevant; Core Graphics decides.
            selectableWindows: Fixture.byID([a, scOnly, moved, b]),
            transformer: Fixture.transformer
        )
        verify(stack.entries.map(\.windowID) == [2, 9, 4, 1, 3], "\(stack.entries.map(\.windowID))")
        verify(stack.entries.last?.kind == .occluder, "A target without any Window Server record sinks to the bottom as an occluder")
        verify(stack.selectableWindows == [b, a], "\(stack.selectableWindows.map(\.id))")
        verify(stack.entries[1].kind == .occluder, "A window absent from ScreenCaptureKit still occludes")
        verify(stack.entries[2].kind == .occluder, "Conflicting geometry becomes an occluder")
        verify(statistics.selectableMissingFromWindowServer == 2 && statistics.geometryConflicts == 1, "\(statistics)")

        let scope = SmartSnapScope.resolve(
            frontmostProcessID: Fixture.activePID,
            ownProcessID: Fixture.ownPID,
            previousApplicationProcessID: nil
        )
        let overlap = SmartSnapWindowResolver().resolve(at: Fixture.point(cgX: 400, cgY: 400), in: stack, scope: scope)
        verify(overlap == .target(b), "\(overlap)")
        let unordered = SmartSnapWindowResolver().resolve(at: Fixture.point(cgX: 1600, cgY: 600), in: stack, scope: scope)
        verify(unordered == .blocked(.occluded), "A window without a z position is never a candidate nor exposed desktop: \(unordered)")
    }

    static func scopeResolution() {
        let own = Fixture.ownPID
        let other = SmartSnapScope.resolve(frontmostProcessID: 7, ownProcessID: own, previousApplicationProcessID: 9)
        verify(other.applicationProcessIDs == [7] && !other.includesOwnInterfaceWindows && other.origin == .frontmostApplication, "\(other)")
        let afterPin = SmartSnapScope.resolve(frontmostProcessID: own, ownProcessID: own, previousApplicationProcessID: 9)
        verify(afterPin.applicationProcessIDs == [9] && afterPin.includesOwnInterfaceWindows && afterPin.origin == .ushotWithPreviousApplication, "\(afterPin)")
        let ushotOnly = SmartSnapScope.resolve(frontmostProcessID: own, ownProcessID: own, previousApplicationProcessID: nil)
        verify(ushotOnly.applicationProcessIDs.isEmpty && ushotOnly.includesOwnInterfaceWindows && ushotOnly.origin == .ushotOnly, "\(ushotOnly)")
        let selfPrevious = SmartSnapScope.resolve(frontmostProcessID: own, ownProcessID: own, previousApplicationProcessID: own)
        verify(selfPrevious.origin == .ushotOnly, "\(selfPrevious)")
        let unknown = SmartSnapScope.resolve(frontmostProcessID: nil, ownProcessID: own, previousApplicationProcessID: 9)
        verify(unknown == .pinnedImagesOnly, "\(unknown)")

        let elevated = Fixture.window(5, pid: 7, cg: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 3)
        verify(!other.admits(elevated), "Only layer-zero windows of the scoped app are targets")
        let pinned = Fixture.window(6, pid: own, cg: CGRect(x: 0, y: 0, width: 10, height: 10), layer: 3, isPinnedImage: true)
        verify(SmartSnapScope.pinnedImagesOnly.admits(pinned), "Pinned images are always admitted")
    }

    static func accessibilityOwnershipIsGeometricAndFailsClosed() {
        let ownership = AccessibilityWindowOwnership()
        let target = CGRect(x: 100, y: -500, width: 800, height: 600)
        verify(ownership.isVerified(containerFrame: target.offsetBy(dx: 1.5, dy: -1), target: target, siblingFrames: []),
               "Small AX/Window Server rounding differences are tolerated")
        verify(!ownership.isVerified(containerFrame: CGRect(x: 150, y: -450, width: 187, height: 51), target: target, siblingFrames: []),
               "An element owned by a different same-process window is rejected")
        verify(!ownership.isVerified(containerFrame: target, target: target, siblingFrames: [target.offsetBy(dx: 1, dy: 0)]),
               "Two indistinguishable same-process windows refuse control refinement")
        verify(ownership.isVerified(containerFrame: target, target: target, siblingFrames: [CGRect(x: 0, y: 0, width: 50, height: 50)]),
               "Unrelated siblings do not prevent verification")
        let base = CGRect(x: 100, y: 100, width: 800, height: 600)
        let sibling = CGRect(x: 103, y: 100, width: 800, height: 600)
        let between = CGRect(x: 101.5, y: 100, width: 800, height: 600)
        verify(!ownership.matches(sibling, base), "The fixture sibling is distinguishable from the target")
        verify(!ownership.isVerified(containerFrame: between, target: base, siblingFrames: [sibling]),
               "A container that also fits a sibling is ambiguous")
    }

    static func accessibilityNeverQueriesUshot() {
        let resolver = InterfaceElementSelectionResolver(ownProcessID: Fixture.ownPID)
        let settings = Fixture.window(21, pid: Fixture.ownPID, cg: CGRect(x: 0, y: 0, width: 800, height: 600), isOwnInterfaceWindow: true)
        verify(resolver.resolve(at: CGPoint(x: 10, y: 1000), in: settings, primaryDisplayHeight: 1152) == .noElement,
               "Settings is a window-level target only")
        let disguised = Fixture.window(22, pid: Fixture.ownPID, cg: CGRect(x: 0, y: 0, width: 800, height: 600))
        verify(resolver.resolve(at: CGPoint(x: 10, y: 1000), in: disguised, primaryDisplayHeight: 1152) == .noElement,
               "Any window owned by Ushot's process is never AX-queried")
    }

    static func windowServerRecordsParseInOrder() {
        let list: [[String: Any]] = [
            [
                kCGWindowNumber as String: NSNumber(value: 5),
                kCGWindowOwnerPID as String: NSNumber(value: 42),
                kCGWindowOwnerName as String: "Window Server",
                kCGWindowLayer as String: NSNumber(value: 8),
                kCGWindowAlpha as String: NSNumber(value: 0.0),
                kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation,
            ],
            [
                kCGWindowNumber as String: NSNumber(value: 7),
                kCGWindowOwnerPID as String: NSNumber(value: 43),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowBounds as String: CGRect(x: -10, y: 1200, width: 30, height: 40).dictionaryRepresentation,
            ],
        ]
        guard let parsed = WindowServerRecord.records(fromWindowList: list) else {
            verify(false, "Complete records must parse")
            return
        }
        verify(parsed.incompleteCount == 0, "\(parsed.incompleteCount)")
        verify(parsed.records.map(\.windowID) == [5, 7], "\(parsed.records)")
        verify(parsed.records.first?.alpha == 0 && parsed.records.first?.layer == 8, "\(parsed.records)")
        verify(parsed.records.first?.ownerName == "Window Server", "\(parsed.records)")
        verify(parsed.records.last?.alpha == 1, "A missing alpha means an opaque window")
        verify(parsed.records.last?.bounds == CGRect(x: -10, y: 1200, width: 30, height: 40), "\(parsed.records)")
    }

    static func incompleteRecordsFailClosed() {
        let floatBounds = CGRect(x: 400, y: 1250, width: 200, height: 150)
        let activeBounds = CGRect(x: 300, y: 1200, width: 1200, height: 800)
        let list: [[String: Any]] = [
            // Bounds are readable but owner and layer are missing.
            [
                kCGWindowNumber as String: NSNumber(value: 3),
                kCGWindowBounds as String: floatBounds.dictionaryRepresentation,
            ],
            [
                kCGWindowNumber as String: NSNumber(value: 1),
                kCGWindowOwnerPID as String: NSNumber(value: Fixture.activePID),
                kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowBounds as String: activeBounds.dictionaryRepresentation,
            ],
        ]
        guard let parsed = WindowServerRecord.records(fromWindowList: list) else {
            verify(false, "Records with readable bounds must parse")
            return
        }
        verify(parsed.incompleteCount == 1 && parsed.records.count == 2, "\(parsed)")
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let (stack, statistics) = Fixture.builder().build(
            records: parsed.records,
            selectableWindows: Fixture.byID([active]),
            transformer: Fixture.transformer
        )
        verify(statistics.incompleteOccluders == 1, "\(statistics)")
        let resolver = SmartSnapWindowResolver()
        verify(resolver.resolve(at: Fixture.point(cgX: 450, cgY: 1300), in: stack, scope: Fixture.activeScope) == .blocked(.occluded),
               "An incomplete front record still blocks the window beneath it")
        verify(resolver.resolve(at: Fixture.point(cgX: 1400, cgY: 1900), in: stack, scope: Fixture.activeScope) == .target(active),
               "Exposed parts stay snappable")

        // A record whose covered area is unknown makes the whole stack untrustworthy.
        let unbounded: [[String: Any]] = [
            [kCGWindowNumber as String: NSNumber(value: 9), kCGWindowLayer as String: NSNumber(value: 3)],
        ] + list
        verify(WindowServerRecord.records(fromWindowList: unbounded) == nil,
               "A record without readable bounds disables the stack")
        let reconciled = WindowStackStability.reconcile(before: nil, after: stack, primaryDisplayHeight: Fixture.primaryHeight)
        verify(reconciled.outcome == .unavailable && reconciled.stack.entries.isEmpty
                   && reconciled.stack.availability == .unavailable, "\(reconciled)")
        verify(resolver.resolve(at: Fixture.point(cgX: 1400, cgY: 1900), in: reconciled.stack, scope: Fixture.activeScope) == .blocked(.unavailable),
               "An unavailable stack never offers a candidate, not even exposed desktop")
    }

    static func onlyTheSystemMenuBarIsTransparentAtMainMenuLevel() {
        let activeBounds = CGRect(x: 280, y: 1152, width: 1728, height: 1117)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let systemBars = [
            Fixture.record(18311, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                           cg: CGRect(x: 280, y: 1152, width: 1728, height: 33)),
            Fixture.record(18303, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                           cg: CGRect(x: 0, y: 0, width: 2048, height: 30)),
        ]
        let (clear, statistics) = Fixture.builder().build(
            records: systemBars + [Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)],
            selectableWindows: Fixture.byID([active]),
            transformer: Fixture.transformer
        )
        verify(statistics.skippedMenuBar == 2, "Both displays' system menu bars are skipped: \(statistics)")
        let resolver = SmartSnapWindowResolver()
        verify(resolver.resolve(at: Fixture.point(cgX: 500, cgY: 1160), in: clear, scope: Fixture.activeScope) == .target(active),
               "The secondary display's system menu bar does not hide the window")

        let thirdParty = Fixture.record(40, pid: Fixture.floatingPID, owner: "Overlay Tool", layer: Fixture.menuLevel,
                                        cg: Fixture.secondaryDisplay)
        let impostor = Fixture.record(41, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                                      cg: CGRect(x: 600, y: 1600, width: 300, height: 30))
        let blocked = Fixture.stack([impostor, thirdParty] + systemBars + [Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)], [active])
        verify(resolver.resolve(at: Fixture.point(cgX: 1000, cgY: 2000), in: blocked, scope: Fixture.activeScope) == .blocked(.occluded),
               "A third-party main-menu-level panel occludes")
        verify(blocked.entries.first?.windowID == 41 && blocked.entries.first?.kind == .occluder,
               "A main-menu-level strip that is not at a display top occludes")
    }

    static func freezeStabilityRestrictsSnappingWhereSnapshotsDisagree() {
        let activeBounds = CGRect(x: 300, y: 1200, width: 1200, height: 800)
        let otherBounds = CGRect(x: 1000, y: 1300, width: 600, height: 500)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let other = Fixture.window(2, pid: Fixture.otherPID, cg: otherBounds)
        let base = [
            Fixture.record(2, pid: Fixture.otherPID, cg: otherBounds),
            Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
        ]
        let before = Fixture.stack(base, [active, other])
        let resolver = SmartSnapWindowResolver()

        let unchanged = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack(base, [active, other]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(unchanged.outcome == .stable && unchanged.stack == before, "\(unchanged.outcome)")

        // A notification banner appears on the secondary display mid-freeze.
        let bannerBounds = CGRect(x: 350, y: 1250, width: 300, height: 80)
        let banner = Fixture.record(50, pid: Fixture.floatingPID, layer: 23, cg: bannerBounds)
        let inserted = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack([banner] + base, [active, other]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(inserted.outcome == .partiallyUnstable, "\(inserted.outcome)")
        verify(resolver.resolve(at: Fixture.point(cgX: 400, cgY: 1270), in: inserted.stack, scope: Fixture.activeScope) == .blocked(.unstable),
               "The banner area never passes through to the window beneath")
        verify(resolver.resolve(at: Fixture.point(cgX: 350, cgY: 1900), in: inserted.stack, scope: Fixture.activeScope) == .target(active),
               "Unaffected areas still snap")

        // The two windows swap order: only their overlap is affected.
        let flipped = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack(base.reversed(), [active, other]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(flipped.outcome == .partiallyUnstable, "\(flipped.outcome)")
        verify(resolver.resolve(at: Fixture.point(cgX: 1100, cgY: 1400), in: flipped.stack, scope: Fixture.activeScope) == .blocked(.unstable),
               "The overlap of a swapped pair is refused")
        verify(resolver.resolve(at: Fixture.point(cgX: 350, cgY: 1900), in: flipped.stack, scope: Fixture.activeScope) == .target(active),
               "Outside the overlap the active window still snaps")

        // The primary display changed between snapshots.
        let invalidated = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack(base, [active, other], primaryHeight: 1117),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(invalidated.outcome == .invalidated && invalidated.stack.entries.isEmpty, "\(invalidated.outcome)")
        let unreadable = WindowStackStability.reconcile(before: before, after: nil, primaryDisplayHeight: Fixture.primaryHeight)
        verify(unreadable.outcome == .unavailable && unreadable.stack.entries.isEmpty, "\(unreadable.outcome)")
    }

    /// A panel that moved between the two reads may be frozen anywhere along
    /// its path, so the whole transition envelope is refused.
    static func movingSurfacesBlockTheirWholeTransitionEnvelope() {
        // The active window spans both displays.
        let activeBounds = CGRect(x: 0, y: 40, width: 2000, height: 2200)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let resolver = SmartSnapWindowResolver()
        func reconcile(from: CGRect, to: CGRect) -> WindowStack {
            let before = Fixture.stack([
                Fixture.record(60, pid: Fixture.floatingPID, layer: 3, cg: from),
                Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
            ], [active])
            let after = Fixture.stack([
                Fixture.record(60, pid: Fixture.floatingPID, layer: 3, cg: to),
                Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
            ], [active])
            let result = WindowStackStability.reconcile(before: before, after: after, primaryDisplayHeight: Fixture.primaryHeight)
            verify(result.outcome == .partiallyUnstable, "\(result.outcome)")
            return result.stack
        }
        func hit(_ stack: WindowStack, cgX x: CGFloat, cgY y: CGFloat) -> SmartSnapWindowHit {
            resolver.resolve(at: Fixture.point(cgX: x, cgY: y), in: stack, scope: Fixture.activeScope)
        }

        let horizontal = reconcile(from: CGRect(x: 100, y: 300, width: 100, height: 100),
                                   to: CGRect(x: 500, y: 300, width: 100, height: 100))
        verify(hit(horizontal, cgX: 300, cgY: 350) == .blocked(.unstable), "Mid-path of a horizontal move")
        verify(hit(horizontal, cgX: 1500, cgY: 1000) == .target(active), "Far from the path the window still snaps")

        let diagonal = reconcile(from: CGRect(x: 100, y: 200, width: 100, height: 100),
                                 to: CGRect(x: 500, y: 600, width: 100, height: 100))
        verify(hit(diagonal, cgX: 350, cgY: 450) == .blocked(.unstable), "Mid-path of a diagonal move")

        let scaled = reconcile(from: CGRect(x: 100, y: 200, width: 100, height: 100),
                               to: CGRect(x: 100, y: 200, width: 500, height: 400))
        verify(hit(scaled, cgX: 400, cgY: 500) == .blocked(.unstable), "Inside a growing panel's envelope")

        let crossDisplay = reconcile(from: CGRect(x: 100, y: 1000, width: 100, height: 100),
                                     to: CGRect(x: 700, y: 1500, width: 100, height: 100))
        verify(hit(crossDisplay, cgX: 400, cgY: 1250) == .blocked(.unstable), "Across the display seam")
        verify(hit(crossDisplay, cgX: 1900, cgY: 200) == .target(active), "Unrelated parts of the active window still snap")
    }

    static func unknownSurfacesInvalidateOnlyWhenUnpaired() {
        let activeBounds = CGRect(x: 0, y: 40, width: 1600, height: 1000)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        func unknown(_ bounds: CGRect) -> WindowServerRecord {
            WindowServerRecord(windowID: nil, processID: nil, layer: nil, bounds: bounds)
        }
        let unknownBounds = CGRect(x: 100, y: 100, width: 200, height: 200)
        let before = Fixture.stack([unknown(unknownBounds), Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)], [active])

        let moved = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack([unknown(unknownBounds.offsetBy(dx: 300, dy: 0)), Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)], [active]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(moved.outcome == .invalidated && moved.stack.entries.isEmpty, "A moved unknown surface cannot be bounded: \(moved.outcome)")
        verify(moved.result?.invalidationReason == .unpairedUnknownSurface, "\(String(describing: moved.result))")

        let banner = Fixture.record(50, pid: Fixture.floatingPID, layer: 23, cg: CGRect(x: 900, y: 100, width: 300, height: 80))
        let bannerAppeared = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack([banner, unknown(unknownBounds), Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)], [active]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(bannerAppeared.outcome == .partiallyUnstable, "\(bannerAppeared.outcome)")
        verify(bannerAppeared.result?.changes == WindowStackStability.ChangeCounts(appeared: 1), "\(String(describing: bannerAppeared.result))")
        let resolver = SmartSnapWindowResolver()
        verify(resolver.resolve(at: Fixture.point(cgX: 1000, cgY: 120), in: bannerAppeared.stack, scope: Fixture.activeScope) == .blocked(.unstable), "Banner area")
        verify(resolver.resolve(at: Fixture.point(cgX: 150, cgY: 150), in: bannerAppeared.stack, scope: Fixture.activeScope) == .blocked(.occluded), "Stationary unknown surface still occludes")
        verify(resolver.resolve(at: Fixture.point(cgX: 1400, cgY: 900), in: bannerAppeared.stack, scope: Fixture.activeScope) == .target(active), "Exposed area")
    }

    static func reorderDuringMoveBlocksTheNewOverlap() {
        let activeBounds = CGRect(x: 0, y: 40, width: 1200, height: 900)
        let otherBounds = CGRect(x: 1400, y: 100, width: 500, height: 400)
        let movedBounds = CGRect(x: 800, y: 300, width: 500, height: 400)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let before = Fixture.stack([
            Fixture.record(2, pid: Fixture.otherPID, cg: otherBounds),
            Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
        ], [active, Fixture.window(2, pid: Fixture.otherPID, cg: otherBounds)])
        let after = Fixture.stack([
            Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
            Fixture.record(2, pid: Fixture.otherPID, cg: movedBounds),
        ], [active, Fixture.window(2, pid: Fixture.otherPID, cg: movedBounds)])
        let result = WindowStackStability.reconcile(before: before, after: after, primaryDisplayHeight: Fixture.primaryHeight)
        verify(result.outcome == .partiallyUnstable, "\(result.outcome)")
        let hit = SmartSnapWindowResolver().resolve(at: Fixture.point(cgX: 1000, cgY: 500), in: result.stack, scope: Fixture.activeScope)
        verify(hit == .blocked(.unstable), "The new overlap of a reordered, moved pair is refused: \(hit)")
    }

    static func duplicateIdentitiesAndIdenticalSnapshots() {
        let activeBounds = CGRect(x: 0, y: 40, width: 1200, height: 900)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let panel = Fixture.record(9, pid: Fixture.floatingPID, layer: 3, cg: CGRect(x: 100, y: 100, width: 100, height: 100))
        let before = Fixture.stack([panel, Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)], [active])
        let duplicate = Fixture.record(9, pid: Fixture.floatingPID, layer: 3, cg: CGRect(x: 600, y: 600, width: 100, height: 100))
        let duplicated = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack([panel, duplicate, Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)], [active]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(duplicated.outcome == .invalidated && duplicated.stack.entries.isEmpty, "\(duplicated.outcome)")
        verify(duplicated.result?.invalidationReason == .duplicateIdentity, "\(String(describing: duplicated.result))")

        // Identical snapshots are stable by definition. A surface that appeared
        // and vanished entirely between the two reads is not observable.
        let identical = WindowStackStability.reconcile(
            before: before,
            after: Fixture.stack([panel, Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)], [active]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(identical.outcome == .stable && identical.stack == before, "\(identical.outcome)")
    }

    /// Seeded property: outside every unstable region of a non-invalidated
    /// session, both snapshots expose the same topmost surface.
    static func stabilityPropertyHoldsForRandomSnapshots() {
        var generator = SeededGenerator(seed: 0x5EED_2026_1126)
        var checkedPoints = 0
        var invalidatedCases = 0
        var violations: [String] = []
        func randomFrame() -> CGRect {
            CGRect(
                x: CGFloat(generator.next(upTo: 40)) * 10,
                y: CGFloat(generator.next(upTo: 40)) * 10,
                width: CGFloat(generator.next(upTo: 20) + 1) * 10,
                height: CGFloat(generator.next(upTo: 20) + 1) * 10
            )
        }
        func entry(_ id: CGWindowID, _ frame: CGRect, pid: pid_t) -> WindowStackEntry {
            WindowStackEntry(windowID: id, frame: frame, processID: pid, kind: .occluder)
        }
        for _ in 0..<3_000 {
            var nextID: CGWindowID = 1
            var beforeEntries: [WindowStackEntry] = []
            for _ in 0..<(generator.next(upTo: 7) + 1) {
                let unknown = generator.next(upTo: 10) == 0
                beforeEntries.append(entry(unknown ? kCGNullWindowID : nextID, randomFrame(), pid: 1))
                nextID += 1
            }
            var afterEntries: [WindowStackEntry] = []
            for original in beforeEntries {
                switch generator.next(upTo: 20) {
                case 0..<11: afterEntries.append(original)
                case 11..<15:
                    afterEntries.append(entry(original.windowID, randomFrame(), pid: 1))
                case 15..<17: break // disappeared
                case 17: afterEntries.append(entry(original.windowID, original.frame, pid: 2))
                default:
                    afterEntries.append(original)
                    if afterEntries.count > 1 { afterEntries.swapAt(afterEntries.count - 1, afterEntries.count - 2) }
                }
            }
            for _ in 0..<generator.next(upTo: 3) {
                let index = generator.next(upTo: afterEntries.count + 1)
                afterEntries.insert(entry(nextID, randomFrame(), pid: 1), at: index)
                nextID += 1
            }
            let before = WindowStack(entries: beforeEntries, primaryDisplayHeight: 1000)
            let after = WindowStack(entries: afterEntries, primaryDisplayHeight: 1000)
            let result = WindowStackStability.compare(before: before, after: after)
            if result.invalidatesSession {
                invalidatedCases += 1
                continue
            }
            for _ in 0..<40 {
                let point = CGPoint(x: CGFloat(generator.next(upTo: 6_000)) / 10, y: CGFloat(generator.next(upTo: 6_000)) / 10)
                guard !result.unstableRegions.contains(where: { $0.contains(point) }) else { continue }
                checkedPoints += 1
                let topBefore = before.entries.first { $0.frame.contains(point) }
                let topAfter = after.entries.first { $0.frame.contains(point) }
                if topBefore != topAfter, violations.count < 5 {
                    violations.append("point=\(point) before=\(String(describing: topBefore)) after=\(String(describing: topAfter))")
                }
            }
        }
        verify(violations.isEmpty, "Stable points disagreed: \(violations)")
        verify(checkedPoints > 10_000 && invalidatedCases > 0, "checked=\(checkedPoints), invalidated=\(invalidatedCases)")
    }

    static func accessibilityReadClassification() {
        verify(AccessibilityRead(status: .success, decoded: "AXButton") == .value("AXButton"), "success with value")
        verify(AccessibilityRead<String>(status: .success, decoded: nil) == .unreadable(.undecodableValue), "success without a decodable value")
        verify(AccessibilityRead(status: .noValue, decoded: "ignored") == .absent, "noValue")
        verify(AccessibilityRead<String>(status: .attributeUnsupported, decoded: nil) == .absent, "attributeUnsupported")
        // The SDK has no dedicated messaging-timeout code; timeouts surface as
        // cannotComplete.
        for status in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure,
                       .illegalArgument, .notImplemented, .invalidUIElementObserver,
                       .actionUnsupported, .parameterizedAttributeUnsupported, .notEnoughPrecision] {
            verify(AccessibilityRead<String>(status: status, decoded: "x") == .unreadable(.status(status.rawValue)),
                   "\(status.rawValue) is unreadable and keeps its raw code")
        }
        if let unknown = AXError(rawValue: -1) {
            verify(AccessibilityRead<String>(status: unknown, decoded: "x") == .unreadable(.status(-1)), "Unknown codes are unreadable")
        } else {
            verify(false, "AXError must represent unknown raw values")
        }
    }

    static func accessibilityProofReadsLazilyAndFailsClosed() {
        let ownership = AccessibilityWindowOwnership()
        let host = CGRect(x: 100, y: 100, width: 800, height: 600)
        let detached = CGRect(x: 250, y: 300, width: 400, height: 250)
        func rejected(_ result: AccessibilityOwnershipVerification<Int>) -> AccessibilityOwnershipRejection? {
            if case .rejected(let failure) = result { return failure.rejection }
            return nil
        }
        func path(_ result: AccessibilityOwnershipVerification<Int>) -> [Int]? {
            if case .verified(let path) = result { return path }
            return nil
        }
        let window = FakeNode(role: .value("AXWindow"), parent: .value(99), frame: .value(host))
        let application = FakeNode(role: .value("AXApplication"), parent: .absent)

        // A sheet whose role cannot be read must not verify through its host.
        let unreadableSheet = FakeAccessibilityTree([
            1: FakeNode(role: .value("AXButton"), parent: .value(2), topLevel: .value(3), window: .value(3)),
            2: FakeNode(role: .unreadable(.status(AXError.cannotComplete.rawValue)), parent: .value(3), frame: .value(detached)),
            3: window, 99: application,
        ])
        verify(rejected(ownership.verify(hit: 1, reader: unreadableSheet, target: host, siblingFrames: [])) == .roleUnreadable, "unreadable sheet role")
        verify(!unreadableSheet.calls.contains { $0.hasPrefix("topLevel") || $0.hasPrefix("window") }, "\(unreadableSheet.calls)")

        // A popover is its own container; its host frame is irrelevant.
        let popover = FakeAccessibilityTree([
            1: FakeNode(role: .value("AXButton"), parent: .value(2), window: .value(3)),
            2: FakeNode(role: .value("AXPopover"), parent: .value(3), frame: .value(detached)),
            3: window, 99: application,
        ])
        verify(rejected(ownership.verify(hit: 1, reader: popover, target: host, siblingFrames: [])) == .frameMismatchOrAmbiguous, "popover")

        let brokenParent = FakeAccessibilityTree([
            1: FakeNode(role: .value("AXButton"), parent: .value(2)),
            2: FakeNode(role: .value("AXGroup"), parent: .unreadable(.status(AXError.cannotComplete.rawValue))),
        ])
        verify(rejected(ownership.verify(hit: 1, reader: brokenParent, target: host, siblingFrames: [])) == .parentUnreadable, "parent unreadable")

        func chain(length: Int) -> FakeAccessibilityTree {
            var nodes: [Int: FakeNode] = [:]
            for index in 1..<length {
                nodes[index] = FakeNode(role: .value("AXGroup"), parent: .value(index + 1), frame: .value(host))
            }
            nodes[length] = FakeNode(role: .value("AXWindow"), parent: .value(10_000), frame: .value(host))
            nodes[10_000] = application
            return FakeAccessibilityTree(nodes)
        }
        verify(rejected(ownership.verify(hit: 1, reader: chain(length: 130), target: host, siblingFrames: [])) == .proofDepthExceeded, "deeper than 128")
        let deep = ownership.verify(hit: 1, reader: chain(length: 40), target: host, siblingFrames: [])
        verify(path(deep) == Array(1...12), "A 40-level web tree verifies and returns 12 levels: \(String(describing: path(deep)))")

        // The chain ends without a container: top-level, then AXWindow.
        func ended(topLevel: AccessibilityRead<Int>, window: AccessibilityRead<Int>) -> FakeAccessibilityTree {
            FakeAccessibilityTree([
                1: FakeNode(role: .value("AXButton"), parent: .value(2), topLevel: topLevel, window: window),
                2: FakeNode(role: .value("AXApplication"), parent: .absent),
                5: FakeNode(role: .value("AXSheet"), parent: .absent, frame: .value(detached)),
                6: FakeNode(role: .value("AXWindow"), parent: .absent, frame: .value(host)),
            ])
        }
        let mismatchedTop = ended(topLevel: .value(5), window: .value(6))
        verify(rejected(ownership.verify(hit: 1, reader: mismatchedTop, target: host, siblingFrames: [])) == .frameMismatchOrAmbiguous, "top-level sheet mismatch")
        verify(!mismatchedTop.calls.contains("window:1"), "AXWindow must not be read after a top-level answer")
        let windowOnly = ended(topLevel: .absent, window: .value(6))
        verify(path(ownership.verify(hit: 1, reader: windowOnly, target: host, siblingFrames: [])) == [1, 2], "AXWindow fallback")
        verify(windowOnly.calls.contains("window:1"), "\(windowOnly.calls)")
        let unreadableTop = ended(topLevel: .unreadable(.status(AXError.cannotComplete.rawValue)), window: .value(6))
        verify(rejected(ownership.verify(hit: 1, reader: unreadableTop, target: host, siblingFrames: [])) == .topLevelUnreadable, "unreadable top-level")
        verify(!unreadableTop.calls.contains("window:1"), "\(unreadableTop.calls)")
        verify(rejected(ownership.verify(hit: 1, reader: ended(topLevel: .absent, window: .absent), target: host, siblingFrames: [])) == .windowUnavailable, "no evidence")

        // A verified nearest container never consults the top-level element.
        let direct = FakeAccessibilityTree([
            1: FakeNode(role: .value("AXButton"), parent: .value(3), topLevel: .unreadable(.status(AXError.cannotComplete.rawValue))),
            3: window, 99: application,
        ])
        verify(path(ownership.verify(hit: 1, reader: direct, target: host, siblingFrames: [])) == [1, 3], "direct container")
        verify(!direct.calls.contains { $0.hasPrefix("topLevel") }, "\(direct.calls)")

        let unreadableFrame = FakeAccessibilityTree([
            1: FakeNode(role: .value("AXWindow"), parent: .absent, frame: .unreadable(.status(AXError.cannotComplete.rawValue))),
        ])
        verify(rejected(ownership.verify(hit: 1, reader: unreadableFrame, target: host, siblingFrames: [])) == .containerFrameUnreadable, "frame unreadable")
    }

    static func alphaAndBoundsParsingFailClosed() {
        let activeBounds = CGRect(x: 0, y: 40, width: 1600, height: 1000)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let panelBounds = CGRect(x: 100, y: 100, width: 200, height: 200)
        let resolver = SmartSnapWindowResolver()
        func topHit(alpha: Double) -> SmartSnapWindowHit {
            let stack = Fixture.stack([
                Fixture.record(5, pid: Fixture.floatingPID, layer: 3, alpha: alpha, cg: panelBounds),
                Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
            ], [active])
            return resolver.resolve(at: Fixture.point(cgX: 150, cgY: 150), in: stack, scope: Fixture.activeScope)
        }
        for alpha in [Double.nan, -1, -Double.infinity] {
            verify(topHit(alpha: alpha) == .blocked(.occluded), "alpha \(alpha) must occlude")
        }
        verify(topHit(alpha: 0.0) == .target(active) && topHit(alpha: -0.0) == .target(active), "Exact zero alpha is transparent")

        func list(bounds: [String: Any]) -> [[String: Any]] {
            [[
                kCGWindowNumber as String: NSNumber(value: 5),
                kCGWindowOwnerPID as String: NSNumber(value: 42),
                kCGWindowLayer as String: NSNumber(value: 3),
                kCGWindowBounds as String: bounds as NSDictionary,
            ]]
        }
        verify(WindowServerRecord.records(fromWindowList: list(bounds: ["X": "10", "Y": 0, "Width": 10, "Height": 10])) == nil,
               "A string bounds member is rejected")
        verify(WindowServerRecord.records(fromWindowList: list(bounds: ["X": 0, "Y": NSNull(), "Width": 10, "Height": 10])) == nil,
               "An NSNull bounds member is rejected")
        verify(WindowServerRecord.records(fromWindowList: list(bounds: ["X": true, "Y": 0, "Width": 10, "Height": 10])) == nil,
               "A Boolean bounds member is rejected")
        verify(WindowServerRecord.records(fromWindowList: list(bounds: ["X": 1e308, "Y": 0, "Width": 1e308, "Height": 10])) == nil,
               "An overflowing maxX is rejected")
        guard let negative = WindowServerRecord.records(fromWindowList: list(bounds: ["X": 600, "Y": 600, "Width": -400, "Height": -400])) else {
            verify(false, "Finite negative sizes parse")
            return
        }
        let negativeStack = Fixture.builder().build(
            records: negative.records + [Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)],
            selectableWindows: Fixture.byID([active]),
            transformer: Fixture.transformer
        ).stack
        verify(resolver.resolve(at: Fixture.point(cgX: 400, cgY: 400), in: negativeStack, scope: Fixture.activeScope) == .blocked(.occluded),
               "A negative-size record still occludes its standardized area")
    }

    static func inexactIdentityFieldsBecomeUnknownOccluders() {
        let activeBounds = CGRect(x: 0, y: 40, width: 1600, height: 1000)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let panelBounds = CGRect(x: 100, y: 100, width: 200, height: 200)
        let wrappedPID = Int64(Fixture.ownPID) + (Int64(1) << 32)
        let cases: [(String, [String: Any])] = [
            ("wrapping pid", [
                kCGWindowNumber as String: NSNumber(value: 5),
                kCGWindowOwnerPID as String: NSNumber(value: wrappedPID),
                kCGWindowLayer as String: NSNumber(value: 3),
            ]),
            ("fractional layer", [
                kCGWindowNumber as String: NSNumber(value: 5),
                kCGWindowOwnerPID as String: NSNumber(value: Fixture.floatingPID),
                kCGWindowLayer as String: NSNumber(value: -0.5),
            ]),
            ("NaN window ID", [
                kCGWindowNumber as String: NSNumber(value: Double.nan),
                kCGWindowOwnerPID as String: NSNumber(value: Fixture.floatingPID),
                kCGWindowLayer as String: NSNumber(value: 3),
            ]),
            ("Boolean layer", [
                kCGWindowNumber as String: NSNumber(value: 5),
                kCGWindowOwnerPID as String: NSNumber(value: Fixture.floatingPID),
                kCGWindowLayer as String: kCFBooleanFalse as Any,
            ]),
        ]
        let activeRecord: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 1),
            kCGWindowOwnerPID as String: NSNumber(value: Fixture.activePID),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowBounds as String: activeBounds.dictionaryRepresentation,
        ]
        for (name, fields) in cases {
            var record = fields
            record[kCGWindowBounds as String] = panelBounds.dictionaryRepresentation
            guard let parsed = WindowServerRecord.records(fromWindowList: [record, activeRecord]) else {
                verify(false, "\(name): bounds are valid")
                continue
            }
            verify(parsed.incompleteCount == 1 && !parsed.records[0].isComplete, "\(name): \(parsed.records[0])")
            verify(parsed.records[0].processID != Fixture.ownPID, "\(name): must never wrap into Ushot's process ID")
            verify(parsed.records[0].layer != 0, "\(name): must never become the normal layer")
            let (stack, statistics) = Fixture.builder().build(
                records: parsed.records,
                selectableWindows: Fixture.byID([active]),
                transformer: Fixture.transformer
            )
            verify(statistics.skippedOwnApplication == 0 && stack.entries.first?.kind == .occluder, "\(name): \(statistics)")
            verify(SmartSnapWindowResolver().resolve(at: Fixture.point(cgX: 150, cgY: 150), in: stack, scope: Fixture.activeScope) == .blocked(.occluded),
                   "\(name): blocks the active window beneath")
        }
    }

    /// Measured on macOS 27.2.1 with two displays: every ScreenCaptureKit
    /// capture makes Window Server add two 28x28 cursor-level indicators to
    /// each menu bar, both extending past the right display edge, and rebuild
    /// them with new window IDs while the capture indicator stays visible.
    static let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
    static let measuredMenuBars = [
        Fixture.record(18827, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                       cg: CGRect(x: 280, y: 1152, width: 1728, height: 33)),
        Fixture.record(18819, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                       cg: CGRect(x: 0, y: 0, width: 2048, height: 30)),
    ]

    static func measuredIndicators(firstID: CGWindowID) -> [WindowServerRecord] {
        [
            CGRect(x: 1982, y: 1153, width: 28, height: 28),
            CGRect(x: 1982, y: 1153, width: 28, height: 28),
            CGRect(x: 2024, y: 1, width: 28, height: 28),
            CGRect(x: 2024, y: 1, width: 28, height: 28),
        ].enumerated().map { index, bounds in
            Fixture.record(firstID + CGWindowID(index), pid: Fixture.windowServerPID, owner: "Window Server",
                           layer: cursorLevel, cg: bounds)
        }
    }

    static func captureIndicatorsInsideMenuBarsKeepTheFreezeStable() {
        let activeBounds = CGRect(x: 66, y: 44, width: 1894, height: 1067)
        let floatBounds = CGRect(x: 1574, y: 30, width: 396, height: 235)
        let secondaryBounds = CGRect(x: 280, y: 1185, width: 1728, height: 1084)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let secondary = Fixture.window(2, pid: Fixture.activePID, cg: secondaryBounds)
        let windows = [
            Fixture.record(3, pid: Fixture.floatingPID, layer: 3, cg: floatBounds),
            Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
            Fixture.record(2, pid: Fixture.activePID, cg: secondaryBounds),
        ]
        let before = Fixture.stack(measuredMenuBars + windows, [active, secondary])
        let (afterStack, statistics) = Fixture.builder().build(
            records: measuredIndicators(firstID: 19074) + measuredMenuBars + windows,
            selectableWindows: Fixture.byID([active, secondary]),
            transformer: Fixture.transformer
        )
        verify(statistics.skippedMenuBarIndicators == 4 && statistics.skippedMenuBar == 2, "\(statistics)")
        verify(afterStack == before, "Indicators add no entries: \(afterStack.entries.map(\.windowID))")
        let reconciled = WindowStackStability.reconcile(before: before, after: afterStack, primaryDisplayHeight: Fixture.primaryHeight)
        verify(reconciled.outcome == .stable, "\(reconciled.outcome) \(String(describing: reconciled.result))")

        // Rebuilt with new IDs on the next read: still nothing changes.
        let rebuilt = Fixture.stack(measuredIndicators(firstID: 19082) + measuredMenuBars + windows, [active, secondary])
        verify(WindowStackStability.compare(before: afterStack, after: rebuilt).isStable, "Rebuilt indicators stay stable")

        // The floating panel in the content area still occludes the window.
        let resolver = SmartSnapWindowResolver()
        verify(resolver.resolve(at: Fixture.point(cgX: 1700, cgY: 100), in: afterStack, scope: Fixture.activeScope) == .blocked(.occluded),
               "A layer-3 panel keeps occluding")
        verify(resolver.resolve(at: Fixture.point(cgX: 1000, cgY: 1500), in: afterStack, scope: Fixture.activeScope) == .target(secondary),
               "The secondary display still snaps")
    }

    static func onlyConfirmedMenuBarIndicatorsAreTransparent() {
        let activeBounds = CGRect(x: 0, y: 0, width: 2048, height: 1152)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let app = Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)
        func firstEntry(_ records: [WindowServerRecord], builder: WindowStackBuilder = Fixture.builder()) -> WindowStackEntry? {
            builder.build(records: records + [app], selectableWindows: Fixture.byID([active]), transformer: Fixture.transformer)
                .stack.entries.first
        }
        let indicatorBounds = CGRect(x: 2024, y: 1, width: 28, height: 28)
        func surface(_ id: CGWindowID, pid: pid_t = Fixture.windowServerPID, owner: String? = "Window Server",
                     layer: Int = cursorLevel, alpha: Double = 1, cg bounds: CGRect = indicatorBounds) -> WindowServerRecord {
            Fixture.record(id, pid: pid, owner: owner, layer: layer, alpha: alpha, cg: bounds)
        }
        verify(firstEntry([surface(60)] + measuredMenuBars)?.windowID == 1, "The measured indicator is transparent")

        let cases: [(String, [WindowServerRecord])] = [
            ("third-party owner at cursor level", [surface(61, pid: Fixture.floatingPID, owner: "Overlay Tool")] + measuredMenuBars),
            ("Control Center owner", [surface(62, pid: Fixture.floatingPID, owner: "Control Center")] + measuredMenuBars),
            ("Window Server at status level", [surface(63, layer: Int(CGWindowLevelForKey(.statusWindow)))] + measuredMenuBars),
            ("Window Server at pop-up menu level", [surface(64, layer: Int(CGWindowLevelForKey(.popUpMenuWindow)))] + measuredMenuBars),
            ("reaches below the menu bar", [surface(65, cg: CGRect(x: 2000, y: 1, width: 40, height: 60))] + measuredMenuBars),
            ("control-center-sized drop-down", [surface(66, cg: CGRect(x: 1700, y: 30, width: 340, height: 600))] + measuredMenuBars),
            ("banner in the content area", [surface(67, cg: CGRect(x: 1650, y: 60, width: 380, height: 90))] + measuredMenuBars),
            ("menu bar hidden", [surface(68)]),
            ("only a transparent menu bar", [surface(69)] + measuredMenuBars.map {
                Fixture.record($0.windowID!, pid: $0.processID!, owner: $0.ownerName, layer: $0.layer!, alpha: 0, cg: $0.bounds)
            }),
            ("different Window Server process", [surface(70, pid: Fixture.windowServerPID + 1)] + measuredMenuBars),
            ("missing owner name", [surface(71, owner: nil)] + measuredMenuBars),
            ("entirely off the desktop", [surface(72, cg: CGRect(x: 3000, y: 1, width: 28, height: 28))] + measuredMenuBars),
        ]
        for (name, records) in cases {
            let entry = firstEntry(records)
            verify(entry?.kind == .occluder && entry?.windowID != 1, "\(name) must occlude: \(String(describing: entry))")
        }

        // A display to the right of the primary: the indicator's overhang
        // covers its content unless that display's menu bar contains it too.
        let rightDisplay = CGRect(x: 2048, y: 0, width: 1920, height: 1080)
        let builder = WindowStackBuilder(
            ownProcessID: Fixture.ownPID,
            dockProcessIDs: [Fixture.dockPID],
            displayBounds: [Fixture.primaryDisplay, rightDisplay]
        )
        let primaryBar = measuredMenuBars[1]
        let shortRightBar = Fixture.record(80, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                                           cg: CGRect(x: 2048, y: 0, width: 1920, height: 24))
        let tallRightBar = Fixture.record(80, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                                          cg: CGRect(x: 2048, y: 0, width: 1920, height: 30))
        verify(firstEntry([surface(81), primaryBar], builder: builder)?.kind == .occluder,
               "An overhang onto a display without a menu bar occludes")
        verify(firstEntry([surface(82), primaryBar, shortRightBar], builder: builder)?.kind == .occluder,
               "An overhang below the neighbor's menu bar occludes")
        verify(firstEntry([surface(83), primaryBar, tallRightBar], builder: builder)?.windowID == 1,
               "An overhang inside the neighbor's menu bar is transparent")

        // A neighbor 4 pt lower: its 24 pt menu bar ends at y=28 while the
        // measured indicator reaches y=29. That single point covers content,
        // so no tolerance may widen the clipped containment check.
        let lowerRightDisplay = CGRect(x: 2048, y: 4, width: 1920, height: 1080)
        let lowerBuilder = WindowStackBuilder(
            ownProcessID: Fixture.ownPID,
            dockProcessIDs: [Fixture.dockPID],
            displayBounds: [Fixture.primaryDisplay, lowerRightDisplay]
        )
        let lowerRightBar = Fixture.record(84, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                                           cg: CGRect(x: 2048, y: 4, width: 1920, height: 24))
        let lowerRightContentBounds = CGRect(x: 2048, y: 28, width: 1920, height: 1056)
        let lowerRightContent = Fixture.window(2, pid: Fixture.activePID, cg: lowerRightContentBounds)
        let lowerStack = lowerBuilder.build(
            records: [surface(85), primaryBar, lowerRightBar, Fixture.record(2, pid: Fixture.activePID, cg: lowerRightContentBounds), app],
            selectableWindows: Fixture.byID([active, lowerRightContent]),
            transformer: Fixture.transformer
        ).stack
        verify(lowerStack.entries.first?.windowID == 85 && lowerStack.entries.first?.kind == .occluder,
               "A 1 pt overhang into the neighbor's content occludes: \(lowerStack.entries.map(\.windowID))")
        verify(SmartSnapWindowResolver().resolve(at: Fixture.point(cgX: 2050, cgY: 28.5), in: lowerStack, scope: Fixture.activeScope)
               == .blocked(.occluded), "That covered content point never passes through")
        let tallLowerRightBar = Fixture.record(84, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                                               cg: CGRect(x: 2048, y: 4, width: 1920, height: 25))
        verify(firstEntry([surface(86), primaryBar, tallLowerRightBar], builder: lowerBuilder)?.windowID == 1,
               "Exactly reaching the neighbor's menu bar edge stays transparent")
    }

    static func appearingSystemPanelsStillRestrictTheFreeze() {
        let activeBounds = CGRect(x: 66, y: 44, width: 1894, height: 1067)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let app = Fixture.record(1, pid: Fixture.activePID, cg: activeBounds)
        let before = Fixture.stack(measuredMenuBars + [app], [active])
        let dropDown = Fixture.record(90, pid: Fixture.floatingPID, owner: "Control Center",
                                      layer: Int(CGWindowLevelForKey(.popUpMenuWindow)),
                                      cg: CGRect(x: 1700, y: 30, width: 340, height: 600))
        let banner = Fixture.record(91, pid: Fixture.windowServerPID, owner: "Window Server", layer: cursorLevel,
                                    cg: CGRect(x: 1650, y: 60, width: 380, height: 90))
        let after = Fixture.stack(measuredIndicators(firstID: 19074) + [dropDown, banner] + measuredMenuBars + [app], [active])
        let result = WindowStackStability.compare(before: before, after: after)
        verify(result.changes.appeared == 2 && result.unstableRegions.count == 2,
               "Only the two content-area panels are new: \(result.changes)")
        let reconciled = WindowStackStability.reconcile(before: before, after: after, primaryDisplayHeight: Fixture.primaryHeight)
        verify(reconciled.outcome == .partiallyUnstable, "\(reconciled.outcome)")
        verify(SmartSnapWindowResolver().resolve(at: Fixture.point(cgX: 1800, cgY: 300), in: reconciled.stack, scope: Fixture.activeScope)
               == .blocked(.unstable), "The drop-down area is refused")
    }

    static func accessibilityRejectionsCarryPrivacySafeDiagnostics() {
        let ownership = AccessibilityWindowOwnership()
        let host = CGRect(x: 100, y: 100, width: 800, height: 600)
        func failure(_ result: AccessibilityOwnershipVerification<Int>) -> AccessibilityOwnershipFailure? {
            if case .rejected(let failure) = result { return failure }
            return nil
        }
        let invalid = AXError.invalidUIElement.rawValue
        let roleAtAncestor = FakeAccessibilityTree([
            1: FakeNode(role: .value("AXStaticText"), parent: .value(2)),
            2: FakeNode(role: .value("AXGroup"), parent: .value(3)),
            3: FakeNode(role: .unreadable(.status(invalid)), parent: .value(4)),
        ])
        let atAncestor = failure(ownership.verify(hit: 1, reader: roleAtAncestor, target: host, siblingFrames: []))
        verify(atAncestor == AccessibilityOwnershipFailure(.roleUnreadable, depth: 2, readFailure: .status(invalid), lastReadableRole: "AXGroup"),
               "\(String(describing: atAncestor))")
        verify(atAncestor?.diagnosticKey == "role-unreadable@2:ax-25202<AXGroup", "\(String(describing: atAncestor?.diagnosticKey))")

        let leaf = failure(ownership.verify(hit: 1, reader: FakeAccessibilityTree([
            1: FakeNode(role: .unreadable(.undecodableValue), parent: .value(2)),
        ]), target: host, siblingFrames: []))
        verify(leaf?.diagnosticKey == "role-unreadable@0:undecodable", "The hit element itself: \(String(describing: leaf))")

        // An application-defined role never reaches the log verbatim.
        let custom = failure(ownership.verify(hit: 1, reader: FakeAccessibilityTree([
            1: FakeNode(role: .value("AXSecretDocumentTitle"), parent: .unreadable(.status(AXError.cannotComplete.rawValue))),
        ]), target: host, siblingFrames: []))
        verify(custom?.diagnosticKey == "parent-unreadable@0:ax-25204<custom", "\(String(describing: custom?.diagnosticKey))")
        verify(AccessibilityRoleLabel.label(for: "AXWebArea") == "AXWebArea" && AccessibilityRoleLabel.label(for: "AX") == "custom",
               "Only fixed system roles are labeled")

        let frame = failure(ownership.verify(hit: 1, reader: FakeAccessibilityTree([
            1: FakeNode(role: .value("AXWindow"), parent: .absent, frame: .unreadable(.status(invalid))),
        ]), target: host, siblingFrames: []))
        verify(frame == AccessibilityOwnershipFailure(.containerFrameUnreadable, readFailure: .status(invalid), lastReadableRole: "AXWindow"),
               "\(String(describing: frame))")
    }

    static func hitTestFailuresNeverLookLikeEmptySpace() {
        typealias Resolver = InterfaceElementSelectionResolver
        verify(Resolver.hitTestFailure(status: .success, hasElement: true) == nil, "A hit proceeds to the proof")
        verify(Resolver.hitTestFailure(status: .noValue, hasElement: false) == .noElement, "Nothing at the point")
        verify(Resolver.hitTestFailure(status: .apiDisabled, hasElement: false) == .accessibilityPermissionRequired,
               "Revoked trust is a permission failure")
        verify(Resolver.hitTestFailure(status: .success, hasElement: false)
               == .ownershipUnverified(AccessibilityOwnershipFailure(.hitTestUnreadable, readFailure: .undecodableValue)),
               "Success without an element is unknown")
        for status in [AXError.cannotComplete, .invalidUIElement, .failure, .illegalArgument, .notImplemented] {
            verify(Resolver.hitTestFailure(status: status, hasElement: false)
                   == .ownershipUnverified(AccessibilityOwnershipFailure(.hitTestUnreadable, readFailure: .status(status.rawValue))),
                   "\(status.rawValue) drops the previous control")
        }
    }

    static func unstableRegionSummaryNeverTraps() {
        let regions = [
            CGRect(x: 1981.6, y: -33.4, width: 28, height: 28),
            CGRect(x: 1e20, y: -1e20, width: 1e20, height: 5),
            CGRect(x: 0, y: 0, width: 10, height: 10),
        ]
        let summary = WindowStackStability.diagnosticSummary(of: regions, limit: 2)
        verify(summary == "(1982,-33,28x28),(overflow,overflow,overflowx5)", summary)
        verify(WindowStackStability.diagnosticSummary(of: []) == "none", "No regions")
        verify(WindowStackStability.diagnosticSummary(of: [CGRect(x: 10, y: 10, width: -4, height: 3)]) == "(6,10,4x3)",
               "Unstandardized rectangles are normalized")
    }

    static func defaultPreparationStackKeepsProvidedOrder() {
        let first = Fixture.window(1, pid: Fixture.activePID, cg: CGRect(x: 0, y: 0, width: 100, height: 100))
        let second = Fixture.window(2, pid: Fixture.activePID, cg: CGRect(x: 0, y: 0, width: 200, height: 200))
        let preparation = RegionCapturePreparation(displays: [], windows: [first, second])
        verify(preparation.windowStack.selectableWindows == [first, second], "\(preparation.windowStack)")
    }

    // MARK: - Display-level smart snapping

    static let primaryGeometry = DisplayGeometry(
        id: 1,
        frame: Fixture.transformer.appKitRect(fromScreenCaptureRect: Fixture.primaryDisplay),
        scale: 2
    )
    static let secondaryGeometry = DisplayGeometry(
        id: 2,
        frame: Fixture.transformer.appKitRect(fromScreenCaptureRect: Fixture.secondaryDisplay),
        scale: 2
    )
    static let dualGeometry = ScreenGeometry(displays: [primaryGeometry, secondaryGeometry])

    static func availableEmptyStackIsDesktopButDisabledStacksNeverAre() {
        let resolver = SmartSnapWindowResolver()
        let scope = Fixture.activeScope
        let primaryPoint = Fixture.point(cgX: 500, cgY: 500)
        let secondaryPoint = Fixture.point(cgX: 1000, cgY: 1700)

        let empty = WindowStack(entries: [], primaryDisplayHeight: Fixture.primaryHeight)
        verify(empty.isAvailable && empty.availability == .available, "\(empty)")
        verify(resolver.resolve(at: primaryPoint, in: empty, scope: scope) == .desktop,
               "A trustworthy stack without surfaces exposes the desktop")
        verify(resolver.resolvePointer(at: secondaryPoint, in: empty, scope: scope, geometry: dualGeometry)
                   == .desktop(secondaryGeometry),
               "Exposed desktop snaps to the display under the pointer")

        let unavailable = WindowStack.unavailable(primaryDisplayHeight: Fixture.primaryHeight)
        let invalidated = WindowStack.invalidated(.duplicateIdentity, primaryDisplayHeight: Fixture.primaryHeight)
        verify(unavailable.entries == empty.entries && invalidated.entries == empty.entries,
               "Disabled stacks carry no entries, exactly like an empty desktop")
        for point in [primaryPoint, secondaryPoint] {
            verify(resolver.resolve(at: point, in: unavailable, scope: scope) == .blocked(.unavailable),
                   "An unreadable window list must never be treated as an empty desktop")
            verify(resolver.resolve(at: point, in: invalidated, scope: scope) == .blocked(.invalidated),
                   "An invalidated session must never be treated as an empty desktop")
            verify(resolver.resolvePointer(at: point, in: unavailable, scope: scope, geometry: dualGeometry)
                       == .cleared(.blocked(.unavailable)), "Unavailable stacks clear every candidate")
            verify(resolver.resolvePointer(at: point, in: invalidated, scope: scope, geometry: dualGeometry)
                       == .cleared(.blocked(.invalidated)), "Invalidated stacks clear every candidate")
        }
        verify(invalidated.withUnstableRegions([CGRect(x: 0, y: 0, width: 1, height: 1)]).availability
                   == .invalidated(.duplicateIdentity),
               "Adding unstable regions never re-enables a disabled stack")

        // Every reconcile outcome that disables the session yields a disabled stack.
        let neither = WindowStackStability.reconcile(before: nil, after: nil, primaryDisplayHeight: Fixture.primaryHeight)
        verify(neither.outcome == .unavailable && neither.stack.availability == .unavailable, "\(neither)")
        let afterOnly = WindowStackStability.reconcile(before: nil, after: empty, primaryDisplayHeight: Fixture.primaryHeight)
        verify(afterOnly.stack.availability == .unavailable, "\(afterOnly)")
        let disabledInput = WindowStackStability.reconcile(
            before: empty,
            after: unavailable,
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(disabledInput.outcome == .unavailable && disabledInput.stack.availability == .unavailable,
               "A disabled snapshot can never reconcile into an available one: \(disabledInput)")
        let primaryChanged = WindowStackStability.reconcile(
            before: empty,
            after: WindowStack(entries: [], primaryDisplayHeight: 1117),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(primaryChanged.outcome == .invalidated
                   && primaryChanged.stack.availability == .invalidated(.primaryDisplayChanged),
               "\(primaryChanged)")
        verify(resolver.resolve(at: primaryPoint, in: primaryChanged.stack, scope: scope) == .blocked(.invalidated),
               "\(primaryChanged.stack)")
        let unknown = WindowStackEntry(
            windowID: kCGNullWindowID,
            frame: CGRect(x: 10, y: 10, width: 50, height: 50),
            processID: nil,
            kind: .occluder
        )
        let unpaired = WindowStackStability.reconcile(
            before: empty,
            after: WindowStack(entries: [unknown], primaryDisplayHeight: Fixture.primaryHeight),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(unpaired.stack.availability == .invalidated(.unpairedUnknownSurface)
                   && resolver.resolve(at: CGPoint(x: 900, y: 900), in: unpaired.stack, scope: scope) == .blocked(.invalidated),
               "\(unpaired)")
        let stable = WindowStackStability.reconcile(before: empty, after: empty, primaryDisplayHeight: Fixture.primaryHeight)
        verify(stable.outcome == .stable && stable.stack.isAvailable
                   && resolver.resolve(at: primaryPoint, in: stable.stack, scope: scope) == .desktop,
               "\(stable)")

        // A synthetic preparation describes a complete desktop.
        let synthetic = RegionCapturePreparation(displays: [], windows: [])
        verify(synthetic.windowStack.isAvailable, "\(synthetic.windowStack)")
    }

    static func blockedPointsNeverSnapToTheDisplay() {
        // The active window sits on the secondary display, partly covered by
        // another app's window and a floating panel; a banner appeared on the
        // primary display while the displays were being frozen.
        let activeBounds = CGRect(x: 300, y: 1200, width: 1200, height: 800)
        let otherBounds = CGRect(x: 900, y: 1500, width: 800, height: 600)
        let floatBounds = CGRect(x: 400, y: 1250, width: 200, height: 150)
        let bannerBounds = CGRect(x: 1600, y: 60, width: 400, height: 100)
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeBounds)
        let other = Fixture.window(2, pid: Fixture.otherPID, cg: otherBounds)
        let base = [
            Fixture.record(40, pid: Fixture.windowServerPID, owner: "Window Server", layer: Fixture.menuLevel,
                           cg: CGRect(x: 0, y: 0, width: 2048, height: 24)),
            Fixture.record(41, pid: Fixture.dockPID, layer: Fixture.dockLevel, cg: Fixture.primaryDisplay),
            Fixture.record(3, pid: Fixture.floatingPID, layer: 3, cg: floatBounds),
            Fixture.record(2, pid: Fixture.otherPID, cg: otherBounds),
            Fixture.record(1, pid: Fixture.activePID, cg: activeBounds),
        ]
        let before = Fixture.stack(base, [active, other])
        let after = Fixture.stack(
            [Fixture.record(7, pid: Fixture.floatingPID, layer: 25, cg: bannerBounds)] + base,
            [active, other]
        )
        let reconciled = WindowStackStability.reconcile(before: before, after: after, primaryDisplayHeight: Fixture.primaryHeight)
        verify(reconciled.outcome == .partiallyUnstable, "\(reconciled.outcome)")
        let stack = reconciled.stack
        let resolver = SmartSnapWindowResolver()
        func pointer(cgX x: CGFloat, cgY y: CGFloat) -> SmartSnapPointerTarget {
            resolver.resolvePointer(
                at: Fixture.point(cgX: x, cgY: y),
                in: stack,
                scope: Fixture.activeScope,
                geometry: dualGeometry
            )
        }
        verify(pointer(cgX: 450, cgY: 1300) == .cleared(.blocked(.occluded)), "A floating panel never exposes the display")
        verify(pointer(cgX: 1000, cgY: 1600) == .cleared(.blocked(.outOfScope)), "Another app's window never exposes the display")
        verify(pointer(cgX: 1700, cgY: 100) == .cleared(.blocked(.unstable)), "A freeze-time banner area never exposes the display")
        verify(pointer(cgX: 350, cgY: 1900) == .window(active, display: secondaryGeometry), "\(pointer(cgX: 350, cgY: 1900))")
        verify(pointer(cgX: 1900, cgY: 2200) == .desktop(secondaryGeometry), "Uncovered secondary desktop")
        verify(pointer(cgX: 500, cgY: 500) == .desktop(primaryGeometry), "Desktop under the skipped Dock surface")
        verify(pointer(cgX: 500, cgY: 10) == .desktop(primaryGeometry), "An uncovered menu bar is exposed desktop")
        verify(pointer(cgX: 1700.5, cgY: 1800) == .desktop(secondaryGeometry), "Desktop starts right at a matching edge")
        // The secondary display starts at x = 280: left of it lies no display.
        verify(pointer(cgX: 100, cgY: 1700) == .cleared(.noDisplay), "Exposed points outside every display never snap")
    }

    static func admittedOwnWindowsWithoutTargetsStillOcclude() {
        let toolbarBounds = CGRect(x: 600, y: 600, width: 30, height: 30)
        let records = [Fixture.record(50, pid: Fixture.ownPID, cg: toolbarBounds)]
        let point = Fixture.point(cgX: 610, cgY: 610)
        let (admitted, admittedStatistics) = Fixture.builder().build(
            records: records,
            selectableWindows: [:],
            transformer: Fixture.transformer,
            admittedOwnWindowIDs: [50]
        )
        verify(admitted.entries.map(\.kind) == [.occluder] && admittedStatistics.skippedOwnApplication == 0,
               "\(admitted.entries)")
        verify(SmartSnapWindowResolver().resolve(at: point, in: admitted, scope: Fixture.activeScope) == .blocked(.occluded),
               "Admitted pixels without a target block the desktop")
        let (unadmitted, statistics) = Fixture.builder().build(
            records: records,
            selectableWindows: [:],
            transformer: Fixture.transformer
        )
        verify(unadmitted.entries.isEmpty && statistics.skippedOwnApplication == 1, "\(unadmitted.entries)")
        verify(SmartSnapWindowResolver().resolve(at: point, in: unadmitted, scope: Fixture.activeScope) == .desktop,
               "Unadmitted Ushot windows are absent from the frozen pixels")
    }

    static func hierarchyAppendsTheDisplayAndDeduplicates() {
        let display = CGRect(x: 0, y: 0, width: 2048, height: 1152)
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let inner = CGRect(x: 200, y: 200, width: 50, height: 20)
        let outer = CGRect(x: 150, y: 150, width: 300, height: 300)
        let full = SmartSnapHierarchy.targets(
            controlFrames: [inner, outer, inner, window, display],
            windowFrame: window,
            displayFrame: display
        )
        verify(full == [
            SmartSnapTarget(frame: inner, kind: .interfaceElement),
            SmartSnapTarget(frame: outer, kind: .interfaceElement),
            SmartSnapTarget(frame: window, kind: .window),
            SmartSnapTarget(frame: display, kind: .display),
        ], "Controls, then the window, then the display; duplicates and controls equal to a parent are dropped: \(full)")
        let fullScreen = SmartSnapHierarchy.targets(controlFrames: [inner], windowFrame: display, displayFrame: display)
        verify(fullScreen == [
            SmartSnapTarget(frame: inner, kind: .interfaceElement),
            SmartSnapTarget(frame: display, kind: .window),
        ], "A window filling its display keeps the window level only: \(fullScreen)")
        let noDisplay = SmartSnapHierarchy.targets(controlFrames: [], windowFrame: window, displayFrame: nil)
        verify(noDisplay == [SmartSnapTarget(frame: window, kind: .window)], "\(noDisplay)")
        let desktop = SmartSnapHierarchy.targets(controlFrames: [], windowFrame: nil, displayFrame: display)
        verify(desktop == [SmartSnapTarget(frame: display, kind: .display)], "\(desktop)")

        // A window spanning both displays: the pointer's display is the top level.
        let spanning = Fixture.window(1, pid: Fixture.activePID, cg: CGRect(x: 300, y: 600, width: 1500, height: 1200))
        let stack = Fixture.stack([Fixture.record(1, pid: Fixture.activePID, cg: CGRect(x: 300, y: 600, width: 1500, height: 1200))],
                                  [spanning])
        let resolver = SmartSnapWindowResolver()
        let onPrimary = resolver.resolvePointer(at: Fixture.point(cgX: 1000, cgY: 1000), in: stack,
                                                scope: Fixture.activeScope, geometry: dualGeometry)
        let onSecondary = resolver.resolvePointer(at: Fixture.point(cgX: 1000, cgY: 1300), in: stack,
                                                  scope: Fixture.activeScope, geometry: dualGeometry)
        verify(onPrimary == .window(spanning, display: primaryGeometry), "\(onPrimary)")
        verify(onSecondary == .window(spanning, display: secondaryGeometry), "\(onSecondary)")
        verify(onPrimary.source == .window(1, displayID: 1) && onSecondary.source == .window(1, displayID: 2),
               "Crossing displays inside one window changes the source display")
    }

    static func hierarchySelectionKeepsTheUserDisplayChoice() {
        let control = SmartSnapTarget(frame: CGRect(x: 200, y: 200, width: 50, height: 20), kind: .interfaceElement)
        let window = SmartSnapTarget(frame: CGRect(x: 100, y: 100, width: 800, height: 600), kind: .window)
        let displayA = SmartSnapTarget(frame: CGRect(x: 0, y: 0, width: 2048, height: 1152), kind: .display)
        let displayB = SmartSnapTarget(frame: CGRect(x: 280, y: -1117, width: 1728, height: 1117), kind: .display)
        func choose(_ targets: [SmartSnapTarget], from previous: [SmartSnapTarget], selected: Int, user: Bool) -> (Int, Bool) {
            let choice = SmartSnapHierarchy.selection(
                in: targets,
                previousTargets: previous,
                previousSelectedIndex: selected,
                previousUserAdjusted: user
            )
            return (choice.index, choice.userAdjusted)
        }
        verify(choose([window, displayA], from: [window, displayA], selected: 1, user: true) == (1, true),
               "A fallback that keeps the window leaf keeps the chosen display")
        verify(choose([control, window, displayA], from: [control, window, displayA], selected: 2, user: true) == (2, true),
               "An unchanged control leaf keeps the chosen display")
        verify(choose([control, window, displayA], from: [window, displayA], selected: 1, user: true) == (0, false),
               "A new deepest control resets to that control")
        verify(choose([window, displayB], from: [window, displayA], selected: 1, user: true) == (1, true),
               "A chosen display follows the pointer to the other display")
        verify(choose([window], from: [window, displayA], selected: 1, user: true) == (0, true),
               "A display collapsing into a full-screen window keeps the top remaining level")
        verify(choose([window, displayB], from: [window, displayA], selected: 0, user: false) == (0, false),
               "Without a user choice the deepest level stays selected")
        verify(choose([control, window, displayA], from: [control, window, displayA], selected: 0, user: false) == (0, false),
               "\(choose([control, window, displayA], from: [control, window, displayA], selected: 0, user: false))")
        verify(choose([window, displayA], from: [], selected: 0, user: false) == (0, false), "Empty history")
        verify(choose([window, displayA], from: [window, displayA], selected: 5, user: true) == (0, false),
               "An out-of-range history never selects a level")
    }


    /// Window Server and ScreenCaptureKit bounds may disagree by up to the
    /// builder's 1 pt tolerance. The sliver must block, never expose the
    /// window or desktop behind it.
    static func windowServerBoundsSliverNeverPassesThrough() {
        let activeCG = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frontCG = CGRect(x: 100, y: 50, width: 101, height: 100) // maxX 201
        let frontSC = CGRect(x: 100, y: 50, width: 100, height: 100) // maxX 200
        let active = Fixture.window(1, pid: Fixture.activePID, cg: activeCG)
        let sliver = Fixture.point(cgX: 200.5, cgY: 100)
        let exposed = Fixture.point(cgX: 250, cgY: 100)
        let resolver = SmartSnapWindowResolver()
        for frontPID in [Fixture.otherPID, Fixture.activePID] {
            let front = Fixture.window(2, pid: frontPID, cg: frontSC)
            let stack = Fixture.stack([
                Fixture.record(2, pid: frontPID, cg: frontCG),
                Fixture.record(1, pid: Fixture.activePID, cg: activeCG),
            ], [active, front])
            verify(stack.selectableWindows == [front, active], "Both windows match within tolerance: \(stack.entries)")
            let frontWindowServerFrame = Fixture.transformer.appKitRect(fromScreenCaptureRect: frontCG)
            verify(stack.entries[0].frame == front.frame
                       && stack.entries[0].windowServerFrame == frontWindowServerFrame
                       && stack.entries[0].occlusionFrame == front.frame.union(frontWindowServerFrame),
                   "One entry keeps the snap frame, the Window Server bounds and their covered area: \(stack.entries[0])")
            let sliverHit = resolver.resolve(at: sliver, in: stack, scope: Fixture.activeScope)
            verify(sliverHit == (frontPID == Fixture.activePID ? .blocked(.occluded) : .blocked(.outOfScope)),
                   "The sliver belongs to the front window, never to the one behind: \(sliverHit)")
            let pointer = resolver.resolvePointer(at: exposed, in: stack, scope: Fixture.activeScope, geometry: dualGeometry)
            verify(pointer == .window(active, display: primaryGeometry), "\(pointer)")
            guard let source = pointer.source else { continue }
            let press = resolver.resolvePointer(at: sliver, in: stack, scope: Fixture.activeScope, geometry: dualGeometry)
            for kind in [SmartSnapTarget.Kind.window, .display] {
                verify(!source.acceptsPress(press, selectedKind: kind),
                       "A press in the sliver never accepts the window behind or its display: \(kind) \(press)")
            }
        }
        // Over bare desktop the sliver still blocks.
        let alone = Fixture.window(2, pid: Fixture.otherPID, cg: frontSC)
        let desktopStack = Fixture.stack([Fixture.record(2, pid: Fixture.otherPID, cg: frontCG)], [alone])
        verify(resolver.resolve(at: sliver, in: desktopStack, scope: Fixture.activeScope) == .blocked(.outOfScope),
               "The sliver never exposes the desktop")
        verify(resolver.resolve(at: Fixture.point(cgX: 201.5, cgY: 100), in: desktopStack, scope: Fixture.activeScope) == .desktop,
               "Desktop begins beyond the Window Server bounds")
        // The freeze-stability envelope covers the sliver as well.
        let moved = Fixture.stack([Fixture.record(2, pid: Fixture.otherPID, cg: frontSC)], [alone])
        let reconciled = WindowStackStability.reconcile(before: desktopStack, after: moved, primaryDisplayHeight: Fixture.primaryHeight)
        verify(reconciled.result?.unstableRegions.contains(where: { $0.contains(sliver) }) == true,
               "A change of the covered area is unstable across its whole envelope: \(String(describing: reconciled.result))")
    }

    /// ScreenCaptureKit reports the front window one point wider (maxX 201)
    /// than Window Server, whose bounds shrink from 201 to 200 while the
    /// displays freeze. Another app's window lies behind.
    static func windowServerShrinkDuringFreezeIsUnstable() {
        let frontSC = CGRect(x: 100, y: 50, width: 101, height: 100)
        let front = Fixture.window(1, pid: Fixture.activePID, cg: frontSC)
        let behindCG = CGRect(x: 150, y: 0, width: 400, height: 300)
        let behind = Fixture.window(2, pid: Fixture.otherPID, cg: behindCG)
        func snapshot(frontCGWidth width: CGFloat) -> WindowStack {
            Fixture.stack([
                Fixture.record(1, pid: Fixture.activePID, cg: CGRect(x: 100, y: 50, width: width, height: 100)),
                Fixture.record(2, pid: Fixture.otherPID, cg: behindCG),
            ], [front, behind])
        }
        let before = snapshot(frontCGWidth: 101)
        let after = snapshot(frontCGWidth: 100)
        verify(before.selectableWindows == [front, behind] && after.selectableWindows == [front, behind],
               "Both snapshots match within tolerance")
        verify(before.entries != after.entries, "The Window Server change is part of the snapshot")
        let reconciled = WindowStackStability.reconcile(before: before, after: after, primaryDisplayHeight: Fixture.primaryHeight)
        verify(reconciled.outcome == .partiallyUnstable, "\(reconciled.outcome)")
        let resolver = SmartSnapWindowResolver()
        let sliver = Fixture.point(cgX: 200.5, cgY: 100)
        let hover = resolver.resolvePointer(at: sliver, in: reconciled.stack, scope: Fixture.activeScope, geometry: dualGeometry)
        verify(hover == .cleared(.blocked(.unstable)), "\(hover)")
        let source = SmartSnapSource.window(front.id, displayID: primaryGeometry.id)
        for kind in [SmartSnapTarget.Kind.window, .display] {
            verify(!source.acceptsPress(hover, selectedKind: kind), "A press in the shrunk sliver never accepts: \(kind)")
        }
    }

    /// The same one-point disagreement without any change: the sliver where
    /// only ScreenCaptureKit places the window blocks, the agreed part snaps
    /// to the ScreenCaptureKit rectangle.
    static func staticWindowServerDisagreementBlocksItsSliver() {
        let frontSC = CGRect(x: 100, y: 50, width: 101, height: 100)
        let front = Fixture.window(1, pid: Fixture.activePID, cg: frontSC)
        let behindCG = CGRect(x: 150, y: 0, width: 400, height: 300)
        let behind = Fixture.window(2, pid: Fixture.otherPID, cg: behindCG)
        let records = [
            Fixture.record(1, pid: Fixture.activePID, cg: CGRect(x: 100, y: 50, width: 100, height: 100)),
            Fixture.record(2, pid: Fixture.otherPID, cg: behindCG),
        ]
        let reconciled = WindowStackStability.reconcile(
            before: Fixture.stack(records, [front, behind]),
            after: Fixture.stack(records, [front, behind]),
            primaryDisplayHeight: Fixture.primaryHeight
        )
        verify(reconciled.outcome == .stable, "\(reconciled.outcome)")
        let resolver = SmartSnapWindowResolver()
        let sliverHover = resolver.resolvePointer(at: Fixture.point(cgX: 200.5, cgY: 100), in: reconciled.stack,
                                                  scope: Fixture.activeScope, geometry: dualGeometry)
        verify(sliverHover == .cleared(.blocked(.occluded)), "\(sliverHover)")
        let agreedHover = resolver.resolvePointer(at: Fixture.point(cgX: 199.5, cgY: 100), in: reconciled.stack,
                                                  scope: Fixture.activeScope, geometry: dualGeometry)
        verify(agreedHover == .window(front, display: primaryGeometry), "\(agreedHover)")
        verify(front.frame.maxX == 201, "The target keeps the ScreenCaptureKit rectangle: \(front.frame)")
        guard let source = agreedHover.source else { return }
        for kind in [SmartSnapTarget.Kind.window, .display] {
            verify(!source.acceptsPress(sliverHover, selectedKind: kind), "A press in the static sliver never accepts: \(kind)")
            verify(source.acceptsPress(agreedHover, selectedKind: kind), "A press where both agree accepts: \(kind)")
        }
    }

    /// The secondary display starts at x = 280, leaving a gap below the
    /// primary display to its left.
    static func windowsExtendingIntoDisplayGapsNeverSnapThere() {
        let bounds = CGRect(x: 100, y: 1000, width: 400, height: 400)
        let window = Fixture.window(1, pid: Fixture.activePID, cg: bounds)
        let stack = Fixture.stack([Fixture.record(1, pid: Fixture.activePID, cg: bounds)], [window])
        let resolver = SmartSnapWindowResolver()
        let gap = Fixture.point(cgX: 150, cgY: 1300)
        verify(resolver.resolve(at: gap, in: stack, scope: Fixture.activeScope) == .target(window),
               "The raw stack hit is the window")
        let gapPointer = resolver.resolvePointer(at: gap, in: stack, scope: Fixture.activeScope, geometry: dualGeometry)
        verify(gapPointer == .cleared(.noDisplay), "A gap between displays never snaps: \(gapPointer)")
        let onPrimary = resolver.resolvePointer(at: Fixture.point(cgX: 150, cgY: 1100), in: stack,
                                                scope: Fixture.activeScope, geometry: dualGeometry)
        let onSecondary = resolver.resolvePointer(at: Fixture.point(cgX: 300, cgY: 1300), in: stack,
                                                  scope: Fixture.activeScope, geometry: dualGeometry)
        verify(onPrimary == .window(window, display: primaryGeometry), "\(onPrimary)")
        verify(onSecondary == .window(window, display: secondaryGeometry), "\(onSecondary)")
        for kind in [SmartSnapTarget.Kind.interfaceElement, .window, .display] {
            for source in [onPrimary.source, onSecondary.source].compactMap({ $0 }) {
                verify(!source.acceptsPress(gapPointer, selectedKind: kind),
                       "A press in the gap never accepts: \(source) \(kind)")
            }
        }
    }

    static func pressValidationCoversDisplayCandidates() {
        let window = Fixture.window(1, pid: Fixture.activePID, cg: CGRect(x: 300, y: 600, width: 1500, height: 1200))
        let otherWindow = Fixture.window(2, pid: Fixture.activePID, cg: CGRect(x: 100, y: 100, width: 100, height: 100))
        let presses: [SmartSnapPointerTarget] = [
            .desktop(primaryGeometry),
            .desktop(secondaryGeometry),
            .window(window, display: primaryGeometry),
            .window(window, display: secondaryGeometry),
            .window(otherWindow, display: primaryGeometry),
            .cleared(.blocked(.occluded)),
            .cleared(.blocked(.outOfScope)),
            .cleared(.blocked(.unstable)),
            .cleared(.blocked(.unavailable)),
            .cleared(.blocked(.invalidated)),
            .cleared(.noDisplay),
        ]
        func accepted(_ source: SmartSnapSource, _ kind: SmartSnapTarget.Kind) -> [Int] {
            presses.indices.filter { source.acceptsPress(presses[$0], selectedKind: kind) }
        }
        verify(accepted(.desktop(displayID: 1), .display) == [0],
               "Exposed desktop accepts only exposed desktop on the same display: \(accepted(.desktop(displayID: 1), .display))")
        verify(accepted(.desktop(displayID: 1), .window).isEmpty, "A desktop source has only a display level")
        verify(accepted(.window(1, displayID: 1), .window) == [2, 3],
               "A window level requires the same window on a frozen display: \(accepted(.window(1, displayID: 1), .window))")
        verify(accepted(.window(1, displayID: 1), .interfaceElement) == [2, 3], "Controls follow the window rule")
        verify(accepted(.window(1, displayID: 1), .display) == [2],
               "A display chosen inside a window requires the same window on the same display: \(accepted(.window(1, displayID: 1), .display))")

        // End to end: hovering the exposed part of the window, then pressing
        // on a floating panel above it rejects even a display candidate.
        let floatBounds = CGRect(x: 400, y: 700, width: 200, height: 150)
        let stack = Fixture.stack([
            Fixture.record(3, pid: Fixture.floatingPID, layer: 3, cg: floatBounds),
            Fixture.record(1, pid: Fixture.activePID, cg: CGRect(x: 300, y: 600, width: 1500, height: 1200)),
        ], [window])
        let resolver = SmartSnapWindowResolver()
        let hover = resolver.resolvePointer(at: Fixture.point(cgX: 1000, cgY: 1000), in: stack,
                                            scope: Fixture.activeScope, geometry: dualGeometry)
        guard let source = hover.source else {
            verify(false, "The exposed window must resolve: \(hover)")
            return
        }
        let pressOnPanel = resolver.resolvePointer(at: Fixture.point(cgX: 450, cgY: 750), in: stack,
                                                   scope: Fixture.activeScope, geometry: dualGeometry)
        verify(!source.acceptsPress(pressOnPanel, selectedKind: .display), "\(pressOnPanel)")
        verify(source.acceptsPress(hover, selectedKind: .display), "The hover point itself accepts")
        verify(source.diagnosticDescription == "window:1@display:1", source.diagnosticDescription)
        verify(SmartSnapSource.desktop(displayID: 2).diagnosticDescription == "desktop@display:2", "Desktop description")
    }
}

#if canImport(XCTest)
final class SmartSnapWindowStackTests: XCTestCase {
    func testDockAndMenuBarSurfacesNeverOccludeButThirdPartyFullScreenFloatsDo() {
        SmartSnapScenarios.dockAndMenuBarSurfacesNeverOccludeButThirdPartyFullScreenFloatsDo()
    }

    func testTransparentAndDesktopLevelSurfacesAreSkipped() {
        SmartSnapScenarios.transparentAndDesktopLevelSurfacesAreSkipped()
    }

    func testSecondaryDisplayFramesUseFrozenPrimaryHeight() {
        SmartSnapScenarios.secondaryDisplayFramesUseFrozenPrimaryHeight()
    }

    func testActiveWindowCoveredByAnotherAppNeverPassesThrough() {
        SmartSnapScenarios.activeWindowCoveredByAnotherAppNeverPassesThrough()
    }

    func testActiveApplicationFloatingWindowsOccludeInsteadOfSnapping() {
        SmartSnapScenarios.activeApplicationFloatingWindowsOccludeInsteadOfSnapping()
    }

    func testOwnWindowsRequireExplicitAdmission() {
        SmartSnapScenarios.ownWindowsRequireExplicitAdmission()
    }

    func testWindowServerOrderIsTheOnlyOrderingAuthority() {
        SmartSnapScenarios.windowServerOrderIsTheOnlyOrderingAuthority()
    }

    func testScopeResolution() {
        SmartSnapScenarios.scopeResolution()
    }

    func testAccessibilityOwnershipIsGeometricAndFailsClosed() {
        SmartSnapScenarios.accessibilityOwnershipIsGeometricAndFailsClosed()
    }

    func testAccessibilityNeverQueriesUshot() {
        SmartSnapScenarios.accessibilityNeverQueriesUshot()
    }

    func testWindowServerRecordsParseInOrder() {
        SmartSnapScenarios.windowServerRecordsParseInOrder()
    }

    func testIncompleteRecordsFailClosed() {
        SmartSnapScenarios.incompleteRecordsFailClosed()
    }

    func testOnlyTheSystemMenuBarIsTransparentAtMainMenuLevel() {
        SmartSnapScenarios.onlyTheSystemMenuBarIsTransparentAtMainMenuLevel()
    }

    func testFreezeStabilityRestrictsSnappingWhereSnapshotsDisagree() {
        SmartSnapScenarios.freezeStabilityRestrictsSnappingWhereSnapshotsDisagree()
    }

    func testMovingSurfacesBlockTheirWholeTransitionEnvelope() {
        SmartSnapScenarios.movingSurfacesBlockTheirWholeTransitionEnvelope()
    }

    func testUnknownSurfacesInvalidateOnlyWhenUnpaired() {
        SmartSnapScenarios.unknownSurfacesInvalidateOnlyWhenUnpaired()
    }

    func testReorderDuringMoveBlocksTheNewOverlap() {
        SmartSnapScenarios.reorderDuringMoveBlocksTheNewOverlap()
    }

    func testDuplicateIdentitiesAndIdenticalSnapshots() {
        SmartSnapScenarios.duplicateIdentitiesAndIdenticalSnapshots()
    }

    func testStabilityPropertyHoldsForRandomSnapshots() {
        SmartSnapScenarios.stabilityPropertyHoldsForRandomSnapshots()
    }

    func testAccessibilityReadClassification() {
        SmartSnapScenarios.accessibilityReadClassification()
    }

    func testAccessibilityProofReadsLazilyAndFailsClosed() {
        SmartSnapScenarios.accessibilityProofReadsLazilyAndFailsClosed()
    }

    func testAlphaAndBoundsParsingFailClosed() {
        SmartSnapScenarios.alphaAndBoundsParsingFailClosed()
    }

    func testInexactIdentityFieldsBecomeUnknownOccluders() {
        SmartSnapScenarios.inexactIdentityFieldsBecomeUnknownOccluders()
    }

    func testDefaultPreparationStackKeepsProvidedOrder() {
        SmartSnapScenarios.defaultPreparationStackKeepsProvidedOrder()
    }

    func testCaptureIndicatorsInsideMenuBarsKeepTheFreezeStable() {
        SmartSnapScenarios.captureIndicatorsInsideMenuBarsKeepTheFreezeStable()
    }

    func testOnlyConfirmedMenuBarIndicatorsAreTransparent() {
        SmartSnapScenarios.onlyConfirmedMenuBarIndicatorsAreTransparent()
    }

    func testAppearingSystemPanelsStillRestrictTheFreeze() {
        SmartSnapScenarios.appearingSystemPanelsStillRestrictTheFreeze()
    }

    func testAccessibilityRejectionsCarryPrivacySafeDiagnostics() {
        SmartSnapScenarios.accessibilityRejectionsCarryPrivacySafeDiagnostics()
    }

    func testHitTestFailuresNeverLookLikeEmptySpace() {
        SmartSnapScenarios.hitTestFailuresNeverLookLikeEmptySpace()
    }

    func testUnstableRegionSummaryNeverTraps() {
        SmartSnapScenarios.unstableRegionSummaryNeverTraps()
    }

    func testAvailableEmptyStackIsDesktopButDisabledStacksNeverAre() {
        SmartSnapScenarios.availableEmptyStackIsDesktopButDisabledStacksNeverAre()
    }

    func testBlockedPointsNeverSnapToTheDisplay() {
        SmartSnapScenarios.blockedPointsNeverSnapToTheDisplay()
    }

    func testAdmittedOwnWindowsWithoutTargetsStillOcclude() {
        SmartSnapScenarios.admittedOwnWindowsWithoutTargetsStillOcclude()
    }

    func testHierarchyAppendsTheDisplayAndDeduplicates() {
        SmartSnapScenarios.hierarchyAppendsTheDisplayAndDeduplicates()
    }

    func testHierarchySelectionKeepsTheUserDisplayChoice() {
        SmartSnapScenarios.hierarchySelectionKeepsTheUserDisplayChoice()
    }

    func testPressValidationCoversDisplayCandidates() {
        SmartSnapScenarios.pressValidationCoversDisplayCandidates()
    }

    func testWindowServerBoundsSliverNeverPassesThrough() {
        SmartSnapScenarios.windowServerBoundsSliverNeverPassesThrough()
    }

    func testWindowsExtendingIntoDisplayGapsNeverSnapThere() {
        SmartSnapScenarios.windowsExtendingIntoDisplayGapsNeverSnapThere()
    }

    func testWindowServerShrinkDuringFreezeIsUnstable() {
        SmartSnapScenarios.windowServerShrinkDuringFreezeIsUnstable()
    }

    func testStaticWindowServerDisagreementBlocksItsSliver() {
        SmartSnapScenarios.staticWindowServerDisagreementBlocksItsSliver()
    }
}
#else
@Test func dockAndMenuBarSurfacesNeverOccludeButThirdPartyFullScreenFloatsDo() {
    SmartSnapScenarios.dockAndMenuBarSurfacesNeverOccludeButThirdPartyFullScreenFloatsDo()
}

@Test func transparentAndDesktopLevelSurfacesAreSkipped() {
    SmartSnapScenarios.transparentAndDesktopLevelSurfacesAreSkipped()
}

@Test func secondaryDisplayFramesUseFrozenPrimaryHeight() {
    SmartSnapScenarios.secondaryDisplayFramesUseFrozenPrimaryHeight()
}

@Test func activeWindowCoveredByAnotherAppNeverPassesThrough() {
    SmartSnapScenarios.activeWindowCoveredByAnotherAppNeverPassesThrough()
}

@Test func activeApplicationFloatingWindowsOccludeInsteadOfSnapping() {
    SmartSnapScenarios.activeApplicationFloatingWindowsOccludeInsteadOfSnapping()
}

@Test func ownWindowsRequireExplicitAdmission() {
    SmartSnapScenarios.ownWindowsRequireExplicitAdmission()
}

@Test func windowServerOrderIsTheOnlyOrderingAuthority() {
    SmartSnapScenarios.windowServerOrderIsTheOnlyOrderingAuthority()
}

@Test func smartSnapScopeResolution() {
    SmartSnapScenarios.scopeResolution()
}

@Test func accessibilityOwnershipIsGeometricAndFailsClosed() {
    SmartSnapScenarios.accessibilityOwnershipIsGeometricAndFailsClosed()
}

@Test func accessibilityNeverQueriesUshot() {
    SmartSnapScenarios.accessibilityNeverQueriesUshot()
}

@Test func windowServerRecordsParseInOrder() {
    SmartSnapScenarios.windowServerRecordsParseInOrder()
}

@Test func incompleteRecordsFailClosed() {
    SmartSnapScenarios.incompleteRecordsFailClosed()
}

@Test func onlyTheSystemMenuBarIsTransparentAtMainMenuLevel() {
    SmartSnapScenarios.onlyTheSystemMenuBarIsTransparentAtMainMenuLevel()
}

@Test func freezeStabilityRestrictsSnappingWhereSnapshotsDisagree() {
    SmartSnapScenarios.freezeStabilityRestrictsSnappingWhereSnapshotsDisagree()
}

@Test func movingSurfacesBlockTheirWholeTransitionEnvelope() {
    SmartSnapScenarios.movingSurfacesBlockTheirWholeTransitionEnvelope()
}

@Test func unknownSurfacesInvalidateOnlyWhenUnpaired() {
    SmartSnapScenarios.unknownSurfacesInvalidateOnlyWhenUnpaired()
}

@Test func reorderDuringMoveBlocksTheNewOverlap() {
    SmartSnapScenarios.reorderDuringMoveBlocksTheNewOverlap()
}

@Test func duplicateIdentitiesAndIdenticalSnapshots() {
    SmartSnapScenarios.duplicateIdentitiesAndIdenticalSnapshots()
}

@Test func stabilityPropertyHoldsForRandomSnapshots() {
    SmartSnapScenarios.stabilityPropertyHoldsForRandomSnapshots()
}

@Test func accessibilityReadClassification() {
    SmartSnapScenarios.accessibilityReadClassification()
}

@Test func accessibilityProofReadsLazilyAndFailsClosed() {
    SmartSnapScenarios.accessibilityProofReadsLazilyAndFailsClosed()
}

@Test func alphaAndBoundsParsingFailClosed() {
    SmartSnapScenarios.alphaAndBoundsParsingFailClosed()
}

@Test func inexactIdentityFieldsBecomeUnknownOccluders() {
    SmartSnapScenarios.inexactIdentityFieldsBecomeUnknownOccluders()
}

@Test func defaultPreparationStackKeepsProvidedOrder() {
    SmartSnapScenarios.defaultPreparationStackKeepsProvidedOrder()
}

@Test func captureIndicatorsInsideMenuBarsKeepTheFreezeStable() {
    SmartSnapScenarios.captureIndicatorsInsideMenuBarsKeepTheFreezeStable()
}

@Test func onlyConfirmedMenuBarIndicatorsAreTransparent() {
    SmartSnapScenarios.onlyConfirmedMenuBarIndicatorsAreTransparent()
}

@Test func appearingSystemPanelsStillRestrictTheFreeze() {
    SmartSnapScenarios.appearingSystemPanelsStillRestrictTheFreeze()
}

@Test func accessibilityRejectionsCarryPrivacySafeDiagnostics() {
    SmartSnapScenarios.accessibilityRejectionsCarryPrivacySafeDiagnostics()
}

@Test func hitTestFailuresNeverLookLikeEmptySpace() {
    SmartSnapScenarios.hitTestFailuresNeverLookLikeEmptySpace()
}

@Test func unstableRegionSummaryNeverTraps() {
    SmartSnapScenarios.unstableRegionSummaryNeverTraps()
}

@Test func availableEmptyStackIsDesktopButDisabledStacksNeverAre() {
    SmartSnapScenarios.availableEmptyStackIsDesktopButDisabledStacksNeverAre()
}

@Test func blockedPointsNeverSnapToTheDisplay() {
    SmartSnapScenarios.blockedPointsNeverSnapToTheDisplay()
}

@Test func admittedOwnWindowsWithoutTargetsStillOcclude() {
    SmartSnapScenarios.admittedOwnWindowsWithoutTargetsStillOcclude()
}

@Test func hierarchyAppendsTheDisplayAndDeduplicates() {
    SmartSnapScenarios.hierarchyAppendsTheDisplayAndDeduplicates()
}

@Test func hierarchySelectionKeepsTheUserDisplayChoice() {
    SmartSnapScenarios.hierarchySelectionKeepsTheUserDisplayChoice()
}

@Test func pressValidationCoversDisplayCandidates() {
    SmartSnapScenarios.pressValidationCoversDisplayCandidates()
}

@Test func windowServerBoundsSliverNeverPassesThrough() {
    SmartSnapScenarios.windowServerBoundsSliverNeverPassesThrough()
}

@Test func windowsExtendingIntoDisplayGapsNeverSnapThere() {
    SmartSnapScenarios.windowsExtendingIntoDisplayGapsNeverSnapThere()
}

@Test func windowServerShrinkDuringFreezeIsUnstable() {
    SmartSnapScenarios.windowServerShrinkDuringFreezeIsUnstable()
}

@Test func staticWindowServerDisagreementBlocksItsSliver() {
    SmartSnapScenarios.staticWindowServerDisagreementBlocksItsSliver()
}
#endif
