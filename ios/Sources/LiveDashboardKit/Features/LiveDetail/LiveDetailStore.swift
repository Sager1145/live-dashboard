import Foundation
import Observation
import LiveIngestionCore

public struct LiveSelection: Equatable, Codable, Sendable {
    public var eventID: String
    public var editionID: String?
    public var stopID: String?
    public var performanceID: String?

    public init(eventID: String, editionID: String? = nil, stopID: String? = nil, performanceID: String? = nil) {
        self.eventID = eventID; self.editionID = editionID; self.stopID = stopID; self.performanceID = performanceID
    }
}

/// Drives the detail tabs off a single `selectedPerformanceID`. Per
/// DESIGN.md 四.3: switching the performance keeps the current tab, but every
/// tab re-resolves its content against the new selection.
@Observable
@MainActor
public final class LiveDetailStore {
    public private(set) var officialBundle: LiveEventBundle
    public var usesAssistantData = true {
        didSet { reconcileSelection() }
    }
    /// AI text may replace the official bundle only when it was produced from
    /// this exact official revision. A stale summary keeps the corrected scrape.
    private var freshAssistantBundle: LiveEventBundle? {
        guard let summary = assistantSummary,
              let organized = summary.organizedBundle,
              organized.event.id == officialBundle.event.id,
              summary.sourceFingerprint == AssistantSummarizer.fingerprint(of: officialBundle) else { return nil }
        return organized
    }
    public var bundle: LiveEventBundle {
        if usesAssistantData, let organized = freshAssistantBundle {
            return organized
        }
        return officialBundle
    }
    public var hasAssistantData: Bool { freshAssistantBundle != nil }
    public var selection: LiveSelection
    /// The day the date control is showing. Venue and activity choices are the
    /// performances that cover this day.
    public private(set) var selectedLocalDate: String?
    public var selectedPerformanceID: String {
        get { selection.performanceID ?? "" }
        set {
            guard bundle.performances.contains(where: { $0.id == newValue }) else { return }
            let performance = bundle.performances.first { $0.id == newValue }
            selection.performanceID = newValue
            selection.stopID = performance?.stopID
            selection.editionID = bundle.editions.first { edition in
                performance?.id != nil && performance?.editionIDValue == edition.id
            }?.id
            replacedPerformanceID = nil
            userDataStore.setSelectedPerformance(newValue, eventID: bundle.event.id)
        }
    }
    /// Set when `reconcileSelection()` had to fall back away from the
    /// previously selected performance because it doesn't exist in the
    /// current data source (e.g. switching to an AI bundle that omits it).
    /// `LiveDetailView` shows a short notice, and switching back to the
    /// source that had it restores the original selection and clears this.
    public private(set) var replacedPerformanceID: String?
    public var selectedTab: DetailTab = .overview
    public var assistantSummary: AssistantEventSummary? {
        didSet { reconcileSelection() }
    }

    private let userDataStore: UserDataStore

    public init(bundle: LiveEventBundle, initialPerformanceID: String? = nil, userDataStore: UserDataStore) {
        self.officialBundle = bundle
        self.userDataStore = userDataStore
        let sorted = bundle.performances.sorted { $0.order < $1.order }
        let explicitID = initialPerformanceID ?? userDataStore.selectedPerformanceID(eventID: bundle.event.id)
        let today = Self.localDayString(Date(), timeZone: bundle.event.resolvedTimeZone)
        let performance: Performance?
        let date: String?
        if let explicitID, let explicit = sorted.first(where: { $0.id == explicitID }) {
            performance = explicit
            date = explicit.covers(localDate: today) ? today : explicit.localDate
        } else {
            let coveringToday = sorted.filter { $0.covers(localDate: today) }
            if coveringToday.count == 1 {
                performance = coveringToday[0]
                date = today
            } else if coveringToday.count > 1 {
                performance = nil
                date = today
            } else {
                performance = sorted.first(where: { ($0.startAt ?? .distantPast) >= Date() }) ?? sorted.last
                date = performance?.localDate
            }
        }
        self.selectedLocalDate = date
        self.selection = LiveSelection(eventID: bundle.event.id, stopID: performance?.stopID, performanceID: performance?.id)
        pruneParticipation(in: bundle)
    }

    /// Dates that at least one performance covers, in calendar order.
    public var selectableLocalDates: [String] {
        var seen: Set<String> = []
        var dates: [String] = []
        for performance in sortedPerformances {
            for day in Self.daysCovered(by: performance) where seen.insert(day).inserted {
                dates.append(day)
            }
        }
        return dates.sorted()
    }

    public var performancesOnSelectedDate: [Performance] {
        guard let selectedLocalDate else { return sortedPerformances }
        return sortedPerformances.filter { $0.covers(localDate: selectedLocalDate) }
    }

