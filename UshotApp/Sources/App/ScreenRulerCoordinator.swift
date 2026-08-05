import AppKit
import CoreGraphics
import UshotCore

@MainActor
final class ScreenRulerCoordinator {
    var onError: ((Error) -> Void)?
    var isSessionActive: Bool { !panels.isEmpty }

    private var panels: [PixelToolOverlayPanel] = []
    private var views: [ScreenRulerOverlayView] = []
    private var calculator: ScreenMeasurementCalculator?
    private var shape: MeasurementShape = .rectangle
    private var startPoint: CGPoint?
    private var endPoint: CGPoint?
    private var pointerPoint: CGPoint?
    private var measurement: ScreenMeasurement?
    private var isDragging = false
    private var didPushCursor = false

    func start() {
        guard panels.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            let displays = try currentDisplayDescriptors()
            calculator = ScreenMeasurementCalculator(displays: displays)
            pointerPoint = initialPoint(in: displays)
            try present(displays: displays)
            invalidateViews()
            AppLog.screenRuler.notice("Screen ruler presented across \(displays.count, privacy: .public) display(s)")
        } catch {
            fail(error)
        }
    }

    func cancel() {
        cleanup()
    }

    fileprivate func mouseMoved(to point: CGPoint) {
        pointerPoint = point
        invalidateViews()
    }

    fileprivate func mouseDown(at point: CGPoint) {
        pointerPoint = point
        startPoint = point
        endPoint = point
        isDragging = true
        updateMeasurement()
    }

    fileprivate func mouseDragged(to point: CGPoint, constrained: Bool) {
        guard let startPoint, let calculator else { return }
        pointerPoint = point
        endPoint = constrained ? calculator.constrainedEnd(start: startPoint, proposedEnd: point) : point
        updateMeasurement()
    }

    fileprivate func mouseUp(at point: CGPoint, constrained: Bool) {
        mouseDragged(to: point, constrained: constrained)
        isDragging = false
        invalidateViews()
    }

    fileprivate func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cleanup()
            return
        }
        if event.keyCode == 8, event.modifierFlags.contains(.command) {
            copyMeasurement()
            return
        }
        if event.keyCode == 48 {
            shape = shape == .rectangle ? .line : .rectangle
            updateMeasurement()
            return
        }
        if event.keyCode == 15 {
            restart()
            return
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            nudgeEndpoint(keyCode: event.keyCode, largeStep: event.modifierFlags.contains(.shift))
        }
    }

    fileprivate func drawState(for panelFrame: CGRect) -> ScreenRulerDrawState {
        ScreenRulerDrawState(
            panelFrame: panelFrame,
            pointerPoint: pointerPoint,
            startPoint: startPoint,
            endPoint: endPoint,
            shape: shape,
            measurement: measurement,
            isDragging: isDragging
        )
    }

    private func present(displays: [DisplayDescriptor]) throws {
        var keyPanel: PixelToolOverlayPanel?
        for screen in NSScreen.screens {
            guard
                let displayID = displayID(for: screen),
                displays.contains(where: { $0.id == displayID })
            else { continue }
            let view = ScreenRulerOverlayView(coordinator: self)
            let panel = PixelToolOverlayPanel(screen: screen, contentView: view)
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
            if pointerPoint.map(screen.frame.contains) == true { keyPanel = panel }
        }
        guard !panels.isEmpty else { throw ScreenshotAppError.noDisplayAvailable }
        NSCursor.crosshair.push()
        didPushCursor = true
        let panel = keyPanel ?? panels[0]
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    private func initialPoint(in displays: [DisplayDescriptor]) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        if displays.contains(where: { $0.frame.contains(mouse) }) { return mouse }
        return CGPoint(x: displays[0].frame.midX, y: displays[0].frame.midY)
    }

    private func updateMeasurement() {
        guard let calculator, let startPoint, let endPoint else {
            measurement = nil
            invalidateViews()
            return
        }
        do {
            measurement = try calculator.measurement(shape: shape, start: startPoint, end: endPoint)
            invalidateViews()
        } catch {
            fail(error)
        }
    }

    private func nudgeEndpoint(keyCode: UInt16, largeStep: Bool) {
        guard
            let calculator,
            let endPoint,
            let display = calculator.displays.first(where: { $0.frame.contains(endPoint) })
        else {
            NSSound.beep()
            return
        }
        let step = CGFloat(largeStep ? 10 : 1) / display.scale
        var next = endPoint
        switch keyCode {
        case 123: next.x -= step
        case 124: next.x += step
        case 125: next.y -= step
        default: next.y += step
        }
        let inset = 0.5 / display.scale
        next.x = min(max(next.x, display.frame.minX + inset), display.frame.maxX - inset)
        next.y = min(max(next.y, display.frame.minY + inset), display.frame.maxY - inset)
        self.endPoint = next
        pointerPoint = next
        updateMeasurement()
    }

    private func copyMeasurement() {
        guard let measurement else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(measurement.copyRepresentation, forType: .string) else {
            fail(ScreenshotAppError.exportFailed(description: "The measurement could not be written to the pasteboard."))
            return
        }
        AppLog.export.notice("Copied screen ruler measurement at \(measurement.displayScale, privacy: .public)x")
    }

    private func restart() {
        startPoint = nil
        endPoint = nil
        measurement = nil
        isDragging = false
        invalidateViews()
    }

    private func invalidateViews() {
        views.forEach { $0.needsDisplay = true }
    }

    private func fail(_ error: Error) {
        AppLog.screenRuler.error("Screen ruler failed: \(error.localizedDescription, privacy: .public)")
        cleanup()
        onError?(error)
    }

    private func cleanup() {
        panels.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        panels.removeAll()
        views.removeAll()
        calculator = nil
        startPoint = nil
        endPoint = nil
        pointerPoint = nil
        measurement = nil
        isDragging = false
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}

