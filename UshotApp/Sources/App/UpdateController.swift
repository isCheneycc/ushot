import Foundation
import Sparkle
import UshotCore

private enum SparkleUpdateConfigurationError: Error, LocalizedError {
    case invalidFeedURL
    case invalidPublicKey
    case invalidPolicy(key: String, expected: Bool)
    case invalidNumberPolicy(key: String, expected: Int)
    case updaterStartFailed(domain: String, code: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            return String(
                localized: "Updates are unavailable because this build has an invalid update feed."
            )
        case .invalidPublicKey:
            return String(
                localized: "Updates are unavailable because this build has an invalid update-signing key."
            )
        case .invalidPolicy, .invalidNumberPolicy:
            return String(
                localized: "Updates are unavailable because this build has an incomplete update security policy."
            )
        case .updaterStartFailed:
            return String(
                localized: "Updates are unavailable because the update service could not start."
            )
        }
    }

    var diagnosticCode: String {
        switch self {
        case .invalidFeedURL:
            return "invalid-feed-url"
        case .invalidPublicKey:
            return "invalid-public-key"
        case .invalidPolicy(let key, let expected):
            return "invalid-policy-\(key)-expected-\(expected)"
        case .invalidNumberPolicy(let key, let expected):
            return "invalid-policy-\(key)-expected-\(expected)"
        case .updaterStartFailed(let domain, let code):
            return "start-failed-\(domain)-\(code)"
        }
    }
}

private struct SparkleUpdateConfiguration {
    static let feedURLString = ProductIdentity.updateFeedURLString
    static let publicEDKey = ProductIdentity.sparklePublicEDKey

    let feedURL: URL

    init(bundle: Bundle) throws {
        guard
            let configuredFeed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            configuredFeed == Self.feedURLString,
            let feedURL = URL(string: configuredFeed),
            feedURL.scheme == "https",
            feedURL.host != nil
        else {
            throw SparkleUpdateConfigurationError.invalidFeedURL
        }

        guard
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            publicKey == Self.publicEDKey,
            Data(base64Encoded: publicKey)?.count == 32
        else {
            throw SparkleUpdateConfigurationError.invalidPublicKey
        }

        try Self.requireBoolean("SUEnableAutomaticChecks", expected: false, in: bundle)
        try Self.requireBoolean("SUAutomaticallyUpdate", expected: false, in: bundle)
        try Self.requireBoolean("SUAllowsAutomaticUpdates", expected: false, in: bundle)
        try Self.requireBoolean("SUEnableSystemProfiling", expected: false, in: bundle)
        try Self.requireBoolean("SUVerifyUpdateBeforeExtraction", expected: true, in: bundle)
        try Self.requireBoolean("SURequireSignedFeed", expected: true, in: bundle)
        try Self.requireInteger(
            "SUSignedFeedFailureExpirationInterval",
            expected: 0,
            in: bundle
        )

        self.feedURL = feedURL
    }

    private static func requireBoolean(
        _ key: String,
        expected: Bool,
        in bundle: Bundle
    ) throws {
        guard
            let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber,
            value.boolValue == expected
        else {
            throw SparkleUpdateConfigurationError.invalidPolicy(key: key, expected: expected)
        }
    }

    private static func requireInteger(
        _ key: String,
        expected: Int,
        in bundle: Bundle
    ) throws {
        guard
            let value = bundle.object(forInfoDictionaryKey: key) as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.intValue == expected
        else {
            throw SparkleUpdateConfigurationError.invalidNumberPolicy(
                key: key,
                expected: expected
            )
        }
    }
}

private struct SparkleReleaseItemPolicyFailure {
    let diagnostic: String
    let error: NSError
}

private enum SparkleReleaseItemPolicy {
    static func failure(for item: SUAppcastItem) -> SparkleReleaseItemPolicyFailure? {
        guard let violation = UpdateEndpointPolicy.releaseItemViolation(
            displayVersion: item.displayVersionString,
            buildVersion: item.versionString,
            archiveURL: item.fileURL,
            releaseNotesURL: item.releaseNotesURL,
            embeddedReleaseNotes: item.itemDescription,
            embeddedReleaseNotesFormat: item.itemDescriptionFormat,
            informationURL: item.infoURL,
            fullReleaseNotesURL: item.fullReleaseNotesURL,
            isInformationOnly: item.isInformationOnlyUpdate,
            isMajorUpgrade: item.isMajorUpgrade,
            installationType: item.installationType,
            isSignedFeedValidated: item.signingValidationStatus == .succeeded,
            isDeltaUpdate: item.isDeltaUpdate,
            deltaUpdateCount: item.deltaUpdates?.count ?? 0
        ) else {
            return nil
        }
        return makeFailure(diagnostic: violation.rawValue)
    }

