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
    public private(set) var bundle: LiveEventBundle
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
            userDataStore.setSelectedPerformance(newValue, eventID: bundle.event.id)
        }
    }
    public var selectedTab: DetailTab = .overview
    public var assistantSummary: AssistantEventSummary?

    private let userDataStore: UserDataStore

    public init(bundle: LiveEventBundle, initialPerformanceID: String? = nil, userDataStore: UserDataStore) {
        self.bundle = bundle
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
        let previousPerformanceID = selection.performanceID
        self.bundle = bundle

        let sorted = bundle.performances.sorted { $0.order < $1.order }
        let selectedID = sorted.contains(where: { $0.id == previousPerformanceID })
            ? previousPerformanceID
            : sorted.first(where: { ($0.startAt ?? .distantPast) >= Date() })?.id ?? sorted.last?.id
        let performance = sorted.first { $0.id == selectedID }

        selection.eventID = bundle.event.id
        selection.performanceID = performance?.id
        selection.stopID = performance?.stopID
        selection.editionID = bundle.editions.first { edition in
            performance?.editionIDValue == edition.id
        }?.id
        if let selectedID { userDataStore.setSelectedPerformance(selectedID, eventID: bundle.event.id) }
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
