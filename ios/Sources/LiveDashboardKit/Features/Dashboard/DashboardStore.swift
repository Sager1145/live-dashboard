import Foundation
import Observation
import LiveIngestionCore

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
    /// One row per performance: date, day label, start time, venue, and whether the user marked that day.
    public let days: [DashboardDayLine]
}

/// Basic facts for one performance, shown as its own row on the event card.
public struct DashboardDayLine: Identifiable, Hashable, Sendable {
    public let id: String
    /// Date, day label, and start time when the source gives a clock time.
    public let primaryText: String
    /// Subtitle and venue. Empty when the performance has neither.
    public let secondaryText: String
    public let isParticipating: Bool
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
    public private(set) var bundles: [LiveEventBundle] = [] {
        didSet { summaryCacheVersion &+= 1 }
    }
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

    /// The single running refresh (automatic or manual), so a second caller never starts a
    /// second network pass. `inFlightIsManual` records which kind is running so a manual
    /// request arriving during an *automatic* pass knows to queue one more manual pass once
    /// it finishes, while a manual request arriving during another *manual* pass just joins it.
    private var inFlightRefresh: Task<Void, Never>?
    private var inFlightIsManual = false
    /// A manual pass queued to run right after the current automatic pass finishes; concurrent
    /// manual callers all await this same task instead of each queuing their own extra pass.
    private var queuedManualTask: Task<Void, Never>?
    /// The single running manual history fetch, tracked the same way as `inFlightRefresh` so a
    /// catalog `refresh()`/`refreshIfNeeded()` arriving mid-fetch waits for it instead of racing
    /// it for `bundles`.
    private var inFlightHistoryFetch: Task<HistoryFetchSummary?, Never>?

    /// Bumped whenever `bundles` changes, so the summary cache below knows to recompute.
    /// `@ObservationIgnored` because these are a plain memoization cache, not view state:
    /// mutating them during `visibleSummaries(in:)` (which views call from `body`) must never
    /// register as an observed write, or SwiftUI would re-invoke `body` while it is running.
    @ObservationIgnored
    private var summaryCacheVersion = 0
    @ObservationIgnored
    private var summaryCache: [DashboardScope: (key: SummaryCacheKey, result: [DashboardEventSummary])] = [:]

    /// Everything `visibleSummaries(in:)`'s result depends on, besides the scope itself.
    /// Includes the follow-state token and the phone's calendar day so a follow toggle or a
    /// midnight scope change (upcoming → past) invalidates the cache even though `bundles`
    /// itself did not change.
    private struct SummaryCacheKey: Equatable {
        let bundlesVersion: Int
        let filters: DashboardFilters
        let followedIDs: Set<String>
        /// Event-wide plans and per-day marks. A participation toggle must refresh the cards
        /// even though `bundles` and the follow set did not change.
        let participation: [String]
        let phoneDay: String
    }

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