    static func malformedLatestItemFailure() -> SparkleReleaseItemPolicyFailure {
        makeFailure(diagnostic: "invalid-latest-appcast-item-type")
    }

    private static func makeFailure(
        diagnostic: String
    ) -> SparkleReleaseItemPolicyFailure {
        return SparkleReleaseItemPolicyFailure(
            diagnostic: diagnostic,
            error: NSError(
                domain: ProductIdentity.bundleIdentifier,
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The update was rejected because the signed update feed violates Ushot's security policy."
                    )
                ]
            )
        )
    }
}

@MainActor
private final class PolicyEnforcingStandardUserDriver: SPUStandardUserDriver {
    private let onPolicyFailure: (SparkleReleaseItemPolicyFailure, String) -> Void

    init(
        hostBundle: Bundle,
        delegate: SPUStandardUserDriverDelegate,
        onPolicyFailure: @escaping (SparkleReleaseItemPolicyFailure, String) -> Void
    ) {
        self.onPolicyFailure = onPolicyFailure
        super.init(hostBundle: hostBundle, delegate: delegate)
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if let failure = SparkleReleaseItemPolicy.failure(for: appcastItem) {
            onPolicyFailure(failure, "show-update-found")
            showUpdaterError(failure.error) {
                reply(Self.rejectionChoice(for: state))
            }
            return
        }
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    override func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        let nsError = error as NSError
        if let latestValue = nsError.userInfo[SPULatestAppcastItemFoundKey] {
            guard let latestItem = latestValue as? SUAppcastItem else {
                let failure = SparkleReleaseItemPolicy.malformedLatestItemFailure()
                onPolicyFailure(failure, "show-update-not-found")
                showUpdaterError(failure.error, acknowledgement: acknowledgement)
                return
            }
            if let failure = SparkleReleaseItemPolicy.failure(for: latestItem) {
                onPolicyFailure(failure, "show-update-not-found")
                showUpdaterError(failure.error, acknowledgement: acknowledgement)
                return
            }
        }

        super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
    private static func rejectionChoice(
        for state: SPUUserUpdateState
    ) -> SPUUserUpdateChoice {
        switch state.stage {
        case .notDownloaded, .downloaded, .installing:
            // Skip is the only choice that discards a resumed download and
            // explicitly cancels an already-started installation.
            return .skip
        @unknown default:
            preconditionFailure("Sparkle returned an unknown resumed-update stage.")
        }
    }
}

@MainActor
final class SparkleUpdateChecker:
    NSObject,
    UpdateChecking,
    SPUUpdaterDelegate,
    SPUStandardUserDriverDelegate
{
    private struct PendingCheck {
        let generation: UInt64
        let admission: UpdateCheckAdmission
    }

    private struct ActiveCheck {
        let generation: UInt64
        let updateCheckRawValue: Int
        let startedAt: TimeInterval
        let admission: UpdateCheckAdmission
        var policyFailureDiagnostic: String?
    }

    let availability: UpdateCheckAvailability = .available

    var canCheckForUpdates: Bool {
        pendingCheck == nil
            && activeCheck == nil
            && !updater.sessionInProgress
            && updater.canCheckForUpdates
    }

    var isSessionActive: Bool {
        pendingCheck != nil
            || activeCheck != nil
            || updater.sessionInProgress
    }

    private let configuration: SparkleUpdateConfiguration
    private var nextGeneration: UInt64 = 0
    private var pendingCheck: PendingCheck?
    private var activeCheck: ActiveCheck?
    private var postponedRelaunchTask: Task<Void, Never>?
    private var updater: SPUUpdater!
    private var userDriver: PolicyEnforcingStandardUserDriver!

    init(bundle: Bundle = .main) throws {
        self.configuration = try SparkleUpdateConfiguration(bundle: bundle)
        super.init()

        let userDriver = PolicyEnforcingStandardUserDriver(
            hostBundle: bundle,
            delegate: self
        ) { [weak self] failure, boundary in
            self?.recordPolicyFailure(failure, boundary: boundary)
        }
        self.userDriver = userDriver
        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: userDriver,
            delegate: self
        )
        self.updater = updater
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false

        do {
            try updater.start()
        } catch {
            let nsError = error as NSError
            throw SparkleUpdateConfigurationError.updaterStartFailed(
                domain: nsError.domain,
                code: nsError.code
            )
        }

        guard
            updater.automaticallyChecksForUpdates == false,
            updater.automaticallyDownloadsUpdates == false,
            updater.sendsSystemProfile == false
        else {
            throw SparkleUpdateConfigurationError.invalidPolicy(
                key: "runtime-manual-only-policy",
                expected: true
            )
        }

        AppLog.updates.notice(
            "Update controller started: feedHost=\(self.configuration.feedURL.host ?? "unknown", privacy: .public), manualOnly=true, automaticDownloads=false, systemProfile=false, verifyBeforeExtraction=true, signedFeed=true, signedFeedFailureExpirationSeconds=0"
        )
    }

