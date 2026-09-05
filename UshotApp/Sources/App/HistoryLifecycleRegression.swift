#if DEBUG
import AppKit
import Combine
import Foundation
import UshotCore

/// Exercises the real session/recorder/store boundaries with synthetic pixels.
/// The optional Canvas check runs only in the isolated Debug UI host. No
/// capture permission or user's history directory is involved.
@MainActor
enum HistoryLifecycleRegression {
    static func run(includingCanvasWindow: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UshotHistoryLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let settings = try makeSettings()
            try await duplicateOpenAndDeletion(root: root.appendingPathComponent("identity"), settings: settings)
            try await deletionDuringOpen(root: root.appendingPathComponent("opening"), settings: settings)
            try await sharedRenderPublishesLatestSnapshotOnce(root: root.appendingPathComponent("render"), settings: settings)
            try await finalRenderAndSaveFailure(root: root.appendingPathComponent("closing"), settings: settings)
            if includingCanvasWindow {
                try await canvasCloseWaitsForPersistence(root: root.appendingPathComponent("canvas"), settings: settings)
            }
            try FileManager.default.removeItem(at: root)
        } catch {
            do { try FileManager.default.removeItem(at: root) }
            catch let cleanupError {
                AppLog.history.fault("Synthetic history regression cleanup failed: \(cleanupError.localizedDescription, privacy: .public)")
            }
            throw error
        }
        AppLog.history.notice(
            "History lifecycle regression passed: sharedIdentity=true, revokedWritesRejected=true, pendingOpenRejected=true, sharedRenderPublishedOnce=true, finalRenderSaved=true, failedSaveRetried=true"
        )
    }

    private static func duplicateOpenAndDeletion(root: URL, settings: SettingsStore) async throws {
        let backing = SystemScreenshotHistoryStore(rootDirectory: root)
        let tracker = UpdateSensitiveActivityTracker()
        let registry = AnnotationSessionRegistry()
        let record = try makeRecord()
        try await backing.save(record)
        let gate = LoadGate()
        let store = ControlledStore(backing: backing, loadGate: gate)
        let firstOpen = registry.openHistory(
            id: record.metadata.id, store: store, settingsStore: settings,
            updateSensitiveActivityTracker: tracker
        )
        let secondOpen = registry.openHistory(
            id: record.metadata.id, store: store, settingsStore: settings,
            updateSensitiveActivityTracker: tracker
        )
        await gate.waitUntilStarted()
        await gate.release()
        let first = try await firstOpen.value
        let second = try await secondOpen.value
        try require(first === second, "Repeated history opens created independent sessions.")
        let loadCount = await store.loadCount
        try require(loadCount == 1, "Repeated history opens loaded independent snapshots.")
        first.controller.add(mark(.rectangle, x: 1))
        second.controller.add(mark(.ellipse, x: 12))
        try await first.flushHistory()
        let combined = try await backing.load(id: record.metadata.id)
        try require(combined.document.annotations.count == 2, "A shared history edit overwrote another mark.")

        try await backing.delete(id: record.metadata.id)
        first.controller.add(mark(.rectangle, x: 20))
        try await first.flushHistory()
        await tracker.waitUntilIdle()
        let afterDeletion = try await backing.list()
        try require(afterDeletion.isEmpty, "An open editor recreated deleted history.")

        let pendingRecord = try makeRecord()
        let pendingSession = makeSession(pendingRecord, settings: settings, tracker: tracker, store: backing)
        await tracker.waitUntilIdle()
        pendingSession.controller.add(mark(.rectangle, x: 1))
        _ = try await pendingSession.resolvedPreviewImage()
        try await backing.clear()
        await tracker.waitUntilIdle()
        let afterClear = try await backing.list()
        try require(afterClear.isEmpty, "A pre-clear debounce recreated screenshot history.")
    }

    private static func deletionDuringOpen(root: URL, settings: SettingsStore) async throws {
        let backing = SystemScreenshotHistoryStore(rootDirectory: root)
        let record = try makeRecord()
        try await backing.save(record)
        let gate = LoadGate()
        let store = ControlledStore(backing: backing, loadGate: gate)
        let registry = AnnotationSessionRegistry()
        let tracker = UpdateSensitiveActivityTracker()
        let opening = registry.openHistory(
            id: record.metadata.id, store: store, settingsStore: settings,
            updateSensitiveActivityTracker: tracker
        )
        await gate.waitUntilStarted()
        try await backing.clear()
        await gate.release()
        do {
            _ = try await opening.value
            throw Failure("An in-flight history open survived clear and created a recorder.")
        } catch HistoryWriteAuthorizationError.revoked {
            // Expected: the original admission cannot be renewed after clear.
        }
        await tracker.waitUntilIdle()
        try require(registry.session(for: record.metadata.id) == nil, "A revoked open registered a live session.")
        let remaining = try await backing.list()
        try require(remaining.isEmpty, "A revoked open wrote an initial snapshot.")
    }

    private static func sharedRenderPublishesLatestSnapshotOnce(root: URL, settings: SettingsStore) async throws {
        let store = SystemScreenshotHistoryStore(rootDirectory: root)
        let tracker = UpdateSensitiveActivityTracker()
        let record = try makeRecord()
        let renderer = PausedRenderer()
        let session = makeSession(record, settings: settings, tracker: tracker, store: store, renderer: renderer)
        await tracker.waitUntilIdle()
        var publishedSnapshots: [AnnotationEditingSession.HistoryPreviewSnapshot] = []
        let observation = session.$historyPreviewSnapshot.dropFirst().compactMap { $0 }.sink {
            publishedSnapshots.append($0)
        }
        defer {
            renderer.release()
            observation.cancel()
        }

        session.controller.add(mark(.rectangle, x: 1))
        await renderer.waitUntilStarted()
        let firstStarted = Signal()
        let first = Task { @MainActor in
            firstStarted.signal()
            return try await session.resolvedPreviewImage()
        }
        await firstStarted.wait()

        // Supersede the image the first waiter is already waiting on. Every
        // waiter must receive the newer pixels through one shared publication.
        session.controller.add(mark(.ellipse, x: 12))
        let latestDocument = session.controller.document
        let laterWaiters = (0..<2).map { _ in
            let started = Signal()
            let task = Task { @MainActor in
                started.signal()
                return try await session.resolvedPreviewImage()
            }
            return (started, task)
        }
        for (started, _) in laterWaiters { await started.wait() }
        let publishedWhilePaused = !publishedSnapshots.isEmpty
        renderer.release()

        var outputs = [try await first.value]
        for (_, task) in laterWaiters { outputs.append(try await task.value) }
        await tracker.waitUntilIdle()
        try require(!publishedWhilePaused, "A paused renderer published an unfinished history preview.")
        try require(publishedSnapshots.count == 1, "Concurrent output waiters published the same history render more than once.")
        try require(
            publishedSnapshots.first?.document == latestDocument.recordingCurrentCachedPreviewRenderRevision(),
            "A superseded renderer published a stale history document."
        )
        let expected = try AnnotationRenderer().render(
            document: latestDocument, baseImage: record.baseImage.image, scale: record.baseImage.scale
        )
        let exporter = SystemImageExporter()
        let expectedPNG = try exporter.pngData(for: expected)
        for output in outputs {
            try require(
                try exporter.pngData(for: output.image) == expectedPNG,
                "An output waiter received pixels from the superseded annotation render."
            )
        }
        let saved = try await store.load(id: record.metadata.id)
        try require(
            saved.document.annotations == latestDocument.annotations,
            "The shared render persisted a stale history document."
        )
    }

    private static func finalRenderAndSaveFailure(root: URL, settings: SettingsStore) async throws {
        let backing = SystemScreenshotHistoryStore(rootDirectory: root)
        let tracker = UpdateSensitiveActivityTracker()
        let record = try makeRecord()
        let renderer = PausedRenderer()
        var closing: AnnotationEditingSession? = makeSession(
            record, settings: settings, tracker: tracker, store: backing, renderer: renderer
        )
        await tracker.waitUntilIdle()
        closing!.controller.add(mark(.rectangle, x: 1))
        await renderer.waitUntilStarted()
        let finalization = Task { @MainActor [session = closing!] in
            try await session.flushHistory()
        }
        weak var retainedSession = closing
        closing = nil
        try require(retainedSession != nil, "The close barrier released its editing session before persistence.")
        retainedSession = nil
        renderer.release()
        try await finalization.value
        await tracker.waitUntilIdle()
        let finalized = try await backing.load(id: record.metadata.id)
        try require(finalized.document.annotations.count == 1, "The close barrier lost the final rendered annotation.")

        let retryRecord = try makeRecord()
        let failingStore = ControlledStore(backing: backing)
        let retrySession = makeSession(retryRecord, settings: settings, tracker: tracker, store: failingStore)
        await tracker.waitUntilIdle()
        await failingStore.setSavingFailure(true)
        retrySession.controller.add(mark(.ellipse, x: 10))
        do {
            try await retrySession.flushHistory()
            throw Failure("A failed final save was reported as a successful close.")
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            // The caller keeps its window/session available for a retry.
        }
        try require(retrySession.controller.document.annotations.count == 1, "A failed close discarded editable state.")
        await failingStore.setSavingFailure(false)
        try await retrySession.flushHistory()
        await tracker.waitUntilIdle()
        let retried = try await backing.load(id: retryRecord.metadata.id)
        try require(retried.document.annotations.count == 1, "A failed close could not persist its original edit on retry.")
    }

    private static func canvasCloseWaitsForPersistence(root: URL, settings: SettingsStore) async throws {
        let store = SystemScreenshotHistoryStore(rootDirectory: root)
        let tracker = UpdateSensitiveActivityTracker()
        let registry = AnnotationSessionRegistry()
        let record = try makeRecord()
        let renderer = PausedRenderer()
        defer { renderer.release() }
        let session = makeSession(record, settings: settings, tracker: tracker, store: store, renderer: renderer)
        await tracker.waitUntilIdle()
        let manager = CanvasEditorManager(
            settingsStore: settings, updateSensitiveActivityTracker: tracker, sessionRegistry: registry
        )
        let closed = Signal()
        manager.open(session: session, onClose: { closed.signal() })
        try await manager.waitForCanvasForRegression(documentID: record.metadata.id)
        session.controller.add(mark(.rectangle, x: 4))
        await renderer.waitUntilStarted()
        manager.requestCloseForRegression(documentID: record.metadata.id)
        try require(manager.hasOpenEditors, "Canvas closed before its final renderer and save completed.")
        renderer.release()
        await closed.wait()
        await tracker.waitUntilIdle()
        try require(!manager.hasOpenEditors, "Canvas did not close after final persistence succeeded.")
        let loaded = try await store.load(id: record.metadata.id)
        try require(loaded.document.annotations.count == 1, "Closing the actual Canvas window lost its final annotation.")
    }

    private final class Signal {
        private var signalled = false
        private var waiter: CheckedContinuation<Void, Never>?

        func signal() {
            signalled = true
            waiter?.resume()
            waiter = nil
        }

        func wait() async {
            if !signalled { await withCheckedContinuation { waiter = $0 } }
        }
    }

    private static func makeSession(
        _ record: ScreenshotHistoryRecord,
        settings: SettingsStore,
        tracker: UpdateSensitiveActivityTracker,
        store: any ScreenshotHistoryStoring,
        renderer: any AnnotationRendering = AnnotationRenderer()
    ) -> AnnotationEditingSession {
        let session = AnnotationEditingSession(
            capturedImage: record.baseImage, previewImage: record.previewImage,
            document: record.document, editorSettings: settings.settings.editor,
            updateSensitiveActivityTracker: tracker, renderer: renderer
        )
        session.attachHistoryRecorder(HistorySessionRecorder(
            session: session, store: store, settingsStore: settings,
            updateSensitiveActivityTracker: tracker
        ))
        return session
    }

    private static func makeSettings() throws -> SettingsStore {
        guard let defaults = UserDefaults(suiteName: "UshotHistoryRegression-\(UUID().uuidString)") else {
            throw Failure("Could not create isolated regression settings.")
        }
        var settings = AppSettings.defaults
        settings.history.isEnabled = true
        defaults.register(defaults: [SettingsStore.storageKey: try JSONEncoder().encode(settings)])
        return SettingsStore(defaults: defaults)
    }

    private static func makeRecord() throws -> ScreenshotHistoryRecord {
        let size = CGSize(width: 32, height: 32)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw Failure("Could not create synthetic history pixels.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { throw Failure("Could not finish synthetic history pixels.") }
        let captured = CapturedImage(
            image: image, colorSpace: space, pixelSize: size, logicalSize: size, scale: 1,
            sourceMetadata: .init(kind: .region, displayIDs: [], windowID: nil,
                                  desktopFrame: CGRect(origin: .zero, size: size))
        )
        let document = AnnotationDocument(baseImageReference: .init(pixelSize: size), canvasSize: size)
        return ScreenshotHistoryRecord(
            metadata: .make(documentID: document.id, baseImage: captured), document: document,
            baseImage: captured, previewImage: captured
        )
    }

    private static func mark(_ kind: AnnotationKind, x: CGFloat) -> AnnotationItem {
        AnnotationItem(kind: kind, zIndex: 0, geometry: .rect(CGRect(x: x, y: 2, width: 6, height: 6)))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private actor LoadGate {
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pause() async {
            started = true
            startWaiter?.resume()
            startWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilStarted() async {
            if !started { await withCheckedContinuation { startWaiter = $0 } }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private actor ControlledStore: ScreenshotHistoryStoring {
        nonisolated let rootDirectory: URL
        nonisolated let writeAuthority: HistoryWriteAuthority
        private let backing: SystemScreenshotHistoryStore
        private let loadGate: LoadGate?
        private var failsSaving = false
        private(set) var loadCount = 0

        init(backing: SystemScreenshotHistoryStore, loadGate: LoadGate? = nil) {
            self.backing = backing
            self.rootDirectory = backing.rootDirectory
            self.writeAuthority = backing.writeAuthority
            self.loadGate = loadGate
        }

        func setSavingFailure(_ failing: Bool) { failsSaving = failing }
        func save(_ record: ScreenshotHistoryRecord, authorization: HistoryWriteAuthorization) async throws {
            if failsSaving { throw CocoaError(.fileWriteNoPermission) }
            try await backing.save(record, authorization: authorization)
        }
        func list() async throws -> [HistoryRecordSummary] { try await backing.list() }
        func load(id: UUID) async throws -> ScreenshotHistoryRecord {
            loadCount += 1
            let record = try await backing.load(id: id)
            if let loadGate { await loadGate.pause() }
            return record
        }
        func delete(id: UUID) async throws { try await backing.delete(id: id) }
        func clear() async throws { try await backing.clear() }
        func enforceRetention(days: Int, maximumItemCount: Int, now: Date) async throws {
            try await backing.enforceRetention(days: days, maximumItemCount: maximumItemCount, now: now)
        }
    }

    private final class PausedRenderer: AnnotationRendering, @unchecked Sendable {
        private let condition = NSCondition()
        private var released = false
        private var started = false
        private var startWaiter: CheckedContinuation<Void, Never>?

        func render(document: AnnotationDocument, baseImage: CGImage, scale: CGFloat) throws -> CGImage {
            condition.lock()
            started = true
            let waiter = startWaiter
            startWaiter = nil
            condition.unlock()
            waiter?.resume()
            condition.lock()
            while !released { condition.wait() }
            condition.unlock()
            return try AnnotationRenderer().render(document: document, baseImage: baseImage, scale: scale)
        }

        func waitUntilStarted() async {
            await withCheckedContinuation { continuation in
                condition.lock()
                let alreadyStarted = started
                if !alreadyStarted { startWaiter = continuation }
                condition.unlock()
                if alreadyStarted { continuation.resume() }
            }
        }

        func release() {
            // A selected Canvas annotation also requests a background preview.
            // Release the render boundary for every current and future request;
            // a single semaphore permit can strand the authoritative render.
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }
}
#endif
