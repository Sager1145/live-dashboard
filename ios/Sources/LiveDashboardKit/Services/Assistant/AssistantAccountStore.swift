import Foundation
import LiveIngestionCore

/// Persists the assistant sign-in credential (API key or ChatGPT session) in
/// the Keychain.
public actor AssistantAccountStore {
    private static let account = "credential"

    private let secrets: any SecretStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(secrets: any SecretStore = KeychainStore()) {
        self.secrets = secrets
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> AssistantCredential? {
        guard let data = (try? secrets.read(Self.account)) ?? nil else { return nil }
        return try? decoder.decode(AssistantCredential.self, from: data)
    }

    public func save(_ credential: AssistantCredential) throws {
        let data = try encoder.encode(credential)
        try secrets.write(data, account: Self.account)
    }

    public func clear() throws {
        try secrets.delete(Self.account)
    }
}
