import CoreGraphics
import Foundation

/// One visible surface in the frozen desktop, ordered front to back.
public struct WindowStackEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A capture target that smart snapping may return when it is in scope.
        case selectable(WindowDescriptor)
        /// A visible surface that blocks every window beneath it but can never
        /// be selected: another app's floating panel, menu, banner, a window
        /// below the minimum size, or a window ScreenCaptureKit did not list.
        case occluder
    }

    public let windowID: CGWindowID
    /// AppKit global desktop coordinates. For a selectable entry this is the
    /// ScreenCaptureKit target frame used as the snap rectangle.
    public let frame: CGRect
    /// The Window Server bounds in AppKit coordinates. For a selectable entry
    /// they may differ from `frame` within the builder's tolerance; both
    /// freeze snapshots compare them, so a sub-point change is observable.
    public let windowServerFrame: CGRect
    public let processID: pid_t?
    public let kind: Kind

    public init(
        windowID: CGWindowID,
        frame: CGRect,
        windowServerFrame: CGRect? = nil,
        processID: pid_t?,
        kind: Kind
    ) {
        self.windowID = windowID
        self.frame = frame
        self.windowServerFrame = windowServerFrame ?? frame
        self.processID = processID
        self.kind = kind
    }

    /// The area this surface covers for hit testing: either source's bounds,
    /// so a sub-point disagreement can never expose what lies beneath.
    public var occlusionFrame: CGRect { frame.union(windowServerFrame) }

    /// Where both sources agree the surface is. Only here may a selectable
    /// entry become a target; the rest of `occlusionFrame` only blocks.
    public var agreedFrame: CGRect { frame.intersection(windowServerFrame) }

    public static func selectable(
        _ window: WindowDescriptor,
        windowServerFrame: CGRect? = nil
    ) -> WindowStackEntry {
        WindowStackEntry(
            windowID: window.id,
            frame: window.frame,
            windowServerFrame: windowServerFrame,
            processID: window.processID,
            kind: .selectable(window)
        )
    }

    public var selectableWindow: WindowDescriptor? {
        guard case .selectable(let window) = kind else { return nil }
        return window
    }
}

/// The frozen visible window stack together with the coordinate basis that was
/// current when it was captured, so later Accessibility queries interpret the
/// same desktop even if the display configuration changes underneath them.
public struct WindowStack: Equatable, Sendable {
    /// Whether the entries describe the frozen desktop at all. An available
    /// stack without entries is a desktop with no visible surfaces; an
    /// unavailable or invalidated stack carries no entries because nothing
    /// about the desktop is known, so every point must refuse snapping.
    public enum Availability: Equatable, Sendable {
        case available
        /// A Window Server snapshot could not be read.
        case unavailable
        /// The snapshots read around the freeze cannot be reconciled.
        case invalidated(WindowStackStability.InvalidationReason)
    }

    public let entries: [WindowStackEntry]
    public let primaryDisplayHeight: CGFloat
    /// AppKit regions where the stack read before freezing disagreed with the
    /// one read afterwards. Smart snapping is refused inside them.
    public let unstableRegions: [CGRect]
    public let availability: Availability

    public init(
        entries: [WindowStackEntry],
        primaryDisplayHeight: CGFloat,
        unstableRegions: [CGRect] = []
    ) {
        self.init(
            entries: entries,
            primaryDisplayHeight: primaryDisplayHeight,
            unstableRegions: unstableRegions,
            availability: .available
        )
    }

    private init(
        entries: [WindowStackEntry],
        primaryDisplayHeight: CGFloat,
        unstableRegions: [CGRect],
        availability: Availability
    ) {
        self.entries = entries
        self.primaryDisplayHeight = primaryDisplayHeight
        self.unstableRegions = unstableRegions
        self.availability = availability
    }

    public func withUnstableRegions(_ regions: [CGRect]) -> WindowStack {
        WindowStack(
            entries: entries,
            primaryDisplayHeight: primaryDisplayHeight,
            unstableRegions: unstableRegions + regions,
            availability: availability
        )
    }

    /// No snapshot was readable: snapping is disabled at every point.
    public static func unavailable(primaryDisplayHeight: CGFloat) -> WindowStack {
        WindowStack(
            entries: [],
            primaryDisplayHeight: primaryDisplayHeight,
            unstableRegions: [],
            availability: .unavailable
        )
    }

    /// The snapshots disagree beyond repair: snapping is disabled at every point.
    public static func invalidated(
        _ reason: WindowStackStability.InvalidationReason,
        primaryDisplayHeight: CGFloat
    ) -> WindowStack {
        WindowStack(
            entries: [],
            primaryDisplayHeight: primaryDisplayHeight,
            unstableRegions: [],
            availability: .invalidated(reason)
        )
    }

    public var isAvailable: Bool { availability == .available }

