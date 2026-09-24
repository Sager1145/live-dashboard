import Foundation

/// Applicability range of a record, per API_CONTRACT.md.
/// "没有写 Day2" must never silently become `.wholeEvent`; parsers that cannot
/// determine applicability must emit `.unconfirmed`.
public enum Scope: Hashable, Sendable {
    case wholeEvent
    case stop(stopID: String)
    case performances(performanceIDs: [String])
    case unconfirmed
}

extension Scope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case stopID
        case performanceIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "wholeEvent", "all_event":
            // v2 responses materialize the exact performances covered by an
            // event-wide fact. Converting that wire shape to the explicit
            // case prevents a later-added performance from inheriting it.
            if let ids = try container.decodeIfPresent([String].self, forKey: .performanceIDs), !ids.isEmpty {
                self = .performances(performanceIDs: ids)
            } else {
                self = .unconfirmed
            }
        case "stop":
            if let ids = try container.decodeIfPresent([String].self, forKey: .performanceIDs), !ids.isEmpty {
                self = .performances(performanceIDs: ids)
            } else {
                self = .unconfirmed
            }
        case "performances", "performance_ids":
            let performanceIDs = try container.decode([String].self, forKey: .performanceIDs)
            self = performanceIDs.isEmpty ? .unconfirmed : .performances(performanceIDs: performanceIDs)
        case "unconfirmed":
            self = .unconfirmed
        default:
            self = .unconfirmed
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .wholeEvent:
            try container.encode("wholeEvent", forKey: .kind)
        case .stop(let stopID):
            try container.encode("stop", forKey: .kind)
            try container.encode(stopID, forKey: .stopID)
        case .performances(let performanceIDs):
            try container.encode("performances", forKey: .kind)
            try container.encode(performanceIDs, forKey: .performanceIDs)
        case .unconfirmed:
            try container.encode("unconfirmed", forKey: .kind)
        }
    }
}
