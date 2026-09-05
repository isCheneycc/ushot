import CoreGraphics
import Foundation
import Testing
@testable import UshotCore

@Suite("History write authorization")
struct ScreenshotHistoryAuthorizationTests {
    @Test func deletionRejectsTheOldWriterAndPreservesOtherRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store
        let first = try fixture.record()
        let second = try fixture.record()
        let firstAuthorization = store.writeAuthority.authorization(for: first.metadata.id)
        let secondAuthorization = store.writeAuthority.authorization(for: second.metadata.id)
        try await store.save(first, authorization: firstAuthorization)
        try await store.save(second, authorization: secondAuthorization)

        try await store.delete(id: first.metadata.id)

        await #expect(throws: HistoryWriteAuthorizationError.revoked) {
            try await store.save(first, authorization: firstAuthorization)
        }
        try await store.save(second, authorization: secondAuthorization)
        let items = try await store.list()
        #expect(items.map(\.id) == [second.metadata.id])
    }

    @Test func clearRejectsAnAdmittedRecordThatHasNotReachedDisk() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pending = try fixture.record()
        let authorization = fixture.store.writeAuthority.authorization(for: pending.metadata.id)

        try await fixture.store.clear()

        await #expect(throws: HistoryWriteAuthorizationError.revoked) {
            try await fixture.store.save(pending, authorization: authorization)
        }
        #expect(try await fixture.store.list().isEmpty)
        let newCapture = try fixture.record()
        try await fixture.store.save(
            newCapture,
            authorization: fixture.store.writeAuthority.authorization(for: newCapture.metadata.id)
        )
        #expect(try await fixture.store.list().map(\.id) == [newCapture.metadata.id])
    }

    @Test func failedDeletionKeepsItsExistingWriterRetryable() async throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let fixture = try Fixture(fileManager: RejectingRemovalFileManager(blockedName: id.uuidString))
        defer { fixture.remove() }
        let record = try fixture.record(id: id)
        let authorization = fixture.store.writeAuthority.authorization(for: id)
        try await fixture.store.save(record, authorization: authorization)

        await #expect(throws: ScreenshotAppError.self) {
            try await fixture.store.delete(id: id)
        }

        #expect(fixture.store.writeAuthority.isCurrent(authorization))
        try await fixture.store.save(record, authorization: authorization)
        #expect(try await fixture.store.list().map(\.id) == [id])
    }

    @Test func partiallyFailedClearRevokesOnlyTheRecordsAlreadyRemoved() async throws {
        let removedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let survivingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let fixture = try Fixture(fileManager: RejectingRemovalFileManager(blockedName: survivingID.uuidString))
        defer { fixture.remove() }
        let removed = try fixture.record(id: removedID)
        let surviving = try fixture.record(id: survivingID)
        let oldRemovedAuthorization = fixture.store.writeAuthority.authorization(for: removedID)
        let survivingAuthorization = fixture.store.writeAuthority.authorization(for: survivingID)
        try await fixture.store.save(removed, authorization: oldRemovedAuthorization)
        try await fixture.store.save(surviving, authorization: survivingAuthorization)

        await #expect(throws: ScreenshotAppError.self) { try await fixture.store.clear() }

        await #expect(throws: HistoryWriteAuthorizationError.revoked) {
            try await fixture.store.save(removed, authorization: oldRemovedAuthorization)
        }
        #expect(fixture.store.writeAuthority.isCurrent(survivingAuthorization))
        try await fixture.store.save(surviving, authorization: survivingAuthorization)
        #expect(try await fixture.store.list().map(\.id) == [survivingID])
    }

    @Test func authorizationCannotBeUsedForAnotherStoreOrRecord() async throws {
        let fixture = try Fixture()
        let other = try Fixture()
        defer { fixture.remove(); other.remove() }
        let record = try fixture.record()
        let foreign = other.store.writeAuthority.authorization(for: record.metadata.id)
        let wrongRecord = fixture.store.writeAuthority.authorization(for: UUID())
        await #expect(throws: HistoryWriteAuthorizationError.revoked) {
            try await fixture.store.save(record, authorization: foreign)
        }
        await #expect(throws: HistoryWriteAuthorizationError.revoked) {
            try await fixture.store.save(record, authorization: wrongRecord)
        }
        #expect(try await fixture.store.list().isEmpty)
    }

    private struct Fixture {
        let root: URL
        let store: SystemScreenshotHistoryStore

        init(fileManager: FileManager = .default) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("UshotHistoryAuthorization-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            store = SystemScreenshotHistoryStore(rootDirectory: root, fileManager: fileManager)
        }

        func remove() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove synthetic history fixture: \(error)") }
        }

        func record(id: UUID = UUID()) throws -> ScreenshotHistoryRecord {
            let size = CGSize(width: 8, height: 8)
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let image = try #require(context.makeImage())
            let captured = CapturedImage(
                image: image, colorSpace: colorSpace, pixelSize: size, logicalSize: size, scale: 1,
                sourceMetadata: .init(kind: .region, displayIDs: [], windowID: nil,
                                      desktopFrame: CGRect(origin: .zero, size: size))
            )
            let document = AnnotationDocument(id: id, baseImageReference: .init(pixelSize: size), canvasSize: size)
            return ScreenshotHistoryRecord(
                metadata: .make(documentID: id, baseImage: captured), document: document,
                baseImage: captured, previewImage: captured
            )
        }
    }

    private final class RejectingRemovalFileManager: FileManager, @unchecked Sendable {
        let blockedName: String

        init(blockedName: String) {
            self.blockedName = blockedName
            super.init()
        }

        override func removeItem(at URL: URL) throws {
            if URL.lastPathComponent == blockedName {
                throw CocoaError(.fileWriteNoPermission)
            }
            try super.removeItem(at: URL)
        }
    }
}
