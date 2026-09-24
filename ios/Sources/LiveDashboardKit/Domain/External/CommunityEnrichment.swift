import Foundation
import LiveIngestionCore

public struct CommunityFieldDiff: Identifiable, Equatable, Sendable {
    public var field: String
    public var officialText: String
    public var communityText: String?
    public var outcome: String

    public var id: String { field }
}

public struct CommunitySetlistRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var title: String
    public var position: Int
}

public struct CommunitySetlistPresentation: Equatable, Sendable {
    public var isActual: Bool
    public var rows: [CommunitySetlistRow]
}

public struct CommunityVenueSupplement: Equatable, Sendable {
    public var name: String
    public var address: String?
    public var coordinate: String?
    public var seatURL: String?
    public var source: String?
    public var confidence: Double?
    public var reviewRequired: Bool
}

public struct CommunityPerformanceEnrichment: Equatable, Sendable {
    public var performanceID: String
    public var diffs: [CommunityFieldDiff]
    public var conflicts: [String]
    public var references: [ExternalReference]
    public var setlist: CommunitySetlistPresentation?
    public var venue: CommunityVenueSupplement?
}

public enum CommunityEnrichmentBuilder {
    public static func make(
        performance: Performance,
        event: LiveEvent,
        community: LLerPerformance?,
        references: [ExternalReference],
        setlist: LLerSetlist?,
        songs: [LLerSong],
        venue: LLerVenue?,
        placeSeatURL: String? = nil
    ) -> CommunityPerformanceEnrichment {
        var diffs: [CommunityFieldDiff] = []
        if let community {
            diffs.append(diff(field: "开演", official: clock(performance.startAt, zone: event.resolvedTimeZone), community: community.startTime, unpublished: performance.startAt == nil))
            diffs.append(diff(field: "开场", official: clock(performance.doorsAt, zone: event.resolvedTimeZone), community: community.openTime, unpublished: performance.doorsAt == nil))
            diffs.append(diff(field: "场馆", official: performance.venueName.isEmpty ? nil : performance.venueName, community: community.venueName, unpublished: performance.venueName.isEmpty))
            if community.canceled == true, event.status != .cancelled {
                diffs.append(CommunityFieldDiff(field: "取消", officialText: event.status.rawValue, communityText: "社区标记为取消", outcome: "保留官网状态"))
            }
        }
        let conflicts = references.compactMap { reference -> String? in
            guard reference.relation == .rejected else { return nil }
            return "\(reference.external.key) 与本场冲突，未合并"
        }
        let songNames = Dictionary(songs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let presentedSetlist = setlist.map { list in
            CommunitySetlistPresentation(isActual: list.isActual, rows: list.items.map { item in
                let title = item.customSongName ?? item.songID.flatMap { songNames[$0] } ?? item.title ?? item.type
                return CommunitySetlistRow(id: item.id, type: item.type, title: title, position: item.position)
            }.sorted { $0.position < $1.position })
        }
        let supplement = venue.map { place in
            CommunityVenueSupplement(
                name: place.name, address: place.address,
                coordinate: coordinate(place), seatURL: placeSeatURL,
                source: place.source, confidence: place.confidence, reviewRequired: place.reviewRequired == true
            )
        }
        return CommunityPerformanceEnrichment(
            performanceID: performance.id, diffs: diffs.filter { $0.communityText != nil || $0.outcome != "一致" },
            conflicts: conflicts, references: references, setlist: presentedSetlist, venue: supplement
        )
    }

    private static func diff(field: String, official: String?, community: String?, unpublished: Bool) -> CommunityFieldDiff {
        let state: OfficialFieldState<String> = {
            if let official, !official.isEmpty { return .value(official) }
            if unpublished { return .unpublished }
            return .absent
        }()
        let outcome = FieldMergePolicy.merge(official: state, community: community)
        let officialText: String
        let label: String
        switch outcome {
        case .retainOfficial(let value, _):
            officialText = value
            label = community != nil && community != value ? "官网值保留，社区值仅对照" : "一致"
        case .unpublished:
            officialText = "官方未公布"
            label = "官方未公布"
        case .staleOfficial(let retained, _, let reason):
            officialText = retained ?? "官网值暂缺"
            label = reason == .unparsed ? "解析失败，保留旧值" : "请求失败，保留旧值"
        case .absent:
            officialText = "没有这项资料"
            label = "确实没有"
        }
        return CommunityFieldDiff(field: field, officialText: officialText, communityText: community, outcome: label)
    }

    private static func clock(_ date: Date?, zone: TimeZone) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func coordinate(_ venue: LLerVenue) -> String? {
        guard let latitude = venue.latitude, let longitude = venue.longitude else { return nil }
        return "\(latitude), \(longitude)"
    }
}
