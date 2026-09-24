import Foundation

public struct MoneyAmount: Codable, Hashable, Sendable {
    public let minorUnits: Int64
    public let currency: String

    public init(minorUnits: Int64, currency: String) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public var formatted: String {
        let exponent: Int
        if Self.zeroDecimalCurrencies.contains(currency) { exponent = 0 }
        else if Self.threeDecimalCurrencies.contains(currency) { exponent = 3 }
        else if Self.fourDecimalCurrencies.contains(currency) { exponent = 4 }
        else { exponent = 2 }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = exponent
        formatter.maximumFractionDigits = exponent
        let divisor = Decimal(pow(10.0, Double(exponent)))
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minorUnits) / divisor))
            ?? "\(currency) \(minorUnits)"
    }

    private static let zeroDecimalCurrencies: Set<String> = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"]
    private static let threeDecimalCurrencies: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
    private static let fourDecimalCurrencies: Set<String> = ["CLF", "UYW"]
}

public struct Edition: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let name: String
    public let order: Int

    public init(id: String, eventID: String, name: String, order: Int) {
        self.id = id
        self.eventID = eventID
        self.name = name
        self.order = order
    }
}

public struct StreamOffer: Codable, Hashable, Identifiable, Sendable, ScopedRecord {
    public let id: String
    public let eventID: String
    public let platform: String
    public let officialName: String
    public let scope: Scope
    public let amount: MoneyAmount?
    public let salesStartAt: Date?
    public let salesEndAt: Date?
    public let archiveAvailableUntil: Date?
    public let regionNote: String?
    public let url: String?
    public let status: DataStatus

    public init(id: String, eventID: String, platform: String, officialName: String, scope: Scope, amount: MoneyAmount?, salesStartAt: Date?, salesEndAt: Date?, archiveAvailableUntil: Date?, regionNote: String?, url: String?, status: DataStatus) {
        self.id = id
        self.eventID = eventID
        self.platform = platform
        self.officialName = officialName
        self.scope = scope
        self.amount = amount
        self.salesStartAt = salesStartAt
        self.salesEndAt = salesEndAt
        self.archiveAvailableUntil = archiveAvailableUntil
        self.regionNote = regionNote
        self.url = url
        self.status = status
    }

    public func replacingSalesDates(
        salesStartAt: Date?,
        salesEndAt: Date?,
        archiveAvailableUntil: Date?
    ) -> StreamOffer {
        StreamOffer(
            id: id,
            eventID: eventID,
            platform: platform,
            officialName: officialName,
            scope: scope,
            amount: amount,
            salesStartAt: salesStartAt,
            salesEndAt: salesEndAt,
            archiveAvailableUntil: archiveAvailableUntil,
            regionNote: regionNote,
            url: url,
            status: status
        )
    }
}

public struct ProductVariant: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let amount: MoneyAmount?
    public let stockStatus: String?

    public init(id: String, name: String, amount: MoneyAmount?, stockStatus: String?) {
        self.id = id
        self.name = name
        self.amount = amount
        self.stockStatus = stockStatus
    }
}

public struct Product: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let campaignID: String
    public let name: String
    public let amount: MoneyAmount?
    public let url: String?
    public let variants: [ProductVariant]
    public let purchaseLimit: String?

    public init(id: String, eventID: String, campaignID: String, name: String, amount: MoneyAmount?, url: String?, variants: [ProductVariant], purchaseLimit: String?) {
        self.id = id
        self.eventID = eventID
        self.campaignID = campaignID
        self.name = name
        self.amount = amount
        self.url = url
        self.variants = variants
        self.purchaseLimit = purchaseLimit
    }
}

public struct GoodsSession: Codable, Hashable, Identifiable, Sendable, ScopedRecord {
    public let id: String
    public let eventID: String
    public let campaignID: String
    public let scope: Scope
    public let startsAt: Date?
    public let endsAt: Date?
    public let location: String

    public init(id: String, eventID: String, campaignID: String, scope: Scope, startsAt: Date?, endsAt: Date?, location: String) {
        self.id = id
        self.eventID = eventID
        self.campaignID = campaignID
        self.scope = scope
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
    }
}

public enum SourceHealthState: String, Hashable, Sendable, LossyStringEnum {
    case healthy, stale, blocked
    case fetchFailed = "fetch_failed"
    case parseFailed = "parse_failed"
    public static let fallback: SourceHealthState = .stale
}

public struct EventChangeHistory: Codable, Hashable, Identifiable, Sendable {
    public let revision: Int
    public let reason: String
    public let publishedAt: Date
    public var id: Int { revision }
    public var title: String { reason }
    public var body: String? { nil }
    public var evidenceIDs: [String] { [] }
}
