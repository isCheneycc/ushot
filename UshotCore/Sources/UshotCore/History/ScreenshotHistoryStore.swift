import CoreGraphics
import Foundation
import ImageIO

public struct HistoryRecordMetadata: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public var schemaVersion: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var captureKind: String
    public var displayIDs: [CGDirectDisplayID]
    public var windowID: CGWindowID?
    public var desktopFrame: CGRect
    public var basePixelSize: CGSize
    public var baseLogicalSize: CGSize
    public var baseScale: CGFloat
    public var sourceColorSpaceName: String?

    public init(
        id: UUID,
        schemaVersion: Int = HistoryRecordMetadata.currentSchemaVersion,
        createdAt: Date,
        updatedAt: Date,
        captureKind: String,
        displayIDs: [CGDirectDisplayID],
        windowID: CGWindowID?,
        desktopFrame: CGRect,
        basePixelSize: CGSize,
        baseLogicalSize: CGSize,
        baseScale: CGFloat,
        sourceColorSpaceName: String?
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.captureKind = captureKind
        self.displayIDs = displayIDs
        self.windowID = windowID
        self.desktopFrame = desktopFrame
        self.basePixelSize = basePixelSize
        self.baseLogicalSize = baseLogicalSize
        self.baseScale = baseScale
        self.sourceColorSpaceName = sourceColorSpaceName
    }

    public static func make(
        documentID: UUID,
        baseImage: CapturedImage,
        now: Date = Date()
    ) -> HistoryRecordMetadata {
        HistoryRecordMetadata(
            id: documentID,
            createdAt: baseImage.sourceMetadata.capturedAt,
            updatedAt: now,
            captureKind: baseImage.sourceMetadata.kind.rawValue,
            displayIDs: baseImage.sourceMetadata.displayIDs,
            windowID: baseImage.sourceMetadata.windowID,
            desktopFrame: baseImage.sourceMetadata.desktopFrame,
            basePixelSize: baseImage.pixelSize,
            baseLogicalSize: baseImage.logicalSize,
            baseScale: baseImage.scale,
            sourceColorSpaceName: baseImage.colorSpace?.name as String?
        )
    }
}

public struct ScreenshotHistoryRecord: @unchecked Sendable {
    public var metadata: HistoryRecordMetadata
    public var document: AnnotationDocument
    public let baseImage: CapturedImage
    public var previewImage: CapturedImage

    public init(
        metadata: HistoryRecordMetadata,
        document: AnnotationDocument,
        baseImage: CapturedImage,
        previewImage: CapturedImage
    ) {
        self.metadata = metadata
        self.document = document
        self.baseImage = baseImage
        self.previewImage = previewImage
    }
}

public struct HistoryRecordSummary: Identifiable, Equatable, Sendable {
    public let metadata: HistoryRecordMetadata
    public let previewFileURL: URL
    public let cachedPreviewIsAuthoritative: Bool

    public init(
        metadata: HistoryRecordMetadata,
        previewFileURL: URL,
        cachedPreviewIsAuthoritative: Bool = true
    ) {
        self.metadata = metadata
        self.previewFileURL = previewFileURL
        self.cachedPreviewIsAuthoritative = cachedPreviewIsAuthoritative
    }

    public var id: UUID { metadata.id }
}

public protocol ScreenshotHistoryStoring: Sendable {
    var rootDirectory: URL { get }
    func save(_ record: ScreenshotHistoryRecord) async throws
    func list() async throws -> [HistoryRecordSummary]
    func load(id: UUID) async throws -> ScreenshotHistoryRecord
    func delete(id: UUID) async throws
    func clear() async throws
    func enforceRetention(days: Int, maximumItemCount: Int, now: Date) async throws
}

public struct HistoryDirectoryMigrationResult: Equatable, Sendable {
    public let copiedItemCount: Int
    public let identicalItemCount: Int

