import Foundation
import LiveIngestionCore

public struct LLerPerformance: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var eventID: String?
    public var concertID: String?
    public var tourName: String
    public var date: String?
    public var venueName: String?
    public var venueID: String?
    public var seriesIDs: [String]
    /// Source status text. It does not replace an official cancellation.
    public var status: String?
    public var hasSetlist: Bool
    public var performanceName: String?
    public var concertName: String?
    public var openTime: String?
    public var startTime: String?
    public var tourType: String?
    /// Nil means the snapshot did not say, which is not an explicit "not canceled".
    public var canceled: Bool?
    public var note: String?
    /// Nil or an unrecognized value stays unknown. It is not rewritten to live.
    public var category: String?

    public var identity: ExternalIdentity { ExternalIdentity(namespace: .llfans, entity: .performance, rawID: id) }
}

public struct LLerVenue: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var source: String?
    public var sourceID: String?
    public var confidence: Double?
    public var reviewRequired: Bool?
    public var address: String?
    public var latitude: Double?
    public var longitude: Double?
    public var country: String?
    public var region: String?
    public var locality: String?
    public var website: String?
}

public struct LLerSetlistItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var position: Int
    public var songID: String?
    public var customSongName: String?
    public var isCustomSong: Bool?
    public var title: String?
    public var remarks: String?
}

public struct LLerSetlistSection: Codable, Hashable, Sendable {
    public var name: String
    public var startIndex: Int
    public var endIndex: Int
    public var type: String
}

public struct LLerSetlist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var performanceID: String
    public var items: [LLerSetlistItem]
    public var sections: [LLerSetlistSection]
    public var isActual: Bool
}

public struct LLerSong: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var seriesIDs: [String]
}

public struct LLerNoteCatalog: Codable, Hashable, Sendable {
    public var revision: String
    public var performances: [LLerPerformance]
    public var venues: [LLerVenue]
    /// LLFans performance id to Eventernote event id. Duplicate targets stay in `eventernoteTargets`.
    public var eventernoteByPerformance: [String: String]
    public var eventernoteTargets: [String: [String]]
    public var setlists: [LLerSetlist]
    public var songs: [LLerSong]

    public func venue(id: String?) -> LLerVenue? { id.flatMap { venueID in venues.first { $0.id == venueID } } }
    public func setlist(performanceID: String) -> LLerSetlist? { setlists.first { $0.performanceID == performanceID } }
}
