import Foundation
import Observation

/// A precomputed view of one `LiveEventBundle` for the dashboard card list.
/// Per DESIGN.md 四.2: identity → dates/venue → current ticket phase → next
/// action, with same-event multi-day merged and tours showing a stop count.
public struct DashboardEventSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let officialTitle: String
    /// Official event page, shared by the card's share button.
    public let primarySourceURL: String
    public let groups: [String]
    public let franchise: Franchise
    public let status: EventStatus
    public let eventType: EventType
    public let isFollowed: Bool
    public let dayLabels: [String]
    public let stopCount: Int
    public let venueSummary: String
    public let firstLocalDate: String?
    public let lastLocalDate: String?
    public let firstStartAt: Date?
    public let officialThumbnail: MediaAsset?
    public let minimumPriceJPY: Int?
    public let currentRoundLabel: String?
    public let ticketBadges: [TicketPhaseBadge]
    public let nextDeadline: Date?
    public let hasPendingAction: Bool
    public let hasImportantUpdate: Bool
    public let timeZoneIdentifier: String
}

/// Which part of the catalog a dashboard list shows, split on the phone's calendar day.
public enum DashboardScope: String, CaseIterable, Hashable, Sendable {
    /// Events with a performance today or later, or with any unknown date.
    case upcoming
    /// Events whose every performance has a known date before today.
    case past
}

@Observable
@MainActor
public final class DashboardStore {
    public private(set) var bundles: [LiveEventBundle] = []
    /// Filters for the upcoming list.
    public var filters = DashboardFilters()
    /// Filters for the past list, independent so switching tabs never carries a selection over.
    public var pastFilters = DashboardFilters()
    public private(set) var refreshingEventIDs: Set<String> = []
    public private(set) var isRefreshing = false
    public private(set) var lastRefreshedAt: Date?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var assistant: AssistantCoordinator?
    /// Result of the last manual history fetch, for the settings UI.
    public private(set) var lastHistoryFetch: HistoryFetchSummary?
    /// True while `isRefreshing` is caused by a manual history fetch rather than a catalog refresh.
    public private(set) var isFetchingHistory = false

    public struct HistoryFetchSummary: Equatable, Sendable {
        public let start: String
        public let end: String
        public let fetchedCount: Int
        public let finishedAt: Date
    }