    public var selectableWindows: [WindowDescriptor] {
        entries.compactMap(\.selectableWindow)
    }

    /// Frames of every other visible surface owned by the same process, used
    /// to reject Accessibility results whose owning window is ambiguous.
    public func siblingFrames(of window: WindowDescriptor) -> [CGRect] {
        guard let processID = window.processID else { return [] }
        return entries.compactMap { entry in
            guard entry.windowID != window.id, entry.processID == processID else { return nil }
            return entry.frame
        }
    }
}

/// One Core Graphics on-screen window record. `bounds` uses Core Graphics
/// global coordinates (top-left origin of the primary display).
///
/// A record whose bounds are known but whose identity, owner or layer is
/// missing is retained as an unknown occluder: its pixels are in the frozen
/// image, so it must still block everything beneath it.
public struct WindowServerRecord: Equatable, Sendable {
    public let windowID: CGWindowID?
    public let processID: pid_t?
    public let ownerName: String?
    public let layer: Int?
    public let alpha: Double
    public let bounds: CGRect

    public init(
        windowID: CGWindowID?,
        processID: pid_t?,
        ownerName: String? = nil,
        layer: Int?,
        alpha: Double = 1,
        bounds: CGRect
    ) {
        self.windowID = windowID
        self.processID = processID
        self.ownerName = ownerName
        self.layer = layer
        self.alpha = alpha
        self.bounds = bounds
    }

    public var isComplete: Bool {
        windowID != nil && processID != nil && layer != nil
    }

    /// Parses `CGWindowListCopyWindowInfo` output, preserving its documented
    /// front-to-back order. Returns nil when any record has no readable,
    /// finite bounds: an unknown covered area makes the whole stack
    /// untrustworthy. Identity, owner and layer must be exact integers;
    /// anything else (Booleans, fractions, non-finite or out-of-range values)
    /// becomes nil so the record is kept as an unknown occluder and can never
    /// wrap into Ushot's process ID or the normal window layer. A missing or
    /// non-numeric alpha is treated as opaque.
    public static func records(
        fromWindowList list: [[String: Any]]
    ) -> (records: [WindowServerRecord], incompleteCount: Int)? {
        var records: [WindowServerRecord] = []
        records.reserveCapacity(list.count)
        var incomplete = 0
        for info in list {
            guard let bounds = finiteBounds(info[kCGWindowBounds as String]) else {
                return nil
            }
            let record = WindowServerRecord(
                windowID: exactInteger(info[kCGWindowNumber as String]),
                processID: exactInteger(info[kCGWindowOwnerPID as String]),
                ownerName: info[kCGWindowOwnerName as String] as? String,
                layer: exactInteger(info[kCGWindowLayer as String]),
                alpha: numericValue(info[kCGWindowAlpha as String]) ?? 1,
                bounds: bounds
            )
            if !record.isComplete { incomplete += 1 }
            records.append(record)
        }
        return (records, incomplete)
    }

    /// A non-Boolean `NSNumber`.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }

    private static func numericValue(_ value: Any?) -> Double? {
        number(value)?.doubleValue
    }

    static func exactInteger<T: FixedWidthInteger>(_ value: Any?) -> T? {
        guard let number = number(value) else { return nil }
        if CFNumberIsFloatType(number) {
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return T(exactly: double)
        }
        // Unsigned 64-bit values above Int64.max would wrap through int64Value.
        if String(cString: number.objCType) == "Q" {
            return T(exactly: number.uint64Value)
        }
        return T(exactly: number.int64Value)
    }

    private static func finiteBounds(_ value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary else { return nil }
        var components: [CGFloat] = []
        for key in ["X", "Y", "Width", "Height"] {
            // Validate before any CoreGraphics conversion: a string or NSNull
            // member must never reach `CGRect(dictionaryRepresentation:)`.
            guard let component = numericValue(dictionary[key]), component.isFinite else {
                return nil
            }
            components.append(CGFloat(component))
        }
        let rect = CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite
        else { return nil }
        return rect
    }
}

/// Builds the occlusion-aware frozen window stack.
///
/// Core Graphics is the ordering authority because `kCGWindowListOptionOnScreenOnly`
/// is documented front to back, whereas `SCShareableContent.windows` carries no
/// ordering guarantee. ScreenCaptureKit remains the authority for which windows
/// are capture targets.
public struct WindowStackBuilder: Sendable {
    public struct Statistics: Equatable, Sendable {
        public var selectable = 0
        public var occluders = 0
        public var incompleteOccluders = 0
        public var skippedTransparent = 0
        public var skippedDesktopLevel = 0
        public var skippedMenuBar = 0
        public var skippedMenuBarIndicators = 0
        public var skippedDockSurface = 0
        public var skippedOwnApplication = 0
        public var geometryConflicts = 0
        public var selectableMissingFromWindowServer = 0

        public init() {}
    }

