import Foundation
import XCTest
@testable import UshotCore

final class SignedAppcastPolicyTests: XCTestCase {
    private let sparkleNamespace =
        "http://www.andymatuschak.org/xml-namespaces/sparkle"

    func testAcceptsCanonicalAuthenticatedFeed() throws {
        XCTAssertNoThrow(
            try SignedAppcastPolicy.validate(
                authenticatedXML: Data(validFeed().utf8)
            )
        )
    }

    func testExtractsTheAuthenticatedPrefixFromAVerifiedSignedFeed() throws {
        let authenticatedXML = Data(validFeed().utf8)
        let signedFeed = authenticatedXML + signatureTrailer()
        XCTAssertEqual(
            try SignedAppcastEnvelope.authenticatedXML(
                fromVerifiedSignedFeed: signedFeed
            ),
            authenticatedXML
        )
        XCTAssertNoThrow(
            try SignedAppcastPolicy.validate(
                authenticatedXML: SignedAppcastEnvelope.authenticatedXML(
                    fromVerifiedSignedFeed: signedFeed
                )
            )
        )
    }

    func testSignedFeedEnvelopeUsesTheLastSignatureMarker() throws {
        let earlierMarker = Data("<!-- sparkle-signatures:\nignored -->\n".utf8)
        let authenticatedXML = earlierMarker + Data(validFeed().utf8)
        let signedFeed = authenticatedXML + signatureTrailer()
        XCTAssertEqual(
            try SignedAppcastEnvelope.authenticatedXML(
                fromVerifiedSignedFeed: signedFeed
            ),
            authenticatedXML
        )
    }

    func testRejectsMissingOrOversizedSignedFeedEnvelope() {
        XCTAssertThrowsError(
            try SignedAppcastEnvelope.authenticatedXML(
                fromVerifiedSignedFeed: Data(validFeed().utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? SignedAppcastEnvelopeViolation,
                .missingSignatureBlock
            )
        }

        let oversizedTrailer = Data(validFeed().utf8)
            + signatureTrailer(
                totalLength:
                    SignedAppcastEnvelope.maximumSignatureTrailerBytes + 1
            )
        XCTAssertThrowsError(
            try SignedAppcastEnvelope.authenticatedXML(
                fromVerifiedSignedFeed: oversizedTrailer
            )
        ) { error in
            XCTAssertEqual(
                error as? SignedAppcastEnvelopeViolation,
                .oversizedSignatureTrailer
            )
        }

        let oversizedFeed = Data(
            repeating: 0x20,
            count: SignedAppcastEnvelope.maximumSignedFeedBytes + 1
        )
        XCTAssertThrowsError(
            try SignedAppcastEnvelope.authenticatedXML(
                fromVerifiedSignedFeed: oversizedFeed
            )
        ) { error in
            XCTAssertEqual(
                error as? SignedAppcastEnvelopeViolation,
                .oversizedSignedFeed
            )
        }
    }

    func testRejectsDuplicateMetadataBeforeSparkleCanFlattenIt() {
        let duplicateDescription = validFeed().replacingOccurrences(
            of: "<description sparkle:format=\"markdown\"><![CDATA[",
            with: "<description sparkle:format=\"markdown\">Duplicate</description>\n"
                + "            <description sparkle:format=\"markdown\"><![CDATA["
        )
        assertViolation(.invalidEmbeddedReleaseNotes, xml: duplicateDescription)

        let duplicateEnclosure = validFeed().replacingOccurrences(
            of: "            <enclosure ",
            with: enclosureLine(indent: "            ") + "\n            <enclosure "
        )
        assertViolation(.invalidEnclosure, xml: duplicateEnclosure)

        let duplicateBuild = validFeed().replacingOccurrences(
            of: "            <sparkle:version>5</sparkle:version>",
            with: "            <sparkle:version>4</sparkle:version>\n"
                + "            <sparkle:version>5</sparkle:version>"
        )
        assertViolation(.invalidVersionIdentity, xml: duplicateBuild)

        let duplicateItemIdentity = validFeed().replacingOccurrences(
            of: "        </item>",
            with: "        </item>\(itemBlock())"
        )
        assertViolation(
            .duplicateVersionIdentity,
            xml: duplicateItemIdentity
        )
    }

    func testRejectsWrongNamespacesAndHierarchy() {
        let wrongSparkleNamespace = validFeed().replacingOccurrences(
            of: sparkleNamespace,
            with: "https://invalid.example/sparkle"
        )
        assertViolation(.invalidItemStructure, xml: wrongSparkleNamespace)

        let nestedItem = validFeed()
            .replacingOccurrences(of: "        <item>", with: "        <wrapper><item>")
            .replacingOccurrences(of: "        </item>", with: "        </item></wrapper>")
        assertViolation(.invalidChannelStructure, xml: nestedItem)

        let extraRootElement = validFeed().replacingOccurrences(
            of: "    </channel>",
            with: "    </channel>\n    <item></item>"
        )
        assertViolation(.invalidRSSRoot, xml: extraRootElement)
    }

    func testRejectsForbiddenUpdateKindsAndExternalMetadata() {
        let forbiddenElements = [
            "<link>https://invalid.example</link>",
            "<sparkle:releaseNotesLink>https://invalid.example</sparkle:releaseNotesLink>",
            "<sparkle:fullReleaseNotesLink>https://invalid.example</sparkle:fullReleaseNotesLink>",
            "<sparkle:deltas></sparkle:deltas>",
            "<sparkle:informationalUpdate></sparkle:informationalUpdate>",
            "<sparkle:minimumAutoupdateVersion>4</sparkle:minimumAutoupdateVersion>"
        ]
        for forbidden in forbiddenElements {
            let xml = validFeed().replacingOccurrences(
                of: "            <description sparkle:format=\"markdown\">",
                with: "            \(forbidden)\n"
                    + "            <description sparkle:format=\"markdown\">"
            )
            assertViolation(.invalidItemStructure, xml: xml)
        }
    }

    func testRejectsDTDAndEntityInputs() {
        let documentType = validFeed().replacingOccurrences(
            of: "<rss ",
            with: "<!DOCTYPE rss [<!ENTITY secret SYSTEM \"file:///etc/passwd\">]>\n<rss "
        )
        assertViolation(.forbiddenXMLDeclaration, xml: documentType)

        let encodedEntity = validFeed().replacingOccurrences(
            of: "Safe recovered update.",
            with: "Safe &amp; recovered update."
        )
        assertViolation(.forbiddenReleaseNotesContent, xml: encodedEntity)
    }

    func testRejectsUnrestrictedMarkdownDestinations() {
        let rejectedNotes = [
            "[Website](https://invalid.example)",
            "<b>Raw HTML</b>",
            "Visit invalid.example",
            "Visit 127.0.0.1",
            "Visit localhost",
            "mailto:person",
            "www.invalid"
        ]
        for notes in rejectedNotes {
            let xml = validFeed().replacingOccurrences(
                of: "Safe recovered update.",
                with: notes
            )
            assertViolation(.forbiddenReleaseNotesContent, xml: xml)
        }
    }

    func testRejectsNoncanonicalArchiveMetadata() {
        let wrongURL = validFeed().replacingOccurrences(
            of: "releases/download/v0.1.4/Ushot-0.1.4-arm64.zip",
            with: "releases/download/v0.1.4/Other.zip"
        )
        assertViolation(.invalidEnclosure, xml: wrongURL)

        let conflictingVersion = validFeed().replacingOccurrences(
            of: "<enclosure ",
            with: "<enclosure sparkle:version=\"999\" "
        )
        assertViolation(.invalidEnclosure, xml: conflictingVersion)

        let invalidLength = validFeed().replacingOccurrences(
            of: "length=\"1234\"",
            with: "length=\"01\""
        )
        assertViolation(.invalidEnclosure, xml: invalidLength)

        let invalidSignature = validFeed().replacingOccurrences(
            of: signature,
            with: "QUJD"
        )
        assertViolation(.invalidEnclosure, xml: invalidSignature)
    }

    func testRejectsMissingItemsMalformedXMLAndNonUTF8() {
        let noItems = validFeed().replacingOccurrences(
            of: itemBlock(),
            with: ""
        )
        assertViolation(.missingUpdateItems, xml: noItems)
        assertViolation(.malformedXML, xml: "<rss>")

        let utf16 = validFeed().data(using: .utf16)!
        XCTAssertThrowsError(
            try SignedAppcastPolicy.validate(authenticatedXML: utf16)
        ) { error in
            XCTAssertEqual(
                error as? SignedAppcastPolicyViolation,
                .invalidUTF8
            )
        }

        XCTAssertThrowsError(
            try SignedAppcastPolicy.validate(
                authenticatedXML: Data(repeating: 0x20, count: 1_048_577)
            )
        ) { error in
            XCTAssertEqual(
                error as? SignedAppcastPolicyViolation,
                .oversizedDocument
            )
        }
    }

    private func assertViolation(
        _ expected: SignedAppcastPolicyViolation,
        xml: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try SignedAppcastPolicy.validate(
                authenticatedXML: Data(xml.utf8)
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SignedAppcastPolicyViolation,
                expected,
                file: file,
                line: line
            )
        }
    }