    public init(copiedItemCount: Int, identicalItemCount: Int) {
        self.copiedItemCount = copiedItemCount
        self.identicalItemCount = identicalItemCount
    }
}

public actor SystemScreenshotHistoryStore: ScreenshotHistoryStoring {
    public nonisolated let rootDirectory: URL

    private let fileManager: FileManager
    private let imageExporter: any ImageExporting
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        imageExporter: any ImageExporting = SystemImageExporter()
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.imageExporter = imageExporter
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func applicationSupportStore(
        bundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> SystemScreenshotHistoryStore {
        guard !bundleIdentifier.isEmpty else {
            throw ScreenshotAppError.historyPersistenceFailed(description: "The bundle identifier is empty.")
        }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SystemScreenshotHistoryStore(
            rootDirectory: support
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("History", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Copies a legacy History directory into the current Application Support
    /// namespace without deleting the recoverable source. Each copied entry is
    /// staged and renamed on the same volume, and conflicting entries fail
    /// closed instead of silently choosing one version.
    public static func migrateApplicationSupportHistory(
        fromBundleIdentifier legacyBundleIdentifier: String,
        toBundleIdentifier currentBundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> HistoryDirectoryMigrationResult {
        guard
            !legacyBundleIdentifier.isEmpty,
            !currentBundleIdentifier.isEmpty,
            legacyBundleIdentifier != currentBundleIdentifier
        else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: "History migration requires two distinct, non-empty application identifiers."
            )
        }

        do {
            let supportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let legacyRoot = supportDirectory
                .appendingPathComponent(legacyBundleIdentifier, isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
            let currentRoot = supportDirectory
                .appendingPathComponent(currentBundleIdentifier, isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
            return try migrateHistory(
                from: legacyRoot,
                to: currentRoot,
                fileManager: fileManager
            )
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: error.localizedDescription
            )
        }
    }

    static func migrateHistory(
        from legacyRoot: URL,
        to currentRoot: URL,
        fileManager: FileManager = .default
    ) throws -> HistoryDirectoryMigrationResult {
        guard fileManager.fileExists(atPath: legacyRoot.path) else {
            return HistoryDirectoryMigrationResult(
                copiedItemCount: 0,
                identicalItemCount: 0
            )
        }
        try requireOrdinaryDirectory(legacyRoot)

        if fileManager.fileExists(atPath: currentRoot.path) {
            try requireOrdinaryDirectory(currentRoot)
        } else {
            try fileManager.createDirectory(
                at: currentRoot,
                withIntermediateDirectories: true
            )
        }

        let legacyItems = try fileManager.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var copiedItemCount = 0
        var identicalItemCount = 0

        for legacyItem in legacyItems {
            try requireSupportedMigrationTree(
                legacyItem,
                fileManager: fileManager
            )
            let destination = currentRoot.appendingPathComponent(
                legacyItem.lastPathComponent,
                isDirectory: false
            )
            if fileManager.fileExists(atPath: destination.path) {
                guard try itemsAreIdentical(
                    legacyItem,
                    destination,
                    fileManager: fileManager
                ) else {
                    throw ScreenshotAppError.historyPersistenceFailed(
                        description: "Legacy and current history contain different data for \(legacyItem.lastPathComponent)."
                    )
                }
                identicalItemCount += 1
                continue
            }

            let staged = currentRoot.appendingPathComponent(
                ".history-migration-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                try fileManager.copyItem(at: legacyItem, to: staged)
                try requireSupportedMigrationTree(
                    staged,
                    fileManager: fileManager
                )
                try fileManager.moveItem(at: staged, to: destination)
            } catch {
                if fileManager.fileExists(atPath: staged.path) {
                    do {
                        try fileManager.removeItem(at: staged)
                    } catch let cleanupError {
                        throw ScreenshotAppError.historyPersistenceFailed(
                            description: "History migration failed and its private staging item could not be removed: \(cleanupError.localizedDescription)"
                        )
                    }
                }
                throw error
            }
            copiedItemCount += 1
        }

        return HistoryDirectoryMigrationResult(
            copiedItemCount: copiedItemCount,
            identicalItemCount: identicalItemCount
        )
    }

    private static func requireSupportedMigrationTree(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: "History migration refuses symbolic links."
            )
        }
        if values.isRegularFile == true {
            return
        }
        guard values.isDirectory == true else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: "History migration encountered an unsupported filesystem item."
            )
        }

        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        for child in children {
            try requireSupportedMigrationTree(child, fileManager: fileManager)
        }
    }

    private static func requireOrdinaryDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: "History migration encountered a non-directory or symbolic-link root."
            )
        }
    }

    private static func itemsAreIdentical(
        _ lhs: URL,
        _ rhs: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        let lhsValues = try lhs.resourceValues(forKeys: keys)
        let rhsValues = try rhs.resourceValues(forKeys: keys)

        guard
            lhsValues.isSymbolicLink != true,
            rhsValues.isSymbolicLink != true
        else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: "History migration refuses symbolic links."
            )
        }

        if lhsValues.isRegularFile == true || rhsValues.isRegularFile == true {
            guard
                lhsValues.isRegularFile == true,
                rhsValues.isRegularFile == true
            else { return false }
            return fileManager.contentsEqual(atPath: lhs.path, andPath: rhs.path)
        }

        guard
            lhsValues.isDirectory == true,
            rhsValues.isDirectory == true
        else {
            throw ScreenshotAppError.historyPersistenceFailed(
                description: "History migration encountered an unsupported filesystem item."
            )
        }
        let lhsChildren = try fileManager.contentsOfDirectory(
            at: lhs,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let rhsChildren = try fileManager.contentsOfDirectory(
            at: rhs,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard lhsChildren.map(\.lastPathComponent) == rhsChildren.map(\.lastPathComponent) else {
            return false
        }
        for (lhsChild, rhsChild) in zip(lhsChildren, rhsChildren) {
            guard try itemsAreIdentical(lhsChild, rhsChild, fileManager: fileManager) else {
                return false
            }
        }
        return true
    }

    public func save(_ record: ScreenshotHistoryRecord) async throws {
        do {
            try validate(record)
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let destination = recordDirectory(id: record.metadata.id)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory)
            if exists {
                guard isDirectory.boolValue else {
                    throw ScreenshotAppError.historyPersistenceFailed(
                        description: "History record \(record.metadata.id) is not a directory."
                    )
                }
                try write(record, to: destination, writesBaseImage: false)
            } else {
                try writeNewRecordAtomically(record, destination: destination)
            }
            AppLog.history.debug("Saved editable history record \(record.metadata.id, privacy: .public)")
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            AppLog.history.error("History save failed for \(record.metadata.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.historyPersistenceFailed(description: error.localizedDescription)
        }
    }

    public func list() async throws -> [HistoryRecordSummary] {
        do {
            guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
            let directories = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var summaries: [HistoryRecordSummary] = []
            for directory in directories {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true, UUID(uuidString: directory.lastPathComponent) != nil else {
                    continue
                }
                do {
                    summaries.append(try validateAndSummarize(directory: directory))
                } catch {
                    AppLog.history.error(
                        "Skipping corrupt history record \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return summaries.sorted { $0.metadata.createdAt > $1.metadata.createdAt }
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            throw ScreenshotAppError.historyPersistenceFailed(description: error.localizedDescription)
        }
    }

    public func load(id: UUID) async throws -> ScreenshotHistoryRecord {
        do {
            let directory = recordDirectory(id: id)
            let metadata = try decode(HistoryRecordMetadata.self, at: directory.appendingPathComponent("metadata.json"))
            let document = try decode(AnnotationDocument.self, at: directory.appendingPathComponent("document.json"))
            try validate(metadata: metadata, document: document, expectedID: id)
            let baseImage = try decodeImage(at: directory.appendingPathComponent("base.png"))
            let previewImage = try decodeImage(at: directory.appendingPathComponent("preview.png"))
            guard let kind = CaptureSourceMetadata.SourceKind(rawValue: metadata.captureKind) else {
                throw ScreenshotAppError.historyCorrupted(
                    description: "Unknown capture kind \(metadata.captureKind)."
                )
            }
            let source = CaptureSourceMetadata(
                kind: kind,
                displayIDs: metadata.displayIDs,
                windowID: metadata.windowID,
                desktopFrame: metadata.desktopFrame,
                capturedAt: metadata.createdAt
            )
            let base = CapturedImage(
                image: baseImage,
                colorSpace: baseImage.colorSpace,
                pixelSize: CGSize(width: baseImage.width, height: baseImage.height),
                logicalSize: metadata.baseLogicalSize,
                scale: metadata.baseScale,
                sourceMetadata: source
            )
            let previewLogicalSize = document.outputLogicalSize
            let preview = CapturedImage(
                image: previewImage,
                colorSpace: previewImage.colorSpace,
                pixelSize: CGSize(width: previewImage.width, height: previewImage.height),
                logicalSize: previewLogicalSize,
                scale: previewLogicalSize.width > 0
                    ? CGFloat(previewImage.width) / previewLogicalSize.width
                    : metadata.baseScale,
                sourceMetadata: source
            )
            return ScreenshotHistoryRecord(
                metadata: metadata,
                document: document,
                baseImage: base,
                previewImage: preview
            )
        } catch let error as ScreenshotAppError {
            throw error
        } catch {
            AppLog.history.error("History load failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ScreenshotAppError.historyCorrupted(description: error.localizedDescription)
        }
    }

    public func delete(id: UUID) async throws {
        let directory = recordDirectory(id: id)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
            AppLog.history.notice("Deleted history record \(id, privacy: .public)")
        } catch {
            throw ScreenshotAppError.historyPersistenceFailed(description: error.localizedDescription)
        }
    }

    public func clear() async throws {
        do {
            if fileManager.fileExists(atPath: rootDirectory.path) {
                try fileManager.removeItem(at: rootDirectory)
            }
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            AppLog.history.notice("Cleared screenshot history")
        } catch {
            throw ScreenshotAppError.historyPersistenceFailed(description: error.localizedDescription)
        }
    }

    public func enforceRetention(
        days: Int,
        maximumItemCount: Int,
        now: Date = Date()
    ) async throws {
        guard days > 0, maximumItemCount > 0 else {
            throw ScreenshotAppError.settingsCorrupted(
                description: "History retention must use positive day and item limits."
            )
        }
        let summaries = try await list()
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let expired = summaries.filter { $0.metadata.createdAt < cutoff }
        for summary in expired {
            try await delete(id: summary.id)
        }
        let remaining = summaries.filter { $0.metadata.createdAt >= cutoff }
        if remaining.count > maximumItemCount {
            for summary in remaining.dropFirst(maximumItemCount) {
                try await delete(id: summary.id)
            }
        }
    }

    private func writeNewRecordAtomically(
        _ record: ScreenshotHistoryRecord,
        destination: URL
    ) throws {
        let temporary = rootDirectory.appendingPathComponent(
            ".\(record.metadata.id.uuidString).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
            try write(record, to: temporary, writesBaseImage: true)
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            if fileManager.fileExists(atPath: temporary.path) {
                do {
                    try fileManager.removeItem(at: temporary)
                } catch {
                    AppLog.history.error(
                        "History staging cleanup failed for \(record.metadata.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
    }

    private func write(
        _ record: ScreenshotHistoryRecord,
        to directory: URL,
        writesBaseImage: Bool
    ) throws {
        var document = record.document
        document.baseImageReference.relativePath = "base.png"
        if writesBaseImage {
            try imageExporter.pngData(for: record.baseImage.image)
                .write(to: directory.appendingPathComponent("base.png"), options: .atomic)
        } else if !fileManager.fileExists(atPath: directory.appendingPathComponent("base.png").path) {
            throw ScreenshotAppError.historyCorrupted(description: "base.png is missing from an existing record.")
        }
        try imageExporter.pngData(for: record.previewImage.image)
            .write(to: directory.appendingPathComponent("preview.png"), options: .atomic)
        try encoder.encode(document)
            .write(to: directory.appendingPathComponent("document.json"), options: .atomic)
        try encoder.encode(record.metadata)
            .write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func validate(_ record: ScreenshotHistoryRecord) throws {
        try validate(
            metadata: record.metadata,
            document: record.document,
            expectedID: record.metadata.id
        )
        guard record.baseImage.pixelSize.width > 0, record.baseImage.pixelSize.height > 0,
              record.previewImage.pixelSize.width > 0, record.previewImage.pixelSize.height > 0
        else {
            throw ScreenshotAppError.historyPersistenceFailed(description: "History images must have positive dimensions.")
        }
    }

    private func validate(
        metadata: HistoryRecordMetadata,
        document: AnnotationDocument,
        expectedID: UUID
    ) throws {
        guard metadata.id == expectedID, document.id == expectedID else {
            throw ScreenshotAppError.historyCorrupted(description: "Record, metadata and document identifiers do not match.")
        }
        guard metadata.schemaVersion == HistoryRecordMetadata.currentSchemaVersion else {
            throw ScreenshotAppError.historyCorrupted(
                description: "Unsupported metadata schema version \(metadata.schemaVersion)."
            )
        }
        guard document.schemaVersion == AnnotationDocument.currentSchemaVersion else {
            throw ScreenshotAppError.historyCorrupted(
                description: "Unsupported annotation schema version \(document.schemaVersion)."
            )
        }
    }

    private func validateAndSummarize(directory: URL) throws -> HistoryRecordSummary {
        guard let expectedID = UUID(uuidString: directory.lastPathComponent) else {
            throw ScreenshotAppError.historyCorrupted(description: "The history directory name is not a UUID.")
        }
        let metadata = try decode(HistoryRecordMetadata.self, at: directory.appendingPathComponent("metadata.json"))
        let document = try decode(AnnotationDocument.self, at: directory.appendingPathComponent("document.json"))
        try validate(metadata: metadata, document: document, expectedID: expectedID)
        try validateImage(at: directory.appendingPathComponent("base.png"))
        let previewURL = directory.appendingPathComponent("preview.png")
        try validateImage(at: previewURL)
        let cachedPreviewIsAuthoritative = document.isCachedPreviewCompatibleWithCurrentRenderer
        if !cachedPreviewIsAuthoritative {
            AppLog.history.notice(
                "History cached preview requires renderer refresh: id=\(expectedID, privacy: .public), storedRevision=\(document.cachedPreviewRenderRevision, privacy: .public), currentRevision=\(AnnotationDocument.currentCachedPreviewRenderRevision, privacy: .public), affectedAnnotations=\(document.cachedPreviewRevisionAffectedAnnotationCount, privacy: .public)"
            )
        }
        return HistoryRecordSummary(
            metadata: metadata,
            previewFileURL: previewURL,
            cachedPreviewIsAuthoritative: cachedPreviewIsAuthoritative
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func validateImage(at url: URL) throws {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else {
            throw ScreenshotAppError.historyCorrupted(
                description: "\(url.lastPathComponent) is missing or not a decodable image."
            )
        }
    }

    private func decodeImage(at url: URL) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ScreenshotAppError.historyCorrupted(
                description: "\(url.lastPathComponent) is missing or not a decodable image."
            )
        }
        return image
    }

    private func recordDirectory(id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