    /// `scope(of:)` looked up by event ID, for views that only hold a summary/ID (e.g. "My
    /// Lives" sectioning followed events into upcoming/past). `nil` when the bundle isn't cached.
    public func scope(ofEventID eventID: String) -> DashboardScope? {
        bundles.first(where: { $0.event.id == eventID }).map { scope(of: $0) }
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

    /// Dismisses the current error banner without retrying, e.g. from a user tapping "关闭".
    public func dismissError() { errorMessage = nil }

    public func refreshIfNeeded() async {
        if let historyTask = inFlightHistoryFetch { _ = await historyTask.value }
        if let queued = queuedManualTask { await queued.value; return }
        if let current = inFlightRefresh { await current.value; return }
        await runRefresh(manual: false)
    }

    public func refresh() async {
        if let historyTask = inFlightHistoryFetch { _ = await historyTask.value }
        if let queued = queuedManualTask { await queued.value; return }
        if let current = inFlightRefresh {
            if inFlightIsManual {
                // Identical concurrent manual request: join the pass already running.
                await current.value
                return
            }
            // A manual refresh requested during an automatic one: wait for it, then run
            // exactly one more manual pass, shared by every caller that arrives while we wait.
            let task = Task { [weak self] in
                await current.value
                await self?.runRefresh(manual: true)
            }
            queuedManualTask = task
            await task.value
            if queuedManualTask == task { queuedManualTask = nil }
            isRefreshing = (inFlightRefresh != nil) || (inFlightHistoryFetch != nil)
            return
        }
        await runRefresh(manual: true)
    }

    private func runRefresh(manual: Bool) async {
        let task = Task { await self.update(manual: manual) }
        inFlightRefresh = task
        inFlightIsManual = manual
        isRefreshing = true
        await task.value
        if inFlightRefresh == task {
            inFlightRefresh = nil
            isRefreshing = (queuedManualTask != nil) || (inFlightHistoryFetch != nil)
        }
    }

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
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func requestServerUpdate(eventID: String) {
        errorMessage = String(localized: "更新请求要发给已连接的资料服务器", bundle: .kit)
    }

    /// Returns the summary of this run, or nil when nothing ran or the whole fetch failed.
    /// Routed through `inFlightHistoryFetch` the same way `refresh()` uses `inFlightRefresh`: a
    /// concurrent caller joins the same pass instead of starting a second one, and a catalog
    /// `refresh()`/`refreshIfNeeded()` arriving mid-fetch waits for this pass first.
    @discardableResult
    public func fetchHistory(from startDate: Date, to endDate: Date) async -> HistoryFetchSummary? {
        if let historyTask = inFlightHistoryFetch { return await historyTask.value }
        if let queued = queuedManualTask { await queued.value }
        if let current = inFlightRefresh { await current.value }
        guard !isRefreshing else { return nil }
        let task = Task { await self.runHistoryFetch(from: startDate, to: endDate) }
        inFlightHistoryFetch = task
        isRefreshing = true
        isFetchingHistory = true
        let result = await task.value
        if inFlightHistoryFetch == task {
            inFlightHistoryFetch = nil
            isFetchingHistory = false
            isRefreshing = (inFlightRefresh != nil) || (queuedManualTask != nil)
        }
        return result
    }

    private func runHistoryFetch(from startDate: Date, to endDate: Date) async -> HistoryFetchSummary? {
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
        do {
            bundles = try await (manual ? repository.refresh() : repository.refreshIfNeeded())
            userDataStore.reconcile(remaps: await repository.consumeRemaps(), availableBundles: bundles)
            errorMessage = nil
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
            .flatMap { performance in Self.yearMonths(covering: performance) }
    }

    private func matchesCalendarFilters(_ bundle: LiveEventBundle, filters: DashboardFilters) -> Bool {
        guard filters.year != nil || filters.month != nil else { return true }
        return bundle.performances.contains { performance in
            Self.yearMonths(covering: performance).contains { year, month in
                (filters.year == nil || filters.year == year) && (filters.month == nil || filters.month == month)
            }
        }
    }

    /// Upcoming events run soonest first with unknown dates last; past events run most recent first.
    /// Cached per scope: recomputed only when `bundles` changes or this scope's filters differ from
    /// the cached ones, so the view can call this from `body` more than once per render for free.
    public func visibleSummaries(in scope: DashboardScope) -> [DashboardEventSummary] {
        let filters = filters(for: scope)
        // Touch these on every call, including a cache hit, so SwiftUI's observation tracking
        // still sees `bundles`/`filters`/`userDataStore.eventStates` as read dependencies of
        // `body` even when the memoized result below is returned without recomputing.
        let followedIDs = Set(userDataStore.eventStates.values.filter(\.isFollowed).map(\.eventID))
        let participation = userDataStore.eventStates.values.map { state in
            "\(state.eventID)|\(state.planningToAttend)|\(state.participatingPerformanceIDs.sorted().joined(separator: ","))"
        }.sorted()
        let day = phoneDay
        _ = bundles.count
        let key = SummaryCacheKey(bundlesVersion: summaryCacheVersion, filters: filters, followedIDs: followedIDs, participation: participation, phoneDay: day)
        if let cached = summaryCache[scope], cached.key == key {
            return cached.result
        }
        let result = computeVisibleSummaries(in: scope, filters: filters)
        summaryCache[scope] = (key, result)
        return result
    }

    private func computeVisibleSummaries(in scope: DashboardScope, filters: DashboardFilters) -> [DashboardEventSummary] {
        let summaries = bundles(in: scope)
            .filter { matchesCalendarFilters($0, filters: filters) }
            .map { summarize($0, finished: scope == .past) }
            .filter { matchesFilters($0, filters: filters) }
        return sorted(summaries, in: scope)
    }

    private func sorted(_ summaries: [DashboardEventSummary], in scope: DashboardScope) -> [DashboardEventSummary] {
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

    /// Every followed event regardless of either tab's filters, upcoming first (soonest date
    /// first, unknown last) then past (most recent first) — for the "My Lives" list.
    /// Marks or unmarks a single performance from its card row.
    public func toggleDayParticipation(eventID: String, performanceID: String) {
        let known = bundles.first(where: { $0.event.id == eventID })?.performances.map(\.id) ?? [performanceID]
        userDataStore.toggleParticipation(eventID: eventID, performanceID: performanceID, knownPerformanceIDs: known)
    }

    public func followedSummaries() -> [DashboardEventSummary] {
        let upcoming = sorted(bundles(in: .upcoming).map { summarize($0, finished: false) }.filter(\.isFollowed), in: .upcoming)
        let past = sorted(bundles(in: .past).map { summarize($0, finished: true) }.filter(\.isFollowed), in: .past)
        return upcoming + past
    }

    private func summarize(_ bundle: LiveEventBundle, finished: Bool) -> DashboardEventSummary {
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
            venueSummary: sortedPerformances.map(\.venueCity).filter { !$0.isEmpty }
                .reduce(into: [String]()) { cities, city in
                    if !cities.contains(city) { cities.append(city) }
                }.joined(separator: " · "),
            firstLocalDate: sortedPerformances.first?.localDate,
            lastLocalDate: sortedPerformances.compactMap(\.periodEndLocalDate).max(),
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
            hasImportantUpdate: Self.hasImportantUpdate(bundle: bundle, now: now, finished: finished),
            timeZoneIdentifier: deadlineTimeZone,
            days: dayLines(for: bundle, performances: sortedPerformances, userState: userState, finished: finished, now: now)
        )
    }

    private func dayLines(for bundle: LiveEventBundle, performances: [Performance], userState: UserEventState, finished: Bool, now: Date) -> [DashboardDayLine] {
        let multipleStops = Set(performances.compactMap(\.stopID)).count > 1
        return performances.map { performance in
            let zone = EventFormatting.timeZone(identifier: performance.timeZone ?? bundle.event.timeZone, fallback: bundle.event.resolvedTimeZone)
            var parts: [String] = [dayDateText(for: performance, zone: zone, finished: finished, now: now)]
            if !performance.dayLabel.isEmpty, performance.dayLabel != parts[0] {
                parts.append(performance.dayLabel)
            }
            if multipleStops, let stopName = bundle.stops.first(where: { $0.id == performance.stopID })?.name, !stopName.isEmpty {
                parts.append(stopName)
            }
            if performance.precision == .minute, let startAt = performance.startAt {
                parts.append(EventFormatting.clockTime(startAt, in: zone))
            }
            var place: [String] = []
            if let subtitle = performance.subtitle, !subtitle.isEmpty { place.append(subtitle) }
            if !performance.venueName.isEmpty { place.append(performance.venueName) }
            if !performance.venueCity.isEmpty, performance.venueCity != performance.venueName {
                place.append(performance.venueCity)
            }
            return DashboardDayLine(
                id: performance.id,
                primaryText: parts.joined(separator: " · "),
                secondaryText: place.joined(separator: " · "),
                isParticipating: userState.isParticipating(in: performance.id)
            )
        }
    }

    private static func yearMonths(covering performance: Performance) -> [(Int, Int)] {
        guard let start = performance.localDate, start.count >= 7 else { return [] }
        let end = performance.localEndDate ?? start
        guard let startYear = Int(start.prefix(4)), let startMonth = Int(start.dropFirst(5).prefix(2)),
              let endYear = Int(end.prefix(4)), let endMonth = Int(end.dropFirst(5).prefix(2)) else { return [] }
        var year = startYear
        var month = startMonth
        var result: [(Int, Int)] = []
        while year < endYear || (year == endYear && month <= endMonth) {
            result.append((year, month))
            month += 1
            if month > 12 { month = 1; year += 1 }
            if result.count > 36 { break }
        }
        return result
    }

    private func dayDateText(for performance: Performance, zone: TimeZone, finished: Bool, now: Date) -> String {
        if let start = performance.localDate, let end = performance.localEndDate, end != start,
           let startDate = EventFormatting.parseISODate(start, in: zone),
           let endDate = EventFormatting.parseISODate(end, in: zone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let includesYear = finished || calendar.component(.year, from: startDate) != calendar.component(.year, from: now)
            return "\(EventFormatting.date(startDate, in: zone, includesYear: includesYear)) – \(EventFormatting.date(endDate, in: zone, includesYear: includesYear))"
        }
        if let localDate = performance.localDate, let date = EventFormatting.parseISODate(localDate, in: zone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let includesYear = finished || calendar.component(.year, from: date) != calendar.component(.year, from: now)
            return EventFormatting.date(date, in: zone, includesYear: includesYear)
        }
        if let rawDate = performance.rawDate, !rawDate.isEmpty { return rawDate }
        return String(localized: "日期待公布", bundle: .kit)
    }

    /// True when the event has a notice published within the last 7 days and the event has not
    /// already finished. Notices without a `publishedAt` (some scraped sources omit it) cannot be
    /// judged "recent", so they never trigger this badge — falling back to `false` rather than
    /// treating every undated notice as a fresh update.
    private static func hasImportantUpdate(bundle: LiveEventBundle, now: Date, finished: Bool) -> Bool {
        guard !finished else { return false }
        return bundle.notices.contains { notice in
            guard let publishedAt = notice.publishedAt else { return false }
            let age = now.timeIntervalSince(publishedAt)
            return age >= 0 && age <= 7 * 24 * 3600
        }
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
            guard let first = summary.firstLocalDate else { return false }
            let lower = Self.phoneLocalDateFormatter.string(from: range.lowerBound)
            let upper = Self.phoneLocalDateFormatter.string(from: range.upperBound)
            if !(lower <= first && first <= upper) { return false }
        }
        return true
    }

    /// Formats a `Date` as "yyyy-MM-dd" in the phone's own calendar/time zone, so a DatePicker
    /// bound (an instant) compares against `firstLocalDate` (already a calendar-day string) by
    /// calendar day rather than by instant.
    private static let phoneLocalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
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