    /// Picks the day, then keeps the current activity only when it still covers
    /// that day. Two venues on the same day stay unselected until the user picks one.
    public func selectLocalDate(_ date: String) {
        selectedLocalDate = date
        let matches = sortedPerformances.filter { $0.covers(localDate: date) }
        if matches.count == 1 {
            selectedPerformanceID = matches[0].id
        } else if let current = selectedPerformance, current.covers(localDate: date) {
            return
        } else {
            selection.performanceID = nil
            selection.stopID = nil
            selection.editionID = nil
            userDataStore.setSelectedPerformance(nil, eventID: bundle.event.id)
        }
    }

    private func pruneParticipation(in bundle: LiveEventBundle) {
        userDataStore.pruneMissingPerformances(eventID: bundle.event.id, validPerformanceIDs: Set(bundle.performances.map(\.id)))
    }

    private static func localDayString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func daysCovered(by performance: Performance) -> [String] {
        guard let start = performance.localDate else { return [] }
        let end = performance.localEndDate ?? start
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard var cursor = formatter.date(from: start), let last = formatter.date(from: end), cursor <= last else { return [start] }
        var days: [String] = []
        while cursor <= last, days.count < 400 {
            days.append(formatter.string(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    public var sortedPerformances: [Performance] {
        bundle.performances.sorted { $0.order < $1.order }
    }

    public var selectedPerformance: Performance? {
        bundle.performances.first { $0.id == selectedPerformanceID }
    }

    /// Applies a scoped card refresh without disturbing the tab currently in
    /// view. Keep the selected performance when it still exists; otherwise
    /// choose the same valid fallback used for initial detail presentation.
    public func replaceBundle(_ bundle: LiveEventBundle) {
        self.officialBundle = bundle
        pruneParticipation(in: bundle)
        reconcileSelection()
    }

    private func reconcileSelection() {
        let previousPerformanceID = selection.performanceID
        let previousReplacedPerformanceID = replacedPerformanceID
        let sorted = bundle.performances.sorted { $0.order < $1.order }

        let selectedID: String?
        if let previousReplacedPerformanceID, sorted.contains(where: { $0.id == previousReplacedPerformanceID }) {
            selectedID = previousReplacedPerformanceID
        } else if let previousPerformanceID, sorted.contains(where: { $0.id == previousPerformanceID }) {
            selectedID = previousPerformanceID
        } else if let selectedLocalDate {
            let matches = sorted.filter { $0.covers(localDate: selectedLocalDate) }
            selectedID = matches.count == 1 ? matches[0].id : nil
        } else {
            selectedID = sorted.first(where: { ($0.startAt ?? .distantPast) >= Date() })?.id ?? sorted.last?.id
        }
        let performance = sorted.first { $0.id == selectedID }

        selection.eventID = bundle.event.id
        selection.performanceID = performance?.id
        selection.stopID = performance?.stopID
        selection.editionID = bundle.editions.first { edition in
            performance?.editionIDValue == edition.id
        }?.id

        let newReplacedPerformanceID: String?
        if selectedID == previousReplacedPerformanceID {
            newReplacedPerformanceID = nil
        } else if let previousPerformanceID, selectedID != previousPerformanceID, previousReplacedPerformanceID == nil {
            newReplacedPerformanceID = previousPerformanceID
        } else {
            newReplacedPerformanceID = previousReplacedPerformanceID
        }

        // A temporary fallback (the AI bundle lacks the previously selected
        // performance) must never overwrite the user's persisted selection —
        // switching back to the source that has it should restore the
        // original, not the fallback.
        if let selectedID, newReplacedPerformanceID == nil {
            userDataStore.setSelectedPerformance(selectedID, eventID: bundle.event.id)
        }
        replacedPerformanceID = newReplacedPerformanceID
    }

    public func stopID(for performanceID: String) -> String? {
        bundle.performances.first { $0.id == performanceID }?.stopID
    }

    // MARK: - Scope resolution for the selected performance

    public func applicableTicketRounds() -> ScopeResolution<TicketRound> {
        PerformanceScopeResolver.resolve(
            records: bundle.ticketRounds,
            selectedPerformanceID: selectedPerformanceID,
            stopID: stopID(for:)
        )
    }

    public func applicableStreamOffers() -> ScopeResolution<StreamOffer> {
        PerformanceScopeResolver.resolve(records: bundle.streamOffers, selectedPerformanceID: selectedPerformanceID, stopID: stopID(for:))
    }

    public func applicableGoodsCampaigns() -> ScopeResolution<GoodsCampaign> {
        PerformanceScopeResolver.resolve(
            records: bundle.goodsCampaigns,
            selectedPerformanceID: selectedPerformanceID,
            stopID: stopID(for:)
        )
    }

    public func applicableMediaAssets() -> ScopeResolution<MediaAsset> {
        PerformanceScopeResolver.resolve(
            records: bundle.mediaAssets,
            selectedPerformanceID: selectedPerformanceID,
            stopID: stopID(for:)
        )
    }

    public func applicableTicketBenefits() -> ScopeResolution<TicketBenefit> {
        PerformanceScopeResolver.resolve(records: bundle.ticketBenefits, selectedPerformanceID: selectedPerformanceID, stopID: stopID(for:))
    }

    /// Tiers whose official name marks them as goods-bundled (グッズ付き), used
    /// to show a placeholder when the page never describes the bonus.
    public var goodsBundledTiers: [TicketTier] {
        bundle.ticketTiers.filter { $0.name.contains("グッズ付") }
    }

    public func applicableNotices() -> ScopeResolution<Notice> {
        PerformanceScopeResolver.resolve(
            records: bundle.notices,
            selectedPerformanceID: selectedPerformanceID,
            stopID: stopID(for:)
        )
    }

    /// A critical notice (cancellation/postponement/refund), always sourced
    /// from the official bundle even when an AI bundle is displayed, so
    /// switching to AI mode can never hide an official cancellation. AI-only
    /// critical notices (facts the official page hasn't published a matching
    /// notice for) are appended, clearly marked.
    public struct CriticalNoticeItem: Identifiable, Hashable, Sendable {
        public let notice: Notice
        public let isScopeUnconfirmed: Bool
        public let isAssistantOnly: Bool
        public var id: String { (isAssistantOnly ? "ai|" : "official|") + notice.id }
    }

    public static let criticalNoticeKinds: Set<NoticeKind> = [.cancellation, .postponement, .refund]

    public func criticalNotices() -> [CriticalNoticeItem] {
        let officialCritical = officialBundle.notices.filter { Self.criticalNoticeKinds.contains($0.kind) }
        let officialStopID: (String) -> String? = { [officialBundle] id in officialBundle.performances.first { $0.id == id }?.stopID }
        let resolution = PerformanceScopeResolver.resolve(
            records: officialCritical,
            selectedPerformanceID: selectedPerformanceID,
            stopID: officialStopID
        )

        var items = resolution.applicable.map { CriticalNoticeItem(notice: $0, isScopeUnconfirmed: false, isAssistantOnly: false) }
        items += resolution.unconfirmed.map { CriticalNoticeItem(notice: $0, isScopeUnconfirmed: true, isAssistantOnly: false) }

        // The selected performance doesn't exist in the official bundle
        // (e.g. selection came from an AI-only performance) — never drop an
        // official critical fact just because scope can't be resolved.
        if !officialBundle.performances.contains(where: { $0.id == selectedPerformanceID }) {
            let includedIDs = Set(items.map(\.notice.id))
            for notice in officialCritical where !includedIDs.contains(notice.id) {
                items.append(CriticalNoticeItem(notice: notice, isScopeUnconfirmed: true, isAssistantOnly: false))
            }
        }

        if bundle != officialBundle {
            let aiResolution = applicableNotices()
            let officialIDs = Set(officialCritical.map(\.id))
            let officialTitles = Set(officialCritical.map(\.title))
            for notice in aiResolution.applicable where Self.criticalNoticeKinds.contains(notice.kind) {
                guard !officialIDs.contains(notice.id), !officialTitles.contains(notice.title) else { continue }
                items.append(CriticalNoticeItem(notice: notice, isScopeUnconfirmed: false, isAssistantOnly: true))
            }
            for notice in aiResolution.unconfirmed where Self.criticalNoticeKinds.contains(notice.kind) {
                guard !officialIDs.contains(notice.id), !officialTitles.contains(notice.title) else { continue }
                items.append(CriticalNoticeItem(notice: notice, isScopeUnconfirmed: true, isAssistantOnly: true))
            }
        }

        return items
    }

    public func offers(for round: TicketRound) -> [TicketOffer] {
        bundle.ticketOffers.filter {
            $0.roundID == round.id && $0.performanceIDs.contains(selectedPerformanceID)
        }
    }

    public func tier(for offer: TicketOffer) -> TicketTier? {
        bundle.ticketTiers.first { $0.id == offer.tierID }
    }

    /// Runs `operation` and discards its result if `selectedPerformanceID`
    /// changed while it was awaiting — per DESIGN.md 六.3: async work must be
    /// tagged with the entity ID and re-checked against the current
    /// selection before being applied.
    public func loadIfStillSelected<T: Sendable>(
        entityID: String,
        _ operation: @Sendable () async -> T
    ) async -> T? {
        let result = await operation()
        return selectedPerformanceID == entityID ? result : nil
    }

    public var userDataStoreRef: UserDataStore { userDataStore }
}
