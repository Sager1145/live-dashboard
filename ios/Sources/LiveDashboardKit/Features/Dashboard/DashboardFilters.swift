import Foundation
import LiveIngestionCore

public struct DashboardFilters: Hashable, Sendable {
    public var franchise: Franchise?
    public var group: String?
    public var eventType: EventType?
    public var searchText: String = ""
    public var year: Int?
    public var month: Int?
    public var dateRange: ClosedRange<Date>?
    public var onlyFollowed: Bool = false
    public var onlyWithPendingAction: Bool = false

    public init(
        franchise: Franchise? = nil,
        group: String? = nil,
        eventType: EventType? = nil,
        searchText: String = "",
        dateRange: ClosedRange<Date>? = nil,
        year: Int? = nil,
        month: Int? = nil,
        onlyFollowed: Bool = false,
        onlyWithPendingAction: Bool = false
    ) {
        self.franchise = franchise
        self.group = group
        self.eventType = eventType
        self.searchText = searchText
        self.dateRange = dateRange
        self.year = year
        self.month = month
        self.onlyFollowed = onlyFollowed
        self.onlyWithPendingAction = onlyWithPendingAction
    }
}
