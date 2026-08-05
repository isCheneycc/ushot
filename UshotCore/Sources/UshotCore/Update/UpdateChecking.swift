import Foundation

public enum UpdateItemPolicyViolation: String, Equatable, Sendable {
    case invalidVersionIdentity = "invalid-version-identity"
    case invalidArchiveURL = "invalid-archive-url"
    case unexpectedReleaseNotesURL = "unexpected-release-notes-url"
    case missingEmbeddedReleaseNotes = "missing-embedded-release-notes"
    case invalidEmbeddedReleaseNotesFormat = "invalid-embedded-release-notes-format"
    case unexpectedInformationURL = "unexpected-information-url"
    case unexpectedFullReleaseNotesURL = "unexpected-full-release-notes-url"
    case informationOnlyUpdate = "information-only-update"
    case majorUpgrade = "major-upgrade"
    case unexpectedInstallationType = "unexpected-installation-type"
    case unverifiedSignedFeed = "unverified-signed-feed"
    case deltaUpdatesPresent = "delta-updates-present"
}

public enum UpdateEndpointPolicy {
    public static func hasCanonicalVersionIdentity(
        displayVersion: String,
        buildVersion: String
    ) -> Bool {
        isStableSemanticVersion(displayVersion)
            && isPositiveInteger(buildVersion)
    }

    public static func isOfficialReleaseArchiveURL(
        _ url: URL,
        displayVersion: String,
        buildVersion: String
    ) -> Bool {
        guard
            hasCanonicalVersionIdentity(
                displayVersion: displayVersion,
                buildVersion: buildVersion
            ),
            hasCanonicalHTTPSOrigin(url, host: "github.com")
        else { return false }

        return url.absoluteString
            == "https://github.com/isCheneycc/ushot/releases/download/v\(displayVersion)/Ushot-\(displayVersion)-arm64.zip"
    }

    public static func releaseItemViolation(
        displayVersion: String,
        buildVersion: String,
        archiveURL: URL?,
        releaseNotesURL: URL?,
        embeddedReleaseNotes: String?,
        embeddedReleaseNotesFormat: String?,
        informationURL: URL?,
        fullReleaseNotesURL: URL?,
        isInformationOnly: Bool,
        isMajorUpgrade: Bool,
        installationType: String,
        isSignedFeedValidated: Bool,
        isDeltaUpdate: Bool,
        deltaUpdateCount: Int
    ) -> UpdateItemPolicyViolation? {
        guard hasCanonicalVersionIdentity(
            displayVersion: displayVersion,
            buildVersion: buildVersion
        ) else {
            return .invalidVersionIdentity
        }
        guard
            let archiveURL,
            isOfficialReleaseArchiveURL(
                archiveURL,
                displayVersion: displayVersion,
                buildVersion: buildVersion
            )
        else {
            return .invalidArchiveURL
        }
        guard releaseNotesURL == nil else {
            return .unexpectedReleaseNotesURL
        }
        guard let embeddedReleaseNotes,
              !embeddedReleaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .missingEmbeddedReleaseNotes
        }
        guard embeddedReleaseNotesFormat == "markdown" else {
            return .invalidEmbeddedReleaseNotesFormat
        }
        guard informationURL == nil else {
            return .unexpectedInformationURL
        }
        guard fullReleaseNotesURL == nil else {
            return .unexpectedFullReleaseNotesURL
        }
        guard !isInformationOnly else {
            return .informationOnlyUpdate
        }
        guard !isMajorUpgrade else {
            return .majorUpgrade
        }
        guard installationType == "application" else {
            return .unexpectedInstallationType
        }
        guard isSignedFeedValidated else {
            return .unverifiedSignedFeed
        }
        guard !isDeltaUpdate, deltaUpdateCount == 0 else {
            return .deltaUpdatesPresent
        }
        return nil
    }

    private static func isStableSemanticVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components.allSatisfy(isCanonicalNonnegativeInteger)
    }

    private static func isPositiveInteger(_ value: String) -> Bool {
        guard let first = value.utf8.first, (49...57).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    private static func isCanonicalNonnegativeInteger(_ value: Substring) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first else { return false }
        if first == 48 {
            return bytes.count == 1
        }
        return (49...57).contains(first)
            && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    private static func hasCanonicalHTTPSOrigin(_ url: URL, host: String) -> Bool {
        guard
            url.scheme?.lowercased() == "https",
            url.host?.lowercased() == host,
            url.port == nil,
            url.user == nil,
            url.password == nil,
            url.fragment == nil,
            url.query == nil,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.percentEncodedPath == url.path
        else { return false }
        return true
    }
}

public enum UpdateCheckAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

public enum UpdateCheckError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(reason: String)
    case rejected(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .rejected(let reason):
            return reason
        }
    }
}

public typealias UpdateCheckAdmission = @MainActor () throws -> Void

/// A command boundary for a user-initiated update check.
///
/// Sparkle owns update discovery and its standard UI, so this boundary does
/// not synthesize an asynchronous result. Callers provide an admission check
/// that runs immediately before the updater begins its transaction.
@MainActor
public protocol UpdateChecking: AnyObject {
    var availability: UpdateCheckAvailability { get }
    var canCheckForUpdates: Bool { get }
    var isSessionActive: Bool { get }

    func checkForUpdates(admission: @escaping UpdateCheckAdmission) throws
}

/// An explicit fail-closed state used when update configuration is invalid.
/// It never reports that the app is current and always returns the original
/// configuration reason to the caller.
@MainActor
public final class UnavailableUpdateChecker: UpdateChecking {
    public let availability: UpdateCheckAvailability
    public let canCheckForUpdates = false
    public let isSessionActive = false

    public init(reason: String) {
        precondition(!reason.isEmpty, "An unavailable updater requires a visible reason.")
        self.availability = .unavailable(reason: reason)
    }

    public func checkForUpdates(admission: @escaping UpdateCheckAdmission) throws {
        guard let reason = availability.unavailableReason else {
            preconditionFailure("UnavailableUpdateChecker lost its configuration reason.")
        }
        throw UpdateCheckError.unavailable(reason: reason)
    }
}
