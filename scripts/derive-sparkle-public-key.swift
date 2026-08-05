#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

enum KeyDerivationError: Error {
    case unreadableUTF8
    case nonCanonicalBase64
    case invalidSeedLength
    case keyConstructionFailed

    var message: String {
        switch self {
        case .unreadableUTF8:
            return "Sparkle private key seed must be UTF-8 encoded canonical base64."
        case .nonCanonicalBase64:
            return "Sparkle private key seed must be canonical base64 without whitespace."
        case .invalidSeedLength:
            return "Sparkle private key seed must decode to exactly 32 bytes."
        case .keyConstructionFailed:
            return "Sparkle private key seed could not construct an Ed25519 signing key."
        }
    }
}

func derivePublicKey() throws -> String {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    guard let encodedSeed = String(data: inputData, encoding: .utf8) else {
        throw KeyDerivationError.unreadableUTF8
    }
    guard
        let seed = Data(base64Encoded: encodedSeed),
        seed.base64EncodedString() == encodedSeed
    else {
        throw KeyDerivationError.nonCanonicalBase64
    }
    guard seed.count == 32 else {
        throw KeyDerivationError.invalidSeedLength
    }

    do {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return privateKey.publicKey.rawRepresentation.base64EncodedString()
    } catch {
        throw KeyDerivationError.keyConstructionFailed
    }
}

do {
    print(try derivePublicKey())
} catch let error as KeyDerivationError {
    FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
} catch {
    FileHandle.standardError.write(Data("error: Sparkle public-key derivation failed.\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
