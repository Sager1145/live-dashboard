import Foundation
import CryptoKit
import Security

/// RFC 7636 PKCE parameters for the ChatGPT OAuth authorization-code flow.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        verifier = Self.base64URLEncode(Self.randomBytes(count: 64))
        challenge = Self.challenge(for: verifier)
        state = Self.randomBytes(count: 32).map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the S256 code_challenge for a given verifier, per RFC 7636.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // Fall back to a non-cryptographic generator only if the secure
            // API is unavailable; this should not happen on iOS.
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return bytes
    }

    private static func base64URLEncode<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