private struct ScreenRulerDrawState {
    let panelFrame: CGRect
    let pointerPoint: CGPoint?
    let startPoint: CGPoint?
    let endPoint: CGPoint?
    let shape: MeasurementShape
    let measurement: ScreenMeasurement?
    let isDragging: Bool
}

@MainActor
private final class ScreenRulerOverlayView: NSView {
    private weak var coordinator: ScreenRulerCoordinator?
    private var trackingAreaReference: NSTrackingArea?

    init(coordinator: ScreenRulerCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Screen ruler", comment: "Screen ruler overlay"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) { coordinator?.mouseMoved(to: globalPoint(for: event)) }
    override func mouseDown(with event: NSEvent) { coordinator?.mouseDown(at: globalPoint(for: event)) }
    override func mouseDragged(with event: NSEvent) {
        coordinator?.mouseDragged(
            to: globalPoint(for: event),
            constrained: event.modifierFlags.contains(.shift)
        )
    }
    override func mouseUp(with event: NSEvent) {
        coordinator?.mouseUp(
            at: globalPoint(for: event),
            constrained: event.modifierFlags.contains(.shift)
        )
    }
    override func keyDown(with event: NSEvent) { coordinator?.keyDown(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let coordinator else { return }
        let state = coordinator.drawState(for: window.frame)
        drawCrosshair(state)
        drawMeasurement(state)
    }

    private func drawCrosshair(_ state: ScreenRulerDrawState) {
        guard let pointer = state.pointerPoint, state.panelFrame.contains(pointer) else { return }
        let local = localPoint(pointer, panelFrame: state.panelFrame)
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: local.x - 10, y: local.y))
        path.line(to: CGPoint(x: local.x + 10, y: local.y))
        path.move(to: CGPoint(x: local.x, y: local.y - 10))
        path.line(to: CGPoint(x: local.x, y: local.y + 10))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawMeasurement(_ state: ScreenRulerDrawState) {
        guard let start = state.startPoint, let end = state.endPoint else {
            drawHint(state)
            return
        }
        let localStart = localPoint(start, panelFrame: state.panelFrame)
        let localEnd = localPoint(end, panelFrame: state.panelFrame)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSColor.controlAccentColor.setStroke()

        if state.shape == .rectangle {
            let rect = CGRect(
                x: min(localStart.x, localEnd.x),
                y: min(localStart.y, localEnd.y),
                width: abs(localEnd.x - localStart.x),
                height: abs(localEnd.y - localStart.y)
            )
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 2
            path.fill()
            path.stroke()
            let diagonal = NSBezierPath()
            diagonal.move(to: localStart)
            diagonal.line(to: localEnd)
            diagonal.lineWidth = 1
            diagonal.setLineDash([5, 4], count: 2, phase: 0)
            diagonal.stroke()
        } else {
            let path = NSBezierPath()
            path.move(to: localStart)
            path.line(to: localEnd)
            path.lineWidth = 2
            path.stroke()
        }
        drawEndpoint(start, local: localStart, state: state)
        drawEndpoint(end, local: localEnd, state: state)
        if state.panelFrame.contains(end), let measurement = state.measurement {
            drawCard(measurement, near: localEnd, shape: state.shape, isDragging: state.isDragging)
        }
    }

    private func drawEndpoint(_ global: CGPoint, local: CGPoint, state: ScreenRulerDrawState) {
        guard state.panelFrame.insetBy(dx: -6, dy: -6).contains(global) else { return }
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        let circle = NSBezierPath(ovalIn: CGRect(x: local.x - 5, y: local.y - 5, width: 10, height: 10))
        circle.lineWidth = 2
        circle.fill()
        circle.stroke()
    }

    private func drawCard(
        _ measurement: ScreenMeasurement,
        near point: CGPoint,
        shape: MeasurementShape,
        isDragging: Bool
    ) {
        let size = CGSize(width: 328, height: 164)
        var x = point.x + 18
        if x + size.width > bounds.maxX - 8 { x = point.x - size.width - 18 }
        x = min(max(8, x), max(8, bounds.maxX - size.width - 8))
        var y = point.y - size.height / 2
        y = min(max(8, y), max(8, bounds.maxY - size.height - 8))
        let card = CGRect(origin: CGPoint(x: x, y: y), size: size)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12).stroke()

        let title = shape == .rectangle ? "Rectangle Measurement" : "Line Measurement"
        let lines = [
            title + (isDragging ? " — measuring" : ""),
            String(format: "%.1f × %.1f point", measurement.widthInPoints, measurement.heightInPoints),
            String(format: "%.0f × %.0f physical pixel", measurement.widthInPixels, measurement.heightInPixels),
            String(format: "Distance %.1f pt / %.1f px", measurement.distanceInPoints, measurement.distanceInPixels),
            String(format: "Start (%.1f, %.1f)   End (%.1f, %.1f)", measurement.start.x, measurement.start.y, measurement.end.x, measurement.end.y),
            "\(measurement.displayName) — scale \(String(format: "%.2f", measurement.displayScale))x",
            "⇧ constrain   ↑↓←→ nudge   Tab shape   ⌘C copy   R restart   Esc close"
        ]
        var lineY = card.maxY - 27
        for (index, line) in lines.enumerated() {
            line.draw(
                in: CGRect(x: card.minX + 14, y: lineY - 13, width: card.width - 28, height: 22),
                withAttributes: [
                    .font: index == 0
                        ? NSFont.systemFont(ofSize: 13, weight: .semibold)
                        : index == lines.count - 1
                            ? AppKitDrawingFonts.compactChrome
                            : AppKitDrawingFonts.screenRulerBody,
                    .foregroundColor: index == 0 ? NSColor.controlAccentColor : NSColor.labelColor
                ]
            )
            lineY -= index == 0 ? 23 : 20
        }
    }

    private func drawHint(_ state: ScreenRulerDrawState) {
        guard let point = state.pointerPoint, state.panelFrame.contains(point) else { return }
        let local = localPoint(point, panelFrame: state.panelFrame)
        let value = "Drag to measure • Tab switches line/rectangle • Esc closes"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = value.size(withAttributes: attributes)
        var origin = CGPoint(x: local.x + 16, y: local.y - textSize.height / 2)
        if origin.x + textSize.width + 16 > bounds.maxX { origin.x = local.x - textSize.width - 24 }
        let background = CGRect(x: origin.x - 8, y: origin.y - 5, width: textSize.width + 16, height: textSize.height + 10)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: background, xRadius: 7, yRadius: 7).fill()
        value.draw(at: origin, withAttributes: attributes)
    }

    private func localPoint(_ global: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: global.x - panelFrame.minX, y: global.y - panelFrame.minY)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return .zero }
        return CGPoint(
            x: window.frame.minX + event.locationInWindow.x,
            y: window.frame.minY + event.locationInWindow.y
        )
    }
}
