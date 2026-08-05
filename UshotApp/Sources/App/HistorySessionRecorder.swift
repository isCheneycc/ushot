import Combine
import Foundation
import UshotCore

@MainActor
final class HistorySessionRecorder {
    var onError: ((Error) -> Void)?

    private weak var session: AnnotationEditingSession?
    private let store: any ScreenshotHistoryStoring
    private let settingsStore: SettingsStore
    private var metadata: HistoryRecordMetadata
    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        session: AnnotationEditingSession,
        store: any ScreenshotHistoryStoring,
        settingsStore: SettingsStore,
        onError: ((Error) -> Void)? = nil
    ) {
        self.session = session
        self.store = store
        self.settingsStore = settingsStore
        self.onError = onError
        metadata = HistoryRecordMetadata.make(
            documentID: session.controller.document.id,
            baseImage: session.baseImage
        )

        session.$historyPreviewSnapshot
            .dropFirst()
            .compactMap { $0 }
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.persist(snapshot: snapshot)
            }
            .store(in: &cancellables)

        if let snapshot = session.historyPreviewSnapshot {
            persist(snapshot: snapshot)
        }
    }

    private func persist(snapshot: AnnotationEditingSession.HistoryPreviewSnapshot) {
        guard settingsStore.settings.history.isEnabled, let session else { return }
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
        let previousTask = saveTask
        let store = store
        let retention = settingsStore.settings.history
        saveTask = Task { [weak self] in
            if let previousTask { await previousTask.value }
            do {
                try await store.save(record)
                try await store.enforceRetention(
                    days: retention.retentionDays,
                    maximumItemCount: retention.maximumItemCount,
                    now: Date()
                )
            } catch {
                self?.onError?(error)
            }
        }
    }
}
