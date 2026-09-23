import Foundation

/// Important-notice categories a ticket round page may call out (顔認証,
/// 同行者登録, 本人確認, etc). Only emitted when the official page explicitly
/// says so; `other` is the fallback for unrecognised raw values decoded from
/// an older or newer payload.
public enum TicketNoteKind: String, Hashable, Sendable, LossyStringEnum {
    case faceRecognition
    case companionRegistration
    case identityCheck
    case smartTicketOnly
    case creditCardOnly
    case membershipRequired
    case other
    public static let fallback: TicketNoteKind = .other
}

/// A verbatim important-notice sentence captured from a ticket round, with
/// any guide/procedure links found in the same block.
public struct TicketNote: Codable, Hashable, Identifiable, Sendable {
    public let kind: TicketNoteKind
    public let text: String
    public let links: [OfficialLink]

    public init(kind: TicketNoteKind, text: String, links: [OfficialLink] = []) {
        self.kind = kind
        self.text = text
        self.links = links
    }

    public var id: String { "\(kind.rawValue)::\(text)" }
}