    /// Owner names Core Graphics reports for the system menu bar. The value is
    /// not localized (verified under a Chinese system locale).
    public static let systemMenuBarOwnerNames: Set<String> = ["Window Server"]
    /// The tallest system menu bar strip, including notched displays.
    public static let maximumMenuBarHeight: CGFloat = 64

    public let ownProcessID: pid_t
    public let dockProcessIDs: Set<pid_t>
    /// Display bounds in Core Graphics global coordinates.
    public let displayBounds: [CGRect]
    public let mainMenuWindowLevel: Int
    public let dockWindowLevel: Int
    /// The plane of the screen-capture status indicators Window Server adds to
    /// every menu bar while a capture runs.
    public let cursorWindowLevel: Int
    /// Maximum per-edge difference between ScreenCaptureKit and Core Graphics
    /// bounds before the record is treated as a conflicting occluder.
    public let geometryTolerance: CGFloat

    public init(
        ownProcessID: pid_t,
        dockProcessIDs: Set<pid_t>,
        displayBounds: [CGRect],
        mainMenuWindowLevel: Int = Int(CGWindowLevelForKey(.mainMenuWindow)),
        dockWindowLevel: Int = Int(CGWindowLevelForKey(.dockWindow)),
        cursorWindowLevel: Int = Int(CGWindowLevelForKey(.cursorWindow)),
        geometryTolerance: CGFloat = 1
    ) {
        self.ownProcessID = ownProcessID
        self.dockProcessIDs = dockProcessIDs
        self.displayBounds = displayBounds
        self.mainMenuWindowLevel = mainMenuWindowLevel
        self.dockWindowLevel = dockWindowLevel
        self.cursorWindowLevel = cursorWindowLevel
        self.geometryTolerance = geometryTolerance
    }

    /// - Parameters:
    ///   - records: Core Graphics on-screen records in front-to-back order.
    ///   - selectableWindows: ScreenCaptureKit-derived capture targets keyed by
    ///     window ID, already filtered for size, owner and own-window admission.
    ///   - transformer: Converts Core Graphics bounds to AppKit coordinates.
    ///   - admittedOwnWindowIDs: Every Ushot window the capture filter keeps
    ///     in the frozen pixels. One without a selectable descriptor (for
    ///     example below the minimum target size) still occludes.
    public func build(
        records: [WindowServerRecord],
        selectableWindows: [CGWindowID: WindowDescriptor],
        transformer: CoordinateTransformer,
        admittedOwnWindowIDs: Set<CGWindowID> = []
    ) -> (stack: WindowStack, statistics: Statistics) {
        var statistics = Statistics()
        var entries: [WindowStackEntry] = []
        entries.reserveCapacity(records.count)
        var placedSelectableIDs: Set<CGWindowID> = []
        let menuBars = confirmedMenuBars(in: records)

        func appendOccluder(_ record: WindowServerRecord, frame: CGRect) {
            entries.append(WindowStackEntry(
                windowID: record.windowID ?? kCGNullWindowID,
                frame: frame,
                processID: record.processID,
                kind: .occluder
            ))
            statistics.occluders += 1
        }

        for record in records {
            // Only an exactly zero alpha (either sign) proves the window adds
            // no pixels; NaN, negative or other unexpected values occlude.
            guard record.alpha != 0 else {
                statistics.skippedTransparent += 1
                continue
            }
            let frame = transformer.appKitRect(fromScreenCaptureRect: record.bounds).standardized
            guard let windowID = record.windowID,
                  let processID = record.processID,
                  let layer = record.layer
            else {
                // Unknown identity or plane: fail closed and block.
                statistics.incompleteOccluders += 1
                appendOccluder(record, frame: frame)
                continue
            }
            // Desktop picture, desktop icons and similar planes sit below every
            // normal window and can never cover a capture target.
            guard layer >= 0 else {
                statistics.skippedDesktopLevel += 1
                continue
            }
            if processID == ownProcessID {
                // Unadmitted Ushot windows are excluded from the frozen pixels,
                // so they neither occlude nor become targets.
                guard let window = selectableWindows[windowID],
                      window.isOwnApplicationWindow
                else {
                    if admittedOwnWindowIDs.contains(windowID) {
                        // Admitted pixels without a target descriptor are
                        // still in the frozen image and must block.
                        appendOccluder(record, frame: frame)
                    } else {
                        statistics.skippedOwnApplication += 1
                    }
                    continue
                }
                guard matches(window.frame, frame) else {
                    // Admitted pixels are in the frozen image, so a window
                    // with conflicting geometry still blocks what lies beneath.
                    statistics.geometryConflicts += 1
                    appendOccluder(record, frame: frame)
                    continue
                }
                entries.append(.selectable(window, windowServerFrame: frame))
                placedSelectableIDs.insert(window.id)
                statistics.selectable += 1
                continue
            }
            // The product contract keeps the system menu bar and the Dock from
            // hiding windows. Both are recognized by owner, level and geometry,
            // so a third-party panel at the same level still occludes.
            if menuBarDisplay(of: record, layer: layer) != nil {
                statistics.skippedMenuBar += 1
                continue
            }
            if isMenuBarIndicator(record, processID: processID, layer: layer, menuBars: menuBars) {
                statistics.skippedMenuBarIndicators += 1
                continue
            }
            if layer == dockWindowLevel, dockProcessIDs.contains(processID) {
                statistics.skippedDockSurface += 1
                continue
            }

            if let window = selectableWindows[windowID],
               !window.isOwnApplicationWindow,
               window.processID == processID,
               window.layer == 0,
               layer == 0
            {
                if matches(window.frame, frame) {
                    entries.append(.selectable(window, windowServerFrame: frame))
                    placedSelectableIDs.insert(window.id)
                    statistics.selectable += 1
                    continue
                }
                statistics.geometryConflicts += 1
            }
            appendOccluder(record, frame: frame)
        }
        // A capture target without a trustworthy z position cannot be placed
        // relative to occluders, so it is never appended as a candidate.
        statistics.selectableMissingFromWindowServer = selectableWindows.keys
            .filter { !placedSelectableIDs.contains($0) }
            .count
        // Its pixels may still be in the frozen image, so a target with no
        // Window Server record at all is kept beneath every ordered surface:
        // it never outranks them, but exposed desktop is never asserted there.
        let recordedWindowIDs = Set(records.compactMap(\.windowID))
        for window in selectableWindows.values.sorted(by: { $0.id < $1.id })
        where !recordedWindowIDs.contains(window.id) {
            entries.append(WindowStackEntry(
                windowID: window.id,
                frame: window.frame,
                processID: window.processID,
                kind: .occluder
            ))
            statistics.occluders += 1
        }
        return (
            WindowStack(entries: entries, primaryDisplayHeight: transformer.primaryDisplayHeight),
            statistics
        )
    }

