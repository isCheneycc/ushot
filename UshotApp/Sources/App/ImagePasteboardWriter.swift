import AppKit
import UshotCore

/// Accepts encoded PNG data so callers can retain their existing image cache.
@MainActor
func writeImageToPasteboard(
    _ image: CGImage,
    pngData: Data,
    pasteboard: NSPasteboard = .general
) throws {
    let item = NSPasteboardItem()
    item.setData(pngData, forType: .png)
    if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
        item.setData(tiff, forType: .tiff)
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
        throw ScreenshotAppError.exportFailed(
            description: "The pasteboard rejected the rendered image."
        )
    }
}
