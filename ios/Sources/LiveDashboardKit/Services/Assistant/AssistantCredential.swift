import Foundation
import LiveIngestionCore

/// A ChatGPT OAuth session, as obtained through `ChatGPTOAuthClient`.
public struct ChatGPTSession: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date?
    public var accountID: String?
    public var email: String?
    /// An OpenAI API key obtained through token exchange. When present it is
    /// the preferred transport, since it talks to the public Responses API
    /// instead of the ChatGPT backend.
    public var apiKey: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        expiresAt: Date? = nil,
        accountID: String? = nil,
        email: String? = nil,
        apiKey: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.email = email
        self.apiKey = apiKey
    }
}

/// The credential the user signed in with, persisted in the Keychain.
public enum AssistantCredential: Codable, Hashable, Sendable {
    case apiKey(String)
    case chatGPT(ChatGPTSession)

    public var accountState: AssistantAccountState {
        switch self {
        case .apiKey(let key):
            return .apiKey(hint: Self.maskedHint(for: key))
        case .chatGPT(let session):
            return .chatGPT(email: session.email, accountID: session.accountID)
        }
    }

    private static func maskedHint(for key: String) -> String {
        let suffix = key.count >= 4 ? String(key.suffix(4)) : key
        return "sk-…\(suffix)"
    }

    private enum CodingKeys: String, CodingKey {
        case type, apiKey, chatGPT
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "apiKey":
            self = .apiKey(try container.decode(String.self, forKey: .apiKey))
        case "chatGPT":
            self = .chatGPT(try container.decode(ChatGPTSession.self, forKey: .chatGPT))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown credential type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .apiKey(let key):
            try container.encode("apiKey", forKey: .type)
            try container.encode(key, forKey: .apiKey)
        case .chatGPT(let session):
            try container.encode("chatGPT", forKey: .type)
            try container.encode(session, forKey: .chatGPT)
        }
    }
}
