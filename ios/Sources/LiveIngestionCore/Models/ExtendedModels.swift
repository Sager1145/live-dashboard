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
}

public struct ProductVariant: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let amount: MoneyAmount?
    public let stockStatus: String?
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
}

public struct GoodsSession: Codable, Hashable, Identifiable, Sendable, ScopedRecord {
    public let id: String
    public let eventID: String
    public let campaignID: String
    public let scope: Scope
    public let startsAt: Date?
    public let endsAt: Date?
    public let location: String
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
