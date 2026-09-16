import AppKit
import CoreText
import Foundation

public enum AnnotationFontRegistrationError: Error, LocalizedError {
    case missingResource(String)
    case invalidResource(String)
    case registrationFailed(String, underlying: Error?)
    case sourceMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "The bundled annotation font '\(name)' is missing."
        case .invalidResource(let name):
            return "The bundled annotation font '\(name)' is invalid."
        case .registrationFailed(let name, let underlying):
            let detail = underlying.map { " \($0.localizedDescription)" } ?? ""
            return "The bundled annotation font '\(name)' could not be registered.\(detail)"
        case .sourceMismatch(let name):
            return "The annotation font '\(name)' did not resolve to its bundled source."
        }
    }
}

/// Offline annotation fonts, registered only for Ushot's process. Resolve from
/// their bundled descriptors so an installed font with the same name cannot
/// change persisted glyph fingerprints or the handwritten Chinese fallback.
public enum AnnotationFonts {
    public static let handwrittenFontName = "Excalifont-Regular"
    public static let handwrittenFallbackFontName = "XiaolaiSC"

    /// Registration is lazy and initialized once by Swift, including when
    /// UshotCore is used without the application startup path.
    private static let registeredFonts: Result<RegisteredFonts, Error> = Result {
        let primary = try RegisteredFont(
            name: handwrittenFontName,
            resourceName: "Excalifont-Regular"
        )
        let fallback = try RegisteredFont(
            name: handwrittenFallbackFontName,
            resourceName: "Xiaolai-Regular"
        )
        AppLog.lifecycle.notice(
            "Registered bundled annotation fonts: primary=\(handwrittenFontName, privacy: .public), fallback=\(handwrittenFallbackFontName, privacy: .public), scope=process"
        )
        return RegisteredFonts(primary: primary, fallback: fallback)
    }

    public static func register() throws {
        _ = try registeredFonts.get()
    }

    static func resolvedHandwrittenFont(size: CGFloat) throws -> NSFont {
        let fonts = try registeredFonts.get()
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            fonts.primary.descriptor,
            [kCTFontCascadeListAttribute: [fonts.fallback.descriptor]] as CFDictionary
        )
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        try fonts.primary.validateSource(of: font)
        return font as NSFont
    }

    static func resolvedHandwrittenFallbackFont(size: CGFloat) throws -> NSFont {
        let fallback = try registeredFonts.get().fallback
        let font = CTFontCreateWithFontDescriptor(fallback.descriptor, size, nil)
        try fallback.validateSource(of: font)
        return font as NSFont
    }

    private struct RegisteredFonts {
        let primary: RegisteredFont
        let fallback: RegisteredFont
    }

    private struct RegisteredFont {
        let name: String
        let url: URL
        let descriptor: CTFontDescriptor

        init(name: String, resourceName: String) throws {
            guard let url = Bundle.module.url(
                forResource: resourceName,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) else {
                throw AnnotationFontRegistrationError.missingResource(name)
            }
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
                url as CFURL
            ) as? [CTFontDescriptor],
                  descriptors.count == 1,
                  let descriptor = descriptors.first,
                  CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String == name
            else {
                throw AnnotationFontRegistrationError.invalidResource(name)
            }
            self.name = name
            self.url = url.standardizedFileURL.resolvingSymlinksInPath()
            self.descriptor = descriptor

            var registrationError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &registrationError
            )
            if !registered {
                let error = registrationError?.takeRetainedValue()
                // Another Core client may have registered this exact resource.
                // Source validation below is still required before accepting it.
                guard let error,
                      CFErrorGetDomain(error) == kCTFontManagerErrorDomain,
                      CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
                else {
                    throw AnnotationFontRegistrationError.registrationFailed(
                        name,
                        underlying: error
                    )
                }
            }
            try validateSource(of: CTFontCreateWithFontDescriptor(descriptor, 18, nil))
        }

        func validateSource(of font: CTFont) throws {
            guard CTFontCopyPostScriptName(font) as String == name,
                  let source = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
                  source.standardizedFileURL.resolvingSymlinksInPath() == url
            else {
                throw AnnotationFontRegistrationError.sourceMismatch(name)
            }
        }
    }
}
