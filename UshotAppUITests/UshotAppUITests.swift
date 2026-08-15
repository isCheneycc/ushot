import AppKit
import XCTest

final class UshotAppUITests: XCTestCase {
    private let isolatedSettingsSuiteName =
        "io.github.ischeneycc.ushot.UITests.\(UUID().uuidString)"

    @MainActor
    func testSettingsOpensAndDockToggleChangesValue() {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-settings"])
        defer { app.terminate() }
        XCTAssertTrue(app.windows["settings.window"].waitForExistence(timeout: 5))

        let dockToggle = app.switches["settings.showDockIcon"]
        XCTAssertTrue(dockToggle.waitForExistence(timeout: 3))
        XCTAssertEqual((dockToggle.value as? NSNumber)?.intValue, 0)
        dockToggle.click()
        XCTAssertEqual((dockToggle.value as? NSNumber)?.intValue, 1)
    }

    @MainActor
    func testShortcutRecordersSurviveRepeatedFocusRedraws() {
        let app = launch(arguments: [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--uitest-reset-settings",
            "--uitest-settings-shortcuts"
        ])
        defer { app.terminate() }

        let settingsWindow = app.windows["settings.window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        let recorder = app.buttons["settings.shortcuts.global.1"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.buttons["settings.shortcuts.annotation.crop"].exists,
            "Shortcut settings must not expose Crop as an annotation tool."
        )

        for _ in 0..<40 {
            recorder.click()
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertNotEqual(app.state, .notRunning)
        }

        XCTAssertTrue(settingsWindow.exists)
    }

    @MainActor
    func testGlobalShortcutRecorderAcceptsBareFunctionKeysButRejectsBareLetters() {
        let app = launch(arguments: [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--uitest-reset-settings",
            "--uitest-settings-shortcuts"
        ])
        defer { app.terminate() }

        XCTAssertTrue(app.windows["settings.window"].waitForExistence(timeout: 5))
        let recorder = app.buttons["settings.shortcuts.global.1"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 3))

        recorder.click()
        app.typeKey(.F1, modifierFlags: [])
        waitForValue(of: recorder, containing: "F1")
        XCTAssertEqual(recorder.value as? String, "F1")

        recorder.click()
        app.typeKey(.F2, modifierFlags: [])
        waitForValue(of: recorder, containing: "F2")
        XCTAssertEqual(recorder.value as? String, "F2")

        recorder.click()
        app.typeKey("a", modifierFlags: [])
        XCTAssertEqual(
            recorder.value as? String,
            "F2",
            "An ordinary global shortcut must still include Command, Option, Control or Shift."
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testCanvasEditorSwitchesBasicTools() {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-editor"])
        defer { app.terminate() }
        XCTAssertTrue(app.windows["editor.window"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["editor.tool.crop"].exists,
            "Canvas Editor must not expose Crop in its tool rail."
        )

        let rectangle = app.buttons["editor.tool.rectangle"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 3))
        let notSelectedValue = rectangle.value as? String
        rectangle.click()
        XCTAssertNotEqual(rectangle.value as? String, notSelectedValue)

        let arrow = app.buttons["editor.tool.arrow"]
        XCTAssertTrue(arrow.exists)
        arrow.click()
        XCTAssertNotEqual(arrow.value as? String, notSelectedValue)
        XCTAssertEqual(rectangle.value as? String, notSelectedValue)
    }

    @MainActor
    func testCanvasEditorSurvivesSelectedAnnotationRemovalWhileInspectorUpdates() {
        let app = launch(arguments: [
            "--uitest-reset-settings",
            "--uitest-editor-selection-invalidation"
        ])
        defer { app.terminate() }
        let editorWindow = app.windows["editor.window"]
        XCTAssertTrue(editorWindow.waitForExistence(timeout: 5))

        Thread.sleep(forTimeInterval: 2)

        XCTAssertTrue(
            editorWindow.exists,
            "Removing the selected annotation must replace the inspector without terminating the app."
        )
        XCTAssertNotEqual(app.state, .notRunning)
    }

    @MainActor
    func testEditorSettingsPersistsRectangleCornerRadius() {
        let app = launch(arguments: [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--uitest-reset-settings",
            "--uitest-settings-editor"
        ])
        XCTAssertTrue(app.windows["settings.window"].waitForExistence(timeout: 5))

        let textColor = app.descendants(matching: .any)["settings.editor.defaultTextColor"]
        XCTAssertTrue(textColor.waitForExistence(timeout: 3))
        XCTAssertTrue((textColor.value as? String)?.contains("#FF3B30") == true)

        let textFont = app.descendants(matching: .any)["settings.editor.defaultTextFont"]
        XCTAssertTrue(textFont.waitForExistence(timeout: 3))
        XCTAssertTrue((textFont.value as? String)?.contains("System Font") == true)

        let rectangleRow = app.buttons["settings.editor.tool.rectangle"]
        XCTAssertTrue(rectangleRow.waitForExistence(timeout: 3))
        rectangleRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)
        ).click()
        XCTAssertEqual(rectangleRow.value as? String, "Selected")
        let rectangleColor = app.descendants(matching: .any)["settings.editor.defaultRectangleColor"]
        XCTAssertTrue(rectangleColor.waitForExistence(timeout: 3))
        XCTAssertTrue((rectangleColor.value as? String)?.contains("#FF3B30") == true)

        let cornerRadius = app.textFields["settings.editor.rectangleCornerRadius"]
        XCTAssertTrue(cornerRadius.waitForExistence(timeout: 3))
        cornerRadius.click()
        cornerRadius.typeKey("a", modifierFlags: .command)
        cornerRadius.typeText("12.5")
        app.typeKey(.return, modifierFlags: [])

        app.buttons["settings.editor.tool.ellipse"].click()
        XCTAssertTrue(app.buttons["settings.editor.tool.ellipse"].label.contains("Circle"))
        let ellipseColor = app.descendants(matching: .any)["settings.editor.defaultEllipseColor"]
        XCTAssertTrue(ellipseColor.waitForExistence(timeout: 3))
        XCTAssertTrue((ellipseColor.value as? String)?.contains("#FF3B30") == true)
        app.terminate()

