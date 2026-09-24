import Foundation
import Security
import UIKit
import LiveIngestionCore

public struct InstallationIdentity: Codable, Sendable {
    public let id: String
    public let credential: String
}

public struct InstallationSubscription: Codable, Hashable, Sendable {
    public let eventID: String
    public let performanceIDs: [String]
    public let changesEnabled: Bool
}

public struct ServerReminderRule: Codable, Hashable, Sendable {
    public let eventID: String
    public let performanceID: String
    public let recordID: String
    public let field: String
    public let leadSeconds: Int
    public let enabled: Bool
}

public enum InstallationServiceError: Error, LocalizedError, Sendable {
    case remoteServicesUnavailable

    public var errorDescription: String? {
        String(localized: "此版本仅使用本机资料与通知", bundle: .kit)
    }
}

public actor InstallationService {
    private let baseURL: URL?
    private let session: URLSession
    private let keychain: InstallationKeychain
    private var registrationTask: Task<InstallationIdentity, Error>?

    /// Local-only mode used by the standalone app. Compatibility methods that
    /// used to mirror local follow state to a server become harmless no-ops.
    public init() {
        self.baseURL = nil
        self.session = .shared
        self.keychain = InstallationKeychain(account: "local-only")
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.keychain = InstallationKeychain(account: Self.namespace(for: baseURL))
    }

    public func ensureRegistered() async throws -> InstallationIdentity {
        guard baseURL != nil else { throw InstallationServiceError.remoteServicesUnavailable }
        if let saved = keychain.load() { return saved }
        if let registrationTask { return try await registrationTask.value }
        let task = Task { try await self.registerFresh() }
        registrationTask = task
        do { let value = try await task.value; registrationTask = nil; return value }
        catch { registrationTask = nil; throw error }
    }

    public func updatePushToken(_ token: String, environment: String) async throws {
        guard baseURL != nil else { return }
        struct Body: Encodable { let token: String; let environment: String }
        let identity = try await ensureRegistered()
        let _: EmptyResponse = try await request(path: "v1/installations/\(identity.id)/push-token", method: "PUT", body: Body(token: token, environment: environment), identity: identity)
    }

    public func replaceSubscriptions(_ subscriptions: [InstallationSubscription]) async throws {
        guard baseURL != nil else { return }
        struct Body: Encodable { let subscriptions: [InstallationSubscription]; let clientVersion: String; let idempotencyKey: String }
        let identity = try await ensureRegistered()
        let body = Body(subscriptions: subscriptions, clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1", idempotencyKey: UUID().uuidString)
        let _: EmptyResponse = try await request(path: "v1/installations/\(identity.id)/subscriptions", method: "PUT", body: body, identity: identity)
    }

    public func replaceReminders(_ reminders: [ServerReminderRule]) async throws {
        guard baseURL != nil else { throw InstallationServiceError.remoteServicesUnavailable }
        struct Body: Encodable { let reminders: [ServerReminderRule] }
        let identity = try await ensureRegistered()
        let _: EmptyResponse = try await request(path: "v1/installations/\(identity.id)/reminders", method: "PUT", body: Body(reminders: reminders), identity: identity)
    }

    public func deleteInstallation() async throws {
        guard baseURL != nil else { keychain.delete(); return }
        guard let identity = keychain.load() else { return }
        let _: EmptyResponse = try await request(path: "v1/installations/\(identity.id)", method: "DELETE", body: EmptyBody(), identity: identity)
        keychain.delete()
    }

    public func registerForRemoteNotifications() async {
        guard baseURL != nil else { return }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    private func request<Response: Decodable, Body: Encodable>(path: String, method: String, body: Body, identity: InstallationIdentity?) async throws -> Response {
        guard let baseURL else { throw InstallationServiceError.remoteServicesUnavailable }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let identity { request.setValue("Bearer \(identity.credential)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(Response.self, from: data.isEmpty ? Data("{}".utf8) : data)
    }

    private func registerFresh() async throws -> InstallationIdentity {
        let identity: InstallationIdentity = try await request(path: "v1/installations", method: "POST", body: EmptyBody(), identity: nil)
        try keychain.save(identity)
        return identity
    }

    private static func namespace(for url: URL) -> String {
        let normalized = "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))\(url.path)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

private struct EmptyBody: Encodable {}
private struct EmptyResponse: Codable {}

private struct InstallationKeychain: Sendable {
    private let service = "app.live-dashboard.installation"
    private let account: String

    init(account: String) { self.account = account }

    func save(_ identity: InstallationIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        delete()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func load() -> InstallationIdentity? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(InstallationIdentity.self, from: data)
    }

    func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
