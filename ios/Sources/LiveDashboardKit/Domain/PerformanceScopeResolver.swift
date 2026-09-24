import Foundation
import LiveIngestionCore

/// Records that apply to the selected performance, split from records whose
/// applicability could not be determined by the parser.
public struct ScopeResolution<T> {
    /// wholeEvent, the stop containing the selection, or an explicit
    /// performance list including the selection.
    public let applicable: [T]
    /// scope == .unconfirmed — shown in a separate "适用日期待确认" bucket,
    /// never merged into `applicable`.
    public let unconfirmed: [T]

    public init(applicable: [T], unconfirmed: [T]) {
        self.applicable = applicable
        self.unconfirmed = unconfirmed
    }
}

/// Resolves which scoped records apply to a given `selectedPerformanceID`.
/// Per DESIGN.md 三: "没有写 Day2" is never interpreted as "same as Day1";
/// unconfirmed scope must never be silently merged into common information.
/// Titles, subtitles, day labels, and local dates are not match keys.
public enum PerformanceScopeResolver {
    public static func resolve<T: ScopedRecord>(
        records: [T],
        selectedPerformanceID: String,
        stopID stopIDForPerformance: (String) -> String?
    ) -> ScopeResolution<T> {
        var applicable: [T] = []
        var unconfirmed: [T] = []

        let selectedStopID = stopIDForPerformance(selectedPerformanceID)

        for record in records {
            switch record.scope {
            case .wholeEvent:
                applicable.append(record)
            case .stop(let stopID):
                if let selectedStopID, selectedStopID == stopID {
                    applicable.append(record)
                }
            case .performances(let performanceIDs):
                if performanceIDs.contains(selectedPerformanceID) {
                    applicable.append(record)
                }
            case .unconfirmed:
                unconfirmed.append(record)
            }
        }

        return ScopeResolution(applicable: applicable, unconfirmed: unconfirmed)
    }

    /// Records that may appear in one date's action list. `.unconfirmed` is
    /// excluded. Matching uses scope IDs only — never a title or a date string.
    public static func actionRecords<T: ScopedRecord>(
        records: [T],
        selectedPerformanceID: String,
        stopID stopIDForPerformance: (String) -> String?
    ) -> [T] {
        guard !selectedPerformanceID.isEmpty else { return [] }
        return resolve(
            records: records,
            selectedPerformanceID: selectedPerformanceID,
            stopID: stopIDForPerformance
        ).applicable
    }

    /// Whether an outbound action (purchase, stream link) may target this
    /// scope for the selected performance. `.unconfirmed` never qualifies.
    public static func allowsAction(
        scope: Scope,
        selectedPerformanceID: String,
        selectedStopID: String?
    ) -> Bool {
        switch scope {
        case .wholeEvent:
            return true
        case .stop(let stopID):
            return selectedStopID == stopID
        case .performances(let performanceIDs):
            return performanceIDs.contains(selectedPerformanceID)
        case .unconfirmed:
            return false
        }
    }
}
