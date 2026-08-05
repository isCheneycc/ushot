import XCTest
@testable import UshotCore

@MainActor
final class UpdateCheckingTests: XCTestCase {
    func testUnavailableCheckerExposesReasonAndCannotStart() {
        let reason = "The updater is not securely configured."
        let checker = UnavailableUpdateChecker(reason: reason)

        XCTAssertEqual(checker.availability, .unavailable(reason: reason))
        XCTAssertEqual(checker.availability.unavailableReason, reason)
        XCTAssertFalse(checker.canCheckForUpdates)
        XCTAssertFalse(checker.isSessionActive)
    }

    func testUnavailableCheckerThrowsOriginalReasonWithoutRunningAdmission() {
        let reason = "The updater is not securely configured."
        let checker = UnavailableUpdateChecker(reason: reason)
        var admissionRan = false

        XCTAssertThrowsError(try checker.checkForUpdates {
            admissionRan = true
        }) { error in
            XCTAssertEqual(error as? UpdateCheckError, .unavailable(reason: reason))
            XCTAssertEqual(error.localizedDescription, reason)
        }
        XCTAssertFalse(admissionRan)
    }

    func testAvailableStateDoesNotExposeAnUnavailableReason() {
        XCTAssertNil(UpdateCheckAvailability.available.unavailableReason)
    }

    func testEndpointPolicyAcceptsOnlyCanonicalReleaseAssets() throws {
        let displayVersion = "0.1.1"
        let buildVersion = "2"
        let valid = try XCTUnwrap(URL(string:
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.1-arm64.zip"
        ))
        XCTAssertTrue(UpdateEndpointPolicy.isOfficialReleaseArchiveURL(
            valid,
            displayVersion: displayVersion,
            buildVersion: buildVersion
        ))

        let rejected = [
            "http://github.com/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.1-arm64.zip",
            "https://github.com.evil.example/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.1-arm64.zip",
            "https://github.com:443/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.1-arm64.zip",
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.1/Other.zip",
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.1-arm64.zip?token=unexpected",
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.1/Ushot-%30.1.1-arm64.zip"
        ]
        for value in rejected {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(
                UpdateEndpointPolicy.isOfficialReleaseArchiveURL(
                    url,
                    displayVersion: displayVersion,
                    buildVersion: buildVersion
                ),
                "Unexpectedly accepted \(value)"
            )
        }

        let mismatchedTag = try XCTUnwrap(URL(string:
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.2/Ushot-0.1.1-arm64.zip"
        ))
        let mismatchedFilename = try XCTUnwrap(URL(string:
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.2-arm64.zip"
        ))
        XCTAssertFalse(UpdateEndpointPolicy.isOfficialReleaseArchiveURL(
            mismatchedTag,
            displayVersion: displayVersion,
            buildVersion: buildVersion
        ))
        XCTAssertFalse(UpdateEndpointPolicy.isOfficialReleaseArchiveURL(
            mismatchedFilename,
            displayVersion: displayVersion,
            buildVersion: buildVersion
        ))
    }

    func testEndpointPolicyRequiresStableSemanticAndPositiveBuildVersions() throws {
        let archiveURL = try XCTUnwrap(URL(string:
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.1-arm64.zip"
        ))
        XCTAssertTrue(UpdateEndpointPolicy.hasCanonicalVersionIdentity(
            displayVersion: "0.1.1",
            buildVersion: "2"
        ))

        let invalidDisplayVersions = [
            "", "0.1", "0.1.1.0", "00.1.1", "0.01.1", "0.1.01",
            "v0.1.1", "0.1.1-beta.1", "0.1.1+1", "０.1.1"
        ]
        for displayVersion in invalidDisplayVersions {
            XCTAssertFalse(UpdateEndpointPolicy.hasCanonicalVersionIdentity(
                displayVersion: displayVersion,
                buildVersion: "2"
            ))
            XCTAssertFalse(UpdateEndpointPolicy.isOfficialReleaseArchiveURL(
                archiveURL,
                displayVersion: displayVersion,
                buildVersion: "2"
            ))
        }

        let invalidBuildVersions = ["", "0", "00", "01", "-1", "+1", "1.0", "１"]
        for buildVersion in invalidBuildVersions {
            XCTAssertFalse(UpdateEndpointPolicy.hasCanonicalVersionIdentity(
                displayVersion: "0.1.1",
                buildVersion: buildVersion
            ))
            XCTAssertFalse(UpdateEndpointPolicy.isOfficialReleaseArchiveURL(
                archiveURL,
                displayVersion: "0.1.1",
                buildVersion: buildVersion
            ))
        }
    }

