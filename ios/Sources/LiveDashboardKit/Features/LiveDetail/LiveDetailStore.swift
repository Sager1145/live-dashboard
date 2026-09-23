import Foundation
import Observation

public struct LiveSelection: Equatable, Codable, Sendable {
    public var eventID: String
    public var editionID: String?
    public var stopID: String?
    public var performanceID: String?

    public init(eventID: String, editionID: String? = nil, stopID: String? = nil, performanceID: String? = nil) {
        self.eventID = eventID; self.editionID = editionID; self.stopID = stopID; self.performanceID = performanceID
    }
}

/// Drives the four detail tabs off a single `selectedPerformanceID`. Per
/// DESIGN.md 四.3: switching the performance keeps the current tab, but every
/// tab re-resolves its content against the new selection.
@Observable
@MainActor
public final class LiveDetailStore {
    public private(set) var officialBundle: LiveEventBundle
    public var usesAssistantData = true {
        didSet { reconcileSelection() }
    }
    public var bundle: LiveEventBundle {
        if usesAssistantData, let organized = assistantSummary?.organizedBundle,
           organized.event.id == officialBundle.event.id {
            return organized
        }
        return officialBundle
    }
    public var hasAssistantData: Bool {
        assistantSummary?.organizedBundle?.event.id == officialBundle.event.id
    }
    public var selection: LiveSelection
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
        let candidate = initialPerformanceID
            ?? userDataStore.selectedPerformanceID(eventID: bundle.event.id)
            ?? sorted.first(where: { ($0.startAt ?? .distantPast) >= Date() })?.id
            ?? sorted.last?.id
        let performance = sorted.first { $0.id == candidate }
        self.selection = LiveSelection(eventID: bundle.event.id, stopID: performance?.stopID, performanceID: performance?.id)
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
