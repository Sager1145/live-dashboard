import SwiftUI

/// A titled list of official links captured verbatim from the source page,
/// deduplicated against any URLs already shown elsewhere on the card (e.g.
/// the round's `applyURL`). Renders nothing when there is nothing to show.
struct OfficialLinksView: View {
    let links: [OfficialLink]
    let title: String
    var prominentFirst: Bool = false
    var excluding: [String] = []
    /// When supplied, link labels are rendered via `OfficialText` so a
    /// card-level translation toggle also swaps in translated labels.
    var cardKey: String?
    var eventID: String?

    private var filtered: [OfficialLink] {
        let excludedSet = Set(excluding)
        return links.filter { !excludedSet.contains($0.url) }
    }

    var body: some View {
        let items = filtered
        if !items.isEmpty {
            let promotes = prominentFirst && items.count == 1
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title), bundle: .kit)
                    .font(prominentFirst ? .subheadline.weight(.semibold) : .caption)
                    .foregroundStyle(prominentFirst ? .primary : .secondary)
                ForEach(items) { link in
                    linkRow(link, isProminent: promotes && link == items.first)
                }
            }
        }
    }

    @ViewBuilder
    private func linkRow(_ link: OfficialLink, isProminent: Bool) -> some View {
        if let url = URL(string: link.url) {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if isProminent {
                        Link(destination: url) {
                            Label { linkLabelText(link) } icon: { Image(systemName: "arrow.up.right.square") }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Link(destination: url) {
                            Label { linkLabelText(link) } icon: { Image(systemName: "arrow.up.right.square") }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .accessibilityHint(Text("在浏览器中打开", bundle: .kit))
                .accessibilityValue(Text(verbatim: link.host ?? ""))
                if let host = link.host {
                    Text(host).font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private func linkLabelText(_ link: OfficialLink) -> some View {
        if let cardKey, let eventID {
            OfficialText(link.label, cardKey: cardKey, eventID: eventID)
        } else {
            Text(verbatim: link.label)
        }
    }
}