    /// The system menu bar is one Window Server strip per display: main-menu
    /// level, flush with the display's top edge and spanning its full width.
    /// Returns the Core Graphics bounds of the display it belongs to.
    private func menuBarDisplay(of record: WindowServerRecord, layer: Int) -> CGRect? {
        guard layer == mainMenuWindowLevel,
              let ownerName = record.ownerName,
              Self.systemMenuBarOwnerNames.contains(ownerName),
              record.bounds.height > 0,
              record.bounds.height <= Self.maximumMenuBarHeight
        else { return nil }
        return displayBounds.first { display in
            abs(record.bounds.minX - display.minX) <= geometryTolerance
                && abs(record.bounds.minY - display.minY) <= geometryTolerance
                && abs(record.bounds.width - display.width) <= geometryTolerance
        }
    }

    private struct ConfirmedMenuBar {
        /// Core Graphics bounds of the display and of its menu bar strip.
        let display: CGRect
        let strip: CGRect
        let processID: pid_t
    }

    /// Visible system menu bars of one snapshot, independent of record order.
    private func confirmedMenuBars(in records: [WindowServerRecord]) -> [ConfirmedMenuBar] {
        records.compactMap { record in
            guard record.alpha != 0,
                  record.windowID != nil,
                  let processID = record.processID,
                  let layer = record.layer,
                  let display = menuBarDisplay(of: record, layer: layer)
            else { return nil }
            return ConfirmedMenuBar(display: display, strip: record.bounds, processID: processID)
        }
    }

    /// Window Server places a screen-capture status indicator at cursor level
    /// on every menu bar while any capture runs, including Ushot's own freeze.
    /// It is as transparent to hit testing as the menu bar itself, but only
    /// while every visible part of it lies inside a confirmed menu bar of the
    /// same snapshot. Its frame may extend past the desktop edge; a part that
    /// covers another display's content keeps the whole record occluding, and
    /// so does a hidden menu bar (full-screen or auto-hide), where the
    /// indicator sits above application pixels.
    private func isMenuBarIndicator(
        _ record: WindowServerRecord,
        processID: pid_t,
        layer: Int,
        menuBars: [ConfirmedMenuBar]
    ) -> Bool {
        guard layer == cursorWindowLevel,
              let ownerName = record.ownerName,
              Self.systemMenuBarOwnerNames.contains(ownerName)
        else { return false }
        var isVisible = false
        for display in displayBounds {
            let visiblePart = record.bounds.intersection(display)
            guard !visiblePart.isNull, visiblePart.width > 0, visiblePart.height > 0 else { continue }
            isVisible = true
            guard menuBars.contains(where: { menuBar in
                menuBar.display == display
                    && menuBar.processID == processID
                    && containsExactly(menuBar.strip, visiblePart)
            }) else { return false }
        }
        return isVisible
    }

