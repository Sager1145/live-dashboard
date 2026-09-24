import Foundation

public enum TicketPriceKind: String, Hashable, Sendable, LossyStringEnum {
    case full
    case upgradeDifference
    case streaming
    case under20
    case other
    public static let fallback: TicketPriceKind = .other
}

public struct TicketTier: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let name: String
    public let priceJPY: Int?
    public let amount: MoneyAmount?
    public let priceKind: TicketPriceKind
    public let includes: String?
    public let feeNote: String?
    public let taxNote: String?

    public init(
        id: String,
        eventID: String,
        name: String,
        priceJPY: Int?,
        priceKind: TicketPriceKind,
        amount: MoneyAmount? = nil,
        includes: String?,
        feeNote: String?,
        taxNote: String?
    ) {
        self.id = id
        self.eventID = eventID
        self.name = name
        self.priceJPY = priceJPY
        self.amount = amount
        self.priceKind = priceKind
        self.includes = includes
        self.feeNote = feeNote
        self.taxNote = taxNote
    }
}
