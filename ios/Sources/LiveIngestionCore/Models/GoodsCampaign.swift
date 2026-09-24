import Foundation

public enum GoodsChannel: String, Hashable, Sendable, LossyStringEnum {
    case online
    case venue
    case unknown
    public static let fallback: GoodsChannel = .unknown
}

public enum GoodsFulfillment: String, Hashable, Sendable, LossyStringEnum {
    case shipping
    case venuePickup
    case unknown
    public static let fallback: GoodsFulfillment = .unknown
}

public enum GoodsPhase: String, Hashable, Sendable, LossyStringEnum {
    case pre
    case during
    case post
    case unknown
    public static let fallback: GoodsPhase = .unknown
}

public struct GoodsCampaign: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let officialName: String
    public let channel: GoodsChannel
    public let fulfillment: GoodsFulfillment
    public let phase: GoodsPhase
    public let scope: Scope
    public let salesStartAt: Date?
    public let salesEndAt: Date?
    public let pickupWindow: String?
    public let shippingNote: String?
    public let location: String?
    public let requiresTicket: Bool?
    public let purchaseLimit: String?
    public let paymentMethods: String?
    public let url: String?
    public let mediaAssetIDs: [String]
    public let status: DataStatus
    public let links: [OfficialLink]

    public init(
        id: String,
        eventID: String,
        officialName: String,
        channel: GoodsChannel,
        fulfillment: GoodsFulfillment,
        phase: GoodsPhase,
        scope: Scope,
        salesStartAt: Date?,
        salesEndAt: Date?,
        pickupWindow: String?,
        shippingNote: String?,
        location: String?,
        requiresTicket: Bool?,
        purchaseLimit: String?,
        paymentMethods: String?,
        url: String?,
        mediaAssetIDs: [String],
        status: DataStatus,
        links: [OfficialLink] = []
    ) {
        self.id = id
        self.eventID = eventID
        self.officialName = officialName
        self.channel = channel
        self.fulfillment = fulfillment
        self.phase = phase
        self.scope = scope
        self.salesStartAt = salesStartAt
        self.salesEndAt = salesEndAt
        self.pickupWindow = pickupWindow
        self.shippingNote = shippingNote
        self.location = location
        self.requiresTicket = requiresTicket
        self.purchaseLimit = purchaseLimit
        self.paymentMethods = paymentMethods
        self.url = url
        self.mediaAssetIDs = mediaAssetIDs
        self.status = status
        self.links = links
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventID, officialName, channel, fulfillment, phase, scope
        case salesStartAt, salesEndAt, pickupWindow, shippingNote, location
        case requiresTicket, purchaseLimit, paymentMethods, url, mediaAssetIDs, status, links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = try c.decode(String.self, forKey: .eventID)
        officialName = try c.decode(String.self, forKey: .officialName)
        channel = try c.decode(GoodsChannel.self, forKey: .channel)
        fulfillment = try c.decode(GoodsFulfillment.self, forKey: .fulfillment)
        phase = try c.decode(GoodsPhase.self, forKey: .phase)
        scope = try c.decode(Scope.self, forKey: .scope)
        salesStartAt = try c.decodeIfPresent(Date.self, forKey: .salesStartAt)
        salesEndAt = try c.decodeIfPresent(Date.self, forKey: .salesEndAt)
        pickupWindow = try c.decodeIfPresent(String.self, forKey: .pickupWindow)
        shippingNote = try c.decodeIfPresent(String.self, forKey: .shippingNote)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        requiresTicket = try c.decodeIfPresent(Bool.self, forKey: .requiresTicket)
        purchaseLimit = try c.decodeIfPresent(String.self, forKey: .purchaseLimit)
        paymentMethods = try c.decodeIfPresent(String.self, forKey: .paymentMethods)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        mediaAssetIDs = try c.decode([String].self, forKey: .mediaAssetIDs)
        status = try c.decode(DataStatus.self, forKey: .status)
        links = try c.decodeIfPresent([OfficialLink].self, forKey: .links) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(officialName, forKey: .officialName)
        try c.encode(channel, forKey: .channel)
        try c.encode(fulfillment, forKey: .fulfillment)
        try c.encode(phase, forKey: .phase)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(salesStartAt, forKey: .salesStartAt)
        try c.encodeIfPresent(salesEndAt, forKey: .salesEndAt)
        try c.encodeIfPresent(pickupWindow, forKey: .pickupWindow)
        try c.encodeIfPresent(shippingNote, forKey: .shippingNote)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(requiresTicket, forKey: .requiresTicket)
        try c.encodeIfPresent(purchaseLimit, forKey: .purchaseLimit)
        try c.encodeIfPresent(paymentMethods, forKey: .paymentMethods)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(mediaAssetIDs, forKey: .mediaAssetIDs)
        try c.encode(status, forKey: .status)
        try c.encode(links, forKey: .links)
    }
}
