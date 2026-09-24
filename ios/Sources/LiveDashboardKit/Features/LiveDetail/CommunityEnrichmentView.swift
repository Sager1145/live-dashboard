import SwiftUI
import LiveIngestionCore

public struct CommunityEnrichmentView: View {
    let enrichment: CommunityPerformanceEnrichment?
    @State private var revealsSetlist = false

    public init(enrichment: CommunityPerformanceEnrichment?) {
        self.enrichment = enrichment
    }

    public var body: some View {
        if let enrichment, hasContent(enrichment) {
            VStack(alignment: .leading, spacing: 16) {
                Text("社区资料只作对照，不替换官网日程、票务和状态。", bundle: .kit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !enrichment.conflicts.isEmpty {
                    ForEach(enrichment.conflicts, id: \.self) { conflict in
                        Label(conflict, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.statusWarning)
                    }
                }
                if !enrichment.diffs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("字段对照", bundle: .kit).font(.headline)
                        ForEach(enrichment.diffs) { diff in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: diff.field).font(.subheadline.weight(.semibold))
                                Text(verbatim: "官网：\(diff.officialText)").font(.footnote)
                                if let community = diff.communityText {
                                    Text(verbatim: "社区：\(community)").font(.footnote)
                                }
                                Text(diff.outcome).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let venue = enrichment.venue {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("场馆补充", bundle: .kit).font(.headline)
                        Text(venue.name)
                        if let address = venue.address { Text(address).font(.footnote) }
                        if let coordinate = venue.coordinate { Text(coordinate).font(.footnote) }
                        if let source = venue.source {
                            Text("来源 \(source)\(venue.reviewRequired ? "，待核对" : "")", bundle: .kit)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if venue.seatURL != nil {
                            Text("这是场馆通用座席资料，不是这一场的座位图。", bundle: .kit)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let setlist = enrichment.setlist {
                    setlistSection(setlist)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView {
                Label { Text("没有社区补充", bundle: .kit) } icon: { Image(systemName: "text.badge.plus") }
            } description: {
                Text("导入同一版本的社区快照后，这里显示对照和歌单。", bundle: .kit)
            }
        }
    }

    private func hasContent(_ enrichment: CommunityPerformanceEnrichment) -> Bool {
        !enrichment.diffs.isEmpty || !enrichment.conflicts.isEmpty || enrichment.setlist != nil || enrichment.venue != nil
    }

    @ViewBuilder private func setlistSection(_ setlist: CommunitySetlistPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("歌单", bundle: .kit).font(.headline)
            if setlist.isActual {
                Text("社区记录为实际歌单。", bundle: .kit).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("这不是实际歌单。", bundle: .kit).font(.caption).foregroundStyle(.statusWarning)
            }
            if revealsSetlist {
                ForEach(setlist.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.type).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(row.title).font(.subheadline)
                    }
                }
                Button("隐藏歌单", systemImage: "eye.slash") { revealsSetlist = false }
                    .font(.footnote)
            } else {
                Text("歌单默认遮住，避免剧透。", bundle: .kit).font(.footnote).foregroundStyle(.secondary)
                Button("显示歌单", systemImage: "eye") { revealsSetlist = true }
                    .font(.footnote)
            }
        }
    }
}
