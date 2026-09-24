import Foundation

/// Record/field status. Scraping failure must never render as "officiallyTBA".
public enum DataStatus: String, Hashable, Sendable, LossyStringEnum {
    case confirmed
    case officiallyTBA
    case notFetched
    case needsReview
    case parseFailed
    case notApplicable
    public static let fallback: DataStatus = .needsReview
}
