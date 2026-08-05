import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

@MainActor
public final class ScreenCaptureKitCapturer: ScreenCapturing {
    private let processIdentifier: pid_t

    public init(processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.processIdentifier = processIdentifier
    }

    public func discoverTargets() async throws -> CaptureTargets {
        let content = try await loadShareableContent()
        let transformer = desktopTransformer()
        let currentDisplayID = currentMouseDisplayID()
        return try makeTargets(
            content: content,
            transformer: transformer,
            currentDisplayID: currentDisplayID
        )
    }

    public func capture(_ request: CaptureRequest) async throws -> CaptureResult {
        switch request.mode {
        case .currentDisplay:
            return .image(try await captureCurrentDisplay(request))
        case .selectedDisplay:
            return .image(try await captureSelectedDisplay(request))
        case .allDisplays:
            return .multiDisplay(try await captureAllDisplays(request))
        case .window:
            return .image(try await captureWindow(request))
        case .region:
            guard let region = request.region else {
                throw ScreenshotAppError.captureFailed(description: "A capture region was not selected.")
            }
            let preparation = try await prepareRegionCapture(request)
            return .image(try cropRegion(region, from: preparation))
        }
    }

    public func prepareRegionCapture(_ request: CaptureRequest) async throws -> RegionCapturePreparation {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let content = try await loadShareableContent()
        let transformer = desktopTransformer()
        let targets = try makeTargets(
            content: content,
            transformer: transformer,
            currentDisplayID: currentMouseDisplayID()
        )
        guard !targets.displays.isEmpty else {
            throw ScreenshotAppError.noDisplayAvailable
        }

        var captures: [DisplayCapture] = []
        captures.reserveCapacity(targets.displays.count)
        for descriptor in targets.displays {
            guard let display = content.displays.first(where: { $0.displayID == descriptor.id }) else {
                throw ScreenshotAppError.noDisplayAvailable
            }
            let image = try await captureDisplay(
                display,
                descriptor: descriptor,
                content: content,
                request: request
            )
            captures.append(DisplayCapture(descriptor: descriptor, capturedImage: image))
        }
        AppLog.capture.notice(
            "Frozen desktop prepared before region overlay: displays=\(captures.count, privacy: .public), durationMs=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000, privacy: .public)"
        )
        return RegionCapturePreparation(
            displays: captures,
            windows: targets.windows
        )
    }

    public func cropRegion(
        _ region: CGRect,
        from preparation: RegionCapturePreparation
    ) throws -> CapturedImage {
        try RegionCaptureProcessor().crop(region, from: preparation)
    }

    private func captureCurrentDisplay(_ request: CaptureRequest) async throws -> CapturedImage {
        guard let displayID = currentMouseDisplayID() else {
            throw ScreenshotAppError.noDisplayAvailable
        }

        return try await captureDisplay(id: displayID, request: request)
    }

    private func captureSelectedDisplay(_ request: CaptureRequest) async throws -> CapturedImage {
        guard let displayID = request.targetDisplayID else {
            throw ScreenshotAppError.captureFailed(description: "A target display was not selected.")
        }
        return try await captureDisplay(id: displayID, request: request)
    }

    private func captureAllDisplays(_ request: CaptureRequest) async throws -> MultiDisplayCaptureResult {
        let content = try await loadShareableContent()
        let transformer = desktopTransformer()
        let targets = try makeTargets(
            content: content,
            transformer: transformer,
            currentDisplayID: currentMouseDisplayID()
        )
        guard !targets.displays.isEmpty else {
            throw ScreenshotAppError.noDisplayAvailable
        }

        var captures: [DisplayCapture] = []
        captures.reserveCapacity(targets.displays.count)
        for descriptor in targets.displays {
            guard let display = content.displays.first(where: { $0.displayID == descriptor.id }) else {
                throw ScreenshotAppError.noDisplayAvailable
            }
            let image = try await captureDisplay(
                display,
                descriptor: descriptor,
                content: content,
                request: request
            )
            captures.append(DisplayCapture(descriptor: descriptor, capturedImage: image))
        }
        return try MultiDisplayCompositor().compose(captures)
    }

