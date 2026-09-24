import SwiftUI
import LiveIngestionCore

public extension AssistantRichText {
    /// Maps each segment's style to the colours/weights the UI uses to make
    /// dates, prices, warnings and links stand out. Never synthesizes text:
    /// only styling is applied on top of the model's own segments.
    func attributed() -> AttributedString {
        var result = AttributedString()
        var previousWasWarning = false
        for segment in segments {
            var run = AttributedString(segment.text)
            switch segment.style {
            case .normal:
                break
            case .bold:
                run.inlinePresentationIntent = .stronglyEmphasized
            case .important:
                // Critical information (cancellation, imminent deadlines,
                // eligibility limits): never colour-only, always bold too.
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = .statusCritical
            case .date:
                // Not colour-coded: dates read fine in body text, and blue
                // read as "tap me". The caller's own font is kept (only
                // monospaced digits are forced) so dates don't override
                // e.g. a `.headline` context.
                run.foregroundColor = .primary
            case .price:
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = .primary
            case .warning:
                // Only prefix the symbol when entering a warning run, not
                // before every consecutive warning segment.
                if !previousWasWarning {
                    var symbolRun = AttributedString("⚠︎ ")
                    symbolRun.foregroundColor = .statusWarning
                    result += symbolRun
                }
                run.foregroundColor = .statusWarning
            case .link:
                if let urlString = segment.url, let url = URL(string: urlString) {
                    run.underlineStyle = .single
                    run.foregroundColor = .accentColor
                    run.link = url
                } else {
                    run.inlinePresentationIntent = .stronglyEmphasized
                }
            }
            result += run
            previousWasWarning = segment.style == .warning
        }
        return result
    }
}

/// Renders one `AssistantRichText` value with its styled segments, selectable
/// like ordinary body text.
public struct AssistantRichTextView: View {
    let text: AssistantRichText
    var font: Font = .body

    public init(text: AssistantRichText, font: Font = .body) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text.attributed())
            .font(font)
            .monospacedDigit()
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public func importanceColor(_ importance: AssistantKeyPoint.Importance) -> Color {
    switch importance {
    case .high: return .statusCritical
    case .medium: return .statusWarning
    case .low: return .secondary
    }
}

/// Importance is never colour-only: `.medium`/`.low` get distinct symbols,
/// `.high` gets a "重要" capsule instead (see `AssistantSummaryCard`).
public func importanceSymbol(_ importance: AssistantKeyPoint.Importance) -> String {
    switch importance {
    case .high: return "exclamationmark.triangle.fill"
    case .medium: return "exclamationmark.circle"
    case .low: return "info.circle"
    }
}

public func importanceText(_ importance: AssistantKeyPoint.Importance) -> String {
    switch importance {
    case .high: return String(localized: "重要", bundle: .kit)
    case .medium: return String(localized: "一般", bundle: .kit)
    case .low: return String(localized: "提示", bundle: .kit)
    }
}

/// A small Chinese label + SF Symbol pair for an `AssistantKeyPoint.Category`.
public struct AssistantCategoryLabel {
    public let text: String
    public let systemImage: String

    public init(_ category: AssistantKeyPoint.Category) {
        switch category {
        case .schedule: text = String(localized: "日程", bundle: .kit); systemImage = "calendar"
        case .ticket: text = String(localized: "售票", bundle: .kit); systemImage = "ticket"
        case .goods: text = String(localized: "周边", bundle: .kit); systemImage = "bag"
        case .seating: text = String(localized: "座位", bundle: .kit); systemImage = "chair.lounge"
        case .stream: text = String(localized: "配信", bundle: .kit); systemImage = "play.rectangle"
        case .notice: text = String(localized: "公告", bundle: .kit); systemImage = "exclamationmark.bubble"
        case .other: text = String(localized: "其他", bundle: .kit); systemImage = "info.circle"
        }
    }
}
