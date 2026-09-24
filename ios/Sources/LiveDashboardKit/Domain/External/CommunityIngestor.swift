import Foundation
import LiveIngestionCore

public struct CommunityIngestReport: Equatable, Sendable {
    public var admission: ExternalSnapshotAdmission
    public var performanceCount: Int
    public var referenceCount: Int
}

public enum CommunityIngestor {
    public static func ingest(files: [String: Data], revision: String, locals: [LocalSession], into store: ExternalDataStore, at date: Date = Date()) async throws -> CommunityIngestReport {
        let catalog = try LLerNoteSnapshotDecoder.decode(files: files, revision: revision)
        let hashes = files.keys.sorted().map { name in
            ExternalSnapshotFile(path: name, sha256: String(files[name]?.count ?? 0), upstreamRevision: revision)
        }
        let snapshot = ExternalSnapshotRevision(provider: .llernote, upstreamRevision: revision, files: hashes, recordCount: catalog.performances.count)
        let admission = try await store.applyCommunityCatalog(catalog, revision: snapshot, at: date)
        guard case .activate = admission else {
            return CommunityIngestReport(admission: admission, performanceCount: catalog.performances.count, referenceCount: 0)
        }
        let provenance = SourceProvenance(
            provider: .llernote, originProvider: .llfans, upstreamRevision: revision, fetchedAt: date, locator: "performance-info.json"
        )
        var count = 0
        for performance in catalog.performances {
            let eventernoteID = catalog.eventernoteByPerformance[performance.id]
            let duplicate = eventernoteID.map { (catalog.eventernoteTargets[$0]?.count ?? 0) > 1 } ?? false
            let observed = ObservedSession(
                llfansPerformanceID: performance.id, eventernoteEventID: eventernoteID,
                localDate: performance.date, startTime: performance.startTime, dayLabel: performance.performanceName,
                venueName: performance.venueName, title: performance.tourName, duplicateEventernoteTarget: duplicate
            )
            for match in PerformanceMatcher.match(locals: locals, observed: observed) {
                let reference = ExternalReference(
                    local: LocalEntityRef(kind: .performance, id: match.localPerformanceID),
                    external: match.external, relation: match.relation, provenance: provenance
                )
                try await store.upsert(reference)
                let fans = ExternalReference(
                    local: reference.local,
                    external: ExternalIdentity(namespace: .llfans, entity: .performance, rawID: performance.id),
                    relation: match.relation, provenance: provenance
                )
                try await store.upsert(fans)
                count += 2
            }
        }
        return CommunityIngestReport(admission: admission, performanceCount: catalog.performances.count, referenceCount: count)
    }

    public static func enrichment(performance: Performance, event: LiveEvent, catalog: LLerNoteCatalog?, references: [ExternalReference]) -> CommunityPerformanceEnrichment {
        let mine = references.filter { $0.local.kind == .performance && $0.local.id == performance.id }
        let community = catalog.flatMap { catalog in uniquePerformance(in: catalog, references: mine) }
        return CommunityEnrichmentBuilder.make(
            performance: performance, event: event, community: community, references: mine,
            setlist: community.flatMap { catalog?.setlist(performanceID: $0.id) },
            songs: catalog?.songs ?? [], venue: community.flatMap { catalog?.venue(id: $0.venueID) }
        )
    }

    private static func uniquePerformance(in catalog: LLerNoteCatalog, references: [ExternalReference]) -> LLerPerformance? {
        let matches = catalog.performances.filter { performance in
            references.contains { reference in
                reference.external == performance.identity
                    || (reference.external.namespace == .eventernote && catalog.eventernoteByPerformance[performance.id] == reference.external.rawID)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
