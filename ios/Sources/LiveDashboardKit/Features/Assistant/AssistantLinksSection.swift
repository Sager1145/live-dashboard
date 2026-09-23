import SwiftUI

/// Shows the links the assistant recognised on the official page for the
/// selected performance, e.g. ticket vendors or mail-order stores. Renders
/// nothing when there is nothing applicable, so it can be appended
/// unconditionally at the end of a tab.
public struct AssistantLinksSection: View {
    let title: LocalizedStringKey
    let links: [AssistantLink]
    let selectedPerformanceID: String

    public init(title: LocalizedStringKey, links: [AssistantLink], selectedPerformanceID: String) {
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
                Text(title, bundle: .kit).font(.headline)
                Text("AI 从官网页面识别，链接均来自官网原文", bundle: .kit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(applicable) { link in
                    linkRow(link)
                }
            }
        }
    }

    @ViewBuilder
    private func linkRow(_ link: AssistantLink) -> some View {
        if let url = URL(string: link.url) {
            Link(destination: url) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        ViewThatFits {
                            HStack(spacing: 6) {
                                Text(verbatim: link.label).bold()
                                kindBadge(link.kind)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: link.label).bold()
                                kindBadge(link.kind)
                            }
                        }
                        if let note = link.note {
                            Text(verbatim: note).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let host = link.host ?? url.host {
                            Text(verbatim: host).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .foregroundStyle(.primary)
            .accessibilityHint(Text("在浏览器中打开", bundle: .kit))
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
        case .ticketSales: return String(localized: "购票", bundle: .kit)
        case .ticketResale: return String(localized: "转售", bundle: .kit)
        case .goodsMailOrder: return String(localized: "通贩", bundle: .kit)
        case .goodsVenue: return String(localized: "会场", bundle: .kit)
        case .stream: return String(localized: "配信", bundle: .kit)
        case .other: return String(localized: "链接", bundle: .kit)
        }
    }
}

private extension AssistantLink {
    var host: String? { URL(string: url)?.host?.lowercased() }
}
