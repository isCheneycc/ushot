import Foundation

public enum SignedAppcastPolicyViolation: String, Error, Equatable, Sendable {
    case oversizedDocument = "oversized-document"
    case invalidUTF8 = "invalid-utf8"
    case forbiddenXMLDeclaration = "forbidden-xml-declaration"
    case malformedXML = "malformed-xml"
    case invalidRSSRoot = "invalid-rss-root"
    case invalidChannelStructure = "invalid-channel-structure"
    case invalidChannelMetadata = "invalid-channel-metadata"
    case missingUpdateItems = "missing-update-items"
    case invalidItemStructure = "invalid-item-structure"
    case invalidVersionIdentity = "invalid-version-identity"
    case duplicateVersionIdentity = "duplicate-version-identity"
    case invalidEmbeddedReleaseNotes = "invalid-embedded-release-notes"
    case forbiddenReleaseNotesContent = "forbidden-release-notes-content"
    case invalidEnclosure = "invalid-enclosure"
}

public enum SignedAppcastEnvelopeViolation: String, Error, Equatable, Sendable {
    case oversizedSignedFeed = "oversized-signed-feed"
    case missingSignatureBlock = "missing-signature-block"
    case oversizedSignatureTrailer = "oversized-signature-trailer"
}

/// Extracts the same authenticated prefix that Sparkle verifies and passes to
/// the host. Call this only after Sparkle's signed-feed verification succeeds.
public enum SignedAppcastEnvelope {
    public static let maximumSignatureTrailerBytes = 512
    public static let maximumSignedFeedBytes =
        SignedAppcastPolicy.maximumAuthenticatedXMLBytes
        + maximumSignatureTrailerBytes

    private static let signatureBlockPrefix =
        Data("<!-- sparkle-signatures:\n".utf8)

    public static func authenticatedXML(
        fromVerifiedSignedFeed data: Data
    ) throws -> Data {
        guard data.count <= maximumSignedFeedBytes else {
            throw SignedAppcastEnvelopeViolation.oversizedSignedFeed
        }
        guard let signatureRange = data.range(
            of: signatureBlockPrefix,
            options: .backwards
        ) else {
            throw SignedAppcastEnvelopeViolation.missingSignatureBlock
        }
        let trailerLength = data.distance(
            from: signatureRange.lowerBound,
            to: data.endIndex
        )
        guard trailerLength <= maximumSignatureTrailerBytes else {
            throw SignedAppcastEnvelopeViolation.oversizedSignatureTrailer
        }
        let authenticatedXML = Data(data[..<signatureRange.lowerBound])
        guard
            authenticatedXML.count
                <= SignedAppcastPolicy.maximumAuthenticatedXMLBytes
        else {
            throw SignedAppcastPolicyViolation.oversizedDocument
        }
        return authenticatedXML
    }
}

/// Validates the exact authenticated XML bytes before Sparkle flattens them
/// into `SUAppcastItem` values. This prevents duplicate or misplaced metadata
/// from disappearing during localized-node selection.
public enum SignedAppcastPolicy {
    public static let maximumAuthenticatedXMLBytes = 1_048_576

    private static let sparkleNamespace =
        "http://www.andymatuschak.org/xml-namespaces/sparkle"
    private static let channelTitle = "Ushot Updates"
    private static let channelDescription = "Stable Ushot updates for macOS."
    private static let channelLanguage = "en"

    public static func validate(authenticatedXML data: Data) throws {
        guard data.count <= maximumAuthenticatedXMLBytes else {
            throw SignedAppcastPolicyViolation.oversizedDocument
        }
        guard
            !data.starts(with: [0xEF, 0xBB, 0xBF]),
            let source = String(data: data, encoding: .utf8),
            Data(source.utf8) == data
        else {
            throw SignedAppcastPolicyViolation.invalidUTF8
        }
        guard
            !source.contains("<!DOCTYPE"),
            !source.contains("<!ENTITY")
        else {
            throw SignedAppcastPolicyViolation.forbiddenXMLDeclaration
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(
                data: data,
                options: [.nodeLoadExternalEntitiesNever]
            )
        } catch {
            throw SignedAppcastPolicyViolation.malformedXML
        }
        guard let root = document.rootElement() else {
            throw SignedAppcastPolicyViolation.invalidRSSRoot
        }
        guard hasOnlyDocumentCommentsWhitespaceAndRoot(document, root: root) else {
            throw SignedAppcastPolicyViolation.invalidRSSRoot
        }
        try validateRoot(root)
    }