    func testReleaseItemPolicyRequiresOnlyCanonicalInstallableMetadata() throws {
        let archiveURL = try XCTUnwrap(URL(string:
            "https://github.com/isCheneycc/ushot/releases/download/v0.1.1/Ushot-0.1.1-arm64.zip"
        ))
        let externalURL = try XCTUnwrap(URL(string: "https://example.com/untrusted"))

        func violation(
            displayVersion: String = "0.1.1",
            buildVersion: String = "2",
            archiveURL: URL? = archiveURL,
            releaseNotesURL: URL? = nil,
            embeddedReleaseNotes: String? = "## Ushot 0.1.1\n\n- Improvements",
            embeddedReleaseNotesFormat: String? = "markdown",
            informationURL: URL? = nil,
            fullReleaseNotesURL: URL? = nil,
            isInformationOnly: Bool = false,
            isMajorUpgrade: Bool = false,
            installationType: String = "application",
            isSignedFeedValidated: Bool = true,
            isDeltaUpdate: Bool = false,
            deltaUpdateCount: Int = 0
        ) -> UpdateItemPolicyViolation? {
            UpdateEndpointPolicy.releaseItemViolation(
                displayVersion: displayVersion,
                buildVersion: buildVersion,
                archiveURL: archiveURL,
                releaseNotesURL: releaseNotesURL,
                embeddedReleaseNotes: embeddedReleaseNotes,
                embeddedReleaseNotesFormat: embeddedReleaseNotesFormat,
                informationURL: informationURL,
                fullReleaseNotesURL: fullReleaseNotesURL,
                isInformationOnly: isInformationOnly,
                isMajorUpgrade: isMajorUpgrade,
                installationType: installationType,
                isSignedFeedValidated: isSignedFeedValidated,
                isDeltaUpdate: isDeltaUpdate,
                deltaUpdateCount: deltaUpdateCount
            )
        }

        XCTAssertNil(violation())
        XCTAssertEqual(
            violation(displayVersion: "0.1.1-beta.1"),
            .invalidVersionIdentity
        )
        XCTAssertEqual(violation(buildVersion: "0"), .invalidVersionIdentity)
        XCTAssertEqual(violation(archiveURL: nil), .invalidArchiveURL)
        XCTAssertEqual(violation(archiveURL: externalURL), .invalidArchiveURL)
        XCTAssertEqual(
            violation(releaseNotesURL: externalURL),
            .unexpectedReleaseNotesURL
        )
        XCTAssertEqual(
            violation(embeddedReleaseNotes: nil),
            .missingEmbeddedReleaseNotes
        )
        XCTAssertEqual(
            violation(embeddedReleaseNotes: " \n\t"),
            .missingEmbeddedReleaseNotes
        )
        XCTAssertEqual(
            violation(embeddedReleaseNotesFormat: nil),
            .invalidEmbeddedReleaseNotesFormat
        )
        XCTAssertEqual(
            violation(embeddedReleaseNotesFormat: "html"),
            .invalidEmbeddedReleaseNotesFormat
        )
        XCTAssertEqual(
            violation(informationURL: externalURL),
            .unexpectedInformationURL
        )
        XCTAssertEqual(
            violation(fullReleaseNotesURL: externalURL),
            .unexpectedFullReleaseNotesURL
        )
        XCTAssertEqual(violation(isInformationOnly: true), .informationOnlyUpdate)
        XCTAssertEqual(violation(isMajorUpgrade: true), .majorUpgrade)
        XCTAssertEqual(
            violation(installationType: "package"),
            .unexpectedInstallationType
        )
        XCTAssertEqual(
            violation(isSignedFeedValidated: false),
            .unverifiedSignedFeed
        )
        XCTAssertEqual(violation(isDeltaUpdate: true), .deltaUpdatesPresent)
        XCTAssertEqual(violation(deltaUpdateCount: 1), .deltaUpdatesPresent)
        XCTAssertEqual(violation(deltaUpdateCount: -1), .deltaUpdatesPresent)
    }
}
