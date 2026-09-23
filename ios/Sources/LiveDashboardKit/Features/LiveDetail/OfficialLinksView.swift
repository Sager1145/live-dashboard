import SwiftUI

/// A titled list of official links captured verbatim from the source page,
/// deduplicated against any URLs already shown elsewhere on the card (e.g.
/// the round's `applyURL`). Renders nothing when there is nothing to show.
struct OfficialLinksView: View {
    let links: [OfficialLink]
    let title: String
    var prominentFirst: Bool = false
    var excluding: [String] = []

    private var filtered: [OfficialLink] {
        let excludedSet = Set(excluding)
        return links.filter { !excludedSet.contains($0.url) }
    }

    var body: some View {
        let items = filtered
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.element.id) { (index: Int, link: OfficialLink) in
                    if let url = URL(string: link.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            if prominentFirst && index == 0 {
                                Link(destination: url) { Label(link.label, systemImage: "link") }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Link(destination: url) { Label(link.label, systemImage: "link") }
                                    .buttonStyle(.bordered)
                            }
                            if let host = link.host {
                                Text(host).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
