import XCTest
@testable import UshotCore

final class ProductIdentityTests: XCTestCase {
    func testPublicIdentityUsesThePermanentBundleIdentifier() {
        XCTAssertEqual(ProductIdentity.name, "Ushot")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "io.github.ischeneycc.ushot")
        XCTAssertEqual(
            ProductIdentity.settingsStorageKey,
            "io.github.ischeneycc.ushot.settings"
        )
        XCTAssertEqual(
            ProductIdentity.applicationSupportDirectoryName,
            ProductIdentity.bundleIdentifier
        )
        XCTAssertEqual(
            ProductIdentity.updateFeedURLString,
            "https://ischeneycc.github.io/ushot/updates/v1/appcast.xml"
        )
        XCTAssertEqual(
            Data(base64Encoded: ProductIdentity.sparklePublicEDKey)?.count,
            32
        )
    }

    func testLegacyIdentityRemainsAvailableForOneTimeMigration() {
        XCTAssertEqual(ProductIdentity.legacyBundleIdentifier, "com.example.UshotApp")
        XCTAssertEqual(
            ProductIdentity.legacySettingsStorageKey,
            "com.example.UshotApp.settings"
        )
        XCTAssertEqual(
            ProductIdentity.legacyApplicationSupportDirectoryName,
            ProductIdentity.legacyBundleIdentifier
        )
        XCTAssertEqual(
            ProductIdentity.legacyHistoryMigrationMarkerKey,
            "io.github.ischeneycc.ushot.history-migration-from-legacy.v1"
        )
    }

    func testHistoryMigrationCopiesSourceWithoutRemovingIt() throws {
        let roots = try makeHistoryRoots()
        let legacyRecord = roots.legacy.appendingPathComponent("record-a", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyRecord,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: legacyRecord.appendingPathComponent("metadata.json")
        )

        let result = try SystemScreenshotHistoryStore.migrateHistory(
            from: roots.legacy,
            to: roots.current
        )

        XCTAssertEqual(result, HistoryDirectoryMigrationResult(
            copiedItemCount: 1,
            identicalItemCount: 0
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRecord.path))
        XCTAssertEqual(
            try Data(contentsOf: roots.current
                .appendingPathComponent("record-a", isDirectory: true)
                .appendingPathComponent("metadata.json")),
            Data("legacy".utf8)
        )
    }

    func testHistoryMigrationMergesMissingItemsAndAcceptsIdenticalItems() throws {
        let roots = try makeHistoryRoots()
        try FileManager.default.createDirectory(at: roots.legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: roots.current, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: roots.legacy.appendingPathComponent("same.json"))
        try Data("same".utf8).write(to: roots.current.appendingPathComponent("same.json"))
        try Data("new".utf8).write(to: roots.legacy.appendingPathComponent("new.json"))

        let result = try SystemScreenshotHistoryStore.migrateHistory(
            from: roots.legacy,
            to: roots.current
        )

        XCTAssertEqual(result, HistoryDirectoryMigrationResult(
            copiedItemCount: 1,
            identicalItemCount: 1
        ))
        XCTAssertEqual(
            try Data(contentsOf: roots.current.appendingPathComponent("new.json")),
            Data("new".utf8)
        )
    }

    func testHistoryMigrationRejectsConflictWithoutOverwritingEitherSide() throws {
        let roots = try makeHistoryRoots()
        try FileManager.default.createDirectory(at: roots.legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: roots.current, withIntermediateDirectories: true)
        let legacy = roots.legacy.appendingPathComponent("record.json")
        let current = roots.current.appendingPathComponent("record.json")
        try Data("legacy".utf8).write(to: legacy)
        try Data("current".utf8).write(to: current)

        XCTAssertThrowsError(try SystemScreenshotHistoryStore.migrateHistory(
            from: roots.legacy,
            to: roots.current
        ))
        XCTAssertEqual(try Data(contentsOf: legacy), Data("legacy".utf8))
        XCTAssertEqual(try Data(contentsOf: current), Data("current".utf8))
    }

    func testHistoryMigrationRejectsNestedSymbolicLinkWithoutCreatingDestination() throws {
        let roots = try makeHistoryRoots()
        let legacyRecord = roots.legacy.appendingPathComponent("record-a", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyRecord,
            withIntermediateDirectories: true
        )
        let outsideFile = roots.legacy.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: legacyRecord.appendingPathComponent("metadata.json"),
            withDestinationURL: outsideFile
        )

        XCTAssertThrowsError(try SystemScreenshotHistoryStore.migrateHistory(
            from: roots.legacy,
            to: roots.current
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: roots.current.appendingPathComponent("record-a").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    @MainActor
    func testLaunchAtLoginReconciliationRegistersTheNewIdentity() throws {
        let manager = FakeLaunchAtLoginManager(
            status: .notRegistered,
            statusAfterUpdate: .requiresApproval
        )

        let result = try manager.reconcile(desiredEnabled: true)

        XCTAssertEqual(result, .updated(status: .requiresApproval))
        XCTAssertEqual(manager.requestedValues, [true])
    }

    @MainActor
    func testLaunchAtLoginReconciliationFailsWhenServiceDoesNotChange() {
        let manager = FakeLaunchAtLoginManager(
            status: .notRegistered,
            statusAfterUpdate: .notRegistered
        )

        XCTAssertThrowsError(try manager.reconcile(desiredEnabled: true))
        XCTAssertEqual(manager.requestedValues, [true])
    }

    private func makeHistoryRoots() throws -> (legacy: URL, current: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ushot-history-migration-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return (
            root.appendingPathComponent("legacy", isDirectory: true),
            root.appendingPathComponent("current", isDirectory: true)
        )
    }
}

@MainActor
private final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    private(set) var status: LaunchAtLoginStatus
    private let statusAfterUpdate: LaunchAtLoginStatus
    private(set) var requestedValues: [Bool] = []

    init(status: LaunchAtLoginStatus, statusAfterUpdate: LaunchAtLoginStatus) {
        self.status = status
        self.statusAfterUpdate = statusAfterUpdate
    }

    func setEnabled(_ isEnabled: Bool) throws {
        requestedValues.append(isEnabled)
        status = statusAfterUpdate
    }

    func openSystemSettings() {}
}