    private let repository: LiveRepository
    private let userDataStore: UserDataStore
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(repository: LiveRepository, userDataStore: UserDataStore,
                timeZone: TimeZone = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }) {
        self.repository = repository
        self.userDataStore = userDataStore
        self.timeZone = timeZone
        self.now = now
    }

    public func filters(for scope: DashboardScope) -> DashboardFilters {
        scope == .past ? pastFilters : filters
    }

    public func setFilters(_ value: DashboardFilters, for scope: DashboardScope) {
        if scope == .past { pastFilters = value } else { filters = value }
    }

    /// An event moves to `.past` the day after its last known performance, in the phone's calendar.
    public func scope(of bundle: LiveEventBundle) -> DashboardScope {
        scope(of: bundle, day: phoneDay)
    }

    private var phoneDay: String { LocalRefreshPolicy.phoneDay(now: now(), timeZone: timeZone) }

    private func scope(of bundle: LiveEventBundle, day: String) -> DashboardScope {
        LocalRefreshPolicy.hasEnded(bundle, before: day) ? .past : .upcoming
    }

    /// Bundles shown by `scope`, with today's date resolved once for the whole pass.
    private func bundles(in scope: DashboardScope) -> [LiveEventBundle] {
        let day = phoneDay
        return bundles.filter { self.scope(of: $0, day: day) == scope }
    }

    public func load() async {
        isLoading = true
        do { bundles = try await repository.allBundles(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
        await refreshIfNeeded()
    }

    public func refreshIfNeeded() async { await update(manual: false) }
    public func refresh() async { await update(manual: true) }

    public func acceptRefreshedBundle(_ updated: LiveEventBundle) {
        if let index = bundles.firstIndex(where: { $0.event.id == updated.event.id }) { bundles[index] = updated }
        else { bundles.append(updated) }
    }

    public func refresh(eventID: String) async {
        guard !refreshingEventIDs.contains(eventID), !isRefreshing else { return }
        refreshingEventIDs.insert(eventID)
        defer { refreshingEventIDs.remove(eventID) }
        do {
            if let updated = try await repository.refresh(eventID: eventID) {
                acceptRefreshedBundle(updated)
                Task { await assistant?.generateStale(in: [updated]) }
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    /// Returns the summary of this run, or nil when nothing ran or the whole fetch failed.
    @discardableResult
    public func fetchHistory(from startDate: Date, to endDate: Date) async -> HistoryFetchSummary? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        isFetchingHistory = true
        defer { isRefreshing = false; isFetchingHistory = false }
        var start = LocalRefreshPolicy.phoneDay(now: startDate, timeZone: timeZone)
        var end = LocalRefreshPolicy.phoneDay(now: endDate, timeZone: timeZone)
        if end < start { swap(&start, &end) }
        do {
            let fetched = try await repository.fetchHistory(start: start, end: end)
            bundles = try await repository.allBundles()
            userDataStore.reconcile(remaps: await repository.consumeRemaps(), availableBundles: bundles)
            errorMessage = nil
            let summary = HistoryFetchSummary(start: start, end: end, fetchedCount: fetched.count, finishedAt: now())
            lastHistoryFetch = summary
            Task { await assistant?.generateStale(in: fetched) }
            return summary
        } catch {
            // Successful pages remain useful when another official source is unavailable.
            if let saved = try? await repository.allBundles() { bundles = saved }
            errorMessage = error.localizedDescription
            if case OfficialEventScraperError.partialFailure(let partial, _) = error {
                let summary = HistoryFetchSummary(start: start, end: end, fetchedCount: partial.count, finishedAt: now())
                lastHistoryFetch = summary
                return summary
            }
            return nil
        }
    }

    private func update(manual: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            bundles = try await (manual ? repository.refresh() : repository.refreshIfNeeded())
            userDataStore.reconcile(remaps: await repository.consumeRemaps(), availableBundles: bundles)
            errorMessage = nil
            Task { await assistant?.generateStale(in: bundles) }
        } catch {
            // Successful pages remain useful when another official source is unavailable.
            if let saved = try? await repository.allBundles() { bundles = saved }
            errorMessage = error.localizedDescription
        }
        lastRefreshedAt = await repository.lastRefreshDate()
    }

    public var availableYears: [Int] { availableYears(in: .upcoming) }
    public var availableMonths: [Int] { availableMonths(in: .upcoming) }
    public var visibleSummaries: [DashboardEventSummary] { visibleSummaries(in: .upcoming) }

    /// Years that have at least one performance, limited to the scope's selected franchise and month.
    public func availableYears(in scope: DashboardScope) -> [Int] {
        let filters = filters(for: scope)
        return Array(Set(performanceYearMonths(in: scope).compactMap { year, month in
            (filters.month == nil || filters.month == month) ? year : nil
        })).sorted()
    }

    /// Months that have at least one performance, limited to the scope's selected franchise and year.
    public func availableMonths(in scope: DashboardScope) -> [Int] {
        let filters = filters(for: scope)
        return Array(Set(performanceYearMonths(in: scope).compactMap { year, month in
            (filters.year == nil || filters.year == year) ? month : nil
        })).sorted()
    }

    /// (year, month) of every performance in the scope that passes its franchise filter.
    private func performanceYearMonths(in scope: DashboardScope) -> [(Int, Int)] {
        let filters = filters(for: scope)
        return bundles(in: scope)
            .filter { filters.franchise == nil || $0.event.franchise == filters.franchise }
            .flatMap { $0.performances }
            .compactMap { performance -> (Int, Int)? in
                guard let date = performance.localDate else { return nil }
                let parts = date.split(separator: "-")
                guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
                return (year, month)
            }
    }

    private func matchesCalendarFilters(_ bundle: LiveEventBundle, filters: DashboardFilters) -> Bool {
        guard filters.year != nil || filters.month != nil else { return true }
        return bundle.performances.contains { performance in
            guard let date = performance.localDate else { return false }
            let parts = date.split(separator: "-")
            guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]) else { return false }
            return (filters.year == nil || filters.year == year)
                && (filters.month == nil || filters.month == month)
        }
    }

    /// Upcoming events run soonest first with unknown dates last; past events run most recent first.
    public func visibleSummaries(in scope: DashboardScope) -> [DashboardEventSummary] {
        let filters = filters(for: scope)
        let summaries = bundles(in: scope)
            .filter { matchesCalendarFilters($0, filters: filters) }
            .map(summarize)
            .filter { matchesFilters($0, filters: filters) }
        switch scope {
        case .upcoming:
            return summaries.sorted { lhs, rhs in
                let leftDate = lhs.firstLocalDate ?? "9999-12-31"
                let rightDate = rhs.firstLocalDate ?? "9999-12-31"
                if leftDate != rightDate { return leftDate < rightDate }
                let leftTime = lhs.firstStartAt ?? .distantFuture
                let rightTime = rhs.firstStartAt ?? .distantFuture
                if leftTime != rightTime { return leftTime < rightTime }
                return lhs.id < rhs.id
            }
        case .past:
            // Every past event has known dates, so no placeholder is needed here.
            return summaries.sorted { lhs, rhs in
                let leftDate = lhs.lastLocalDate ?? ""
                let rightDate = rhs.lastLocalDate ?? ""
                if leftDate != rightDate { return leftDate > rightDate }
                let leftTime = lhs.firstStartAt ?? .distantPast
                let rightTime = rhs.firstStartAt ?? .distantPast
                if leftTime != rightTime { return leftTime > rightTime }
                return lhs.id < rhs.id
            }
        }
    }

    private func summarize(_ bundle: LiveEventBundle) -> DashboardEventSummary {
        let now = now()
        let userState = userDataStore.state(for: bundle.event.id)
        let sortedPerformances = bundle.performances.sorted { lhs, rhs in
            let leftDate = lhs.localDate ?? "9999-12-31"
            let rightDate = rhs.localDate ?? "9999-12-31"
            if leftDate != rightDate { return leftDate < rightDate }
            if lhs.startAt != rhs.startAt { return (lhs.startAt ?? .distantFuture) < (rhs.startAt ?? .distantFuture) }
            return lhs.order < rhs.order
        }
        let performanceIDs = Set(bundle.performances.map(\.id))
        let scopedRounds = bundle.ticketRounds.filter { round in
            guard round.status == .confirmed, round.kind != .upgrade,
                  case .performances(let ids) = round.scope else { return false }
            return !performanceIDs.isDisjoint(with: ids)
        }
        let openRounds = scopedRounds.filter {
            TicketStatusResolver.resolve(round: $0, now: now).displayStatus == .open
        }
        let deadlineRound = openRounds.filter { $0.applyEndAt != nil }.min { $0.applyEndAt! < $1.applyEndAt! }
        let soonestDeadline = deadlineRound?.applyEndAt
        let currentRoundLabel = deadlineRound?.officialName ?? openRounds.first?.officialName
        let deadlineTimeZone = deadlineRound.flatMap { round -> String? in
            guard case .performances(let ids) = round.scope else { return nil }
            return bundle.performances.first(where: { ids.contains($0.id) })?.timeZone
        } ?? bundle.event.timeZone

        let scopedRoundIDs = Set(scopedRounds.map(\.id))
        let ordinaryPrices = bundle.ticketOffers.compactMap { offer -> Int? in
            guard scopedRoundIDs.contains(offer.roundID), !performanceIDs.isDisjoint(with: offer.performanceIDs),
                  let tier = bundle.ticketTiers.first(where: { $0.id == offer.tierID }), tier.priceKind == .full else { return nil }
            if let amount = offer.amount ?? tier.amount, amount.currency == "JPY" { return Int(exactly: amount.minorUnits) }
            return offer.priceJPY ?? tier.priceJPY
        }

        return DashboardEventSummary(
            id: bundle.event.id,
            officialTitle: bundle.event.officialTitle,
            primarySourceURL: bundle.event.primarySourceURL,
            groups: bundle.event.groups,
            franchise: bundle.event.franchise,
            status: bundle.event.status,
            eventType: bundle.event.eventType,
            isFollowed: userState.isFollowed,
            dayLabels: sortedPerformances.map(\.dayLabel),
            stopCount: bundle.stops.count,
            venueSummary: sortedPerformances.first?.venueCity ?? "",
            firstLocalDate: sortedPerformances.first?.localDate,
            lastLocalDate: sortedPerformances.compactMap(\.localDate).max(),
            firstStartAt: sortedPerformances.first?.startAt,
            officialThumbnail: bundle.mediaAssets
                .filter { $0.kind == .eventCover && $0.isImage }
                .max { $0.version < $1.version }
                ?? bundle.mediaAssets
                    .filter { $0.kind == .keyVisual && $0.isImage }
                    .max { $0.version < $1.version },
            minimumPriceJPY: ordinaryPrices.min(),
            currentRoundLabel: currentRoundLabel,
            ticketBadges: TicketPhaseBadgeBuilder.badges(rounds: bundle.ticketRounds, now: now),
            nextDeadline: soonestDeadline,
            hasPendingAction: soonestDeadline != nil,
            hasImportantUpdate: !bundle.notices.isEmpty,
            timeZoneIdentifier: deadlineTimeZone
        )
    }

    private func matchesFilters(_ summary: DashboardEventSummary, filters: DashboardFilters) -> Bool {
        if let franchise = filters.franchise, summary.franchise != franchise { return false }
        if let eventType = filters.eventType, summary.eventType != eventType { return false }
        if !filters.searchText.isEmpty {
            let query = filters.searchText.localizedLowercase
            if !summary.officialTitle.localizedLowercase.contains(query) && !summary.groups.contains(where: { $0.localizedLowercase.contains(query) }) { return false }
        }
        if let group = filters.group, !summary.groups.contains(group) { return false }
        if filters.onlyFollowed, !summary.isFollowed { return false }
        if filters.onlyWithPendingAction, !summary.hasPendingAction { return false }
        if let range = filters.dateRange {
            guard let first = summary.firstLocalDate,
                  let date = DateFormatter.localDate.date(from: first) else { return false }
            if !range.contains(date) { return false }
        }
        return true
    }
}

extension DateFormatter {
    static let localDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