    private var signature: String {
        Data(repeating: 0xA5, count: 64).base64EncodedString()
    }

    private func signatureTrailer(totalLength: Int? = nil) -> Data {
        let prefix = Data("<!-- sparkle-signatures:\n".utf8)
        let suffix = Data("-->\n".utf8)
        let requestedLength = totalLength ?? 160
        precondition(requestedLength >= prefix.count + suffix.count)
        return prefix
            + Data(
                repeating: 0x20,
                count: requestedLength - prefix.count - suffix.count
            )
            + suffix
    }

    private func enclosureLine(indent: String) -> String {
        "\(indent)<enclosure "
            + "url=\"https://github.com/isCheneycc/ushot/releases/download/v0.1.4/Ushot-0.1.4-arm64.zip\" "
            + "length=\"1234\" "
            + "type=\"application/octet-stream\" "
            + "sparkle:edSignature=\"\(signature)\"></enclosure>"
    }

    private func itemBlock() -> String {
        """

                <item>
                    <title>0.1.4</title>
                    <pubDate>Thu, 06 Aug 2026 09:00:00 +0800</pubDate>
                    <sparkle:version>5</sparkle:version>
                    <sparkle:shortVersionString>0.1.4</sparkle:shortVersionString>
                    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                    <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
                    <description sparkle:format="markdown"><![CDATA[## Ushot 0.1.4

        - Safe recovered update.
        ]]></description>
        \(enclosureLine(indent: "            "))
                </item>
        """
    }

    private func validFeed() -> String {
        """
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <!-- sparkle-sign-warning: authenticated fixture -->
        <rss xmlns:sparkle="\(sparkleNamespace)" version="2.0">
            <channel>
                <title>Ushot Updates</title>
                <link>https://ischeneycc.github.io/ushot/updates/v1/appcast.xml</link>
                <description>Stable Ushot updates for macOS.</description>
                <language>en</language>\(itemBlock())
            </channel>
        </rss>
        """
    }
}
