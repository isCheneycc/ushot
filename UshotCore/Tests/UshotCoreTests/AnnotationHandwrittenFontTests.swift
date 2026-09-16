import AppKit
import CoreText
import CryptoKit
import Foundation
import Testing
@testable import UshotCore

/// These tests exercise font resources and document state only. They do not
/// instantiate an editor, render an annotation or validate interface layout.
struct AnnotationHandwrittenFontTests {
    @Test
    func handwrittenFontAutomaticallyRegistersBundledChineseFallback() throws {
        let font = try AnnotationTextLayout.resolvedFont(style: AnnotationStyle(
            fontSize: 24,
            fontName: AnnotationFonts.handwrittenFontName
        )) as CTFont
        try AnnotationFonts.register()
        try AnnotationFonts.register()

        #expect(CTFontCopyPostScriptName(font) as String == AnnotationFonts.handwrittenFontName)
        let chinese = "手写字体中文" as CFString
        let fallback = CTFontCreateForString(
            font,
            chinese,
            CFRange(location: 0, length: CFStringGetLength(chinese))
        )
        #expect(
            CTFontCopyPostScriptName(fallback) as String
                == AnnotationFonts.handwrittenFallbackFontName
        )
        try requireBundledSource(font, name: AnnotationFonts.handwrittenFontName)
        try requireBundledSource(fallback, name: AnnotationFonts.handwrittenFallbackFontName)
        #expect(
            try AnnotationTextLayout.stableFontSourceFingerprint(font)
                != AnnotationTextLayout.stableFontSourceFingerprint(fallback)
        )
        requireGlyphCoverage("Handwritten 0123456789", font: font)
        requireGlyphCoverage("手写字体中文", font: fallback)

        let mixedLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Aa 中文",
            attributes: [.font: font as NSFont]
        ))
        let runs = CTLineGetGlyphRuns(mixedLine) as! [CTRun]
        let sourceNames = try Set(runs.map { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = try #require(
                attributes.object(forKey: kCTFontAttributeName as String) as? NSFont
            )
            try requireBundledSource(runFont as CTFont, name: runFont.fontName)
            return runFont.fontName
        })
        #expect(sourceNames == [
            AnnotationFonts.handwrittenFontName,
            AnnotationFonts.handwrittenFallbackFontName
        ])

        let directChinese = try AnnotationTextLayout.resolvedFont(style: AnnotationStyle(
            fontSize: 24,
            fontName: AnnotationFonts.handwrittenFallbackFontName
        ))
        try requireBundledSource(
            directChinese as CTFont,
            name: AnnotationFonts.handwrittenFallbackFontName
        )
    }

    @Test
    func systemAndInstalledFontSelectionKeepTheirExistingResolution() throws {
        let system = try AnnotationTextLayout.resolvedFont(style: AnnotationStyle(
            fontSize: 18,
            fontWeight: .semibold
        ))
        #expect(system == NSFont.systemFont(ofSize: 18, weight: .semibold))
        let installed = try AnnotationTextLayout.resolvedFont(style: AnnotationStyle(
            fontSize: 18,
            fontName: "Helvetica"
        ))
        #expect(installed.fontName == "Helvetica")
    }

    @Test
    func fontChangePreservesDocumentAnchorAndSurvivesJSONRoundTrip() throws {
        var original = try makeTextItem()
        original.transform = AnnotationTransform(
            translation: CGSize(width: 10, height: -5),
            rotationRadians: 0.4,
            scaleX: 1.2,
            scaleY: 0.8
        )
        let updated = try AnnotationTextLayout.reflowedTextItem(
            original,
            text: original.text ?? "",
            fontSize: original.style.fontSize,
            fontSelection: .named(AnnotationFonts.handwrittenFontName)
        )
        let payload = try #require(updated.textLayout)
        #expect(updated.style.fontName == AnnotationFonts.handwrittenFontName)
        #expect(payload.input?.fontName == AnnotationFonts.handwrittenFontName)
        #expect(updated.transform == original.transform)
        #expect(payload.wrapWidth == original.textLayout?.wrapWidth)
        #expect(updated.geometry != original.geometry)
        let originalAnchor = try anchor(of: original)
        let updatedAnchor = try anchor(of: updated)
        #expect(abs(originalAnchor.x - updatedAnchor.x) < 0.001)
        #expect(abs(originalAnchor.y - updatedAnchor.y) < 0.001)

        let document = makeDocument(item: updated)
        let encoded = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: encoded) == document)

        let preserved = try AnnotationTextLayout.reflowedTextItem(
            updated,
            text: updated.text ?? "",
            fontSize: updated.style.fontSize
        )
        #expect(preserved == updated)
        let system = try AnnotationTextLayout.reflowedTextItem(
            updated,
            text: updated.text ?? "",
            fontSize: updated.style.fontSize,
            fontSelection: .system
        )
        #expect(system.style.fontName == nil)
        #expect(system.textLayout?.input?.fontName == nil)
    }

    @Test @MainActor
    func discreteFontChangeHasOneCompleteUndoRecord() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        try controller.updateTextItemLayout(
            id: original.id,
            text: original.text ?? "",
            fontSize: original.style.fontSize,
            wrapWidthStrategy: .preserve,
            fontSelection: .named(AnnotationFonts.handwrittenFontName)
        )
        let updated = try #require(controller.document.annotations.first)
        #expect(updated.style.fontName == AnnotationFonts.handwrittenFontName)
        #expect(controller.undoStack.count == 1)
        controller.undo()
        #expect(controller.document.annotations == [original])
        controller.redo()
        #expect(controller.document.annotations == [updated])
    }

    @Test @MainActor
    func continuousFontChangeCommitsTogetherAndCanBeCancelled() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        let transaction = controller.beginContinuousEdit(
            label: "Change text font",
            owner: "font-persistence-test",
            itemID: original.id
        )
        #expect(try controller.previewTextItemLayout(
            transaction: transaction,
            id: original.id,
            text: original.text ?? "",
            fontSize: original.style.fontSize,
            wrapWidthStrategy: .preserve,
            fontSelection: .named(AnnotationFonts.handwrittenFontName)
        ))
        #expect(try controller.previewTextItemLayout(
            transaction: transaction,
            id: original.id,
            text: original.text ?? "",
            fontSize: original.style.fontSize + 2,
            wrapWidthStrategy: .scaleWithFont
        ))
        #expect(controller.undoStack.isEmpty)
        #expect(controller.commitContinuousEdit(transaction))
        #expect(controller.undoStack.count == 1)
        controller.undo()
        #expect(controller.document.annotations == [original])

        let cancelled = controller.beginContinuousEdit(
            label: "Cancel text font",
            owner: "font-persistence-cancellation-test",
            itemID: original.id
        )
        #expect(try controller.previewTextItemLayout(
            transaction: cancelled,
            id: original.id,
            text: original.text ?? "",
            fontSize: original.style.fontSize,
            wrapWidthStrategy: .preserve,
            fontSelection: .named(AnnotationFonts.handwrittenFontName)
        ))
        #expect(controller.cancelContinuousEdit(cancelled))
        #expect(controller.document.annotations == [original])
        #expect(controller.undoStack.isEmpty)
    }

    @Test @MainActor
    func unavailableFontCannotPublishOrCreateAnUndoRecord() throws {
        let original = try makeTextItem()
        let controller = AnnotationDocumentController(document: makeDocument(item: original))
        let startingState = controller.state
        let missingName = "Ushot-Intentionally-Unavailable-Handwritten-Test-Font"
        #expect(throws: AnnotationTextRenderingError.fontUnavailable(missingName)) {
            try controller.updateTextItemLayout(
                id: original.id,
                text: original.text ?? "",
                fontSize: original.style.fontSize,
                wrapWidthStrategy: .preserve,
                fontSelection: .named(missingName)
            )
        }
        #expect(controller.state == startingState)
        #expect(controller.undoStack.isEmpty)
    }

    private func requireBundledSource(_ font: CTFont, name: String) throws {
        let url = try #require(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        let expectedFileName = name == AnnotationFonts.handwrittenFallbackFontName
            ? "Xiaolai-Regular.ttf"
            : "Excalifont-Regular.ttf"
        #expect(url.lastPathComponent == expectedFileName)
        #expect(url.deletingLastPathComponent().lastPathComponent == "Fonts")
        #expect(CTFontManagerGetScopeForURL(url as CFURL) == .process)
        let sourceDigest = SHA256.hash(data: try Data(contentsOf: url))
        let sourceSHA = sourceDigest.map {
            String(format: "%02x", $0)
        }.joined()
        let expectedSourceSHA = name == AnnotationFonts.handwrittenFallbackFontName
            ? "17e58fb25e7a421b64ebea1c50104fadf752d9045fb102501434bce577e22b3f"
            : "1255348616f44589c924a8e4dc6798723dea3f8b373efa388de7e8f6296b6562"
        #expect(sourceSHA == expectedSourceSHA)
        // The fingerprint also supports a complete-table digest when stable
        // filesystem generation metadata is unavailable. Both paths must be
        // reproducible, while the separate check above pins exact asset bytes.
        let sourceFingerprint = try AnnotationTextLayout.stableFontSourceFingerprint(font)
        let fontCopy = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, nil)
        #expect(sourceFingerprint.count == 64)
        #expect(try AnnotationTextLayout.stableFontSourceFingerprint(fontCopy) == sourceFingerprint)
    }

    private func requireGlyphCoverage(_ text: String, font: CTFont) {
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
        #expect(glyphs.allSatisfy { $0 != 0 })
    }

    private func makeTextItem() throws -> AnnotationItem {
        let text = "Handwritten 手写字体"
        let style = AnnotationStyle(fontSize: 18)
        let layout = try AnnotationTextLayout.newTextLayout(
            baselineAnchor: CGPoint(x: 60, y: 100),
            text: text,
            style: style,
            maximumWrapWidth: 160
        )
        return AnnotationItem(
            kind: .text,
            zIndex: 0,
            geometry: .rect(layout.rect),
            style: style,
            text: text,
            textLayout: layout.payload
        )
    }

    private func makeDocument(item: AnnotationItem) -> AnnotationDocument {
        AnnotationDocument(
            baseImageReference: ImageReference(pixelSize: CGSize(width: 320, height: 200)),
            canvasSize: CGSize(width: 320, height: 200),
            annotations: [item]
        )
    }

    private func anchor(of item: AnnotationItem) throws -> CGPoint {
        let rectangle: CGRect? = if case .rect(let rect) = item.geometry { rect } else { nil }
        let rect = try #require(rectangle)
        return AnnotationTextLayout.alignmentAnchor(
            in: rect,
            text: item.text ?? "",
            style: item.style,
            layout: item.textLayout
        )
    }
}