    /// No tolerance: the off-display overhang is already clipped, so any
    /// remaining excess, however small, covers another display's content.
    private func containsExactly(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let outer = outer.standardized
        let inner = inner.standardized
        return inner.minX >= outer.minX
            && inner.minY >= outer.minY
            && inner.maxX <= outer.maxX
            && inner.maxY <= outer.maxY
    }

    private func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= geometryTolerance
            && abs(lhs.minY - rhs.minY) <= geometryTolerance
            && abs(lhs.maxX - rhs.maxX) <= geometryTolerance
            && abs(lhs.maxY - rhs.maxY) <= geometryTolerance
    }
}

/// Compares the window stack read before freezing the displays with the one
/// read afterwards. Displays are captured one after another, so a surface that
/// appeared, vanished, moved or changed order meanwhile may be present in some
/// frozen pixels but not in the earlier stack. Snapping is refused wherever the
/// two snapshots disagree.
///
/// Guarantee: for every point outside the returned unstable regions of a
/// session that is not invalidated, both snapshots have the same topmost
/// surface. A moving or resizing surface is covered by the union of its two
/// frames, which contains every intermediate position of a monotonic
/// transition (straight drags, eased animations, scaling, cross-display moves).
///
/// Inherent limits of two samples: a surface that appears and vanishes
/// entirely between the reads, a non-monotonic path (overshoot, a curved slide
/// outside the union) and a single frame captured mid-slide are not observable.
public enum WindowStackStability {
    /// Privacy-safe change counts; never window titles or application names.
    public struct ChangeCounts: Equatable, Sendable {
        public var changed = 0
        public var appeared = 0
        public var disappeared = 0
        public var reordered = 0

        public init(changed: Int = 0, appeared: Int = 0, disappeared: Int = 0, reordered: Int = 0) {
            self.changed = changed
            self.appeared = appeared
            self.disappeared = disappeared
            self.reordered = reordered
        }
    }

    public enum InvalidationReason: String, Equatable, Sendable {
        case primaryDisplayChanged = "primary-display-changed"
        /// A surface without a window ID exists in only one snapshot, so its
        /// path cannot be bounded.
        case unpairedUnknownSurface = "unpaired-unknown-surface"
        /// One snapshot lists the same identity more than once.
        case duplicateIdentity = "duplicate-identity"
    }

    public struct Result: Equatable, Sendable {
        /// AppKit regions in which the snapshots disagree.
        public let unstableRegions: [CGRect]
        public let invalidationReason: InvalidationReason?
        public let changes: ChangeCounts

        public var invalidatesSession: Bool { invalidationReason != nil }
        public var isStable: Bool { !invalidatesSession && unstableRegions.isEmpty }

        static func invalidated(_ reason: InvalidationReason, changes: ChangeCounts = ChangeCounts()) -> Result {
            Result(unstableRegions: [], invalidationReason: reason, changes: changes)
        }
    }

    public enum Outcome: String, Sendable {
        case stable
        /// Snapping is refused only where the snapshots disagree.
        case partiallyUnstable = "partially-unstable"
        /// A snapshot could not be read; snapping is disabled for the session.
        case unavailable
        /// The snapshots cannot be reconciled; snapping is disabled for the session.
        case invalidated
    }

    /// Chooses the stack a region session may snap against. Manual selection
    /// on the frozen pixels is unaffected by every outcome.
    public static func reconcile(
        before: WindowStack?,
        after: WindowStack?,
        primaryDisplayHeight: CGFloat
    ) -> (stack: WindowStack, outcome: Outcome, result: Result?) {
        guard let before, let after, before.isAvailable, after.isAvailable else {
            return (.unavailable(primaryDisplayHeight: primaryDisplayHeight), .unavailable, nil)
        }
        let result = compare(before: before, after: after)
        if let reason = result.invalidationReason {
            return (
                .invalidated(reason, primaryDisplayHeight: before.primaryDisplayHeight),
                .invalidated,
                result
            )
        }
        if result.unstableRegions.isEmpty {
            return (before, .stable, result)
        }
        return (before.withUnstableRegions(result.unstableRegions), .partiallyUnstable, result)
    }

    /// Privacy-safe, never-trapping summary of up to `limit` regions as
    /// `(x,y,WxH)` whole points. A finite coordinate outside `Int` is written
    /// as `overflow`; window bounds are validated only for finiteness.
    public static func diagnosticSummary(of regions: [CGRect], limit: Int = 8) -> String {
        func component(_ value: CGFloat) -> String {
            Int(exactly: value.rounded()).map(String.init) ?? "overflow"
        }
        let summary = regions.prefix(max(limit, 0)).map { region in
            let rect = region.standardized
            return "(\(component(rect.minX)),\(component(rect.minY)),\(component(rect.width))x\(component(rect.height)))"
        }.joined(separator: ",")
        return summary.isEmpty ? "none" : summary
    }

