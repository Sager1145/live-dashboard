import SwiftUI

public extension AssistantRichText {
    /// Maps each segment's style to the colours/weights the UI uses to make
    /// dates, prices, warnings and links stand out. Never synthesizes text:
    /// only styling is applied on top of the model's own segments.
    func attributed() -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var run = AttributedString(segment.text)
            switch segment.style {
            case .normal:
                break
            case .bold:
                run.inlinePresentationIntent = .stronglyEmphasized
            case .important:
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = .red
            case .date:
                run.foregroundColor = .blue
            case .price:
                run.inlinePresentationIntent = .stronglyEmphasized
                run.foregroundColor = .green
            case .warning:
                run.foregroundColor = .orange
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
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public func importanceColor(_ importance: AssistantKeyPoint.Importance) -> Color {
    switch importance {
    case .high: return .red
    case .medium: return .orange
    case .low: return .secondary
    }
}

/// A small Chinese label + SF Symbol pair for an `AssistantKeyPoint.Category`.
public struct AssistantCategoryLabel {
    public let text: String
    public let systemImage: String

    public init(_ category: AssistantKeyPoint.Category) {
        switch category {
        case .schedule: text = "日程"; systemImage = "calendar"
        case .ticket: text = "售票"; systemImage = "ticket"
        case .goods: text = "周边"; systemImage = "bag"
        case .seating: text = "座位"; systemImage = "chair.lounge"
        case .stream: text = "配信"; systemImage = "play.rectangle"
        case .notice: text = "公告"; systemImage = "exclamationmark.bubble"
        case .other: text = "其他"; systemImage = "info.circle"
        }
    }
}
