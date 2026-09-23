import SwiftUI

/// Shows the links the assistant recognised on the official page for the
/// selected performance, e.g. ticket vendors or mail-order stores. Renders
/// nothing when there is nothing applicable, so it can be appended
/// unconditionally at the end of a tab.
public struct AssistantLinksSection: View {
    let title: String
    let links: [AssistantLink]
    let selectedPerformanceID: String

    public init(title: String, links: [AssistantLink], selectedPerformanceID: String) {
        self.title = title
        self.links = links
        self.selectedPerformanceID = selectedPerformanceID
    }

    private var applicable: [AssistantLink] {
        links.filter { $0.applies(to: selectedPerformanceID) }
    }

    public var body: some View {
        if !applicable.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text("AI 从官网页面识别，链接均来自官网原文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(applicable) { link in
                    linkRow(link)
                }
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func linkRow(_ link: AssistantLink) -> some View {
        if let url = URL(string: link.url) {
            Link(destination: url) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(link.label).bold()
                            kindBadge(link.kind)
                        }
                        if let note = link.note {
                            Text(note).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let host = link.host ?? url.host {
                            Text(host).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private func kindBadge(_ kind: AssistantLink.Kind) -> some View {
        Text(kindLabel(kind))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
    }

    private func kindLabel(_ kind: AssistantLink.Kind) -> String {
        switch kind {
        case .ticketSales: return "购票"
        case .ticketResale: return "转售"
        case .goodsMailOrder: return "通贩"
        case .goodsVenue: return "会场"
        case .stream: return "配信"
        case .other: return "链接"
        }
    }
}

private extension AssistantLink {
    var host: String? { URL(string: url)?.host?.lowercased() }
}