    public static func compare(before: WindowStack, after: WindowStack) -> Result {
        guard before.primaryDisplayHeight == after.primaryDisplayHeight else {
            return .invalidated(.primaryDisplayChanged)
        }
        if before.entries == after.entries {
            return Result(unstableRegions: [], invalidationReason: nil, changes: ChangeCounts())
        }
        guard let beforeByKey = uniqueIndex(before.entries),
              let afterByKey = uniqueIndex(after.entries)
        else {
            return .invalidated(.duplicateIdentity)
        }
        var changes = ChangeCounts()
        var regions: [CGRect] = []
        for entry in before.entries {
            let key = key(for: entry)
            guard let counterpart = afterByKey[key] else {
                if entry.windowID == kCGNullWindowID {
                    return .invalidated(.unpairedUnknownSurface, changes: changes)
                }
                changes.disappeared += 1
                regions.append(entry.occlusionFrame)
                continue
            }
            if counterpart != entry {
                // One envelope covers every position of a monotonic transition.
                changes.changed += 1
                regions.append(entry.occlusionFrame.union(counterpart.occlusionFrame))
            }
        }
        for entry in after.entries where beforeByKey[key(for: entry)] == nil {
            if entry.windowID == kCGNullWindowID {
                return .invalidated(.unpairedUnknownSurface, changes: changes)
            }
            changes.appeared += 1
            regions.append(entry.occlusionFrame)
        }
        // Overlapping surfaces whose relative order flipped. Each side uses
        // its complete envelope so a concurrent move is covered too.
        let commonKeys = Set(beforeByKey.keys).intersection(afterByKey.keys)
        let beforeOrder = before.entries.map(key(for:)).filter(commonKeys.contains)
        var afterIndex: [EntryKey: Int] = [:]
        for (index, key) in after.entries.map(key(for:)).filter(commonKeys.contains).enumerated() {
            afterIndex[key] = index
        }
        for (i, upper) in beforeOrder.enumerated() {
            for lower in beforeOrder[(i + 1)...] {
                guard let upperIndex = afterIndex[upper],
                      let lowerIndex = afterIndex[lower],
                      upperIndex > lowerIndex,
                      let upperBefore = beforeByKey[upper], let upperAfter = afterByKey[upper],
                      let lowerBefore = beforeByKey[lower], let lowerAfter = afterByKey[lower]
                else { continue }
                let overlap = upperBefore.occlusionFrame.union(upperAfter.occlusionFrame)
                    .intersection(lowerBefore.occlusionFrame.union(lowerAfter.occlusionFrame))
                if !overlap.isNull, !overlap.isEmpty {
                    changes.reordered += 1
                    regions.append(overlap)
                }
            }
        }
        return Result(
            unstableRegions: regions.filter { !$0.isNull && !$0.isEmpty },
            invalidationReason: nil,
            changes: changes
        )
    }

    private struct EntryKey: Hashable {
        let windowID: CGWindowID
        /// Unknown-identity records are keyed by their geometry.
        let unknownFrame: [CGFloat]?
    }

    private static func key(for entry: WindowStackEntry) -> EntryKey {
        if entry.windowID == kCGNullWindowID {
            let frame = entry.frame
            return EntryKey(windowID: kCGNullWindowID, unknownFrame: [frame.minX, frame.minY, frame.width, frame.height])
        }
        return EntryKey(windowID: entry.windowID, unknownFrame: nil)
    }

    /// Returns nil when any identity occurs more than once.
    private static func uniqueIndex(_ entries: [WindowStackEntry]) -> [EntryKey: WindowStackEntry]? {
        var index: [EntryKey: WindowStackEntry] = [:]
        for entry in entries {
            let key = key(for: entry)
            guard index[key] == nil else { return nil }
            index[key] = entry
        }
        return index
    }
}

/// Which windows smart region snapping may return. Visible committed pinned
/// images are always in scope; everything else depends on the application that
/// was frontmost when the capture started.
public struct SmartSnapScope: Equatable, Sendable {
    public enum Origin: String, Sendable {
        /// Another application was frontmost.
        case frontmostApplication = "frontmost-application"
        /// Ushot was frontmost; its admitted interface windows plus the most
        /// recent other frontmost application are in scope.
        case ushotWithPreviousApplication = "ushot-with-previous-application"
        /// Ushot was frontmost and no previous application is known.
        case ushotOnly = "ushot-only"
        /// No frontmost application could be determined.
        case pinnedImagesOnly = "pinned-images-only"
    }

    public let applicationProcessIDs: Set<pid_t>
    public let includesOwnInterfaceWindows: Bool
    public let origin: Origin

    public init(
        applicationProcessIDs: Set<pid_t>,
        includesOwnInterfaceWindows: Bool,
        origin: Origin
    ) {
        self.applicationProcessIDs = applicationProcessIDs
        self.includesOwnInterfaceWindows = includesOwnInterfaceWindows
        self.origin = origin
    }

