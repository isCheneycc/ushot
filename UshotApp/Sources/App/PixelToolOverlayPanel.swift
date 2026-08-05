import AppKit
import CoreGraphics
import UshotCore

@MainActor
final class PixelToolOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, contentView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }
}

@MainActor
func currentDisplayDescriptors() throws -> [DisplayDescriptor] {
    let mouseLocation = NSEvent.mouseLocation
    let descriptors = try NSScreen.screens.map { screen -> DisplayDescriptor in
        guard let displayID = displayID(for: screen) else {
            throw ScreenshotAppError.noDisplayAvailable
        }
        let backing = try DisplayBackingMetrics.current(
            displayID: displayID,
            logicalSize: screen.frame.size
        )
        return DisplayDescriptor(
            id: displayID,
            name: screen.localizedName,
            frame: screen.frame,
            pixelSize: backing.pixelSize,
            scale: backing.scale,
            isCurrent: screen.frame.contains(mouseLocation)
        )
    }
    guard !descriptors.isEmpty else { throw ScreenshotAppError.noDisplayAvailable }
    return descriptors
}

@MainActor
func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}
