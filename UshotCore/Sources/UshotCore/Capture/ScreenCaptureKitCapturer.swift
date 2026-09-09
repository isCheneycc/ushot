import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

@MainActor
public final class ScreenCaptureKitCapturer: ScreenCapturing {
    private let processIdentifier: pid_t

    public init(processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.processIdentifier = processIdentifier
    }

    public func discoverTargets(includingOwnWindowIDs: Set<CGWindowID> = []) async throws -> CaptureTargets {
        let content = try await loadShareableContent()
        let transformer = desktopTransformer()
        let currentDisplayID = currentMouseDisplayID()
        return try makeTargets(
            content: content,
            transformer: transformer,
            currentDisplayID: currentDisplayID,
            includedOwnWindowIDs: includingOwnWindowIDs
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
            currentDisplayID: currentMouseDisplayID(),
            includedOwnWindowIDs: request.includedOwnWindowIDs
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
        let isPinnedImage = isIncludedOwnWindow(window, windowIDs: request.includedOwnWindowIDs)
        guard
            window.isOnScreen,
            window.frame.width >= (isPinnedImage ? 1 : 40),
            window.frame.height >= (isPinnedImage ? 1 : 40),
            !request.excludesOwnApplication || window.owningApplication?.processID != processIdentifier || isPinnedImage
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
            processID: window.owningApplication?.processID,
            isPinnedImage: isPinnedImage
        )
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        guard scale > 0, filter.contentRect.width > 0, filter.contentRect.height > 0 else {
            throw ScreenshotAppError.contentUnavailable
        }

        do {
            let capture: WindowImageCapture
            if #available(macOS 26.0, *) {
                capture = try await captureWindowUsingAutomaticScreenshotSize(
                    filter: filter,
                    request: request,
                    expectedBodyScale: scale
                )
            } else if request.includesWindowShadow {
                capture = try await captureFramedWindowUsingValidatedStream(
                    filter: filter,
                    request: request
                )
            } else {
                capture = try await captureUnframedWindow(
                    filter: filter,
                    request: request,
                    scale: scale
                )
            }
            // Re-discover the window after pixels arrive. The screenshot APIs
            // do not attach a display color profile to every window image, so
            // silently using the pre-capture display would mis-tag a window
            // moved between same-scale displays while capture was in flight.
            let refreshedContent = try await loadShareableContent()
            guard let refreshedWindow = refreshedContent.windows.first(where: {
                $0.windowID == windowID
                    && $0.owningApplication?.processID == descriptor.processID
            }) else {
                throw windowCaptureGeometryFailure(
                    "The captured window disappeared before its display identity could be validated."
                )
            }
            let refreshedFrame = transformer.appKitRect(
                fromScreenCaptureRect: refreshedWindow.frame
            )
            let refreshedScale = CGFloat(
                SCContentFilter(desktopIndependentWindow: refreshedWindow).pointPixelScale
            )
            guard refreshedScale.isFinite,
                  refreshedScale > 0,
                  abs(refreshedScale - capture.scale) <= 0.000_001
            else {
                throw windowCaptureGeometryFailure(
                    "The captured window changed display scale before its pixels could be committed."
                )
            }
            guard
                let initialDisplay = dominantDisplay(
                    for: descriptor.frame,
                    content: content,
                    transformer: transformer
                ),
                let refreshedDisplay = dominantDisplay(
                    for: refreshedFrame,
                    content: refreshedContent,
                    transformer: transformer
                ),
                initialDisplay.displayID == refreshedDisplay.displayID
            else {
                throw windowCaptureGeometryFailure(
                    "The captured window changed display identity before its color profile could be validated."
                )
            }
            let image = try windowImageByRestoringColorSpaceIfNeeded(
                capture.image,
                displayID: refreshedDisplay.displayID
            )
            guard image.width > 0, image.height > 0 else {
                throw ScreenshotAppError.contentUnavailable
            }
            return CapturedImage(
                image: image,
                colorSpace: image.colorSpace,
                pixelSize: CGSize(width: image.width, height: image.height),
                logicalSize: CGSize(
                    width: CGFloat(image.width) / capture.scale,
                    height: CGFloat(image.height) / capture.scale
                ),
                scale: capture.scale,
                sourceMetadata: CaptureSourceMetadata(
                    kind: .window,
                    displayIDs: displayIDs(
                        intersecting: refreshedFrame,
                        content: refreshedContent,
                        transformer: transformer
                    ),
                    windowID: descriptor.id,
                    desktopFrame: refreshedFrame
                )
            )
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            AppLog.capture.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.captureFailed(description: error.localizedDescription)
        }
    }

    @available(macOS 26.0, *)
    private func captureWindowUsingAutomaticScreenshotSize(
        filter: SCContentFilter,
        request: CaptureRequest,
        expectedBodyScale: CGFloat
    ) async throws -> WindowImageCapture {
        let configuration = SCScreenshotConfiguration()
        // Leaving width and height at their zero defaults asks ScreenCaptureKit
        // to allocate the complete natural-size output, including framing.
        configuration.showsCursor = request.showsCursor
        configuration.ignoreShadows = !request.includesWindowShadow
        configuration.ignoreClipping = true
        // A shadow-free screenshot has an exact window-body size contract.
        // Including an out-of-bounds child would legitimately enlarge the
        // automatic surface and make that contract impossible to validate.
        configuration.includeChildWindows = request.includesWindowShadow
        configuration.dynamicRange = .sdr

        let output: SCScreenshotOutput = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureScreenshot(
                contentFilter: filter,
                configuration: configuration
            ) { output, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let output {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(
                        throwing: ScreenshotAppError.captureFailed(
                            description: "ScreenCaptureKit returned no window screenshot output."
                        )
                    )
                }
            }
        }
        guard let image = output.sdrImage else {
            throw windowCaptureGeometryFailure(
                "ScreenCaptureKit returned no SDR window image."
            )
        }

        let finalBodyScale = CGFloat(filter.pointPixelScale)
        guard finalBodyScale.isFinite,
              finalBodyScale > 0,
              abs(finalBodyScale - expectedBodyScale) <= 0.000_001
        else {
            throw windowCaptureGeometryFailure(
                "The window changed display scale while its screenshot was being captured."
            )
        }
        let expectedBodyWidth = Int(ceil(filter.contentRect.width * expectedBodyScale))
        let expectedBodyHeight = Int(ceil(filter.contentRect.height * expectedBodyScale))
        let hasExpectedSurfaceSize = request.includesWindowShadow
            ? image.width >= expectedBodyWidth && image.height >= expectedBodyHeight
            : image.width == expectedBodyWidth && image.height == expectedBodyHeight
        guard hasExpectedSurfaceSize else {
            throw windowCaptureGeometryFailure(
                "The automatic window surface did not match its native body contract "
                    + "(surface=\(image.width)x\(image.height), body=\(expectedBodyWidth)x\(expectedBodyHeight), "
                    + "shadow=\(request.includesWindowShadow))."
            )
        }

        AppLog.capture.notice(
            "Captured window with automatic native framing: surface=\(image.width, privacy: .public)x\(image.height, privacy: .public), body=\(expectedBodyWidth, privacy: .public)x\(expectedBodyHeight, privacy: .public), scale=\(expectedBodyScale, privacy: .public), shadow=\(request.includesWindowShadow, privacy: .public)"
        )
        return WindowImageCapture(image: image, scale: expectedBodyScale)
    }

    private func captureUnframedWindow(
        filter: SCContentFilter,
        request: CaptureRequest,
        scale: CGFloat
    ) async throws -> WindowImageCapture {
        let dimensions = try windowPixelDimensions(
            width: filter.contentRect.width * scale,
            height: filter.contentRect.height * scale,
            reason: "native window body"
        )
        let configuration = makeWindowStreamConfiguration(
            dimensions: dimensions,
            request: request,
            includesShadow: false
        )
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard image.width == dimensions.width, image.height == dimensions.height else {
            throw windowCaptureGeometryFailure(
                "The unframed window surface did not match its requested native size "
                    + "(surface=\(image.width)x\(image.height), requested=\(dimensions.width)x\(dimensions.height))."
            )
        }
        return WindowImageCapture(image: image, scale: scale)
    }

    private func captureFramedWindowUsingValidatedStream(
        filter: SCContentFilter,
        request: CaptureRequest
    ) async throws -> WindowImageCapture {
        let expansionPadding = 128
        let requiredTrailingFrameGuard = 16
        let initialScale = CGFloat(filter.pointPixelScale)
        let initialDimensions = try windowPixelDimensions(
            width: filter.contentRect.width * initialScale,
            height: filter.contentRect.height * initialScale,
            reason: "initial window body"
        )
        var configuration = makeWindowStreamConfiguration(
            dimensions: initialDimensions,
            request: request,
            includesShadow: true
        )
        configuration.queueDepth = 2

        let output = WindowCaptureStreamOutput()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        let callbackQueue = DispatchQueue(
            label: "io.github.ischeneycc.ushot.window-capture-frame",
            qos: .userInitiated
        )
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: callbackQueue)

        var started = false
        do {
            try await startWindowCaptureStream(stream)
            started = true

            var expectedDimensions = initialDimensions
            let maximumReconfigurations = 3
            for reconfigurationCount in 0...maximumReconfigurations {
                let frame = try await nextCompleteWindowFrame(
                    from: output,
                    expectedDimensions: expectedDimensions
                )
                let metadata = try validatedWindowScaleMetadata(from: frame)
                let nextDimensions: WindowPixelDimensions?
                if metadata.isNativeScale {
                    let alphaBounds = try nontransparentPixelBounds(in: frame.pixelBuffer)
                    // The reported content rect is the source geometry lower
                    // bound. Alpha may extend it for shadows or child windows,
                    // but must never shrink a transparent window's legitimate
                    // frame. Keeping the leading origin also avoids deleting a
                    // transparent leading margin based on alpha alone.
                    let cropWidth = max(
                        metadata.contentPixelExtent.width,
                        alphaBounds?.maxX ?? 0
                    )
                    let cropHeight = max(
                        metadata.contentPixelExtent.height,
                        alphaBounds?.maxY ?? 0
                    )
                    let trailingX = expectedDimensions.width - cropWidth
                    let trailingY = expectedDimensions.height - cropHeight
                    if trailingX >= requiredTrailingFrameGuard,
                       trailingY >= requiredTrailingFrameGuard {
                        let image = try makeCGImage(from: frame.pixelBuffer)
                        let cropRect = CGRect(
                            x: 0,
                            y: 0,
                            width: CGFloat(cropWidth),
                            height: CGFloat(cropHeight)
                        )
                        guard let croppedImage = image.cropping(to: cropRect) else {
                            throw windowCaptureGeometryFailure(
                                "The complete native window framing could not be cropped from its validated content bounds."
                            )
                        }
                        try await stopWindowCaptureStream(stream)
                        started = false
                        output.finish()
                        AppLog.capture.notice(
                            "Captured legacy window at validated native framing: surface=\(image.width, privacy: .public)x\(image.height, privacy: .public), reportedContent=\(metadata.contentPixelExtent.width, privacy: .public)x\(metadata.contentPixelExtent.height, privacy: .public), alpha=\(alphaBounds?.width ?? 0, privacy: .public)x\(alphaBounds?.height ?? 0, privacy: .public), cropped=\(croppedImage.width, privacy: .public)x\(croppedImage.height, privacy: .public), trailingGuard=\(trailingX, privacy: .public)x\(trailingY, privacy: .public), scale=\(metadata.scaleFactor, privacy: .public), reconfigurations=\(reconfigurationCount, privacy: .public)"
                        )
                        return WindowImageCapture(
                            image: croppedImage,
                            scale: metadata.scaleFactor
                        )
                    }
                    nextDimensions = WindowPixelDimensions(
                        width: expectedDimensions.width
                            + (trailingX < requiredTrailingFrameGuard ? expansionPadding : 0),
                        height: expectedDimensions.height
                            + (trailingY < requiredTrailingFrameGuard ? expansionPadding : 0)
                    )
                } else {
                    nextDimensions = try windowPixelDimensions(
                        width: CGFloat(expectedDimensions.width) / metadata.contentScale
                            + CGFloat(expansionPadding),
                        height: CGFloat(expectedDimensions.height) / metadata.contentScale
                            + CGFloat(expansionPadding),
                        reason: "expanded framed window surface"
                    )
                }

                guard reconfigurationCount < maximumReconfigurations,
                      let nextDimensions,
                      nextDimensions != expectedDimensions
                else {
                    throw windowCaptureGeometryFailure(
                        "Window framing did not stabilize at native scale with complete content bounds after "
                            + "\(maximumReconfigurations) reconfigurations."
                    )
                }

                AppLog.capture.notice(
                    "Expanding window capture surface for native framing: from=\(expectedDimensions.width, privacy: .public)x\(expectedDimensions.height, privacy: .public), to=\(nextDimensions.width, privacy: .public)x\(nextDimensions.height, privacy: .public), contentScale=\(metadata.contentScale, privacy: .public), attempt=\(reconfigurationCount + 1, privacy: .public)"
                )
                configuration = makeWindowStreamConfiguration(
                    dimensions: nextDimensions,
                    request: request,
                    includesShadow: true
                )
                configuration.queueDepth = 2
                output.discardPendingFrame()
                try await updateWindowCaptureStream(stream, configuration: configuration)
                expectedDimensions = nextDimensions
            }

            throw windowCaptureGeometryFailure("Window framing validation ended unexpectedly.")
        } catch {
            output.finish(error: error)
            if started {
                do {
                    try await stopWindowCaptureStream(stream)
                } catch {
                    AppLog.capture.error(
                        "Window capture stream cleanup failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
    }

    private func makeWindowStreamConfiguration(
        dimensions: WindowPixelDimensions,
        request: CaptureRequest,
        includesShadow: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = request.showsCursor
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = !includesShadow
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        if #available(macOS 14.2, *) {
            // A body-sized, shadow-free surface cannot prove that an
            // out-of-bounds child window was not scaled into it. The framed
            // stream and macOS 26 automatic-size path can include children;
            // this exact body path must keep its source bounded to the body.
            configuration.includeChildWindows = includesShadow
        }
        return configuration
    }

    private func nextCompleteWindowFrame(
        from output: WindowCaptureStreamOutput,
        expectedDimensions: WindowPixelDimensions
    ) async throws -> WindowCaptureFrame {
        let maximumInspectedFrames = 12
        for _ in 0..<maximumInspectedFrames {
            let frame = try await output.nextFrame(timeout: 3)
            guard frame.dimensions == expectedDimensions else {
                continue
            }
            guard let status = frame.status else {
                throw windowCaptureGeometryFailure(
                    "A window frame was missing its completion status metadata."
                )
            }
            guard status == .complete else {
                continue
            }
            return frame
        }
        throw windowCaptureGeometryFailure(
            "ScreenCaptureKit did not produce a complete window frame matching "
                + "\(expectedDimensions.width)x\(expectedDimensions.height)."
        )
    }

    private func validatedWindowScaleMetadata(
        from frame: WindowCaptureFrame
    ) throws -> ValidatedWindowScaleMetadata {
        guard
            let scaleFactor = frame.scaleFactor,
            scaleFactor.isFinite,
            scaleFactor > 0,
            let contentScale = frame.contentScale,
            contentScale.isFinite,
            contentScale > 0,
            contentScale <= 1.000_001,
            let contentRect = frame.contentRect?.standardized,
            contentRect.origin.x.isFinite,
            contentRect.origin.y.isFinite,
            contentRect.width.isFinite,
            contentRect.height.isFinite,
            contentRect.minX >= 0,
            contentRect.minY >= 0,
            contentRect.width > 0,
            contentRect.height > 0
        else {
            throw windowCaptureGeometryFailure(
                "A window frame contained missing or invalid native-scale metadata."
            )
        }
        let contentPixelExtent = try windowPixelDimensions(
            width: contentRect.maxX * scaleFactor,
            height: contentRect.maxY * scaleFactor,
            reason: "reported framed window content"
        )
        guard contentPixelExtent.width <= frame.dimensions.width,
              contentPixelExtent.height <= frame.dimensions.height
        else {
            throw windowCaptureGeometryFailure(
                "The reported framed window content exceeded its destination surface."
            )
        }
        return ValidatedWindowScaleMetadata(
            scaleFactor: scaleFactor,
            contentScale: contentScale,
            isNativeScale: abs(contentScale - 1) <= 0.000_001,
            contentPixelExtent: contentPixelExtent
        )
    }

    private func nontransparentPixelBounds(
        in pixelBuffer: CVPixelBuffer
    ) throws -> WindowPixelBounds? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw windowCaptureGeometryFailure(
                "The native window frame did not use the requested BGRA pixel format."
            )
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw windowCaptureGeometryFailure(
                "The native window frame pixels could not be locked for alpha validation (status=\(lockStatus))."
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw windowCaptureGeometryFailure(
                "The native window frame had no readable pixel base address."
            )
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw windowCaptureGeometryFailure(
                "The native window frame had invalid BGRA row geometry."
            )
        }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in 0..<width where row[x * 4 + 3] != 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return WindowPixelBounds(
            minX: minX,
            minY: minY,
            maxX: maxX + 1,
            maxY: maxY + 1
        )
    }

    private func windowPixelDimensions(
        width: CGFloat,
        height: CGFloat,
        reason: String
    ) throws -> WindowPixelDimensions {
        let maximumInteger = CGFloat(Int.max)
        guard
            width.isFinite,
            height.isFinite,
            width > 0,
            height > 0,
            width <= maximumInteger,
            height <= maximumInteger
        else {
            throw windowCaptureGeometryFailure(
                "ScreenCaptureKit reported invalid \(reason) dimensions."
            )
        }
        return WindowPixelDimensions(width: Int(ceil(width)), height: Int(ceil(height)))
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard status == noErr, let image else {
            throw windowCaptureGeometryFailure(
                "The validated native window frame could not be converted to an image (status=\(status))."
            )
        }
        return image
    }

    private func startWindowCaptureStream(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func updateWindowCaptureStream(
        _ stream: SCStream,
        configuration: SCStreamConfiguration
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.updateConfiguration(configuration) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func stopWindowCaptureStream(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func windowCaptureGeometryFailure(_ description: String) -> ScreenshotAppError {
        AppLog.capture.error(
            "Window capture geometry validation failed: \(description, privacy: .public)"
        )
        return .captureFailed(description: description)
    }

    private func windowImageByRestoringColorSpaceIfNeeded(
        _ image: CGImage,
        displayID: CGDirectDisplayID
    ) throws -> CGImage {
        guard image.colorSpace == nil else { return image }
        let displayColorSpace = CGDisplayCopyColorSpace(displayID)
        guard let taggedImage = image.copy(colorSpace: displayColorSpace) else {
            throw windowCaptureGeometryFailure(
                "The captured window could not be bound to its display color space."
            )
        }
        AppLog.capture.notice(
            "Restored missing window screenshot color space from display: display=\(displayID, privacy: .public), profile=\(displayColorSpace.name as String? ?? "unnamed", privacy: .public)"
        )
        return taggedImage
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
            exceptingWindows: request.excludesOwnApplication
                ? content.windows.filter { isIncludedOwnWindow($0, windowIDs: request.includedOwnWindowIDs) }
                : []
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
        currentDisplayID: CGDirectDisplayID?,
        includedOwnWindowIDs: Set<CGWindowID> = []
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
            let isPinnedImage = isIncludedOwnWindow(window, windowIDs: includedOwnWindowIDs)
            guard window.isOnScreen,
                  window.frame.width >= (isPinnedImage ? 1 : 40),
                  window.frame.height >= (isPinnedImage ? 1 : 40)
            else {
                rejectedGeometryCount += 1
                continue
            }
            // Layer zero is the normal application-window plane. Menu-bar,
            // Dock, desktop and WindowServer surfaces can cover an entire
            // display and must never outrank the app windows beneath them.
            // Registered pinned images are selectable in their floating layer.
            guard window.windowLayer == 0 || isPinnedImage else {
                rejectedLayerCount += 1
                continue
            }
            guard let application = window.owningApplication else {
                rejectedOwnerCount += 1
                continue
            }
            guard application.processID != processIdentifier || isPinnedImage else {
                rejectedOwnApplicationCount += 1
                continue
            }

            windows.append(WindowDescriptor(
                id: window.windowID,
                title: window.title ?? "Untitled Window",
                applicationName: application.applicationName,
                frame: transformer.appKitRect(fromScreenCaptureRect: window.frame),
                layer: window.windowLayer,
                processID: application.processID,
                isPinnedImage: isPinnedImage
            ))
        }
        AppLog.capture.notice(
            "Discovered selectable app windows: source=\(content.windows.count, privacy: .public), accepted=\(windows.count, privacy: .public), rejectedGeometry=\(rejectedGeometryCount, privacy: .public), rejectedLayer=\(rejectedLayerCount, privacy: .public), rejectedMissingOwner=\(rejectedOwnerCount, privacy: .public), rejectedOwnApp=\(rejectedOwnApplicationCount, privacy: .public)"
        )
        return CaptureTargets(displays: displays, windows: windows)
    }

    private func isIncludedOwnWindow(_ window: SCWindow, windowIDs: Set<CGWindowID>) -> Bool {
        window.owningApplication?.processID == processIdentifier && windowIDs.contains(window.windowID)
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

    private func dominantDisplay(
        for frame: CGRect,
        content: SCShareableContent,
        transformer: CoordinateTransformer
    ) -> SCDisplay? {
        var best: (display: SCDisplay, area: CGFloat)?
        for display in content.displays {
            let displayFrame = transformer.appKitRect(
                fromScreenCaptureRect: display.frame
            )
            let intersection = displayFrame.intersection(frame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if let current = best {
                guard area > current.area
                        || (area == current.area
                            && display.displayID < current.display.displayID)
                else { continue }
                best = (display, area)
            } else {
                best = (display, area)
            }
        }
        return best?.display
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

private struct WindowImageCapture {
    let image: CGImage
    let scale: CGFloat
}

private struct WindowPixelDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

private struct ValidatedWindowScaleMetadata: Sendable {
    let scaleFactor: CGFloat
    let contentScale: CGFloat
    let isNativeScale: Bool
    let contentPixelExtent: WindowPixelDimensions
}

private struct WindowPixelBounds: Equatable, Sendable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
}

private struct WindowCaptureFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let dimensions: WindowPixelDimensions
    let status: SCFrameStatus?
    let scaleFactor: CGFloat?
    let contentScale: CGFloat?
    let contentRect: CGRect?

    init(sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
        dimensions = WindowPixelDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        self.pixelBuffer = pixelBuffer

        let attachments = (
            CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]]
        )?.first
        if
            let rawStatus = windowFrameNumber(attachments?[.status])?.intValue
        {
            status = SCFrameStatus(rawValue: rawStatus)
        } else {
            status = nil
        }
        scaleFactor = windowFrameNumber(attachments?[.scaleFactor]).map(CGFloat.init(truncating:))
        contentScale = windowFrameNumber(attachments?[.contentScale]).map(CGFloat.init(truncating:))
        contentRect = windowFrameRect(attachments?[.contentRect])
    }
}

private final class WindowCaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private typealias FrameContinuation = CheckedContinuation<WindowCaptureFrame, Error>

    private let lock = NSLock()
    private var pendingFrame: WindowCaptureFrame?
    private var waiter: (id: UUID, continuation: FrameContinuation)?
    private var terminalError: Error?
    private var isFinished = false

    func nextFrame(timeout: TimeInterval) async throws -> WindowCaptureFrame {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                var immediateFrame: WindowCaptureFrame?
                var immediateError: Error?
                var registeredWaiter = false
                lock.lock()
                if let pendingFrame {
                    immediateFrame = pendingFrame
                    self.pendingFrame = nil
                } else if let terminalError {
                    immediateError = terminalError
                } else if isFinished {
                    immediateError = CancellationError()
                } else if waiter != nil {
                    immediateError = ScreenshotAppError.captureFailed(
                        description: "Window capture attempted to await more than one frame concurrently."
                    )
                } else {
                    waiter = (waiterID, continuation)
                    registeredWaiter = true
                }
                lock.unlock()

                if let immediateFrame {
                    continuation.resume(returning: immediateFrame)
                } else if let immediateError {
                    continuation.resume(throwing: immediateError)
                } else if registeredWaiter {
                    if Task.isCancelled {
                        failWaiter(id: waiterID, error: CancellationError())
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + timeout
                    ) { [weak self] in
                        self?.failWaiter(
                            id: waiterID,
                            error: ScreenshotAppError.captureFailed(
                                description: "Timed out while waiting for a complete window frame."
                            )
                        )
                    }
                }
            }
        } onCancel: {
            failWaiter(id: waiterID, error: CancellationError())
        }
    }

    func discardPendingFrame() {
        lock.lock()
        pendingFrame = nil
        lock.unlock()
    }

    func finish(error: Error? = nil) {
        var continuation: FrameContinuation?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        terminalError = error ?? CancellationError()
        pendingFrame = nil
        continuation = waiter?.continuation
        waiter = nil
        lock.unlock()
        continuation?.resume(throwing: terminalError ?? CancellationError())
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        guard sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else {
            let error = ScreenshotAppError.captureFailed(
                description: "ScreenCaptureKit returned an invalid window frame buffer."
            )
            AppLog.capture.error(
                "Window capture stream returned an invalid frame buffer."
            )
            finish(error: error)
            return
        }
        publish(WindowCaptureFrame(sampleBuffer: sampleBuffer, pixelBuffer: pixelBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(error: error)
    }

    private func publish(_ frame: WindowCaptureFrame) {
        var continuation: FrameContinuation?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if let waiter {
            continuation = waiter.continuation
            self.waiter = nil
        } else {
            pendingFrame = frame
        }
        lock.unlock()
        continuation?.resume(returning: frame)
    }

    private func failWaiter(id: UUID, error: Error) {
        var continuation: FrameContinuation?
        lock.lock()
        if waiter?.id == id {
            continuation = waiter?.continuation
            waiter = nil
        }
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

private func windowFrameNumber(_ value: Any?) -> NSNumber? {
    value as? NSNumber
}

private func windowFrameRect(_ value: Any?) -> CGRect? {
    if let rect = value as? CGRect {
        return rect
    }
    if let dictionary = value as? NSDictionary {
        return CGRect(dictionaryRepresentation: dictionary)
    }
    return nil
}