    private static func validateRoot(_ root: XMLElement) throws {
        guard
            hasName(root, localName: "rss", namespace: nil),
            hasOnlyAttributes(root, [AttributeName(localName: "version")]),
            attributeValue(root, localName: "version", namespace: nil) == "2.0",
            hasOnlyWhitespaceTextOutsideElements(root)
        else {
            throw SignedAppcastPolicyViolation.invalidRSSRoot
        }

        let rootElements = childElements(of: root)
        guard
            rootElements.count == 1,
            let channel = rootElements.first,
            hasName(channel, localName: "channel", namespace: nil)
        else {
            throw SignedAppcastPolicyViolation.invalidRSSRoot
        }
        guard
            channel.attributes?.isEmpty ?? true,
            hasOnlyWhitespaceTextOutsideElements(channel)
        else {
            throw SignedAppcastPolicyViolation.invalidChannelStructure
        }
        try validateChannel(channel)
    }

    private static func validateChannel(_ channel: XMLElement) throws {
        let elements = childElements(of: channel)
        let permitted = Set([
            ElementName(localName: "title"),
            ElementName(localName: "link"),
            ElementName(localName: "description"),
            ElementName(localName: "language"),
            ElementName(localName: "item")
        ])
        guard elements.allSatisfy({ permitted.contains(elementName($0)) }) else {
            throw SignedAppcastPolicyViolation.invalidChannelStructure
        }

        let title: String
        let link: String
        let description: String
        let language: String
        do {
            title = try uniqueText(
                localName: "title",
                namespace: nil,
                in: elements
            )
            link = try uniqueText(
                localName: "link",
                namespace: nil,
                in: elements
            )
            description = try uniqueText(
                localName: "description",
                namespace: nil,
                in: elements
            )
            language = try uniqueText(
                localName: "language",
                namespace: nil,
                in: elements
            )
        } catch {
            throw SignedAppcastPolicyViolation.invalidChannelMetadata
        }
        guard
            title == channelTitle,
            link == ProductIdentity.updateFeedURLString,
            description == channelDescription,
            language == channelLanguage
        else {
            throw SignedAppcastPolicyViolation.invalidChannelMetadata
        }

        let items = elements.filter {
            hasName($0, localName: "item", namespace: nil)
        }
        guard !items.isEmpty else {
            throw SignedAppcastPolicyViolation.missingUpdateItems
        }
        var displayVersions = Set<String>()
        var buildVersions = Set<String>()
        for item in items {
            let identity = try validateItem(item)
            guard
                displayVersions.insert(identity.displayVersion).inserted,
                buildVersions.insert(identity.buildVersion).inserted
            else {
                throw SignedAppcastPolicyViolation.duplicateVersionIdentity
            }
        }
    }

    private static func validateItem(_ item: XMLElement) throws -> VersionIdentity {
        guard
            item.attributes?.isEmpty ?? true,
            hasOnlyWhitespaceTextOutsideElements(item)
        else {
            throw SignedAppcastPolicyViolation.invalidItemStructure
        }

        let elements = childElements(of: item)
        let permitted = Set([
            ElementName(localName: "title"),
            ElementName(localName: "pubDate"),
            ElementName(localName: "version", namespace: sparkleNamespace),
            ElementName(localName: "shortVersionString", namespace: sparkleNamespace),
            ElementName(localName: "minimumSystemVersion", namespace: sparkleNamespace),
            ElementName(localName: "hardwareRequirements", namespace: sparkleNamespace),
            ElementName(localName: "description"),
            ElementName(localName: "enclosure")
        ])
        guard elements.allSatisfy({ permitted.contains(elementName($0)) }) else {
            throw SignedAppcastPolicyViolation.invalidItemStructure
        }
        try validateOptionalLeaf(
            localName: "title",
            namespace: nil,
            in: elements
        )
        try validateOptionalLeaf(
            localName: "pubDate",
            namespace: nil,
            in: elements
        )
        try validateOptionalLeaf(
            localName: "minimumSystemVersion",
            namespace: sparkleNamespace,
            in: elements
        )
        try validateOptionalLeaf(
            localName: "hardwareRequirements",
            namespace: sparkleNamespace,
            in: elements
        )

        let buildVersion: String
        let displayVersion: String
        do {
            buildVersion = try uniqueText(
                localName: "version",
                namespace: sparkleNamespace,
                in: elements
            )
            displayVersion = try uniqueText(
                localName: "shortVersionString",
                namespace: sparkleNamespace,
                in: elements
            )
        } catch {
            throw SignedAppcastPolicyViolation.invalidVersionIdentity
        }
        guard UpdateEndpointPolicy.hasCanonicalVersionIdentity(
            displayVersion: displayVersion,
            buildVersion: buildVersion
        ) else {
            throw SignedAppcastPolicyViolation.invalidVersionIdentity
        }

        try validateDescription(in: elements)
        try validateEnclosure(
            in: elements,
            displayVersion: displayVersion,
            buildVersion: buildVersion
        )
        return VersionIdentity(
            displayVersion: displayVersion,
            buildVersion: buildVersion
        )
    }

