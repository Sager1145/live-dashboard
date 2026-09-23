import Foundation

/// Official bonus goods bundled with specific ticket tiers
/// (e.g. BanG Dream "グッズ付きチケット特典"). `status == .officiallyTBA`
/// means the official page explicitly says the contents are announced later;
/// a missing record means the page said nothing at all.
public struct TicketBenefit: Codable, Hashable, Identifiable, Sendable, ScopedRecord {
    public let id: String
    public let eventID: String
    public let officialName: String
    public let scope: Scope
    /// Ticket tiers whose name marks them as goods-bundled.
    public let tierIDs: [String]
    /// The bonus contents as printed (nil while officially TBA).
    public let detail: String?
    /// Remarks printed under the contents (※ lines, or the official TBA sentence).
    public let notes: String?
    public let redemptionLocation: String?
    public let redemptionWindow: String?
    public let redemptionNote: String?
    public let mediaAssetIDs: [String]
    public let status: DataStatus
    public let links: [OfficialLink]

    public init(
        id: String,
        eventID: String,
        officialName: String,
        scope: Scope,
        tierIDs: [String] = [],
        detail: String?,
        notes: String? = nil,
        redemptionLocation: String? = nil,
        redemptionWindow: String? = nil,
        redemptionNote: String? = nil,
        mediaAssetIDs: [String] = [],
        status: DataStatus,
        links: [OfficialLink] = []
    ) {
        self.id = id
        self.eventID = eventID
        self.officialName = officialName
        self.scope = scope
        self.tierIDs = tierIDs
        self.detail = detail
        self.notes = notes
        self.redemptionLocation = redemptionLocation
        self.redemptionWindow = redemptionWindow
        self.redemptionNote = redemptionNote
        self.mediaAssetIDs = mediaAssetIDs
        self.status = status
        self.links = links
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventID, officialName, scope, tierIDs, detail, notes
        case redemptionLocation, redemptionWindow, redemptionNote, mediaAssetIDs, status, links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = try c.decode(String.self, forKey: .eventID)
        officialName = try c.decode(String.self, forKey: .officialName)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .unconfirmed
        tierIDs = try c.decodeIfPresent([String].self, forKey: .tierIDs) ?? []
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        redemptionLocation = try c.decodeIfPresent(String.self, forKey: .redemptionLocation)
        redemptionWindow = try c.decodeIfPresent(String.self, forKey: .redemptionWindow)
        redemptionNote = try c.decodeIfPresent(String.self, forKey: .redemptionNote)
        mediaAssetIDs = try c.decodeIfPresent([String].self, forKey: .mediaAssetIDs) ?? []
        status = try c.decodeIfPresent(DataStatus.self, forKey: .status) ?? .needsReview
        links = try c.decodeIfPresent([OfficialLink].self, forKey: .links) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(officialName, forKey: .officialName)
        try c.encode(scope, forKey: .scope)
        try c.encode(tierIDs, forKey: .tierIDs)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(redemptionLocation, forKey: .redemptionLocation)
        try c.encodeIfPresent(redemptionWindow, forKey: .redemptionWindow)
        try c.encodeIfPresent(redemptionNote, forKey: .redemptionNote)
        try c.encode(mediaAssetIDs, forKey: .mediaAssetIDs)
        try c.encode(status, forKey: .status)
        try c.encode(links, forKey: .links)
    }
}
