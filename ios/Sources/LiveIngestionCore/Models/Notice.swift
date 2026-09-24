import Foundation

public enum NoticeKind: String, Hashable, Sendable, LossyStringEnum {
    case change
    case cancellation
    case postponement
    case refund
    case other
    public static let fallback: NoticeKind = .other
}

public struct Notice: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let kind: NoticeKind
    public let title: String
    public let body: String
    public let publishedAt: Date?
    public let sourceURL: String
    public let scope: Scope

    public init(
        id: String,
        eventID: String,
        kind: NoticeKind,
        title: String,
        body: String,
        publishedAt: Date?,
        sourceURL: String,
        scope: Scope
    ) {
        self.id = id
        self.eventID = eventID
        self.kind = kind
        self.title = title
        self.body = body
        self.publishedAt = publishedAt
        self.sourceURL = sourceURL
        self.scope = scope
    }
}