    public static let pinnedImagesOnly = SmartSnapScope(
        applicationProcessIDs: [],
        includesOwnInterfaceWindows: false,
        origin: .pinnedImagesOnly
    )

    /// - Parameters:
    ///   - frontmostProcessID: The frontmost application when capture started.
    ///   - ownProcessID: Ushot's process.
    ///   - previousApplicationProcessID: The most recent non-Ushot frontmost
    ///     application that is still running.
    public static func resolve(
        frontmostProcessID: pid_t?,
        ownProcessID: pid_t,
        previousApplicationProcessID: pid_t?
    ) -> SmartSnapScope {
        guard let frontmostProcessID else { return .pinnedImagesOnly }
        guard frontmostProcessID == ownProcessID else {
            return SmartSnapScope(
                applicationProcessIDs: [frontmostProcessID],
                includesOwnInterfaceWindows: false,
                origin: .frontmostApplication
            )
        }
        if let previousApplicationProcessID, previousApplicationProcessID != ownProcessID {
            return SmartSnapScope(
                applicationProcessIDs: [previousApplicationProcessID],
                includesOwnInterfaceWindows: true,
                origin: .ushotWithPreviousApplication
            )
        }
        return SmartSnapScope(
            applicationProcessIDs: [],
            includesOwnInterfaceWindows: true,
            origin: .ushotOnly
        )
    }

    public func admits(_ window: WindowDescriptor) -> Bool {
        if window.isPinnedImage { return true }
        if window.isOwnInterfaceWindow { return includesOwnInterfaceWindows }
        guard window.layer == 0, let processID = window.processID else { return false }
        return applicationProcessIDs.contains(processID)
    }
}

public enum SmartSnapWindowHit: Equatable, Sendable {
    case target(WindowDescriptor)
    /// The topmost visible surface at the point is not an in-scope target,
    /// or the stack cannot vouch for the point at all.
    case blocked(SmartSnapBlockReason)
    /// The stack is available and no visible surface participating in hit
    /// testing covers the point: the frozen desktop shows through.
    case desktop
}

public enum SmartSnapBlockReason: String, Equatable, Sendable {
    case occluded
    case outOfScope = "out-of-scope"
    /// The window stack changed while the displays were being frozen here.
    case unstable = "unstable-stack"
    /// No Window Server snapshot could be read for this session.
    case unavailable = "stack-unavailable"
    /// The snapshots around the freeze could not be reconciled.
    case invalidated = "stack-invalidated"
}

/// Occlusion-aware smart-snap hit testing: the topmost visible surface at the
/// pointer decides. Snapping never passes through a surface to reach a window
/// or the desktop beneath it.
public struct SmartSnapWindowResolver: Sendable {
    public init() {}

    public func resolve(
        at point: CGPoint,
        in stack: WindowStack,
        scope: SmartSnapScope
    ) -> SmartSnapWindowHit {
        switch stack.availability {
        case .available: break
        case .unavailable: return .blocked(.unavailable)
        case .invalidated: return .blocked(.invalidated)
        }
        if stack.unstableRegions.contains(where: { $0.contains(point) }) {
            return .blocked(.unstable)
        }
        guard let entry = stack.entries.first(where: { $0.occlusionFrame.contains(point) }) else {
            return .desktop
        }
        guard let window = entry.selectableWindow else { return .blocked(.occluded) }
        guard scope.admits(window) else { return .blocked(.outOfScope) }
        // The sliver where Window Server and ScreenCaptureKit bounds disagree,
        // in either direction, belongs to this surface but not to its target.
        return entry.agreedFrame.contains(point) ? .target(window) : .blocked(.occluded)
    }

    /// Resolves what the pointer would snap to: an in-scope window together
    /// with the frozen display under the pointer, or that whole display when
    /// the desktop is exposed there. A point outside every frozen display
    /// (a gap between displays or the outermost edge) never snaps, even where
    /// a window extends into it.
    public func resolvePointer(
        at point: CGPoint,
        in stack: WindowStack,
        scope: SmartSnapScope,
        geometry: ScreenGeometry
    ) -> SmartSnapPointerTarget {
        guard let display = geometry.display(containing: point) else {
            return .cleared(.noDisplay)
        }
        switch resolve(at: point, in: stack, scope: scope) {
        case .blocked(let reason):
            return .cleared(.blocked(reason))
        case .desktop:
            return .desktop(display)
        case .target(let window):
            return .window(window, display: display)
        }
    }
}

public enum SmartSnapClearReason: Equatable, Sendable {
    case blocked(SmartSnapBlockReason)
    case noDisplay

    public var logValue: String {
        switch self {
        case .blocked(let reason): return reason.rawValue
        case .noDisplay: return "no-display"
        }
    }
}

public enum SmartSnapPointerTarget: Equatable, Sendable {
    case window(WindowDescriptor, display: DisplayGeometry)
    case desktop(DisplayGeometry)
    case cleared(SmartSnapClearReason)

