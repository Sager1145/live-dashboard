import Foundation

// MARK: - Rich text

/// One run of text inside an assistant-generated summary. The style names are
/// the vocabulary the model is asked to use; the UI maps them to colours and
/// weights so that dates, prices, warnings and links stand out.
public struct AssistantTextSegment: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
        case normal
        case bold
        /// Critical information (cancellation, deadlines that are about to pass,
        /// eligibility limits). Rendered bold in red.
        case important
        /// A date or time. Rendered in blue.
        case date
        /// A price or fee. Rendered bold in green.
        case price
        /// A hyperlink; `url` must be set. Rendered underlined in the accent colour.
        case link
        /// A caution the reader should notice but that is not critical. Rendered in orange.
        case warning
    }

    public var text: String
    public var style: Style
    public var url: String?

    public init(text: String, style: Style = .normal, url: String? = nil) {
        self.text = text
        self.style = style
        self.url = url
    }
}

public struct AssistantRichText: Codable, Hashable, Sendable {
    public var segments: [AssistantTextSegment]

    public init(segments: [AssistantTextSegment]) {
        self.segments = segments
    }

    public init(_ plain: String) {
        self.segments = [AssistantTextSegment(text: plain)]
    }

    public var plainText: String { segments.map(\.text).joined() }
    public var isEmpty: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Summary records

public struct AssistantKeyPoint: Codable, Hashable, Identifiable, Sendable {
    public enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case schedule, ticket, goods, seating, stream, notice, other
    }

    public enum Importance: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
        case high, medium, low

        private var rank: Int { switch self { case .high: 0; case .medium: 1; case .low: 2 } }
        public static func < (lhs: Importance, rhs: Importance) -> Bool { lhs.rank < rhs.rank }
    }

    public var id: String
    public var category: Category
    public var importance: Importance
    public var text: AssistantRichText
    /// Performance IDs this point applies to. Empty means the whole event.
    public var performanceIDs: [String]

    public init(id: String, category: Category, importance: Importance, text: AssistantRichText, performanceIDs: [String] = []) {
        self.id = id
        self.category = category
        self.importance = importance
        self.text = text
        self.performanceIDs = performanceIDs
    }

    public func applies(to performanceID: String) -> Bool {
        performanceIDs.isEmpty || performanceIDs.contains(performanceID)
    }
}

public struct AssistantPerformanceSummary: Codable, Hashable, Identifiable, Sendable {
    public var performanceID: String
    public var dayLabel: String
    public var summary: AssistantRichText
    public var highlights: [AssistantRichText]

    public var id: String { performanceID }

    public init(performanceID: String, dayLabel: String, summary: AssistantRichText, highlights: [AssistantRichText] = []) {
        self.performanceID = performanceID
        self.dayLabel = dayLabel
        self.summary = summary
        self.highlights = highlights
    }
}

/// One independently extracted value from the current official event page.
/// `section` and `label` are stable, user-facing Chinese names defined by the
/// summarizer's field inventory. A value of `官网未说明` is intentional: it
/// distinguishes an official-page omission from an extraction failure.
public struct AssistantOrganizedField: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var section: String
    public var label: String
    public var value: String
    /// Performance IDs this value applies to. Empty means the whole event.
    public var performanceIDs: [String]

    public init(
        id: String,
        section: String,
        label: String,
        value: String,
        performanceIDs: [String] = []
    ) {
        self.id = id
        self.section = section
        self.label = label
        self.value = value
        self.performanceIDs = performanceIDs
    }

    public func applies(to performanceID: String) -> Bool {
        performanceIDs.isEmpty || performanceIDs.contains(performanceID)
    }
}

