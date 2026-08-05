import AppKit
import SwiftUI
import UshotCore

@MainActor
final class HistoryWindowController: NSWindowController {
    private let model: HistoryBrowserModel

    init(
        store: any ScreenshotHistoryStoring,
        settingsStore: SettingsStore,
        exporter: any ImageExporting = SystemImageExporter(),
        onOpenSession: @escaping (AnnotationEditingSession) -> Void
    ) {
        model = HistoryBrowserModel(
            store: store,
            settingsStore: settingsStore,
            exporter: exporter,
            onOpenSession: onOpenSession
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Screenshot History", comment: "History window title")
        window.minSize = CGSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: HistoryBrowserView(model: model)
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        model.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class HistoryBrowserModel: ObservableObject {
    @Published private(set) var items: [HistoryRecordSummary] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let settingsStore: SettingsStore

    private let store: any ScreenshotHistoryStoring
    private let exporter: any ImageExporting
    private let onOpenSession: (AnnotationEditingSession) -> Void
    private var loadGeneration = 0

    init(
        store: any ScreenshotHistoryStoring,
        settingsStore: SettingsStore,
        exporter: any ImageExporting,
        onOpenSession: @escaping (AnnotationEditingSession) -> Void
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.exporter = exporter
        self.onOpenSession = onOpenSession
    }

    func refresh() {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let records = try await store.list()
                guard generation == loadGeneration else { return }
                items = records
                isLoading = false
            } catch {
                guard generation == loadGeneration else { return }
                isLoading = false
                present(error)
            }
        }
    }

    func open(_ summary: HistoryRecordSummary) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await store.load(id: summary.id)
                let session = AnnotationEditingSession(
                    capturedImage: record.baseImage,
                    previewImage: record.previewImage,
                    document: record.document,
                    editorSettings: settingsStore.settings.editor
                )
                // Do not mount a history editor around a bitmap rejected by
                // session admission. Compatible caches return immediately;
                // incompatible caches must finish a current-renderer pass or
                // fail explicitly before the editor is shown.
                _ = try await session.resolvedPreviewImage()
                let recorder = HistorySessionRecorder(
                    session: session,
                    store: store,
                    settingsStore: settingsStore,
                    onError: { [weak self] error in self?.present(error) }
                )
                session.attachHistoryRecorder(recorder)
                onOpenSession(session)
            } catch {
                present(error)
            }
        }
    }

    func copy(_ summary: HistoryRecordSummary) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await store.load(id: summary.id)
                let image = try await resolvedPreviewImage(for: record).image
                let item = NSPasteboardItem()
                item.setData(try exporter.pngData(for: image), forType: .png)
                if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([item]) else {
                    throw ScreenshotAppError.exportFailed(
                        description: "The pasteboard rejected the history image."
                    )
                }
            } catch {
                present(error)
            }
        }
    }

    func export(_ summary: HistoryRecordSummary) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await store.load(id: summary.id)
                let output = settingsStore.settings.output
                let panel = NSSavePanel()
                panel.allowedContentTypes = [output.format.contentType]
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = FilenameTemplateFormatter().filename(
                    template: output.filenameTemplate,
                    date: record.metadata.createdAt,
                    fileExtension: output.format.fileExtension
                )
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let preview = try await resolvedPreviewImage(for: record)
                try exporter.write(
                    preview.image,
                    format: output.format,
                    preservesColorProfile: output.preservesColorProfile,
                    to: url
                )
            } catch {
                present(error)
            }
        }
    }

    private func resolvedPreviewImage(
        for record: ScreenshotHistoryRecord
    ) async throws -> CapturedImage {
        let session = AnnotationEditingSession(
            capturedImage: record.baseImage,
            previewImage: record.previewImage,
            document: record.document,
            editorSettings: settingsStore.settings.editor
        )
        return try await session.resolvedPreviewImage()
    }

    func delete(_ summary: HistoryRecordSummary) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Delete this history item?", comment: "History delete confirmation")
        alert.informativeText = NSLocalizedString("Its base image and editable annotations will be permanently removed.", comment: "History delete explanation")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Delete button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.delete(id: summary.id)
                refresh()
            } catch {
                present(error)
            }
        }
    }

    func clear() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Clear all screenshot history?", comment: "History clear confirmation")
        alert.informativeText = NSLocalizedString("Every saved base image, preview, and editable annotation document will be permanently removed.", comment: "History clear explanation")
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("Clear History", comment: "Clear history button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.clear()
                refresh()
            } catch {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        AppLog.history.error("History browser operation failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}

private struct HistoryBrowserView: View {
    @ObservedObject var model: HistoryBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screenshot History").font(.title2.bold())
                    Text(NSLocalizedString(
                        model.settingsStore.settings.history.isEnabled
                            ? "New captures are being saved."
                            : "History is off; existing items remain available.",
                        comment: "History recording status"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh history")
                Button(role: .destructive) { model.clear() } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.items.isEmpty)
                .help("Clear all history")
            }
            .padding(14)
            Divider()

            if model.items.isEmpty, !model.isLoading {
                ContentUnavailableView(
                    "No Screenshot History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Enable history in Settings to save future captures as editable records.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.items) { summary in
                    HistoryRecordRow(
                        summary: summary,
                        onOpen: { model.open(summary) },
                        onCopy: { model.copy(summary) },
                        onExport: { model.export(summary) },
                        onDelete: { model.delete(summary) }
                    )
                    .onTapGesture(count: 2) { model.open(summary) }
                }
                .listStyle(.inset)
            }
        }
        .alert(
            "Screenshot History",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK") { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
    }
}

private struct HistoryRecordRow: View {
    let summary: HistoryRecordSummary
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HistoryThumbnail(
                url: summary.previewFileURL,
                isAuthoritative: summary.cachedPreviewIsAuthoritative
            )
                .frame(width: 132, height: 82)
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.metadata.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.headline)
                Text("\(summary.metadata.captureKind.capitalized) • \(Int(summary.metadata.basePixelSize.width)) × \(Int(summary.metadata.basePixelSize.height)) px • \(String(format: "%.2f", summary.metadata.baseScale))x")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(summary.metadata.sourceColorSpaceName ?? NSLocalizedString(
                    "Unspecified color profile",
                    comment: "History color-profile fallback"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Button("Open", action: onOpen).buttonStyle(.borderedProminent)
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .help("Copy rendered image")
                    .accessibilityLabel("Copy rendered history image")
                Button(action: onExport) { Image(systemName: "square.and.arrow.up") }
                    .help("Export rendered image")
                    .accessibilityLabel("Export rendered history image")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Delete history item")
                    .accessibilityLabel("Delete history item")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }
}

private struct HistoryThumbnail: View {
    let url: URL
    let isAuthoritative: Bool

    var body: some View {
        Group {
            if !isAuthoritative {
                Label("Preview refresh required", systemImage: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.separator))
        .accessibilityLabel(
            isAuthoritative ? "Screenshot preview" : "Screenshot preview requires refresh"
        )
    }
}
