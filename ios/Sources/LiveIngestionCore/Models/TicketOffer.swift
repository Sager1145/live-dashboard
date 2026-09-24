import Foundation

/// Joins a round, a tier, and applicable performances with a concrete price.
public struct TicketOffer: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let roundID: String
    public let tierID: String
    public let performanceIDs: [String]
    public let priceJPY: Int?
    public let amount: MoneyAmount?

    public init(id: String, roundID: String, tierID: String, performanceIDs: [String], priceJPY: Int?, amount: MoneyAmount? = nil) {
        self.id = id
        self.roundID = roundID
        self.tierID = tierID
        self.performanceIDs = performanceIDs
        self.priceJPY = priceJPY
        self.amount = amount
    }
}
