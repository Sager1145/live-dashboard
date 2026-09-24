import CryptoKit
import Foundation

enum OnDeviceExtraction {
    static let providerID = "apple.system.onDevice"
    static let promptVersion = "date-role-v1"
    static let schemaVersion = "date-role-schema-v1"
    /// App schema epoch for cache identity. Not a model revision.
    static let engineCompatibilityEpoch = "foundation-models-26"
}

struct EvidenceLine: Codable, Sendable, Equatable {
    var id: String
    var text: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

struct DateMention: Codable, Sendable, Equatable {
    var id: String
    var rawText: String
    var lineIDs: [String]

    init(id: String, rawText: String, lineIDs: [String]) {
        self.id = id
        self.rawText = rawText
        self.lineIDs = lineIDs
    }
}

struct DateClassificationRequest: Codable, Sendable, Equatable {
    var snapshotID: String
    var eventID: String
    var blockID: String
    var headingPath: [String]
    var lines: [EvidenceLine]
    var mentions: [DateMention]

    init(
        snapshotID: String,
        eventID: String,
        blockID: String,
        headingPath: [String],
        lines: [EvidenceLine],
        mentions: [DateMention]
    ) {
        self.snapshotID = snapshotID
        self.eventID = eventID
        self.blockID = blockID
        self.headingPath = headingPath
        self.lines = lines
        self.mentions = mentions
    }
}

enum LocalClassificationError: Error, Equatable {
    case busy
    case unavailable(String)
    case unsupportedLanguage
    case malformedInput
    case unsupportedEvidence
    case invalidCandidateID
    case duplicateCandidateID
    case tooManyResults
    case overBudget
}

enum TicketDateRole: String, Codable, Sendable, CaseIterable {
    case applicationStart
    case applicationEnd
    case resultAnnouncement
    case paymentStart
    case paymentEnd
    case salesStart
    case salesEnd
    case archiveEnd
    case performanceDate
    case unknown
}

struct DateRoleProposal: Codable, Sendable, Equatable {
    var mentionID: String
    var role: TicketDateRole
    var evidenceLineIDs: [String]

    init(mentionID: String, role: TicketDateRole, evidenceLineIDs: [String]) {
        self.mentionID = mentionID
        self.role = role
        self.evidenceLineIDs = evidenceLineIDs
    }
}

struct DateClassificationProposal: Codable, Sendable, Equatable {
    var snapshotID: String
    var eventID: String
    var blockID: String
    var generatedAt: Date
    var providerID: String
    var assignments: [DateRoleProposal]
    var unclassifiedMentionIDs: [String]
    var requiresSemanticReview: Bool

    init(
        snapshotID: String,
        eventID: String,
        blockID: String,
        generatedAt: Date,
        providerID: String,
        assignments: [DateRoleProposal],
        unclassifiedMentionIDs: [String],
        requiresSemanticReview: Bool
    ) {
        self.snapshotID = snapshotID
        self.eventID = eventID
        self.blockID = blockID
        self.generatedAt = generatedAt
        self.providerID = providerID
        self.assignments = assignments
        self.unclassifiedMentionIDs = unclassifiedMentionIDs
        self.requiresSemanticReview = requiresSemanticReview
    }
}

enum DateAssignmentGrounding {
    static func check(
        assignments: [(mentionID: String, roleRaw: String, evidenceLineIDs: [String])],
        input: DateClassificationRequest
    ) throws -> (proposals: [DateRoleProposal], unclassified: [String]) {
        guard assignments.count <= input.mentions.count else {
            throw LocalClassificationError.tooManyResults
        }
        var mentions: [String: DateMention] = [:]
        mentions.reserveCapacity(input.mentions.count)
        for mention in input.mentions where mentions[mention.id] == nil {
            mentions[mention.id] = mention
        }
        let allowedLines = Set(input.lines.map(\.id))
        var claimed = Set<String>()
        var proposals: [DateRoleProposal] = []
        proposals.reserveCapacity(assignments.count)
        for item in assignments {
            guard let mention = mentions[item.mentionID] else {
                throw LocalClassificationError.invalidCandidateID
            }
            guard claimed.insert(item.mentionID).inserted else {
                throw LocalClassificationError.duplicateCandidateID
            }
            guard let role = TicketDateRole(rawValue: item.roleRaw) else {
                throw LocalClassificationError.invalidCandidateID
            }
            let evidence = Set(item.evidenceLineIDs)
            guard !evidence.isEmpty,
                  evidence.isSubset(of: allowedLines),
                  !evidence.isDisjoint(with: Set(mention.lineIDs)) else {
                throw LocalClassificationError.unsupportedEvidence
            }
            proposals.append(DateRoleProposal(
                mentionID: item.mentionID,
                role: role,
                evidenceLineIDs: evidence.sorted()
            ))
        }
        let unclassified = input.mentions.map(\.id).filter { !claimed.contains($0) }
        return (proposals, unclassified)
    }
}

extension DateClassificationRequest {
    func validate() throws {
        guard !snapshotID.isEmpty, !eventID.isEmpty, !blockID.isEmpty,
              !lines.isEmpty, !mentions.isEmpty, mentions.count <= 8,
              Set(lines.map(\.id)).count == lines.count,
              Set(mentions.map(\.id)).count == mentions.count else {
            throw LocalClassificationError.malformedInput
        }
        let lineText = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.text) })
        for mention in mentions {
            guard !mention.id.isEmpty, !mention.rawText.isEmpty, !mention.lineIDs.isEmpty,
                  mention.lineIDs.allSatisfy({ lineText[$0] != nil }) else {
                throw LocalClassificationError.malformedInput
            }
            let citedText = mention.lineIDs.compactMap { lineText[$0] }.joined(separator: "\n")
            guard citedText.contains(mention.rawText) else {
                throw LocalClassificationError.unsupportedEvidence
            }
        }
    }
}

enum ExtractionCacheKey {
    static func hex(
        snapshotHash: String,
        blockHash: String,
        scopeFingerprint: String,
        providerID: String,
        promptVersion: String,
        schemaVersion: String,
        language: String,
        engineCompatibilityEpoch: String
    ) -> String {
        let joined = [
            snapshotHash,
            blockHash,
            scopeFingerprint,
            providerID,
            promptVersion,
            schemaVersion,
            language,
            engineCompatibilityEpoch,
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