        let reloaded = launch(arguments: [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--uitest-settings-editor"
        ])
        defer { reloaded.terminate() }
        XCTAssertTrue(reloaded.windows["settings.window"].waitForExistence(timeout: 5))
        let reloadedRectangle = reloaded.buttons["settings.editor.tool.rectangle"]
        XCTAssertTrue(reloadedRectangle.waitForExistence(timeout: 3))
        XCTAssertTrue(
            reloadedRectangle.label.contains("12.5"),
            "Expected the rectangle summary to expose the persisted 12.5 px corner radius, got \(reloadedRectangle.label)."
        )
    }

    @MainActor
    func testEditorSettingsMeasurementUnitsSwitchIndependentlyAndPersist() {
        let app = launch(arguments: [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--uitest-reset-settings",
            "--uitest-settings-editor"
        ])
        XCTAssertTrue(app.windows["settings.window"].waitForExistence(timeout: 5))

        let fontSizeUnit = app.radioGroups["settings.editor.defaultFontSizeUnit"]
        XCTAssertTrue(fontSizeUnit.waitForExistence(timeout: 3))
        XCTAssertEqual((fontSizeUnit.radioButtons["px"].value as? NSNumber)?.intValue, 1)
        fontSizeUnit.radioButtons["pt"].click()
        XCTAssertEqual((fontSizeUnit.radioButtons["pt"].value as? NSNumber)?.intValue, 1)

        app.buttons["settings.editor.tool.rectangle"].click()
        let lineWidthUnit = app.radioGroups["settings.editor.defaultLineWidthUnit"]
        let cornerRadiusUnit = app.radioGroups[
            "settings.editor.rectangleCornerRadiusUnit"
        ]
        XCTAssertTrue(lineWidthUnit.waitForExistence(timeout: 3))
        XCTAssertTrue(cornerRadiusUnit.waitForExistence(timeout: 3))
        XCTAssertEqual((lineWidthUnit.radioButtons["px"].value as? NSNumber)?.intValue, 1)
        XCTAssertEqual((cornerRadiusUnit.radioButtons["px"].value as? NSNumber)?.intValue, 1)
        lineWidthUnit.radioButtons["pt"].click()
        cornerRadiusUnit.radioButtons["pt"].click()
        XCTAssertEqual((lineWidthUnit.radioButtons["pt"].value as? NSNumber)?.intValue, 1)
        XCTAssertEqual((cornerRadiusUnit.radioButtons["pt"].value as? NSNumber)?.intValue, 1)

        let rectangleSummary = app.buttons["settings.editor.tool.rectangle"]
        XCTAssertTrue(rectangleSummary.label.contains("pt"))
        app.terminate()

        let reloaded = launch(arguments: [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--uitest-settings-editor"
        ])
        defer { reloaded.terminate() }
        XCTAssertTrue(reloaded.windows["settings.window"].waitForExistence(timeout: 5))
        let reloadedFontSizeUnit = reloaded.radioGroups[
            "settings.editor.defaultFontSizeUnit"
        ]
        XCTAssertTrue(reloadedFontSizeUnit.waitForExistence(timeout: 3))
        XCTAssertEqual(
            (reloadedFontSizeUnit.radioButtons["pt"].value as? NSNumber)?.intValue,
            1
        )

        reloaded.buttons["settings.editor.tool.rectangle"].click()
        XCTAssertEqual(
            (reloaded.radioGroups["settings.editor.defaultLineWidthUnit"]
                .radioButtons["pt"].value as? NSNumber)?.intValue,
            1
        )
        XCTAssertEqual(
            (reloaded.radioGroups["settings.editor.rectangleCornerRadiusUnit"]
                .radioButtons["pt"].value as? NSNumber)?.intValue,
            1
        )
    }

    @MainActor
    func testEditorPaletteRestoreCanKeepCustomColors() {
        let app = launch(arguments: [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--uitest-reset-settings",
            "--uitest-settings-editor"
        ])
        defer { app.terminate() }

        XCTAssertTrue(app.windows["settings.window"].waitForExistence(timeout: 5))
        let managePalette = app.buttons["settings.editor.managePalette"]
        XCTAssertTrue(managePalette.waitForExistence(timeout: 3))
        managePalette.click()

        let newColorHex = app.textFields["settings.editor.newPaletteHex"]
        XCTAssertTrue(newColorHex.waitForExistence(timeout: 3))
        newColorHex.click()
        newColorHex.typeKey("a", modifierFlags: .command)
        newColorHex.typeText("#12ABEF")
        app.typeKey(.return, modifierFlags: [])
        let addColor = app.buttons["settings.editor.addAnnotationColor"]
        XCTAssertTrue(addColor.isEnabled)
        addColor.click()

        let customColorRemove = app.buttons["settings.editor.removePaletteColor.12ABEF"]
        XCTAssertTrue(customColorRemove.waitForExistence(timeout: 3))
        let redRemove = app.buttons["settings.editor.removePaletteColor.FF3B30"]
        XCTAssertTrue(redRemove.waitForExistence(timeout: 3))
        redRemove.click()
        let replaceAndRemove = app.buttons["Replace and Remove"]
        XCTAssertTrue(replaceAndRemove.waitForExistence(timeout: 3))
        replaceAndRemove.click()
        XCTAssertTrue(redRemove.waitForNonExistence(timeout: 3))

        let restoreDefaults = app.buttons["settings.editor.restorePaletteDefaults"]
        XCTAssertTrue(restoreDefaults.waitForExistence(timeout: 3))
        restoreDefaults.click()
        let keepCustom = app.buttons["settings.editor.confirmPaletteRestoreKeepingCustom"]
        let replaceWithDefaults = app.buttons["settings.editor.confirmPaletteRestore"]
        XCTAssertTrue(keepCustom.waitForExistence(timeout: 3))
        XCTAssertTrue(replaceWithDefaults.exists)
        XCTAssertTrue(keepCustom.isEnabled)
        keepCustom.click()

        XCTAssertTrue(redRemove.waitForExistence(timeout: 3))
        XCTAssertTrue(
            customColorRemove.exists,
            "Restoring factory colors while keeping custom colors must retain the custom entry."
        )
    }

    @MainActor
    func testRegionSelectionSnapsToHoveredWindowOnClick() {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-region-selection"])
        defer { app.terminate() }

        let overlay = app.groups["capture.region.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        let windowPoint = overlay.coordinate(
            withNormalizedOffset: CGVector(dx: 0.42, dy: 0.44)
        )
        windowPoint.hover()
        waitForValue(of: overlay, containing: "snap=window")
        waitForValue(of: overlay, containing: "magnifier=visible")
        waitForValue(of: overlay, containing: "magnifierTarget=window")
        waitForValue(of: overlay, containing: "magnifierGrid=1px")
        waitForValue(of: overlay, containing: "magnifierCenter=crosshair")
        XCTAssertFalse(
            (overlay.value as? String)?.contains("magnifierSelection=none") == true,
            "A smart-snap candidate must publish its physical-pixel size in the magnifier HUD."
        )
        windowPoint.click()

        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        waitForValue(of: overlay, containing: "magnifier=hidden")
        let expected = CGRect(
            x: overlay.frame.minX + overlay.frame.width * 0.18,
            // The fixture is expressed in AppKit's bottom-left coordinate
            // system, while XCUI reports frames from the screen's top-left.
            y: overlay.frame.minY + overlay.frame.height * (1 - 0.20 - 0.48),
            width: overlay.frame.width * 0.52,
            height: overlay.frame.height * 0.48
        ).integral
        XCTAssertEqual(canvas.frame.minX, expected.minX, accuracy: 3)
        XCTAssertEqual(canvas.frame.minY, expected.minY, accuracy: 3)
        XCTAssertEqual(canvas.frame.width, expected.width, accuracy: 3)
        XCTAssertEqual(canvas.frame.height, expected.height, accuracy: 3)
        app.buttons["capture.region.cancel"].click()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testRegionSelectionKeepsBrowserControlStableAndCyclesParents() {
        let app = launch(arguments: [
            "--uitest-reset-settings",
            "--uitest-region-selection",
            "--uitest-region-selection-controls"
        ])
        defer { app.terminate() }

        let overlay = app.groups["capture.region.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        let innerPoints = [
            CGVector(dx: 0.40, dy: 0.48),
            CGVector(dx: 0.42, dy: 0.50),
            CGVector(dx: 0.46, dy: 0.52)
        ]
        for offset in innerPoints {
            overlay.coordinate(withNormalizedOffset: offset).hover()
        }
        waitForValue(of: overlay, containing: "snap=interface-element")
        waitForValue(of: overlay, containing: "snapLevel=1/3")
        waitForValue(of: overlay, containing: "snapStabilityFallbacks=0")

        app.typeKey(.upArrow, modifierFlags: .option)
        waitForValue(of: overlay, containing: "snapLevel=2/3")

        // Move outside the inner control but remain inside its selected parent.
        // A slow browser accessibility lookup must not flash back to the window.
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.50)).hover()
        waitForValue(of: overlay, containing: "snap=interface-element")
        waitForValue(of: overlay, containing: "snapLevel=1/2")
        waitForValue(of: overlay, containing: "snapStabilityFallbacks=0")

        app.typeKey(.upArrow, modifierFlags: .option)
        waitForValue(of: overlay, containing: "snap=window")
        waitForValue(of: overlay, containing: "snapLevel=2/2")
        app.typeKey(.downArrow, modifierFlags: .option)
        waitForValue(of: overlay, containing: "snap=interface-element")
        waitForValue(of: overlay, containing: "snapLevel=1/2")

        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.50)).click()
        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let expectedParent = CGRect(
            x: overlay.frame.minX + overlay.frame.width * 0.22,
            y: overlay.frame.minY + overlay.frame.height * (1 - 0.24 - 0.40),
            width: overlay.frame.width * 0.44,
            height: overlay.frame.height * 0.40
        ).integral
        XCTAssertEqual(canvas.frame.minX, expectedParent.minX, accuracy: 3)
        XCTAssertEqual(canvas.frame.minY, expectedParent.minY, accuracy: 3)
        XCTAssertEqual(canvas.frame.width, expectedParent.width, accuracy: 3)
        XCTAssertEqual(canvas.frame.height, expectedParent.height, accuracy: 3)
        app.buttons["capture.region.cancel"].click()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testRegionSelectionShowsFullToolbarThenPinsWithoutToolbar() {
        NSPasteboard.general.clearContents()
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-region-selection"])
        defer { app.terminate() }

        let overlay = app.groups["capture.region.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))

        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.30))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65))
        let startPoint = start.screenPoint
        let endPoint = end.screenPoint
        let initialCaptureFrame = CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(overlay.exists, "Mouse-up must retain the masked region-selection overlay.")
        XCTAssertFalse(app.dialogs["pinned.image"].exists, "Mouse-up must not pin the region automatically.")
        let annotationSurface = app.descendants(matching: .any)["capture.region.annotationSurface"]
        XCTAssertTrue(annotationSurface.waitForExistence(timeout: 3))
        waitForValue(of: annotationSurface, containing: "surfaceInput=enabled")
        XCTAssertFalse(
            app.descendants(matching: .any)["capture.region.preview"].exists,
            "Region confirmation must not expose a cropped screenshot preview."
        )
        waitForValue(of: overlay, containing: "selectionChrome=hidden")
        waitForValue(of: overlay, containing: "overlayInput=ignored")
        let resizeChromeMatches = app.groups.matching(identifier: "capture.region.resizeChrome")
        let resizeChrome = resizeChromeMatches.firstMatch
        XCTAssertTrue(resizeChrome.waitForExistence(timeout: 3))
        XCTAssertEqual(resizeChromeMatches.count, 1, "Region confirmation must expose exactly one resize chrome.")
        waitForValue(of: resizeChrome, containing: "handles=8; resize=enabled")
        waitForValue(of: resizeChrome, containing: "handleAlignment=border")
        waitForValue(of: resizeChrome, containing: "borderHitTarget=full")
        waitForValue(of: resizeChrome, containing: "interiorHitTarget=canvas")
        XCTAssertTrue(app.descendants(matching: .any)["capture.region.toolbar"].waitForExistence(timeout: 3))
        let rectangleTool = app.checkBoxes["pinned.tool.rectangle"]
        XCTAssertTrue(rectangleTool.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.checkBoxes["pinned.tool.crop"].exists,
            "Region confirmation must not expose Crop in its quick toolbar."
        )
        XCTAssertTrue(app.checkBoxes["pinned.tool.text"].exists)
        XCTAssertTrue(app.checkBoxes["pinned.tool.spotlight"].exists)
        XCTAssertTrue(app.buttons["pinned.action.undo"].exists)
        XCTAssertTrue(app.buttons["pinned.action.copy"].exists)
        XCTAssertTrue(app.buttons["pinned.action.save"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["pinned.image.clickThrough"].exists,
            "Click-through has no meaning before the selected region becomes a pinned image."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["pinned.image.visibility"].exists,
            "Temporary image visibility has no meaning during region confirmation."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["pinned.action.openEditor"].exists,
            "The full pinned-image editor action must not appear before Pin."
        )
        let pinButton = app.buttons["capture.region.pin"]
        XCTAssertTrue(pinButton.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["capture.region.cancel"].exists)

        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        waitForValue(of: canvas, containing: "editing=enabled")
        let frameBeforeResize = canvas.frame
        let resizeChromeFrame = resizeChrome.frame
        XCTAssertEqual(frameBeforeResize.minX, initialCaptureFrame.minX, accuracy: 3)
        XCTAssertEqual(frameBeforeResize.minY, initialCaptureFrame.minY, accuracy: 3)
        XCTAssertEqual(frameBeforeResize.width, initialCaptureFrame.width, accuracy: 3)
        XCTAssertEqual(frameBeforeResize.height, initialCaptureFrame.height, accuracy: 3)
        XCTAssertEqual(resizeChromeFrame.minX, frameBeforeResize.minX - 10, accuracy: 1)
        XCTAssertEqual(resizeChromeFrame.minY, frameBeforeResize.minY - 10, accuracy: 1)
        XCTAssertEqual(resizeChromeFrame.maxX, frameBeforeResize.maxX + 10, accuracy: 1)
        XCTAssertEqual(resizeChromeFrame.maxY, frameBeforeResize.maxY + 10, accuracy: 1)

        rectangleTool.click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
            .press(
                forDuration: 0.1,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6))
            )
        waitForValue(of: canvas, containing: "annotations=1")

        let eastHandleX = (frameBeforeResize.maxX - resizeChromeFrame.minX)
            / resizeChromeFrame.width
        let eastHandle = resizeChrome.coordinate(
            withNormalizedOffset: CGVector(dx: eastHandleX, dy: 0.28)
        )
        eastHandle.press(
            forDuration: 0.1,
            thenDragTo: eastHandle.withOffset(CGVector(dx: 64, dy: 0))
        )
        waitForFrameWidth(of: canvas, greaterThan: frameBeforeResize.width + 48)
        let horizontalCaptureFrame = resizeChrome.frame.insetBy(dx: 10, dy: 10)
        XCTAssertEqual(horizontalCaptureFrame.minX, frameBeforeResize.minX, accuracy: 3)
        XCTAssertEqual(horizontalCaptureFrame.width, frameBeforeResize.width + 64, accuracy: 4)
        waitForValue(of: resizeChrome, containing: "resize=enabled")
        waitForValue(of: canvas, containing: "annotations=1")
        waitForValue(of: canvas, containing: "regionPreview=committed")
        waitForValue(of: canvas, containing: "regionPreviewScale=1.00,1.00")
        waitForValue(of: canvas, containing: "regionPreviewAnchorError=0.00")
        waitForValue(of: canvas, containing: "regionPreviewGridError=0.00")

        let resizeChromeFrameBeforeVerticalResize = resizeChrome.frame
        let northHandleY = (horizontalCaptureFrame.minY - resizeChromeFrameBeforeVerticalResize.minY)
            / resizeChromeFrameBeforeVerticalResize.height
        let northHandle = resizeChrome.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: northHandleY)
        )
        northHandle.press(
            forDuration: 0.1,
            thenDragTo: northHandle.withOffset(CGVector(dx: 0, dy: -48))
        )
        waitForFrame(
            of: canvas,
            satisfying: { $0.height > horizontalCaptureFrame.height + 36 },
            message: "Dragging the region's north edge must expand its height."
        )
        let expectedCaptureFrame = resizeChrome.frame.insetBy(dx: 10, dy: 10)
        XCTAssertEqual(expectedCaptureFrame.minY, horizontalCaptureFrame.minY - 48, accuracy: 4)
        XCTAssertEqual(expectedCaptureFrame.height, horizontalCaptureFrame.height + 48, accuracy: 4)
        XCTAssertEqual(expectedCaptureFrame.width, horizontalCaptureFrame.width, accuracy: 3)
        waitForValue(of: resizeChrome, containing: "resize=enabled")
        waitForValue(of: canvas, containing: "annotations=1")
        waitForValue(of: canvas, containing: "regionPreview=committed")
        waitForValue(of: canvas, containing: "regionPreviewScale=1.00,1.00")
        waitForValue(of: canvas, containing: "regionPreviewAnchorError=0.00")
        waitForValue(of: canvas, containing: "regionPreviewGridError=0.00")

        app.checkBoxes["pinned.tool.select"].click()
        let annotationBoundsBeforeCanvasMove = try? annotationBounds(of: canvas)
        let canvasMoveStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.84, dy: 0.78)
        )
        canvasMoveStart.press(
            forDuration: 0.1,
            thenDragTo: canvasMoveStart.withOffset(CGVector(dx: 44, dy: 20))
        )
        waitForFrame(
            of: canvas,
            satisfying: { $0.minX > expectedCaptureFrame.minX + 32 },
            message: "Dragging empty canvas space with Select must move the confirmed capture region."
        )
        let movedCaptureFrame = canvas.frame
        XCTAssertEqual(movedCaptureFrame.width, expectedCaptureFrame.width, accuracy: 2)
        XCTAssertEqual(movedCaptureFrame.height, expectedCaptureFrame.height, accuracy: 2)
        waitForValue(of: resizeChrome, containing: "resize=enabled")
        waitForValue(of: canvas, containing: "regionPreview=committed")
        if let annotationBoundsBeforeCanvasMove {
            let annotationBoundsAfterCanvasMove = try? annotationBounds(of: canvas)
            if let annotationBoundsAfterCanvasMove {
                assertSameFrame(
                    annotationBoundsBeforeCanvasMove,
                    annotationBoundsAfterCanvasMove,
                    message: "Moving the whole canvas must preserve annotation-local geometry."
                )
            }
        }

        pinButton.click()

        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["capture.region.pin"].waitForNonExistence(timeout: 3))
        let pinnedImage = app.dialogs["pinned.image"]
        XCTAssertTrue(pinnedImage.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["pinned.toolbar.window"].exists,
            "An explicitly pinned region must hide the quick annotation toolbar."
        )
        waitForValue(of: canvas, containing: "editing=disabled")
        waitForValue(of: canvas, containing: "windowResize=enabled")
        waitForValue(of: canvas, containing: "windowMoveCursor=grab")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.72)).click()
        XCTAssertTrue(
            (canvas.value as? String)?.contains("annotations=1") == true,
            "A pinned region must not accept additional annotation edits."
        )

        let canvasFrame = canvas.frame
        XCTAssertEqual(canvasFrame.minX, movedCaptureFrame.minX, accuracy: 3)
        XCTAssertEqual(canvasFrame.minY, movedCaptureFrame.minY, accuracy: 3)
        XCTAssertEqual(canvasFrame.width, movedCaptureFrame.width, accuracy: 3)
        XCTAssertEqual(canvasFrame.height, movedCaptureFrame.height, accuracy: 3)

        let moveStart = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50))
        moveStart.press(
            forDuration: 0.1,
            thenDragTo: moveStart.withOffset(CGVector(dx: 44, dy: 28))
        )
        waitForFrame(
            of: canvas,
            satisfying: { $0.minX > canvasFrame.minX + 36 },
            message: "Dragging a read-only pinned image must move its window."
        )

        let frameBeforePinnedResize = canvas.frame
        let pinnedEastEdge = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.998, dy: 0.5))
        pinnedEastEdge.press(
            forDuration: 0.1,
            thenDragTo: pinnedEastEdge.withOffset(CGVector(dx: 48, dy: 0))
        )
        waitForFrame(
            of: canvas,
            satisfying: { $0.width > frameBeforePinnedResize.width + 36 },
            message: "Dragging a pinned-image edge must resize it."
        )

        let keyboardCopyChangeCount = NSPasteboard.general.changeCount
        app.typeKey("c", modifierFlags: .command)
        waitForPasteboardPNG(after: keyboardCopyChangeCount)
        XCTAssertTrue(
            pinnedImage.exists,
            "Command-C must keep a region that advanced through explicit Pin visible."
        )

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.18)).rightClick()
        let copyScreenshot = app.menuItems["pinned.context.copy"]
        XCTAssertTrue(copyScreenshot.waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["pinned.context.toggleToolbar"].exists)
        let contextCopyChangeCount = NSPasteboard.general.changeCount
        copyScreenshot.click()
        waitForPasteboardPNG(after: contextCopyChangeCount)
        XCTAssertTrue(pinnedImage.exists, "Copying a pinned screenshot must keep it pinned.")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.18)).rightClick()
        let showToolbar = app.menuItems["pinned.context.toggleToolbar"]
        XCTAssertTrue(showToolbar.waitForExistence(timeout: 3))
        showToolbar.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["pinned.toolbar.window"].waitForExistence(timeout: 3)
        )
        let pinnedRectangleTool = app.checkBoxes["pinned.tool.rectangle"]
        XCTAssertTrue(pinnedRectangleTool.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.checkBoxes["pinned.tool.crop"].exists,
            "Pinned screenshots must not expose Crop after showing the quick toolbar."
        )
        waitForValue(of: canvas, containing: "editing=enabled")
        XCTAssertFalse(app.buttons["capture.region.pin"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["pinned.image.clickThrough"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["pinned.image.visibility"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["pinned.action.openEditor"].exists)

        pinnedRectangleTool.click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.18))
            .press(
                forDuration: 0.1,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.38))
            )
        waitForValue(of: canvas, containing: "annotations=2")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.08)).rightClick()
        let hideToolbar = app.menuItems["pinned.context.toggleToolbar"]
        XCTAssertTrue(hideToolbar.waitForExistence(timeout: 3))
        hideToolbar.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["pinned.toolbar.window"].waitForNonExistence(timeout: 3)
        )
        waitForValue(of: canvas, containing: "editing=disabled")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(pinnedImage.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testRegionCopyMaterializesOutputAndEndsCaptureWithoutPinning() {
        NSPasteboard.general.clearContents()
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-region-selection"])
        defer { app.terminate() }

        let overlay = app.groups["capture.region.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.32))
            .press(
                forDuration: 0.1,
                thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.60))
            )

        XCTAssertTrue(
            app.descendants(matching: .any)["capture.region.annotationSurface"].waitForExistence(timeout: 3)
        )
        let copy = app.buttons["pinned.action.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        copy.click()

        waitForPasteboardPNG(after: pasteboardChangeCount)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.region.annotationSurface"].waitForNonExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.region.toolbar"].waitForNonExistence(timeout: 3)
        )
        XCTAssertFalse(app.dialogs["pinned.image"].exists)
    }

    @MainActor
    func testRegionCommandCopyWithSelectedAnnotationEndsCapture() {
        NSPasteboard.general.clearContents()
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-region-selection"])
        defer { app.terminate() }

        let overlay = app.groups["capture.region.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.32))
            .press(
                forDuration: 0.1,
                thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.60))
            )

        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let rectangleTool = app.checkBoxes["pinned.tool.rectangle"]
        XCTAssertTrue(rectangleTool.waitForExistence(timeout: 3))
        rectangleTool.click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.20))
            .press(
                forDuration: 0.1,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.60))
            )
        waitForValue(of: canvas, containing: "annotations=1")

        app.typeKey("c", modifierFlags: .command)

        waitForPasteboardPNG(after: pasteboardChangeCount)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.region.annotationSurface"]
                .waitForNonExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.region.toolbar"]
                .waitForNonExistence(timeout: 3)
        )
        XCTAssertFalse(app.dialogs["pinned.image"].exists)
    }

    @MainActor
    func testPinnedToolbarCopyMaterializesOutputAndClosesScreenshot() {
        NSPasteboard.general.clearContents()
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-pinned-lifecycle"])
        defer { app.terminate() }

        let imagePanel = app.dialogs["pinned.image"]
        XCTAssertTrue(imagePanel.waitForExistence(timeout: 5))
        let toolbar = app.descendants(matching: .any)["pinned.toolbar.window"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 3))
        let copy = app.buttons["pinned.action.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        copy.click()

        waitForPasteboardPNG(after: pasteboardChangeCount)
        XCTAssertTrue(imagePanel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(toolbar.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testPinnedScreenshotPersistsAcrossDeactivationReplacesPreviousAndClosesWithEscape() {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-pinned-lifecycle"])
        defer { app.terminate() }

        let pinnedImages = app.dialogs.matching(identifier: "pinned.image")
        let imagePanel = pinnedImages.firstMatch
        XCTAssertTrue(imagePanel.waitForExistence(timeout: 5))
        XCTAssertEqual(pinnedImages.count, 1, "A replacement capture must close the previous screenshot.")

        let toolbars = app.descendants(matching: .any).matching(identifier: "pinned.toolbar.window")
        let toolbar = toolbars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 3))
        XCTAssertEqual(toolbars.count, 1, "A replacement capture must close the previous toolbar.")

        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        XCTAssertEqual(canvas.frame.width, 260, accuracy: 2)
        XCTAssertEqual(canvas.frame.height, 160, accuracy: 2)

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(
            imagePanel.waitForExistence(timeout: 3),
            "The current screenshot must remain visible when Ushot deactivates."
        )
        XCTAssertTrue(
            toolbar.waitForExistence(timeout: 3),
            "The current toolbar must remain visible when Ushot deactivates."
        )
        XCTAssertEqual(pinnedImages.count, 1)
        XCTAssertEqual(toolbars.count, 1)

        app.activate()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(imagePanel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(toolbar.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testPinnedNumberShortcutsAndLineWidthDefaultPersistAcrossLaunches() {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-pinned-lifecycle"])
        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.click()

        app.typeKey("2", modifierFlags: [])
        waitForValue(of: canvas, containing: "tool=rectangle")

        let lineWidth = app.textFields["pinned.annotation.lineWidth"]
        XCTAssertTrue(lineWidth.waitForExistence(timeout: 3))
        lineWidth.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("1")
        app.typeText(".")
        XCTAssertEqual(
            lineWidth.value as? String,
            "1.",
            "The field must preserve a trailing decimal separator while the user is still typing."
        )
        app.typeText("5")
        XCTAssertEqual(lineWidth.value as? String, "1.5")
        app.typeKey(.return, modifierFlags: [])
        app.terminate()

        let reloaded = launch(arguments: ["--uitest-pinned-lifecycle"])
        defer { reloaded.terminate() }
        let reloadedCanvas = reloaded.groups["pinned.canvas"]
        XCTAssertTrue(reloadedCanvas.waitForExistence(timeout: 5))

        reloadedCanvas.click()
        reloaded.typeKey("2", modifierFlags: [])
        waitForValue(of: reloadedCanvas, containing: "tool=rectangle")
        let reloadedLineWidth = reloaded.textFields["pinned.annotation.lineWidth"]
        XCTAssertEqual(reloadedLineWidth.value as? String, "1.5")

        reloaded.typeKey("3", modifierFlags: [])
        waitForValue(of: reloadedCanvas, containing: "tool=ellipse")
    }

    @MainActor
    func testPinnedInlineTextCreatesReeditsMovesAndConsumesFirstEscape() throws {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-pinned-lifecycle"])
        defer { app.terminate() }

        let imagePanel = app.dialogs["pinned.image"]
        XCTAssertTrue(imagePanel.waitForExistence(timeout: 5))
        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let textTool = app.checkBoxes["pinned.tool.text"]
        XCTAssertTrue(textTool.waitForExistence(timeout: 3))
        textTool.click()
        waitForValue(of: canvas, containing: "tool=text")

        let originalPosition = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.52))
        originalPosition.click()
        waitForValue(of: canvas, containing: "textEditing=new")
        let newTextEditor = app.textViews["pinned.text.editor"]
        XCTAssertTrue(newTextEditor.waitForExistence(timeout: 3))
        let newTextFrame = app.groups["pinned.text.frame"]
        XCTAssertTrue(newTextFrame.waitForExistence(timeout: 3))
        XCTAssertEqual(newTextFrame.value as? String, "cornerRadius=4.0;background=clear")
        let emptyEditorFrame = newTextFrame.frame
        waitForValue(of: canvas, containing: "textGeometryConfigurations=1")
        let emptyLineOrigin = try serializedPoint(
            in: canvas,
            marker: "textLineOrigin="
        )
        XCTAssertGreaterThanOrEqual(newTextEditor.frame.width, 200)
        newTextEditor.typeText("First中文")
        waitForValue(of: canvas, containing: "textBaselineError=0.00,0.00")
        waitForValue(of: canvas, containing: "textGeometryConfigurations=1")
        let currentLineOrigin = try serializedPoint(
            in: canvas,
            marker: "textLineOrigin="
        )
        XCTAssertEqual(currentLineOrigin.x, emptyLineOrigin.x, accuracy: 0.01)
        XCTAssertEqual(currentLineOrigin.y, emptyLineOrigin.y, accuracy: 0.01)
        assertSameFrame(
            emptyEditorFrame,
            newTextFrame.frame,
            message: "Typing must not move or resize the anchored inline text field."
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(newTextEditor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(imagePanel.exists, "The first Escape must finish text input, not close the screenshot.")
        waitForValue(of: canvas, containing: "annotations=1")
        waitForValue(of: canvas, containing: "textAnnotations=1")
        waitForValue(of: canvas, containing: "textEditing=inactive")

        let colorMenu = app.popUpButtons["pinned.annotation.color"]
        XCTAssertTrue(colorMenu.waitForExistence(timeout: 3))
        colorMenu.click()
        let blue = app.menuItems["pinned.annotation.color.007AFF"]
        XCTAssertTrue(blue.waitForExistence(timeout: 3))
        blue.click()
        waitForValue(of: canvas, containing: "color=#007AFF")

        let defaultColorProbe = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.76, dy: 0.22)
        )
        defaultColorProbe.click()
        waitForValue(of: canvas, containing: "textEditing=new")
        waitForValue(of: canvas, containing: "color=#FF3B30")
        app.typeKey(.escape, modifierFlags: [])
        waitForValue(of: canvas, containing: "textEditing=inactive")
        waitForValue(of: canvas, containing: "annotations=1")

        originalPosition.click()
        waitForValue(of: canvas, containing: "textEditing=existing")
        waitForValue(of: canvas, containing: "color=#007AFF")
        let existingTextEditor = app.textViews["pinned.text.editor"]
        XCTAssertTrue(existingTextEditor.waitForExistence(timeout: 3))
        let existingTextFrame = app.groups["pinned.text.frame"]
        XCTAssertTrue(existingTextFrame.waitForExistence(timeout: 3))
        let reeditFrame = existingTextFrame.frame
        waitForValue(of: canvas, containing: "textGeometryConfigurations=1")
        let reeditLineOrigin = try serializedPoint(
            in: canvas,
            marker: "textLineOrigin="
        )
        existingTextEditor.typeKey("a", modifierFlags: .command)
        existingTextEditor.typeText("Edited")
        waitForValue(of: canvas, containing: "textBaselineError=0.00,0.00")
        waitForValue(of: canvas, containing: "textGeometryConfigurations=1")
        let editedLineOrigin = try serializedPoint(
            in: canvas,
            marker: "textLineOrigin="
        )
        XCTAssertEqual(editedLineOrigin.x, reeditLineOrigin.x, accuracy: 0.01)
        XCTAssertEqual(editedLineOrigin.y, reeditLineOrigin.y, accuracy: 0.01)
        assertSameFrame(
            reeditFrame,
            existingTextFrame.frame,
            message: "Replacing existing text must keep its inline field anchored."
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(existingTextEditor.waitForNonExistence(timeout: 3))
        waitForValue(of: canvas, containing: "annotations=1")

        let movedPosition = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.52))
        originalPosition.press(forDuration: 0.1, thenDragTo: movedPosition)
        originalPosition.click()
        waitForValue(of: canvas, containing: "textEditing=new")
        app.typeKey(.escape, modifierFlags: [])
        waitForValue(of: canvas, containing: "annotations=1")

        movedPosition.click()
        waitForValue(of: canvas, containing: "textEditing=existing")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(imagePanel.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(imagePanel.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testPinnedInlineTextResizesFromThreeCornersAndDeletesFromCloseButton() throws {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-inline-text-resize"])
        defer { app.terminate() }

        let imagePanel = app.dialogs["pinned.image"]
        XCTAssertTrue(imagePanel.waitForExistence(timeout: 5))
        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        waitForValue(of: canvas, containing: "tool=text")
        waitForValue(of: canvas, containing: "textEditing=new")
        let editor = app.textViews["pinned.text.editor"]
        let textFrame = app.groups["pinned.text.frame"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(textFrame.waitForExistence(timeout: 3))
        let expectedText = "Resize 中文混排"
        waitForValue(of: canvas, containing: "textBaselineError=0.00,0.00")
        XCTAssertEqual(
            editor.value as? String,
            expectedText,
            "The active resize fixture must begin with the complete mixed-script text."
        )

        let northWest = app.buttons["pinned.text.resize.northWest"]
        let southWest = app.buttons["pinned.text.resize.southWest"]
        let southEast = app.buttons["pinned.text.resize.southEast"]
        let deleteButton = app.buttons["pinned.text.delete"]
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        for control in [northWest, southWest, southEast, deleteButton] {
            XCTAssertTrue(control.waitForExistence(timeout: 3))
            guard control.isHittable else {
                XCTFail("Expected active inline-text chrome to be hittable: \(control)")
                return
            }
        }

        let initialFontSize = try serializedScalar(in: canvas, marker: "textFontSize=")
        let initialFrame = textFrame.frame
        let initialLineOrigin = try serializedPoint(in: canvas, marker: "textLineOrigin=")
        northWest.click()
        waitForValue(of: canvas, containing: "textResize=idle")
        XCTAssertEqual(
            try serializedScalar(in: canvas, marker: "textFontSize="),
            initialFontSize,
            accuracy: 0.01,
            "Pressing a resize corner without dragging must not change the font size."
        )
        let lineOriginAfterPress = try serializedPoint(in: canvas, marker: "textLineOrigin=")
        XCTAssertEqual(lineOriginAfterPress.x, initialLineOrigin.x, accuracy: 0.01)
        XCTAssertEqual(lineOriginAfterPress.y, initialLineOrigin.y, accuracy: 0.01)
        assertSameFrame(
            initialFrame,
            textFrame.frame,
            message: "A zero-distance resize must not move an edge-clamped text field."
        )

        func fixedCorner(
            of frame: CGRect,
            whileDragging handleIdentifier: String
        ) -> CGPoint {
            switch handleIdentifier {
            case "southEast":
                return CGPoint(x: frame.minX, y: frame.minY)
            case "northWest":
                return CGPoint(x: frame.maxX, y: frame.maxY)
            case "southWest":
                return CGPoint(x: frame.maxX, y: frame.minY)
            default:
                XCTFail("Unknown inline text resize handle: \(handleIdentifier)")
                return CGPoint(x: CGFloat.nan, y: CGFloat.nan)
            }
        }

        func exerciseResizeStep(
            handle: XCUIElement,
            identifier: String,
            offset: CGVector,
            previousFontSize: CGFloat
        ) throws -> CGFloat {
            let frameBeforeDrag = textFrame.frame
            let fixedCornerBeforeDrag = fixedCorner(
                of: frameBeforeDrag,
                whileDragging: identifier
            )
            let dragStart = handle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            dragStart.press(
                forDuration: 0.1,
                thenDragTo: dragStart.withOffset(offset)
            )

            let resizedFontSize = try waitForSerializedScalar(
                in: canvas,
                marker: "textFontSize=",
                satisfying: { abs($0 - previousFontSize) > 0.05 }
            )
            waitForValue(of: canvas, containing: "textResize=idle")
            waitForValue(of: canvas, containing: "textEditing=new")
            waitForValue(of: canvas, containing: "textFocus=active")
            waitForValue(of: canvas, containing: "textBaselineError=0.00,0.00")

            XCTAssertTrue(
                editor.exists && editor.isHittable,
                "The inline editor must remain active after the \(identifier) drag."
            )
            XCTAssertEqual(
                editor.value as? String,
                expectedText,
                "Dragging \(identifier) must not mutate the mixed-script text."
            )
            XCTAssertEqual(
                app.state,
                .runningForeground,
                "Dragging \(identifier) must not terminate or background the app."
            )
            XCTAssertGreaterThan(
                abs(resizedFontSize - previousFontSize),
                0.05,
                "Each \(identifier) drag checkpoint must produce a visible font-size change."
            )
            XCTAssertLessThan(
                try serializedScalar(
                    in: canvas,
                    marker: "textResizeFixedCornerError="
                ),
                0.51,
                "The corner opposite \(identifier) must remain fixed throughout resizing."
            )

            let frameAfterDrag = textFrame.frame
            let fixedCornerAfterDrag = fixedCorner(
                of: frameAfterDrag,
                whileDragging: identifier
            )
            XCTAssertEqual(
                fixedCornerAfterDrag.x,
                fixedCornerBeforeDrag.x,
                accuracy: 1,
                "The field corner opposite \(identifier) moved horizontally."
            )
            XCTAssertEqual(
                fixedCornerAfterDrag.y,
                fixedCornerBeforeDrag.y,
                accuracy: 1,
                "The field corner opposite \(identifier) moved vertically."
            )

            return resizedFontSize
        }

        var currentFontSize = initialFontSize
        currentFontSize = try exerciseResizeStep(
            handle: southEast,
            identifier: "southEast",
            offset: CGVector(dx: 28, dy: 18),
            previousFontSize: currentFontSize
        )
        let firstSouthEastFontSize = currentFontSize
        currentFontSize = try exerciseResizeStep(
            handle: southEast,
            identifier: "southEast",
            offset: CGVector(dx: 24, dy: 14),
            previousFontSize: currentFontSize
        )
        XCTAssertGreaterThan(
            currentFontSize,
            firstSouthEastFontSize,
            "The enlarged fixture must allow more than one continuous bottom-right growth step."
        )
        XCTAssertGreaterThan(textFrame.frame.height, initialFrame.height)

        for offset in [
            CGVector(dx: 24, dy: 12),
            CGVector(dx: 20, dy: 10)
        ] {
            currentFontSize = try exerciseResizeStep(
                handle: northWest,
                identifier: "northWest",
                offset: offset,
                previousFontSize: currentFontSize
            )
        }

        for offset in [
            CGVector(dx: 24, dy: -12),
            CGVector(dx: 20, dy: -10)
        ] {
            currentFontSize = try exerciseResizeStep(
                handle: southWest,
                identifier: "southWest",
                offset: offset,
                previousFontSize: currentFontSize
            )
        }

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        waitForValue(of: canvas, containing: "annotations=1")
        waitForValue(of: canvas, containing: "textAnnotations=1")

        let emptyDraftPoint = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.80, dy: 0.22)
        )
        emptyDraftPoint.click()
        waitForValue(of: canvas, containing: "textEditing=new")
        app.textViews["pinned.text.editor"].typeText("Discard me")
        let newDraftDelete = app.buttons["pinned.text.delete"]
        XCTAssertTrue(newDraftDelete.waitForExistence(timeout: 3))
        newDraftDelete.click()
        waitForValue(of: canvas, containing: "textEditing=inactive")
        waitForValue(of: canvas, containing: "annotations=1")

        let committedBounds = try annotationBounds(of: canvas)
        documentCoordinate(
            CGPoint(x: committedBounds.midX, y: committedBounds.midY),
            in: canvas
        ).click()
        waitForValue(of: canvas, containing: "textEditing=existing")
        let existingDelete = app.buttons["pinned.text.delete"]
        XCTAssertTrue(existingDelete.waitForExistence(timeout: 3))
        existingDelete.click()
        waitForValue(of: canvas, containing: "annotations=0")
        waitForValue(of: canvas, containing: "textAnnotations=0")

        let undo = app.buttons["pinned.action.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.click()
        waitForValue(of: canvas, containing: "annotations=1")
        waitForValue(of: canvas, containing: "textAnnotations=1")
        XCTAssertTrue(imagePanel.exists)
    }

    @MainActor
    func testRegionToolbarPaletteSpotlightAndAnchoredEffects() throws {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-region-selection"])
        defer { app.terminate() }

        let overlay = app.groups["capture.region.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.24))
            .press(
                forDuration: 0.1,
                thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.72))
            )

        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        XCTAssertTrue(app.checkBoxes["pinned.tool.spotlight"].waitForExistence(timeout: 3))

        let colorMenu = app.popUpButtons["pinned.annotation.color"]
        XCTAssertTrue(colorMenu.waitForExistence(timeout: 3))
        XCTAssertEqual(colorMenu.value as? String, "#FF3B30")
        colorMenu.click()
        let blue = app.menuItems["pinned.annotation.color.007AFF"]
        XCTAssertTrue(blue.waitForExistence(timeout: 3))
        blue.click()
        waitForValue(of: canvas, containing: "color=#007AFF")

        app.checkBoxes["pinned.tool.mosaic"].click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.30))
            .press(
                forDuration: 0.1,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.54))
            )
        waitForValue(of: canvas, containing: "annotations=1")
        app.checkBoxes["pinned.tool.select"].click()
        waitForValue(of: canvas, containing: "selectionHandles=0")
        let beforeMove = try selectionBounds(of: canvas)
        let center = CGPoint(x: beforeMove.midX, y: beforeMove.midY)
        let start = documentCoordinate(center, in: canvas)
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 90, dy: 45)))
        let afterMove = try selectionBounds(of: canvas)

        assertSameFrame(
            beforeMove,
            afterMove,
            message: "Mosaic annotations must remain anchored to the pixels they obscure."
        )
        app.buttons["capture.region.cancel"].click()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testRegionHighlightSurvivesTallResizeAndBodyClickWithSemanticYellow() throws {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-region-selection"])
        defer { app.terminate() }

        let overlay = app.groups["capture.region.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.20))
            .press(
                forDuration: 0.1,
                thenDragTo: overlay.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.78, dy: 0.78)
                )
            )

        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        let highlight = app.checkBoxes["pinned.tool.highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 3))
        highlight.click()
        waitForValue(of: canvas, containing: "tool=highlight")
        waitForValue(of: canvas, containing: "color=#FFCC00")

        let thinStart = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.24, dy: 0.50)
        )
        let thinEnd = canvas.coordinate(
            withNormalizedOffset: CGVector(dx: 0.62, dy: 0.58)
        )
        thinStart.press(forDuration: 0.1, thenDragTo: thinEnd)
        let thinBounds = try waitForSerializedRect(
            in: canvas,
            marker: "selectionBounds=",
            containing: ["annotations=1", "selectionHandles=8", "interaction=idle"]
        ) { rect in
            rect.width > 0 && rect.height > 2
        }
        XCTAssertGreaterThan(thinBounds.width, thinBounds.height * 4)

        let verticalGrowth = canvas.frame.height * 0.35
        let northHandle = CGPoint(x: thinBounds.midX, y: thinBounds.maxY)
        documentCoordinate(northHandle, in: canvas)
            .press(
                forDuration: 0.1,
                thenDragTo: documentCoordinate(
                    CGPoint(x: northHandle.x, y: northHandle.y + verticalGrowth),
                    in: canvas
                )
            )

        let resizedBounds = try waitForSerializedRect(
            in: canvas,
            marker: "selectionBounds=",
            containing: ["annotations=1", "selectionHandles=8", "interaction=idle"]
        ) { rect in
            rect.height > thinBounds.height * 4
        }
        XCTAssertEqual(resizedBounds.minX, thinBounds.minX, accuracy: 3)
        XCTAssertEqual(resizedBounds.minY, thinBounds.minY, accuracy: 3)
        XCTAssertEqual(resizedBounds.width, thinBounds.width, accuracy: 3)
        XCTAssertEqual(
            resizedBounds.height,
            thinBounds.height + verticalGrowth,
            accuracy: 5
        )
        XCTAssertGreaterThan(resizedBounds.height, thinBounds.height * 5)

        let select = app.checkBoxes["pinned.tool.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.click()
        waitForValue(of: canvas, containing: "tool=select")
        waitForValue(of: canvas, containing: "color=#FF3B30")

        documentCoordinate(
            CGPoint(x: canvas.frame.width * 0.85, y: canvas.frame.height * 0.15),
            in: canvas
        ).click()
        waitForValue(of: canvas, containing: "selectionHandles=0")
        assertSameFrame(
            resizedBounds,
            try annotationBounds(of: canvas),
            message: "Deselecting a resized highlight must not mutate its document geometry."
        )

        documentCoordinate(
            CGPoint(x: resizedBounds.midX, y: resizedBounds.midY),
            in: canvas
        ).click()
        waitForValue(of: canvas, containing: "selectionHandles=8")
        waitForValue(of: canvas, containing: "color=#FFCC00")

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(canvas.exists)
        XCTAssertEqual(
            app.popUpButtons["pinned.annotation.color"].value as? String,
            "#FFCC00"
        )
        assertSameFrame(
            resizedBounds,
            try selectionBounds(of: canvas),
            message: "Clicking the resized highlight body must not mutate its selection bounds."
        )
        assertSameFrame(
            resizedBounds,
            try annotationBounds(of: canvas),
            message: "Clicking the resized highlight body must not mutate its document geometry."
        )
    }

    @MainActor
    func testPinnedAnnotationSelectionMovesAndResizesWithHandles() throws {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-pinned-lifecycle"])
        defer { app.terminate() }

        XCTAssertTrue(app.dialogs["pinned.image"].waitForExistence(timeout: 5))
        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let rectangle = app.checkBoxes["pinned.tool.rectangle"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 3))
        rectangle.click()

        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.28))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.66))
        start.press(forDuration: 0.1, thenDragTo: end)
        waitForValue(of: canvas, containing: "annotations=1")
        waitForValue(of: canvas, containing: "selectionOutline=hidden")
        waitForValue(of: canvas, containing: "selectionHandles=8")

        let initialBounds = try selectionBounds(of: canvas)
        XCTAssertGreaterThan(initialBounds.width, 60)
        XCTAssertGreaterThan(initialBounds.height, 40)

        let initialCenter = CGPoint(x: initialBounds.midX, y: initialBounds.midY)
        documentCoordinate(initialCenter, in: canvas)
            .press(
                forDuration: 0.1,
                thenDragTo: documentCoordinate(
                    CGPoint(x: initialCenter.x + 42, y: initialCenter.y + 14),
                    in: canvas
                )
            )
        let movedBounds = try selectionBounds(of: canvas)
        XCTAssertEqual(movedBounds.minX, initialBounds.minX + 42, accuracy: 4)
        XCTAssertEqual(movedBounds.minY, initialBounds.minY + 14, accuracy: 4)
        XCTAssertEqual(movedBounds.width, initialBounds.width, accuracy: 2)
        XCTAssertEqual(movedBounds.height, initialBounds.height, accuracy: 2)

        let eastHandle = CGPoint(x: movedBounds.maxX, y: movedBounds.midY)
        documentCoordinate(eastHandle, in: canvas)
            .press(
                forDuration: 0.1,
                thenDragTo: documentCoordinate(
                    CGPoint(x: eastHandle.x + 36, y: eastHandle.y),
                    in: canvas
                )
            )
        let resizedBounds = try selectionBounds(of: canvas)
        XCTAssertEqual(resizedBounds.minX, movedBounds.minX, accuracy: 3)
        XCTAssertEqual(resizedBounds.height, movedBounds.height, accuracy: 3)
        XCTAssertEqual(resizedBounds.width, movedBounds.width + 36, accuracy: 4)
        waitForValue(of: canvas, containing: "interaction=idle")
    }

    @MainActor
    func testPinnedPressImmediatelyUsesClosedHandBeforeMovement() {
        let app = launch(arguments: [
            "--uitest-reset-settings",
            "--uitest-pinned-cursor-press"
        ])
        defer { app.terminate() }

        XCTAssertTrue(app.dialogs["pinned.image"].waitForExistence(timeout: 5))
        let canvas = app.groups["pinned.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 3))
        waitForValue(of: canvas, containing: "windowMoveState=idle-open-hand")
        XCTAssertNotEqual(
            app.state,
            .notRunning,
            "The native zero-movement press regression must complete without terminating the app."
        )
    }

    @MainActor
    func testPinnedEscapeMonitorDoesNotStealCanvasEditorTextEscape() {
        let app = launch(arguments: ["--uitest-reset-settings", "--uitest-pinned-lifecycle"])
        defer { app.terminate() }

        let imagePanel = app.dialogs["pinned.image"]
        XCTAssertTrue(imagePanel.waitForExistence(timeout: 5))
        let openEditor = app.buttons["pinned.action.openEditor"]
        XCTAssertTrue(openEditor.waitForExistence(timeout: 3))
        openEditor.click()

        let editorWindow = app.windows["editor.window"]
        XCTAssertTrue(editorWindow.waitForExistence(timeout: 5))
        let textTool = editorWindow.buttons["editor.tool.text"]
        XCTAssertTrue(textTool.waitForExistence(timeout: 3))
        textTool.click()
        let editorCanvas = editorWindow.groups["pinned.canvas"]
        XCTAssertTrue(editorCanvas.waitForExistence(timeout: 3))
        editorCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.55)).click()

        let textEditor = editorWindow.textViews["pinned.text.editor"]
        XCTAssertTrue(textEditor.waitForExistence(timeout: 3))
        textEditor.typeText("Canvas")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(textEditor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(editorWindow.exists, "Escape in Canvas text input must keep the Canvas Editor open.")
        XCTAssertTrue(imagePanel.exists, "The pinned Escape monitor must not close the screenshot from another window.")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(editorWindow.waitForNonExistence(timeout: 3))
        app.buttons["pinned.action.close"].click()
        XCTAssertTrue(imagePanel.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testColorPickerFirstArrowPublishesTheAdjacentRetinaPixel() throws {
        let app = launch(arguments: [
            "--uitest-reset-settings",
            "--uitest-color-picker-first-nudge"
        ])
        defer { app.terminate() }

        let overlay = app.groups["colorPicker.overlay"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue(
            (overlay.value as? String)?.contains("state=waiting") == true,
            "The regression fixture must keep the older initial sample in flight."
        )
        let pixelWidth = Int((overlay.frame.width * 2).rounded(.up))
        let pixelHeight = Int((overlay.frame.height * 2).rounded(.up))
        let initialPixelX = pixelWidth / 2
        let initialPixelY = pixelHeight / 2

        app.typeKey(.rightArrow, modifierFlags: [])

        waitForValue(
            of: overlay,
            containing: "pixel=\(initialPixelX + 1),\(initialPixelY)",
            timeout: 12
        )
        waitForValue(of: overlay, containing: "copy=#0000FF", timeout: 12)
        waitForValue(
            of: overlay,
            containing: "magnifier=11x11; magnifierCenter=5,5",
            timeout: 12
        )
        waitForValue(
            of: overlay,
            containing: "nudgePixel=\(initialPixelX + 1),\(initialPixelY)",
            timeout: 12
        )
        waitForValue(
            of: overlay,
            containing: "firstPublishedAfterNudge=\(initialPixelX + 1),\(initialPixelY)",
            timeout: 12
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testColorPickerFirstArrowRepaintsVisiblePreviewAndSwatch() throws {
        let app = launch(arguments: [
            "--uitest-reset-settings",
            "--uitest-color-picker-visible-first-nudge"
        ])
        defer { app.terminate() }

        let overlay = app.groups["colorPicker.overlay"].firstMatch
        let card = app.groups["colorPicker.card"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        overlay.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).hover()
        let initialPixelX = Int(overlay.frame.width)
        waitForValue(of: overlay, containing: "pixel=\(initialPixelX),")
        waitForValue(of: overlay, containing: "copy=#FF0000")

        let before = try waitForColorPickerCard(
            card,
            toRender: .red,
            timeout: 3
        )
        let beforeAttachment = XCTAttachment(screenshot: before)
        beforeAttachment.name = "Color picker before the first Right Arrow"
        beforeAttachment.lifetime = .deleteOnSuccess
        add(beforeAttachment)

        app.typeKey(.rightArrow, modifierFlags: [])

        let after = try waitForColorPickerCard(
            card,
            toRender: .blue,
            timeout: 2
        )
        let afterAttachment = XCTAttachment(screenshot: after)
        afterAttachment.name = "Color picker after one Right Arrow"
        afterAttachment.lifetime = .deleteOnSuccess
        add(afterAttachment)
        waitForValue(of: overlay, containing: "copy=#0000FF", timeout: 2)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testColorPickerPanelAcceptsKeyboardCommandsAndCopiesFreshSample() throws {
        NSPasteboard.general.clearContents()
        let app = launch(arguments: [
            "--uitest-reset-settings",
            "--uitest-color-picker"
        ])
        defer { app.terminate() }

        let overlay = app.groups["colorPicker.overlay"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        waitForValue(of: overlay, containing: "state=ready")

        let valueBeforeEdgeMove = try XCTUnwrap(overlay.value as? String)
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.47)).hover()
        waitForValueChange(of: overlay, from: valueBeforeEdgeMove)
        let card = app.groups["colorPicker.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertEqual(card.frame.width, 430, accuracy: 2)
        XCTAssertEqual(card.frame.height, 330, accuracy: 2)
        XCTAssertTrue(overlay.frame.contains(card.frame), "The color card must remain fully on screen.")

        let valueBeforeMove = try XCTUnwrap(overlay.value as? String)
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.47)).hover()
        waitForValueChange(of: overlay, from: valueBeforeMove)
        let initialPixel = try serializedPoint(in: overlay, marker: "pixel=")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Color picker card layout"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.typeKey(.tab, modifierFlags: [])
        waitForValue(of: overlay, containing: "colorSpace=displayP3")

        app.typeKey(.rightArrow, modifierFlags: [])
        waitForValue(
            of: overlay,
            containing: "pixel=\(Int(initialPixel.x) + 1),\(Int(initialPixel.y))"
        )

        app.typeKey(.rightArrow, modifierFlags: .shift)
        waitForValue(
            of: overlay,
            containing: "pixel=\(Int(initialPixel.x) + 11),\(Int(initialPixel.y))"
        )

        NSPasteboard.general.clearContents()
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        app.typeKey("c", modifierFlags: .command)
        let copiedValue = waitForPasteboardString(after: pasteboardChangeCount)
        XCTAssertTrue(copiedValue.hasPrefix("color(display-p3 "))
        XCTAssertTrue(
            overlay.waitForNonExistence(timeout: 3),
            "Command-C must close the color picker after copying the fresh sample."
        )
    }

    private enum ColorPickerRenderedPrimaryColor: String {
        case red
        case blue

        func matches(_ color: ColorPickerRenderedRGB) -> Bool {
            switch self {
            case .red:
                color.red >= 0.8 && color.green <= 0.2 && color.blue <= 0.2
            case .blue:
                color.blue >= 0.8 && color.red <= 0.2 && color.green <= 0.2
            }
        }
    }

    private struct ColorPickerRenderedRGB: CustomStringConvertible {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        var description: String {
            String(
                format: "rgb(%.3f, %.3f, %.3f)",
                red,
                green,
                blue
            )
        }
    }

    @MainActor
    private func waitForColorPickerCard(
        _ card: XCUIElement,
        toRender expected: ColorPickerRenderedPrimaryColor,
        timeout: TimeInterval
    ) throws -> XCUIScreenshot {
        let deadline = Date().addingTimeInterval(timeout)
        var lastScreenshot = card.screenshot()
        var lastSwatch = try colorPickerRenderedColor(
            in: lastScreenshot,
            normalizedPoint: CGPoint(x: 300.0 / 430.0, y: 34.0 / 330.0)
        )
        var lastMagnifierCenter = try colorPickerRenderedColor(
            in: lastScreenshot,
            normalizedPoint: CGPoint(x: 91.0 / 430.0, y: 91.0 / 330.0)
        )

        while !expected.matches(lastSwatch)
                || !expected.matches(lastMagnifierCenter)
        {
            guard Date() < deadline else {
                let failureScreenshot = XCTAttachment(screenshot: lastScreenshot)
                failureScreenshot.name = "Color picker visible color assertion failure"
                failureScreenshot.lifetime = .keepAlways
                add(failureScreenshot)
                throw NSError(
                    domain: "UshotAppUITests.ColorPickerVisibleColor",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Expected \(expected.rawValue), swatch was \(lastSwatch), magnifier center was \(lastMagnifierCenter)."
                    ]
                )
            }
            Thread.sleep(forTimeInterval: 0.03)
            lastScreenshot = card.screenshot()
            lastSwatch = try colorPickerRenderedColor(
                in: lastScreenshot,
                normalizedPoint: CGPoint(x: 300.0 / 430.0, y: 34.0 / 330.0)
            )
            lastMagnifierCenter = try colorPickerRenderedColor(
                in: lastScreenshot,
                normalizedPoint: CGPoint(x: 91.0 / 430.0, y: 91.0 / 330.0)
            )
        }
        return lastScreenshot
    }

    private func colorPickerRenderedColor(
        in screenshot: XCUIScreenshot,
        normalizedPoint: CGPoint
    ) throws -> ColorPickerRenderedRGB {
        var proposedRect = CGRect(origin: .zero, size: screenshot.image.size)
        guard let image = screenshot.image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw NSError(
                domain: "UshotAppUITests.ColorPickerVisibleColor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The card screenshot has no CGImage."]
            )
        }
        let pixelX = min(
            max(0, Int((normalizedPoint.x * CGFloat(image.width)).rounded(.down))),
            image.width - 1
        )
        let pixelY = min(
            max(0, Int((normalizedPoint.y * CGFloat(image.height)).rounded(.down))),
            image.height - 1
        )
        guard let pixel = image.cropping(to: CGRect(
            x: pixelX,
            y: pixelY,
            width: 1,
            height: 1
        )), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw NSError(
                domain: "UshotAppUITests.ColorPickerVisibleColor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The card screenshot pixel could not be read."]
            )
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else {
            throw NSError(
                domain: "UshotAppUITests.ColorPickerVisibleColor",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The card screenshot pixel could not be rendered."]
            )
        }
        return ColorPickerRenderedRGB(
            red: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255
        )
    }

    @MainActor
    private func waitForValue(
        of element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 5
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (element.value as? String)?.contains(expected) == true
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        let actualValue = String(describing: element.value)
        XCTAssertEqual(
            result,
            .completed,
            "Expected accessibility value to contain '\(expected)'; actual value: \(actualValue)"
        )
    }

    @MainActor
    private func waitForValueChange(of element: XCUIElement, from originalValue: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let value = element.value as? String else { return false }
                return value != originalValue && value.contains("state=ready")
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.isEnabled },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    @MainActor
    private func waitForFrameWidth(of element: XCUIElement, greaterThan minimum: CGFloat) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.frame.width > minimum },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func waitForFrame(
        of element: XCUIElement,
        satisfying condition: @escaping (CGRect) -> Bool,
        message: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition(element.frame) },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            message
        )
    }

    @MainActor
    private func waitForPasteboardPNG(after changeCount: Int) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                NSPasteboard.general.changeCount > changeCount
                    && !(NSPasteboard.general.data(forType: .png)?.isEmpty ?? true)
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func waitForPasteboardString(after changeCount: Int) -> String {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                NSPasteboard.general.changeCount > changeCount
                    && NSPasteboard.general.string(forType: .string) != nil
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    private func assertSameFrame(
        _ expected: CGRect,
        _ actual: CGRect,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, message, file: file, line: line)
    }

    @MainActor
    private func serializedPoint(
        in element: XCUIElement,
        marker: String
    ) throws -> CGPoint {
        let value = try XCTUnwrap(element.value as? String)
        let tail = try XCTUnwrap(value.range(of: marker)).upperBound
        let serialized = value[tail...].split(separator: ";", maxSplits: 1)[0]
        let components = serialized.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(components.count, 2, "Invalid point for \(marker) in: \(value)")
        guard components.count == 2 else {
            return CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        }
        return CGPoint(x: components[0], y: components[1])
    }

    @MainActor
    private func serializedScalar(
        in element: XCUIElement,
        marker: String
    ) throws -> CGFloat {
        let value = try XCTUnwrap(element.value as? String)
        let tail = try XCTUnwrap(value.range(of: marker)).upperBound
        let serialized = value[tail...].split(separator: ";", maxSplits: 1)[0]
        return CGFloat(try XCTUnwrap(
            Double(serialized),
            "Invalid scalar for \(marker) in: \(value)"
        ))
    }

    @MainActor
    private func waitForSerializedScalar(
        in element: XCUIElement,
        marker: String,
        satisfying condition: @escaping (CGFloat) -> Bool,
        timeout: TimeInterval = 5
    ) throws -> CGFloat {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let value = element.value as? String,
                      let markerRange = value.range(of: marker),
                      let serialized = value[markerRange.upperBound...]
                        .split(separator: ";", maxSplits: 1)
                        .first,
                      let scalar = Double(serialized)
                else { return false }
                return condition(CGFloat(scalar))
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
        return try serializedScalar(in: element, marker: marker)
    }

    @MainActor
    private func waitForSerializedRect(
        in element: XCUIElement,
        marker: String,
        containing expectedFragments: [String],
        timeout: TimeInterval = 5,
        satisfying condition: @escaping (CGRect) -> Bool
    ) throws -> CGRect {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let value = element.value as? String,
                      expectedFragments.allSatisfy(value.contains),
                      let markerRange = value.range(of: marker)
                else { return false }
                let components = value[markerRange.upperBound...]
                    .split(separator: ";", maxSplits: 1)[0]
                    .split(separator: ",")
                    .compactMap { Double($0) }
                guard components.count == 4 else { return false }
                return condition(CGRect(
                    x: components[0],
                    y: components[1],
                    width: components[2],
                    height: components[3]
                ))
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
            throw NSError(
                domain: "UshotAppUITests.SerializedRectTimeout",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Timed out waiting for \(marker) with \(expectedFragments); actual value: \(String(describing: element.value))"
                ]
            )
        }
        return try serializedRect(in: element, marker: marker)
    }

    @MainActor
    private func selectionBounds(of canvas: XCUIElement) throws -> CGRect {
        try serializedRect(in: canvas, marker: "selectionBounds=")
    }

    @MainActor
    private func annotationBounds(of canvas: XCUIElement) throws -> CGRect {
        try serializedRect(in: canvas, marker: "annotationBounds=")
    }

    @MainActor
    private func serializedRect(in canvas: XCUIElement, marker: String) throws -> CGRect {
        let value = try XCTUnwrap(canvas.value as? String)
        let tail = try XCTUnwrap(value.range(of: marker)).upperBound
        let serialized = value[tail...].split(separator: ";", maxSplits: 1)[0]
        let components = serialized.split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(components.count, 4, "Invalid rect for \(marker) in: \(value)")
        guard components.count == 4 else { return .zero }
        return CGRect(
            x: components[0],
            y: components[1],
            width: components[2],
            height: components[3]
        )
    }

    @MainActor
    private func documentCoordinate(
        _ point: CGPoint,
        in canvas: XCUIElement
    ) -> XCUICoordinate {
        canvas.coordinate(withNormalizedOffset: CGVector(
            dx: point.x / canvas.frame.width,
            dy: 1 - point.y / canvas.frame.height
        ))
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication(url: targetApplicationURL())
        app.launchArguments = arguments
        app.launchEnvironment["USHOT_UI_TEST_SETTINGS_SUITE"] =
            isolatedSettingsSuiteName
        app.launch()
        return app
    }

    private func targetApplicationURL() -> URL {
        let productsDirectory = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let applicationURL = productsDirectory.appendingPathComponent("Ushot.app", isDirectory: true)
        precondition(
            FileManager.default.fileExists(atPath: applicationURL.path),
            "The UI test target application is missing at \(applicationURL.path)."
        )
        return applicationURL
    }
}