    public var source: SmartSnapSource? {
        switch self {
        case .window(let window, let display): return .window(window.id, displayID: display.id)
        case .desktop(let display): return .desktop(displayID: display.id)
        case .cleared: return nil
        }
    }
}

/// What produced the current smart-snap hierarchy.
public enum SmartSnapSource: Equatable, Sendable {
    /// An in-scope window hit; `displayID` is the display under the pointer.
    case window(CGWindowID, displayID: CGDirectDisplayID)
    /// Exposed desktop on one display.
    case desktop(displayID: CGDirectDisplayID)

    public var windowID: CGWindowID? {
        guard case .window(let id, _) = self else { return nil }
        return id
    }

    public var displayID: CGDirectDisplayID {
        switch self {
        case .window(_, let displayID): return displayID
        case .desktop(let displayID): return displayID
        }
    }

    /// Privacy-safe identifiers only; never titles or application names.
    public var diagnosticDescription: String {
        switch self {
        case .window(let windowID, let displayID):
            return "window:\(windowID)@display:\(displayID)"
        case .desktop(let displayID):
            return "desktop@display:\(displayID)"
        }
    }

    /// Mouse-down repeats the hover resolution at the press point. A desktop
    /// candidate requires exposed desktop on the same display; a window-derived
    /// candidate requires the same window to own the press point, and a
    /// display level chosen from inside that window additionally requires the
    /// same display. Any blocked or cleared press rejects.
    public func acceptsPress(
        _ press: SmartSnapPointerTarget,
        selectedKind: SmartSnapTarget.Kind
    ) -> Bool {
        guard let pressSource = press.source else { return false }
        switch self {
        case .desktop(let displayID):
            return selectedKind == .display && pressSource == .desktop(displayID: displayID)
        case .window(let windowID, let displayID):
            guard case .window(let pressWindowID, let pressDisplayID) = pressSource,
                  pressWindowID == windowID
            else { return false }
            return selectedKind != .display || pressDisplayID == displayID
        }
    }
}

/// One selectable smart-snap level.
public struct SmartSnapTarget: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case interfaceElement = "interface-element"
        case window
        case display
    }

    public let frame: CGRect
    public let kind: Kind

    public init(frame: CGRect, kind: Kind) {
        self.frame = frame
        self.kind = kind
    }
}

/// Builds the child-to-parent smart-snap levels and keeps the user's chosen
/// level across rebuilds.
public enum SmartSnapHierarchy {
    /// Levels ordered child to parent: verified controls (deepest first), the
    /// window, then the display under the pointer. Identical rectangles appear
    /// once: a control equal to the window or display is omitted, and a
    /// display equal to the window (a full-screen window) keeps the window.
    public static func targets(
        controlFrames: [CGRect],
        windowFrame: CGRect?,
        displayFrame: CGRect?
    ) -> [SmartSnapTarget] {
        var targets: [SmartSnapTarget] = []
        for frame in controlFrames
        where frame != windowFrame
            && frame != displayFrame
            && !targets.contains(where: { $0.frame == frame })
        {
            targets.append(SmartSnapTarget(frame: frame, kind: .interfaceElement))
        }
        if let windowFrame {
            targets.append(SmartSnapTarget(frame: windowFrame, kind: .window))
        }
        if let displayFrame, displayFrame != windowFrame {
            targets.append(SmartSnapTarget(frame: displayFrame, kind: .display))
        }
        return targets
    }

    /// Chooses the selected level of a rebuilt hierarchy for the same source
    /// window. A user-selected level persists only while the deepest level is
    /// unchanged; otherwise the deepest level is selected. A level whose
    /// rectangle changed keeps its distance from the top, so a selected display
    /// follows the pointer to another display, and one that collapses into a
    /// full-screen window leaves the window selected.
    ///
    /// - Returns: The selected index and whether it is still a user choice.
    public static func selection(
        in targets: [SmartSnapTarget],
        previousTargets: [SmartSnapTarget],
        previousSelectedIndex: Int,
        previousUserAdjusted: Bool
    ) -> (index: Int, userAdjusted: Bool) {
        precondition(!targets.isEmpty, "A smart-snap hierarchy requires at least one level.")
        guard previousTargets.indices.contains(previousSelectedIndex),
              previousTargets.first == targets.first
        else { return (0, false) }
        let previous = previousTargets[previousSelectedIndex]
        if let matched = targets.firstIndex(of: previous) {
            return (matched, previousUserAdjusted)
        }
        guard previousUserAdjusted else { return (0, false) }
        // The display is always the top level, so a chosen display follows
        // the pointer to another display by keeping its distance from the top.
        let levelFromTop = previousTargets.count - 1 - previousSelectedIndex
        return (max(0, targets.count - 1 - levelFromTop), true)
    }
}