    func checkForUpdates(admission: @escaping UpdateCheckAdmission) throws {
        if activeCheck != nil, !updater.sessionInProgress {
            AppLog.updates.fault(
                "Discarded stale update trace state before a new manual request"
            )
            activeCheck = nil
        }
        guard canCheckForUpdates else {
            AppLog.updates.notice(
                "Rejected overlapping manual update check: pending=\(self.pendingCheck != nil, privacy: .public), active=\(self.isSessionActive, privacy: .public), sparkleCanCheck=\(self.updater.canCheckForUpdates, privacy: .public)"
            )
            throw UpdateCheckError.rejected(
                reason: String(localized: "An update check is already in progress.")
            )
        }

        try admission()

        nextGeneration &+= 1
        precondition(nextGeneration != 0, "Update-check generation overflowed.")
        let generation = nextGeneration
        pendingCheck = PendingCheck(generation: generation, admission: admission)
        AppLog.updates.notice(
            "Manual update check requested: generation=\(generation, privacy: .public)"
        )
        updater.checkForUpdates()
        guard updater.sessionInProgress else {
            if pendingCheck?.generation == generation {
                pendingCheck = nil
            }
            AppLog.updates.error(
                "Sparkle did not start the requested update session: generation=\(generation, privacy: .public)"
            )
            throw UpdateCheckError.rejected(
                reason: String(localized: "The update service did not start the requested check.")
            )
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        configuration.feedURL.absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        []
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }

    nonisolated func standardUserDriverShouldShowVersionHistory(
        for item: SUAppcastItem
    ) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard let pendingCheck else {
            AppLog.updates.error(
                "Rejected an update cycle without a manual request: checkType=\(updateCheck.rawValue, privacy: .public)"
            )
            throw NSError(
                domain: ProductIdentity.bundleIdentifier,
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "Ushot only checks for updates when you choose Check for Updates."
                    )
                ]
            )
        }

        do {
            try pendingCheck.admission()
        } catch {
            if self.pendingCheck?.generation == pendingCheck.generation {
                self.pendingCheck = nil
            }
            AppLog.updates.notice(
                "Rejected manual update check at the Sparkle admission boundary: generation=\(pendingCheck.generation, privacy: .public)"
            )
            throw error
        }

        guard activeCheck == nil else {
            preconditionFailure("Sparkle admitted a second update cycle before the first one finished.")
        }
        self.pendingCheck = nil
        activeCheck = ActiveCheck(
            generation: pendingCheck.generation,
            updateCheckRawValue: updateCheck.rawValue,
            startedAt: ProcessInfo.processInfo.systemUptime,
            admission: pendingCheck.admission,
            policyFailureDiagnostic: nil
        )
        AppLog.updates.notice(
            "Manual update cycle admitted: generation=\(pendingCheck.generation, privacy: .public), checkType=\(updateCheck.rawValue, privacy: .public)"
        )
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        AppLog.updates.notice(
            "Update found: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
        )
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        AppLog.updates.notice(
            "User answered update prompt: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(updateItem.displayVersionString, privacy: .public), choice=\(String(describing: choice), privacy: .public), stage=\(String(describing: state.stage), privacy: .public)"
        )
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let displayVersion = updateItem.displayVersionString
        let buildVersion = updateItem.versionString
        if let failure = SparkleReleaseItemPolicy.failure(for: updateItem) {
            recordPolicyFailure(failure, boundary: "should-proceed")
            throw failure.error
        }
        AppLog.updates.notice(
            "Accepted official update endpoints: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(displayVersion, privacy: .public), build=\(buildVersion, privacy: .public), checkType=\(updateCheck.rawValue, privacy: .public)"
        )
    }

    func updater(
        _ updater: SPUUpdater,
        shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem
    ) -> Bool {
        if let failure = SparkleReleaseItemPolicy.failure(for: updateItem) {
            recordPolicyFailure(
                failure,
                boundary: "should-download-release-notes"
            )
            return false
        }
        // Ushot embeds Markdown notes inside the cryptographically signed
        // appcast. No detached release-notes request is permitted.
        return false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let nsError = error as NSError
        if let diagnostic = activeCheck?.policyFailureDiagnostic {
            AppLog.updates.error(
                "Update discovery ended after a policy rejection: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), diagnostic=\(diagnostic, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
        } else {
            AppLog.updates.notice(
                "No applicable update found: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        AppLog.updates.notice(
            "Update download started: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
        )
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        AppLog.updates.notice(
            "Update download finished: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
        )
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        AppLog.updates.notice(
            "User cancelled update download: generation=\(self.activeCheck?.generation ?? 0, privacy: .public)"
        )
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        AppLog.updates.notice(
            "Update extraction started: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
        )
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        AppLog.updates.notice(
            "Update extraction finished: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
        )
    }

    func updater(
        _ updater: SPUUpdater,
        failedToDownloadUpdate item: SUAppcastItem,
        error: any Error
    ) {
        let nsError = error as NSError
        AppLog.updates.error(
            "Update download failed: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(item.displayVersionString, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
        )
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        AppLog.updates.notice(
            "Update installation requested: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
        )
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let activeCheck else {
            AppLog.updates.fault(
                "Sparkle requested an update relaunch without an owned manual transaction"
            )
            preconditionFailure(
                "An update relaunch must belong to an admitted manual update transaction."
            )
        }
        do {
            try activeCheck.admission()
            AppLog.updates.notice(
                "Admitted update relaunch with no active app work: generation=\(activeCheck.generation, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
            )
            return false
        } catch {
            precondition(
                postponedRelaunchTask == nil,
                "Sparkle cannot request a second postponed relaunch before the first resolves."
            )
            let generation = activeCheck.generation
            AppLog.updates.notice(
                "Postponed update relaunch until active app work finishes: generation=\(generation, privacy: .public), version=\(item.displayVersionString, privacy: .public)"
            )
            postponedRelaunchTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch {
                        AppLog.updates.debug(
                            "Cancelled postponed update relaunch polling: generation=\(generation, privacy: .public)"
                        )
                        return
                    }
                    guard
                        let self,
                        let currentCheck = self.activeCheck,
                        currentCheck.generation == generation
                    else {
                        AppLog.updates.fault(
                            "Abandoned stale postponed update relaunch: generation=\(generation, privacy: .public)"
                        )
                        return
                    }
                    do {
                        try currentCheck.admission()
                        self.postponedRelaunchTask = nil
                        AppLog.updates.notice(
                            "Resumed postponed update relaunch after app work finished: generation=\(generation, privacy: .public)"
                        )
                        installHandler()
                        return
                    } catch {
                        continue
                    }
                }
            }
            return true
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        AppLog.updates.notice(
            "Update relaunch handoff started: generation=\(self.activeCheck?.generation ?? 0, privacy: .public)"
        )
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        if let diagnostic = activeCheck?.policyFailureDiagnostic {
            AppLog.updates.error(
                "Update driver aborted after a policy rejection: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), diagnostic=\(diagnostic, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
        } else if Self.isExpectedNoUpdateError(nsError) {
            AppLog.updates.notice(
                "Update driver ended because the app is current: generation=\(self.activeCheck?.generation ?? 0, privacy: .public)"
            )
        } else if Self.isExpectedInstallationCancellation(nsError) {
            AppLog.updates.notice(
                "Update installation authorization was cancelled: generation=\(self.activeCheck?.generation ?? 0, privacy: .public)"
            )
        } else {
            AppLog.updates.error(
                "Update driver aborted: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
            )
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard !updater.sessionInProgress else {
            AppLog.updates.fault(
                "Ignored stale update-cycle completion while a newer Sparkle session is active: checkType=\(updateCheck.rawValue, privacy: .public)"
            )
            return
        }
        guard let activeCheck else {
            if let pendingCheck {
                self.pendingCheck = nil
                AppLog.updates.error(
                    "Update cycle ended before Sparkle admitted the pending request: generation=\(pendingCheck.generation, privacy: .public), checkType=\(updateCheck.rawValue, privacy: .public)"
                )
                return
            }
            AppLog.updates.debug(
                "Ignored update-cycle completion without an owned manual session: checkType=\(updateCheck.rawValue, privacy: .public)"
            )
            return
        }
        guard activeCheck.updateCheckRawValue == updateCheck.rawValue else {
            self.activeCheck = nil
            AppLog.updates.fault(
                "Cleared mismatched update-cycle trace after Sparkle ended its session: generation=\(activeCheck.generation, privacy: .public), expectedType=\(activeCheck.updateCheckRawValue, privacy: .public), receivedType=\(updateCheck.rawValue, privacy: .public)"
            )
            return
        }

        postponedRelaunchTask?.cancel()
        postponedRelaunchTask = nil
        self.activeCheck = nil
        let durationMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - activeCheck.startedAt) * 1_000
        )
        if let diagnostic = activeCheck.policyFailureDiagnostic {
            if let error {
                let nsError = error as NSError
                AppLog.updates.error(
                    "Update cycle finished after a policy rejection: generation=\(activeCheck.generation, privacy: .public), durationMs=\(durationMilliseconds, privacy: .public), diagnostic=\(diagnostic, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
                )
            } else {
                AppLog.updates.error(
                    "Update cycle finished after a policy rejection: generation=\(activeCheck.generation, privacy: .public), durationMs=\(durationMilliseconds, privacy: .public), diagnostic=\(diagnostic, privacy: .public), sparkleError=none"
                )
            }
        } else if let error {
            let nsError = error as NSError
            if Self.isExpectedNoUpdateError(nsError) {
                AppLog.updates.notice(
                    "Update cycle finished with no applicable update: generation=\(activeCheck.generation, privacy: .public), durationMs=\(durationMilliseconds, privacy: .public)"
                )
            } else if Self.isExpectedInstallationCancellation(nsError) {
                AppLog.updates.notice(
                    "Update cycle finished after authorization cancellation: generation=\(activeCheck.generation, privacy: .public), durationMs=\(durationMilliseconds, privacy: .public)"
                )
            } else {
                AppLog.updates.error(
                    "Update cycle finished with an error: generation=\(activeCheck.generation, privacy: .public), durationMs=\(durationMilliseconds, privacy: .public), domain=\(nsError.domain, privacy: .public), code=\(nsError.code, privacy: .public)"
                )
            }
        } else {
            AppLog.updates.notice(
                "Update cycle finished: generation=\(activeCheck.generation, privacy: .public), durationMs=\(durationMilliseconds, privacy: .public)"
            )
        }
    }

    private func recordPolicyFailure(
        _ failure: SparkleReleaseItemPolicyFailure,
        boundary: String
    ) {
        if var activeCheck {
            activeCheck.policyFailureDiagnostic = failure.diagnostic
            self.activeCheck = activeCheck
        }
        AppLog.updates.error(
            "Rejected update item metadata: generation=\(self.activeCheck?.generation ?? 0, privacy: .public), boundary=\(boundary, privacy: .public), diagnostic=\(failure.diagnostic, privacy: .public)"
        )
    }

    private static func isExpectedNoUpdateError(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain && error.code == 1_001
    }

    private static func isExpectedInstallationCancellation(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain && error.code == 4_007
    }
}

extension SparkleUpdateChecker {
    static func makeFailClosed(bundle: Bundle = .main) -> any UpdateChecking {
        do {
            return try SparkleUpdateChecker(bundle: bundle)
        } catch {
            let configurationError = error as? SparkleUpdateConfigurationError
            let reason = error.localizedDescription
            AppLog.updates.fault(
                "Update controller is unavailable: diagnostic=\(configurationError?.diagnosticCode ?? "unknown", privacy: .public)"
            )
            return UnavailableUpdateChecker(reason: reason)
        }
    }
}
