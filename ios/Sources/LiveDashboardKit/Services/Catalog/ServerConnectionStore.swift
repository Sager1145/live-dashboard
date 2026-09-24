import Foundation
import Observation

@MainActor @Observable
public final class ServerConnectionStore {
    public static let shared = ServerConnectionStore()

    public var baseURLString = ""
    public var serverInstanceID = ""
    public var displayName = ""
    public private(set) var validationMessage: String?

    private struct Payload: Codable {
        var baseURL: String
        var serverInstanceID: String
        var displayName: String
    }

    private struct SavedSnapshot {
        var baseURL: URL?
        var serverInstanceID: String
        var displayName: String
    }

    private var savedSnapshot = SavedSnapshot(baseURL: nil, serverInstanceID: "", displayName: "")

    public var savedBaseURL: URL? { savedSnapshot.baseURL }

    public init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        serverInstanceID = payload.serverInstanceID
        displayName = payload.displayName
        let trimmed = payload.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.decide(trimmed) {
        case .accept(let url):
            baseURLString = url.absoluteString
            savedSnapshot = SavedSnapshot(baseURL: url, serverInstanceID: payload.serverInstanceID, displayName: payload.displayName)
        case .disconnect:
            break
        case .reject:
            baseURLString = Self.editableText(for: trimmed)
        }
    }

    public func save() {
        baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        serverInstanceID = serverInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.decide(baseURLString) {
        case .disconnect:
            do {
                try Self.removeFile()
            } catch {
                validationMessage = String(localized: "无法保存服务器连接。", bundle: .kit)
                return
            }
            savedSnapshot = SavedSnapshot(baseURL: nil, serverInstanceID: "", displayName: "")
            validationMessage = nil
        case .reject(let message):
            validationMessage = message
        case .accept(let url):
            baseURLString = url.absoluteString
            let payload = Payload(baseURL: baseURLString, serverInstanceID: serverInstanceID, displayName: displayName)
            do {
                try Self.write(payload)
            } catch {
                validationMessage = String(localized: "无法保存服务器连接。", bundle: .kit)
                return
            }
            savedSnapshot = SavedSnapshot(baseURL: url, serverInstanceID: serverInstanceID, displayName: displayName)
            validationMessage = nil
        }
    }

    private enum Decision {
        case disconnect
        case accept(URL)
        case reject(String)
    }

    private static func decide(_ raw: String) -> Decision {
        if raw.isEmpty { return .disconnect }
        guard var components = URLComponents(string: raw) else {
            return .reject(String(localized: "服务器地址无效。", bundle: .kit))
        }
        guard components.scheme?.lowercased() == "https" else {
            return .reject(String(localized: "服务器地址必须使用 https。", bundle: .kit))
        }
        if components.user != nil || components.password != nil {
            return .reject(String(localized: "服务器地址不能包含用户名或密码。", bundle: .kit))
        }
        guard let host = components.host, host.isEmpty == false else {
            return .reject(String(localized: "服务器地址无效。", bundle: .kit))
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            return .reject(String(localized: "服务器地址无效。", bundle: .kit))
        }
        return .accept(url)
    }

    private static func editableText(for raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return "" }
        if components.user != nil || components.password != nil { return "" }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? ""
    }

    private static var fileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveDashboard", isDirectory: true)
        return root.appendingPathComponent("server-connection.json")
    }

    private static func write(_ payload: Payload) throws {
        let destination = Self.fileURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: destination, options: .atomic)
    }

    private static func removeFile() throws {
        do {
            try FileManager.default.removeItem(at: Self.fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
