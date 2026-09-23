import Foundation

public enum EvidenceVerification: String, Codable, Hashable, Sendable {
    case confirmed
    case needsReview
    case conflict
}

public struct SourceEvidence: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let recordID: String
    public let field: String
    public let sourceURL: String
    public let quote: String
    public let sourcePublishedAt: Date?
    public let verifiedAt: Date
    public let verification: EvidenceVerification

    public init(
        id: String,
        recordID: String,
        field: String,
        sourceURL: String,
        quote: String,
        sourcePublishedAt: Date?,
        verifiedAt: Date,
        verification: EvidenceVerification
    ) {
        self.id = id
        self.recordID = recordID
        self.field = field
        self.sourceURL = sourceURL
        self.quote = quote
        self.sourcePublishedAt = sourcePublishedAt
        self.verifiedAt = verifiedAt
        self.verification = verification
    }
}
