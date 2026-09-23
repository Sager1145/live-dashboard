import Foundation

public enum TicketRoundKind: String, Hashable, Sendable, LossyStringEnum {
    case lottery
    case firstComeFirstServed
    case resale
    case upgrade
    case other
    public static let fallback: TicketRoundKind = .other
}

public struct TicketRound: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let officialName: String
    public let kind: TicketRoundKind
    public let scope: Scope
    public let applyStartAt: Date?
    public let applyEndAt: Date?
    public let resultAt: Date?
    public let paymentDeadlineAt: Date?
    public let eligibility: String?
    public let announcementURL: String?
    public let applyURL: String?
    public let overseasURL: String?
    public let officialStatus: String?
    public let status: DataStatus
    public let links: [OfficialLink]
    public let applyWindowText: String?
    public let resultText: String?
    public let paymentStartAt: Date?
    public let paymentWindowText: String?
    public let quantityLimit: String?
    public let lotteryProducts: [String]
    public let applicationTarget: String?
    public let notes: [TicketNote]

    public init(
        id: String,
        eventID: String,
        officialName: String,
        kind: TicketRoundKind,
        scope: Scope,
        applyStartAt: Date?,
        applyEndAt: Date?,
        resultAt: Date?,
        paymentDeadlineAt: Date?,
        eligibility: String?,
        announcementURL: String?,
        applyURL: String?,
        overseasURL: String?,
        officialStatus: String?,
        status: DataStatus,
        links: [OfficialLink] = [],
        applyWindowText: String? = nil,
        resultText: String? = nil,
        paymentStartAt: Date? = nil,
        paymentWindowText: String? = nil,
        quantityLimit: String? = nil,
        lotteryProducts: [String] = [],
        applicationTarget: String? = nil,
        notes: [TicketNote] = []
    ) {
        self.id = id
        self.eventID = eventID
        self.officialName = officialName
        self.kind = kind
        self.scope = scope
        self.applyStartAt = applyStartAt
        self.applyEndAt = applyEndAt
        self.resultAt = resultAt
        self.paymentDeadlineAt = paymentDeadlineAt
        self.eligibility = eligibility
        self.announcementURL = announcementURL
        self.applyURL = applyURL
        self.overseasURL = overseasURL
        self.officialStatus = officialStatus
        self.status = status
        self.links = links
        self.applyWindowText = applyWindowText
        self.resultText = resultText
        self.paymentStartAt = paymentStartAt
        self.paymentWindowText = paymentWindowText
        self.quantityLimit = quantityLimit
        self.lotteryProducts = lotteryProducts
        self.applicationTarget = applicationTarget
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventID, officialName, kind, scope, applyStartAt, applyEndAt, resultAt
        case paymentDeadlineAt, eligibility, announcementURL, applyURL, overseasURL
        case officialStatus, status, links
        case applyWindowText, resultText, paymentStartAt, paymentWindowText, quantityLimit
        case lotteryProducts, applicationTarget, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = try c.decode(String.self, forKey: .eventID)
        officialName = try c.decode(String.self, forKey: .officialName)
        kind = try c.decode(TicketRoundKind.self, forKey: .kind)
        scope = try c.decode(Scope.self, forKey: .scope)
        applyStartAt = try c.decodeIfPresent(Date.self, forKey: .applyStartAt)
        applyEndAt = try c.decodeIfPresent(Date.self, forKey: .applyEndAt)
        resultAt = try c.decodeIfPresent(Date.self, forKey: .resultAt)
        paymentDeadlineAt = try c.decodeIfPresent(Date.self, forKey: .paymentDeadlineAt)
        eligibility = try c.decodeIfPresent(String.self, forKey: .eligibility)
        announcementURL = try c.decodeIfPresent(String.self, forKey: .announcementURL)
        applyURL = try c.decodeIfPresent(String.self, forKey: .applyURL)
        overseasURL = try c.decodeIfPresent(String.self, forKey: .overseasURL)
        officialStatus = try c.decodeIfPresent(String.self, forKey: .officialStatus)
        status = try c.decode(DataStatus.self, forKey: .status)
        links = try c.decodeIfPresent([OfficialLink].self, forKey: .links) ?? []
        applyWindowText = try c.decodeIfPresent(String.self, forKey: .applyWindowText)
        resultText = try c.decodeIfPresent(String.self, forKey: .resultText)
        paymentStartAt = try c.decodeIfPresent(Date.self, forKey: .paymentStartAt)
        paymentWindowText = try c.decodeIfPresent(String.self, forKey: .paymentWindowText)
        quantityLimit = try c.decodeIfPresent(String.self, forKey: .quantityLimit)
        lotteryProducts = try c.decodeIfPresent([String].self, forKey: .lotteryProducts) ?? []
        applicationTarget = try c.decodeIfPresent(String.self, forKey: .applicationTarget)
        notes = try c.decodeIfPresent([TicketNote].self, forKey: .notes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(officialName, forKey: .officialName)
        try c.encode(kind, forKey: .kind)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(applyStartAt, forKey: .applyStartAt)
        try c.encodeIfPresent(applyEndAt, forKey: .applyEndAt)
        try c.encodeIfPresent(resultAt, forKey: .resultAt)
        try c.encodeIfPresent(paymentDeadlineAt, forKey: .paymentDeadlineAt)
        try c.encodeIfPresent(eligibility, forKey: .eligibility)
        try c.encodeIfPresent(announcementURL, forKey: .announcementURL)
        try c.encodeIfPresent(applyURL, forKey: .applyURL)
        try c.encodeIfPresent(overseasURL, forKey: .overseasURL)
        try c.encodeIfPresent(officialStatus, forKey: .officialStatus)
        try c.encode(status, forKey: .status)
        try c.encode(links, forKey: .links)
        try c.encodeIfPresent(applyWindowText, forKey: .applyWindowText)
        try c.encodeIfPresent(resultText, forKey: .resultText)
        try c.encodeIfPresent(paymentStartAt, forKey: .paymentStartAt)
        try c.encodeIfPresent(paymentWindowText, forKey: .paymentWindowText)
        try c.encodeIfPresent(quantityLimit, forKey: .quantityLimit)
        try c.encode(lotteryProducts, forKey: .lotteryProducts)
        try c.encodeIfPresent(applicationTarget, forKey: .applicationTarget)
        try c.encode(notes, forKey: .notes)
    }
}