/// A link the assistant classified from the official page. `url` must be one
/// of the URLs present in the scraped source; the summarizer drops anything else.
public struct AssistantLink: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// Ticket application / purchase page (e+, ぴあ, ローチケ, KKTIX …).
        case ticketSales
        /// Ticket resale / trade.
        case ticketResale
        /// Mail-order goods store (通販).
        case goodsMailOrder
        /// Venue-only goods information.
        case goodsVenue
        /// Streaming ticket.
        case stream
        case other
    }

    public var label: String
    public var url: String
    public var kind: Kind
    public var note: String?
    /// Performance IDs the link applies to. Empty means the whole event.
    public var performanceIDs: [String]
    /// The `TicketRound.id` or `GoodsCampaign.id` this link belongs to, when known.
    public var relatedRecordID: String?

    public var id: String { "\(kind.rawValue)::\(url)::\(label)" }

    public init(label: String, url: String, kind: Kind, note: String? = nil, performanceIDs: [String] = [], relatedRecordID: String? = nil) {
        self.label = label
        self.url = url
        self.kind = kind
        self.note = note
        self.performanceIDs = performanceIDs
        self.relatedRecordID = relatedRecordID
    }

    public func applies(to performanceID: String) -> Bool {
        performanceIDs.isEmpty || performanceIDs.contains(performanceID)
    }
}

/// The assistant's organised reading of one event. It is derived data: it is
/// stored beside, never inside, the official `LiveEventBundle`, and is
/// regenerated whenever `sourceFingerprint` no longer matches the bundle.
public struct AssistantEventSummary: Codable, Hashable, Sendable {
    public var eventID: String
    public var generatedAt: Date
    public var model: String
    public var sourceFingerprint: String
    public var overview: AssistantRichText
    public var keyPoints: [AssistantKeyPoint]
    public var performances: [AssistantPerformanceSummary]
    public var ticketLinks: [AssistantLink]
    public var goodsLinks: [AssistantLink]
    /// A complete, independently extracted domain bundle built from the live
    /// official page. It is stored beside the scraper bundle so the UI can
    /// switch data sources without overwriting official refresh data.
    public var organizedBundle: LiveEventBundle?
    /// Complete field-by-field reading of the live official page. Optional so
    /// summaries persisted by older app versions continue to decode.
    public var organizedFields: [AssistantOrganizedField]?
    /// Things the model could not map confidently (kept visible so the reader
    /// checks the official page).
    public var warnings: [String]

    public init(
        eventID: String,
        generatedAt: Date,
        model: String,
        sourceFingerprint: String,
        overview: AssistantRichText,
        keyPoints: [AssistantKeyPoint],
        performances: [AssistantPerformanceSummary],
        ticketLinks: [AssistantLink],
        goodsLinks: [AssistantLink],
        warnings: [String],
        organizedFields: [AssistantOrganizedField]? = nil,
        organizedBundle: LiveEventBundle? = nil
    ) {
        self.eventID = eventID
        self.generatedAt = generatedAt
        self.model = model
        self.sourceFingerprint = sourceFingerprint
        self.overview = overview
        self.keyPoints = keyPoints
        self.performances = performances
        self.ticketLinks = ticketLinks
        self.goodsLinks = goodsLinks
        self.warnings = warnings
        self.organizedFields = organizedFields
        self.organizedBundle = organizedBundle
    }

    public func performanceSummary(for performanceID: String) -> AssistantPerformanceSummary? {
        performances.first { $0.performanceID == performanceID }
    }

    public func keyPoints(for performanceID: String) -> [AssistantKeyPoint] {
        keyPoints.filter { $0.applies(to: performanceID) }
            .sorted { lhs, rhs in
                if lhs.importance != rhs.importance { return lhs.importance < rhs.importance }
                return lhs.id < rhs.id
            }
    }
}

// MARK: - Account state

/// What the settings screen shows about the signed-in assistant account.
/// Secrets never appear here; they live in the Keychain.
public enum AssistantAccountState: Hashable, Sendable {
    case signedOut
    /// Signed in with an OpenAI API key. `hint` is the masked key tail, e.g. "sk-…a1b2".
    case apiKey(hint: String)
    /// Signed in with a ChatGPT account through OAuth.
    case chatGPT(email: String?, accountID: String?)

    public var isSignedIn: Bool { self != .signedOut }
}