    private static func validateDescription(in elements: [XMLElement]) throws {
        let descriptions = matchingElements(
            localName: "description",
            namespace: nil,
            in: elements
        )
        guard
            descriptions.count == 1,
            let description = descriptions.first,
            childElements(of: description).isEmpty,
            hasOnlyTextContent(description),
            hasOnlyAttributes(
                description,
                [AttributeName(localName: "format", namespace: sparkleNamespace)]
            ),
            attributeValue(
                description,
                localName: "format",
                namespace: sparkleNamespace
            ) == "markdown",
            let notes = description.stringValue,
            !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SignedAppcastPolicyViolation.invalidEmbeddedReleaseNotes
        }
        guard releaseNotesAreRestricted(notes) else {
            throw SignedAppcastPolicyViolation.forbiddenReleaseNotesContent
        }
    }

    private static func validateEnclosure(
        in elements: [XMLElement],
        displayVersion: String,
        buildVersion: String
    ) throws {
        let enclosures = matchingElements(
            localName: "enclosure",
            namespace: nil,
            in: elements
        )
        guard enclosures.count == 1, let enclosure = enclosures.first else {
            throw SignedAppcastPolicyViolation.invalidEnclosure
        }
        let requiredAttributes = Set([
            AttributeName(localName: "url"),
            AttributeName(localName: "length"),
            AttributeName(localName: "type"),
            AttributeName(localName: "edSignature", namespace: sparkleNamespace)
        ])
        let optionalAttributes = Set([
            AttributeName(localName: "installationType", namespace: sparkleNamespace)
        ])
        let actualAttributes = Set((enclosure.attributes ?? []).map(attributeName))
        guard
            childElements(of: enclosure).isEmpty,
            (enclosure.children ?? []).isEmpty,
            actualAttributes.isSuperset(of: requiredAttributes),
            actualAttributes.isSubset(of: requiredAttributes.union(optionalAttributes)),
            actualAttributes.count == (enclosure.attributes?.count ?? 0),
            let urlString = attributeValue(
                enclosure,
                localName: "url",
                namespace: nil
            ),
            let archiveURL = URL(string: urlString),
            UpdateEndpointPolicy.isOfficialReleaseArchiveURL(
                archiveURL,
                displayVersion: displayVersion,
                buildVersion: buildVersion
            ),
            let length = attributeValue(
                enclosure,
                localName: "length",
                namespace: nil
            ),
            isPositiveInteger(length),
            attributeValue(
                enclosure,
                localName: "type",
                namespace: nil
            ) == "application/octet-stream",
            let signature = attributeValue(
                enclosure,
                localName: "edSignature",
                namespace: sparkleNamespace
            ),
            isCanonicalEd25519Signature(signature)
        else {
            throw SignedAppcastPolicyViolation.invalidEnclosure
        }
        let installationType = attributeValue(
            enclosure,
            localName: "installationType",
            namespace: sparkleNamespace
        )
        guard installationType == nil || installationType == "application" else {
            throw SignedAppcastPolicyViolation.invalidEnclosure
        }
    }

    private static func validateOptionalLeaf(
        localName: String,
        namespace: String?,
        in elements: [XMLElement]
    ) throws {
        let matches = matchingElements(
            localName: localName,
            namespace: namespace,
            in: elements
        )
        guard
            matches.count <= 1,
            matches.allSatisfy({
                ($0.attributes?.isEmpty ?? true)
                    && childElements(of: $0).isEmpty
                    && hasOnlyTextContent($0)
                    && !($0.stringValue ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            })
        else {
            throw SignedAppcastPolicyViolation.invalidItemStructure
        }
    }

    private static func uniqueText(
        localName: String,
        namespace: String?,
        in elements: [XMLElement]
    ) throws -> String {
        let matches = matchingElements(
            localName: localName,
            namespace: namespace,
            in: elements
        )
        guard
            matches.count == 1,
            let element = matches.first,
            element.attributes?.isEmpty ?? true,
            childElements(of: element).isEmpty,
            hasOnlyTextContent(element),
            let value = element.stringValue
        else {
            throw SignedAppcastPolicyViolation.invalidItemStructure
        }
        return value
    }

    private static func releaseNotesAreRestricted(_ notes: String) -> Bool {
        if notes.contains(where: { "[]<>&@\\".contains($0) }) {
            return false
        }
        let patterns = [
            #"(?i)(^|[^A-Za-z0-9])[A-Za-z][A-Za-z0-9+.-]*:"#,
            #"://|//|(?i:www\.)"#,
            #"(?i)[A-Za-z][A-Za-z0-9-]*\.[A-Za-z][A-Za-z-]*"#,
            #"(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)|::|(?i:localhost)"#
        ]
        return !patterns.contains { pattern in
            notes.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func isPositiveInteger(_ value: String) -> Bool {
        guard let first = value.utf8.first, (49...57).contains(first) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { (48...57).contains($0) }
    }

    private static func isCanonicalEd25519Signature(_ value: String) -> Bool {
        guard
            let bytes = Data(base64Encoded: value),
            bytes.count == 64
        else { return false }
        return bytes.base64EncodedString() == value
    }

    private static func matchingElements(
        localName: String,
        namespace: String?,
        in elements: [XMLElement]
    ) -> [XMLElement] {
        elements.filter {
            hasName($0, localName: localName, namespace: namespace)
        }
    }

    private static func childElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    private static func hasOnlyWhitespaceTextOutsideElements(
        _ element: XMLElement
    ) -> Bool {
        (element.children ?? []).allSatisfy { node in
            switch node.kind {
            case .element, .comment:
                return true
            case .text:
                return (node.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            default:
                return false
            }
        }
    }

    private static func hasOnlyTextContent(_ element: XMLElement) -> Bool {
        let children = element.children ?? []
        return !children.isEmpty && children.allSatisfy { $0.kind == .text }
    }

    private static func hasOnlyDocumentCommentsWhitespaceAndRoot(
        _ document: XMLDocument,
        root: XMLElement
    ) -> Bool {
        var rootCount = 0
        for node in document.children ?? [] {
            switch node.kind {
            case .element:
                guard node === root else { return false }
                rootCount += 1
            case .comment:
                continue
            case .text:
                guard (node.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                else { return false }
            default:
                return false
            }
        }
        return rootCount == 1
    }

    private static func hasOnlyAttributes(
        _ element: XMLElement,
        _ expected: Set<AttributeName>
    ) -> Bool {
        let attributes = element.attributes ?? []
        let actual = Set(attributes.map(attributeName))
        return actual == expected && actual.count == attributes.count
    }

    private static func attributeValue(
        _ element: XMLElement,
        localName: String,
        namespace: String?
    ) -> String? {
        (element.attributes ?? []).first {
            attributeName($0) == AttributeName(
                localName: localName,
                namespace: namespace
            )
        }?.stringValue
    }

    private static func hasName(
        _ element: XMLElement,
        localName: String,
        namespace: String?
    ) -> Bool {
        elementName(element) == ElementName(
            localName: localName,
            namespace: namespace
        )
    }

    private static func elementName(_ element: XMLElement) -> ElementName {
        ElementName(
            localName: element.localName ?? element.name ?? "",
            namespace: normalizedNamespace(element.uri)
        )
    }

    private static func attributeName(_ attribute: XMLNode) -> AttributeName {
        AttributeName(
            localName: attribute.localName ?? attribute.name ?? "",
            namespace: normalizedNamespace(attribute.uri)
        )
    }

    private static func normalizedNamespace(_ namespace: String?) -> String? {
        guard let namespace, !namespace.isEmpty else { return nil }
        return namespace
    }

    private struct ElementName: Hashable {
        let localName: String
        let namespace: String?

        init(localName: String, namespace: String? = nil) {
            self.localName = localName
            self.namespace = namespace
        }
    }

    private struct AttributeName: Hashable {
        let localName: String
        let namespace: String?

        init(localName: String, namespace: String? = nil) {
            self.localName = localName
            self.namespace = namespace
        }
    }

    private struct VersionIdentity {
        let displayVersion: String
        let buildVersion: String
    }
}