    private func captureWindow(_ request: CaptureRequest) async throws -> CapturedImage {
        guard let windowID = request.targetWindowID else {
            throw ScreenshotAppError.captureFailed(description: "A target window was not selected.")
        }
        let content = try await loadShareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenshotAppError.contentUnavailable
        }
        guard
            window.isOnScreen,
            window.frame.width >= 40,
            window.frame.height >= 40,
            !request.excludesOwnApplication || window.owningApplication?.processID != processIdentifier
        else {
            throw ScreenshotAppError.noWindowAvailable
        }

        let transformer = desktopTransformer()
        let descriptor = WindowDescriptor(
            id: window.windowID,
            title: window.title ?? "Untitled Window",
            applicationName: window.owningApplication?.applicationName ?? "Unknown Application",
            frame: transformer.appKitRect(fromScreenCaptureRect: window.frame),
            layer: window.windowLayer,
            processID: window.owningApplication?.processID
        )
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        guard scale > 0, filter.contentRect.width > 0, filter.contentRect.height > 0 else {
            throw ScreenshotAppError.contentUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(filter.contentRect.width * scale))
        configuration.height = Int(ceil(filter.contentRect.height * scale))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = request.showsCursor
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = !request.includesWindowShadow
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = false
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = true
        }

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            guard image.width > 0, image.height > 0 else {
                throw ScreenshotAppError.contentUnavailable
            }
            return CapturedImage(
                image: image,
                colorSpace: image.colorSpace,
                pixelSize: CGSize(width: image.width, height: image.height),
                logicalSize: CGSize(
                    width: CGFloat(image.width) / scale,
                    height: CGFloat(image.height) / scale
                ),
                scale: scale,
                sourceMetadata: CaptureSourceMetadata(
                    kind: .window,
                    displayIDs: displayIDs(intersecting: descriptor.frame, content: content, transformer: transformer),
                    windowID: descriptor.id,
                    desktopFrame: descriptor.frame
                )
            )
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            AppLog.capture.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.captureFailed(description: error.localizedDescription)
        }
    }

    private func captureDisplay(
        id displayID: CGDirectDisplayID,
        request: CaptureRequest
    ) async throws -> CapturedImage {
        let content = try await loadShareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotAppError.noDisplayAvailable
        }

        let transformer = desktopTransformer()
        let targets = try makeTargets(
            content: content,
            transformer: transformer,
            currentDisplayID: displayID
        )
        guard let descriptor = targets.displays.first(where: { $0.id == displayID }) else {
            throw ScreenshotAppError.noDisplayAvailable
        }
        return try await captureDisplay(
            display,
            descriptor: descriptor,
            content: content,
            request: request
        )
    }

    private func captureDisplay(
        _ display: SCDisplay,
        descriptor: DisplayDescriptor,
        content: SCShareableContent,
        request: CaptureRequest
    ) async throws -> CapturedImage {
        let excludedApplications: [SCRunningApplication]
        if request.excludesOwnApplication {
            excludedApplications = content.applications.filter { $0.processID == processIdentifier }
        } else {
            excludedApplications = []
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = true
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(descriptor.pixelSize.width)
        configuration.height = Int(descriptor.pixelSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = request.showsCursor
        configuration.captureResolution = .best
        configuration.ignoreShadowsDisplay = !request.includesWindowShadow

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let pixelSize = CGSize(width: image.width, height: image.height)
            guard pixelSize.width > 0, pixelSize.height > 0 else {
                throw ScreenshotAppError.contentUnavailable
            }
            let scale = pixelSize.width / descriptor.frame.width
            return CapturedImage(
                image: image,
                colorSpace: image.colorSpace,
                pixelSize: pixelSize,
                logicalSize: descriptor.frame.size,
                scale: scale,
                sourceMetadata: CaptureSourceMetadata(
                    kind: .display,
                    displayIDs: [descriptor.id],
                    windowID: nil,
                    desktopFrame: descriptor.frame
                )
            )
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            AppLog.capture.error("Display capture failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.captureFailed(description: error.localizedDescription)
        }
    }

    private func loadShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            AppLog.capture.error("Shareable content discovery failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.captureFailed(description: error.localizedDescription)
        }
    }

    private func makeTargets(
        content: SCShareableContent,
        transformer: CoordinateTransformer,
        currentDisplayID: CGDirectDisplayID?
    ) throws -> CaptureTargets {
        let screenNames: [CGDirectDisplayID: String] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let id = screenDisplayID(screen) else { return nil }
                return (id, screen.localizedName)
            }
        )

        let displays = try content.displays.map { display -> DisplayDescriptor in
            let frame = transformer.appKitRect(fromScreenCaptureRect: display.frame)
            let backing = try DisplayBackingMetrics.current(
                displayID: display.displayID,
                logicalSize: frame.size
            )
            AppLog.capture.debug(
                "Discovered display \(display.displayID, privacy: .public): logical=\(frame.width, privacy: .public)x\(frame.height, privacy: .public), backing=\(backing.pixelSize.width, privacy: .public)x\(backing.pixelSize.height, privacy: .public), scale=\(backing.scale, privacy: .public)x"
            )
            return DisplayDescriptor(
                id: display.displayID,
                name: screenNames[display.displayID] ?? "Display \(display.displayID)",
                frame: frame,
                pixelSize: backing.pixelSize,
                scale: backing.scale,
                isCurrent: display.displayID == currentDisplayID
            )
        }

        var windows: [WindowDescriptor] = []
        var rejectedGeometryCount = 0
        var rejectedLayerCount = 0
        var rejectedOwnerCount = 0
        var rejectedOwnApplicationCount = 0
        windows.reserveCapacity(content.windows.count)
        for window in content.windows {
            guard window.isOnScreen,
                  window.frame.width >= 40,
                  window.frame.height >= 40
            else {
                rejectedGeometryCount += 1
                continue
            }
            // Layer zero is the normal application-window plane. Menu-bar,
            // Dock, desktop and WindowServer surfaces can cover an entire
            // display and must never outrank the app windows beneath them.
            guard window.windowLayer == 0 else {
                rejectedLayerCount += 1
                continue
            }
            guard let application = window.owningApplication else {
                rejectedOwnerCount += 1
                continue
            }
            guard application.processID != processIdentifier else {
                rejectedOwnApplicationCount += 1
                continue
            }

            windows.append(WindowDescriptor(
                id: window.windowID,
                title: window.title ?? "Untitled Window",
                applicationName: application.applicationName,
                frame: transformer.appKitRect(fromScreenCaptureRect: window.frame),
                layer: window.windowLayer,
                processID: application.processID
            ))
        }
        AppLog.capture.notice(
            "Discovered selectable app windows: source=\(content.windows.count, privacy: .public), accepted=\(windows.count, privacy: .public), rejectedGeometry=\(rejectedGeometryCount, privacy: .public), rejectedLayer=\(rejectedLayerCount, privacy: .public), rejectedMissingOwner=\(rejectedOwnerCount, privacy: .public), rejectedOwnApp=\(rejectedOwnApplicationCount, privacy: .public)"
        )
        return CaptureTargets(displays: displays, windows: windows)
    }

    private func desktopTransformer() -> CoordinateTransformer {
        CoordinateTransformer(primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    private func displayIDs(
        intersecting frame: CGRect,
        content: SCShareableContent,
        transformer: CoordinateTransformer
    ) -> [CGDirectDisplayID] {
        content.displays.compactMap { display in
            let displayFrame = transformer.appKitRect(fromScreenCaptureRect: display.frame)
            return displayFrame.intersects(frame) ? display.displayID : nil
        }
    }

    private func currentMouseDisplayID() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            return nil
        }
        return screenDisplayID(screen)
    }

    private func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
