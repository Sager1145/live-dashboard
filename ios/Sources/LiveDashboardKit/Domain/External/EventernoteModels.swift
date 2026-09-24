import Foundation
import LiveIngestionCore

public struct EventernoteEntityLink: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: String

    public init(id: String, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }

    public var identity: ExternalIdentity {
        ExternalIdentity(namespace: .eventernote, entity: url.contains("/places/") ? .venue : url.contains("/actors/") ? .actor : .event, rawID: id)
    }
}

public struct EventernoteEventSummary: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var date: String?
    public var weekday: String?
    public var openTime: String?
    public var startTime: String?
    public var endTime: String?
    public var place: EventernoteEntityLink?
    public var actors: [EventernoteEntityLink]
    public var imageURL: String?
    public var url: String
    /// Computed by the client from the date text. It is not an official status.
    public var isPast: Bool
    public var noteCount: Int?

    public init(id: String, name: String, date: String?, weekday: String?, openTime: String?, startTime: String?, endTime: String?, place: EventernoteEntityLink?, actors: [EventernoteEntityLink], imageURL: String?, url: String, isPast: Bool, noteCount: Int?) {
        self.id = id
        self.name = name
        self.date = date
        self.weekday = weekday
        self.openTime = openTime
        self.startTime = startTime
        self.endTime = endTime
        self.place = place
        self.actors = actors
        self.imageURL = imageURL
        self.url = url
        self.isPast = isPast
        self.noteCount = noteCount
    }
}

public struct EventernoteEventDetail: Codable, Hashable, Sendable {
    public var event: EventernoteEventSummary
    public var links: [String]
    public var hashtag: String?
    /// The current Eventernote detail parser does not provide a description body.
    public var description: String? = nil
    public var participantsCount: Int?
}

public struct EventernotePlaceSummary: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var prefectureID: String?
    public var address: String?
    public var postalCode: String?
    public var telephone: String?
    /// Venue capacity text. It is not this performance's ticket allotment.
    public var capacity: String?
    public var webURL: String?
    /// Generic venue seating material, not this performance's seating plan.
    public var seatURL: String?
    public var latitude: Double?
    public var longitude: Double?
    public var url: String

    public init(id: String, name: String, prefectureID: String? = nil, address: String? = nil, postalCode: String? = nil, telephone: String? = nil, capacity: String? = nil, webURL: String? = nil, seatURL: String? = nil, latitude: Double? = nil, longitude: Double? = nil, url: String) {
        self.id = id
        self.name = name
        self.prefectureID = prefectureID
        self.address = address
        self.postalCode = postalCode
        self.telephone = telephone
        self.capacity = capacity
        self.webURL = webURL
        self.seatURL = seatURL
        self.latitude = latitude
        self.longitude = longitude
        self.url = url
    }
}

public struct EventernoteActorSummary: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kana: String?
    public var url: String
}

public struct EventernoteListResult: Equatable, Sendable {
    public var matched: [EventernoteEventSummary]
    public var rawCount: Int
    public var page: Int
    public var reachedBudget: Bool
}

public enum EventernoteClientError: Error, Equatable {
    case parse
    case http(Int)
    case unsupportedFilter
    case budgetExhausted
    case ambiguous
}
