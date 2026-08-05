import Combine
import Foundation
import UshotCore

@MainActor
final class HistorySessionRecorder {
    var onError: ((Error) -> Void)?

    private weak var session: AnnotationEditingSession?
    private let settingsStore: SettingsStore
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private let persistencePipeline: HistoryPersistencePipeline
    private var metadata: HistoryRecordMetadata
    private var debounceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        session: AnnotationEditingSession,
        store: any ScreenshotHistoryStoring,
        settingsStore: SettingsStore,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker,
        onError: ((Error) -> Void)? = nil
    ) {
        self.session = session
        self.settingsStore = settingsStore
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
        self.persistencePipeline = HistoryPersistencePipeline(
            store: store,
            updateSensitiveActivityTracker: updateSensitiveActivityTracker
        )
        self.onError = onError
        metadata = HistoryRecordMetadata.make(
            documentID: session.controller.document.id,
            baseImage: session.baseImage
        )

        session.$historyPreviewSnapshot
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] snapshot in
                self?.scheduleDebouncedPersistence(snapshot: snapshot)
            }
            .store(in: &cancellables)

        if let snapshot = session.historyPreviewSnapshot {
            persistImmediately(snapshot: snapshot)
        }
    }

    private func persistImmediately(
        snapshot: AnnotationEditingSession.HistoryPreviewSnapshot
    ) {
        guard let record = makeRecord(snapshot: snapshot) else { return }
        persistencePipeline.enqueue(
            record: record,
            retention: settingsStore.settings.history,
            onError: onError
        )
    }

    private func scheduleDebouncedPersistence(
        snapshot: AnnotationEditingSession.HistoryPreviewSnapshot
    ) {
        guard let record = makeRecord(snapshot: snapshot) else { return }

        // Acquire the replacement lease before cancelling the previous delay.
        // This keeps updater admission closed across every debounce handoff.
        let lease = updateSensitiveActivityTracker.begin(
            operation: "history-persistence-debounce"
        )
        let previousDebounceTask = debounceTask
        let settingsStore = settingsStore
        let updateSensitiveActivityTracker = updateSensitiveActivityTracker
        let persistencePipeline = persistencePipeline
        let onError = onError
        let task = Task { @MainActor in
            defer { updateSensitiveActivityTracker.finish(lease) }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch is CancellationError {
                AppLog.history.debug(
                    "Cancelled superseded history persistence debounce"
                )
                return
            } catch {
                let nsError = error as NSError
                AppLog.history.fault(
                    "History persistence debounce failed: domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
                )
                onError?(error)
                return
            }

            guard settingsStore.settings.history.isEnabled else {
                AppLog.history.debug(
                    "Skipped debounced history persistence because history was disabled"
                )
                return
            }

            // enqueue acquires the save lease synchronously. The debounce lease
            // is released only by the defer above, after that handoff completes.
            persistencePipeline.enqueue(
                record: record,
                retention: settingsStore.settings.history,
                onError: onError
            )
        }
        debounceTask = task
        previousDebounceTask?.cancel()
    }

    private func makeRecord(
        snapshot: AnnotationEditingSession.HistoryPreviewSnapshot
    ) -> ScreenshotHistoryRecord? {
        guard settingsStore.settings.history.isEnabled, let session else { return nil }
        precondition(
            snapshot.document.isCachedPreviewCompatibleWithCurrentRenderer,
            "History persistence must never label an incompatible cached preview as authoritative."
        )
        metadata.updatedAt = Date()
        let record = ScreenshotHistoryRecord(
            metadata: metadata,
            document: snapshot.document,
            baseImage: session.baseImage,
            previewImage: snapshot.previewImage
        )
        return record
    }
}

@MainActor
private final class HistoryPersistencePipeline {
    private let store: any ScreenshotHistoryStoring
    private let updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    private var saveTask: Task<Void, Never>?

    init(
        store: any ScreenshotHistoryStoring,
        updateSensitiveActivityTracker: UpdateSensitiveActivityTracker
    ) {
        self.store = store
        self.updateSensitiveActivityTracker = updateSensitiveActivityTracker
    }

    func enqueue(
        record: ScreenshotHistoryRecord,
        retention: HistorySettings,
        onError: ((Error) -> Void)?
    ) {
        let lease = updateSensitiveActivityTracker.begin(
            operation: "history-save-and-retention"
        )
        let previousTask = saveTask
        let store = store
        let updateSensitiveActivityTracker = updateSensitiveActivityTracker
        saveTask = Task { @MainActor in
            defer { updateSensitiveActivityTracker.finish(lease) }
            if let previousTask { await previousTask.value }
            do {
                try await store.save(record)
                try await store.enforceRetention(
                    days: retention.retentionDays,
                    maximumItemCount: retention.maximumItemCount,
                    now: Date()
                )
            } catch {
                let nsError = error as NSError
                AppLog.history.error(
                    "History persistence failed: domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
                )
                onError?(error)
            }
        }
    }
}
