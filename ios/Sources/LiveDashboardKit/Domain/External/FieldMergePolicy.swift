import Foundation
import LiveIngestionCore

public enum OfficialFieldState<Value: Equatable>: Equatable {
    case value(Value)
    case unpublished
    case unparsed(stale: Value?)
    case requestFailed(stale: Value?)
    case absent
}

public enum StaleReason: Equatable, Sendable {
    case unparsed
    case requestFailed
}

public enum FieldMergeOutcome<Value: Equatable>: Equatable {
    case retainOfficial(Value, community: Value?)
    case unpublished(community: Value?)
    case staleOfficial(retained: Value?, community: Value?, reason: StaleReason)
    case absent(community: Value?)
}

public enum SupplementalField: String, Equatable, Sendable {
    case venueAddress
    case venueCoordinate
    case venueGenericSeatMap
    case setlist
    case ticketPrice
    case ticketReception
    case paymentDeadline
    case upgradeEligibility
    case performanceSeatMap
}

public enum FieldMergePolicy {
    /// Community values annotate. They do not replace an official value, fill an
    /// unpublished field, or refresh a value the official parser failed to read.
    public static func merge<Value: Equatable>(
        official: OfficialFieldState<Value>,
        community: Value?
    ) -> FieldMergeOutcome<Value> {
        switch official {
        case .value(let officialValue):
            return .retainOfficial(officialValue, community: community)
        case .unpublished:
            return .unpublished(community: community)
        case .unparsed(let stale):
            return .staleOfficial(retained: stale, community: community, reason: .unparsed)
        case .requestFailed(let stale):
            return .staleOfficial(retained: stale, community: community, reason: .requestFailed)
        case .absent:
            return .absent(community: community)
        }
    }

    public static func mayAttachCommunitySupplement(_ field: SupplementalField) -> Bool {
        switch field {
        case .venueAddress, .venueCoordinate, .venueGenericSeatMap, .setlist:
            return true
        case .ticketPrice, .ticketReception, .paymentDeadline, .upgradeEligibility, .performanceSeatMap:
            return false
        }
    }

    /// A venue's generic seating page becomes this performance's seating plan
    /// only when the official page links that plan to the performance.
    public static func seatMapIsPerformanceConfiguration(officialPageLinksThisPerformance: Bool) -> Bool {
        officialPageLinksThisPerformance
    }
}
