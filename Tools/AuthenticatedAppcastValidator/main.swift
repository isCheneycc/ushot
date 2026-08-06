import Darwin
import Foundation
#if canImport(UshotCore)
import UshotCore
#endif

@main
private enum AuthenticatedAppcastValidator {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fail(
                "usage: AuthenticatedAppcastValidator VERIFIED_SIGNED_APPCAST_PATH",
                status: EX_USAGE
            )
        }

        do {
            let data = try Data(
                contentsOf: URL(
                    fileURLWithPath: CommandLine.arguments[1],
                    isDirectory: false
                ),
                options: [.mappedIfSafe]
            )
            let authenticatedXML = try SignedAppcastEnvelope.authenticatedXML(
                fromVerifiedSignedFeed: data
            )
            try SignedAppcastPolicy.validate(
                authenticatedXML: authenticatedXML
            )
        } catch let violation as SignedAppcastEnvelopeViolation {
            fail(
                "verified signed appcast envelope violates Ushot policy: \(violation.rawValue)",
                status: EX_DATAERR
            )
        } catch let violation as SignedAppcastPolicyViolation {
            fail(
                "authenticated appcast violates Ushot runtime policy: \(violation.rawValue)",
                status: EX_DATAERR
            )
        } catch {
            let nsError = error as NSError
            fail(
                "authenticated appcast validation failed: \(nsError.domain)/\(nsError.code)",
                status: EX_IOERR
            )
        }
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        Darwin.exit(status)
    }
}
