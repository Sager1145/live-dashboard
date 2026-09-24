import SwiftUI
import LiveIngestionCore

public struct OverviewView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    let assistant: AssistantCoordinator
    @State private var recentlyHidden: (cardType: CardType, entityID: String, title: String)?

    public init(store: LiveDetailStore, userDataStore: UserDataStore, assistant: AssistantCoordinator) {
        self.store = store
        self.userDataStore = userDataStore
        self.assistant = assistant
    }

    private static let overviewCardTypes: [CardType] = ImportantInformationPolicy.overviewDefaultOrder

    /// Cards whose body already presents a state when no performance is selected.
    private static func rendersWithoutPerformance(_ cardType: CardType) -> Bool {
        switch cardType {
        case .assistantSummary, .pricing, .admission:
            true
        default:
            false
        }
    }

    public var body: some View {
        let configs = userDataStore.effectiveConfigurations(eventID: store.bundle.event.id)
        let order = ImportantInformationPolicy.overviewCards(configurations: configs)
        let hiddenCount = userDataStore.hiddenCardCount(cardTypes: Self.overviewCardTypes, eventID: store.bundle.event.id)
        let performance = store.selectedPerformance
        // Time and venue and performers have no body without a performance.
        let visibleOrder = performance == nil ? order.filter(Self.rendersWithoutPerformance) : order

        LazyVStack(spacing: 12) {
            if performance == nil {
                ContentUnavailableView {
                    Label { Text("尚无可用场次资料", bundle: .kit) } icon: { Image(systemName: "calendar.badge.exclamationmark") }
                } description: {
                    Text("官网尚未公布场次，或当前资料来源中没有场次。", bundle: .kit)
                    if visibleOrder.isEmpty {
                        Text("资料已获取，只是这些卡片被你隐藏了。", bundle: .kit)
                    }
                } actions: {
                    if let url = URL(string: store.bundle.event.primarySourceURL) {
                        Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                    }
                    if visibleOrder.isEmpty {
                        Button {
                            userDataStore.unhideCards(cardTypes: Self.overviewCardTypes, eventID: store.bundle.event.id)
                            recentlyHidden = nil
                        } label: {
                            Text("恢复显示", bundle: .kit)
                        }
                    }
                }
            }
            if visibleOrder.isEmpty, performance != nil {
                ContentUnavailableView {
                    Label { Text("概览卡片已全部隐藏", bundle: .kit) } icon: { Image(systemName: "eye.slash") }
                } description: {
                    Text("资料已获取，只是这些卡片被你隐藏了。", bundle: .kit)
                } actions: {
                    Button {
                        userDataStore.unhideCards(cardTypes: Self.overviewCardTypes, eventID: store.bundle.event.id)
                        recentlyHidden = nil
                    } label: {
                        Text("恢复显示", bundle: .kit)
                    }
                }
            } else if !visibleOrder.isEmpty {
                ForEach(visibleOrder, id: \.self) { cardType in
                    cardView(for: cardType, performance: performance)
                }
            }
            if let recentlyHidden {
                UndoHiddenCardRow(id: "\(recentlyHidden.cardType.rawValue)|\(recentlyHidden.entityID)", title: recentlyHidden.title) {
                    var updated = userDataStore.effectiveConfiguration(cardType: recentlyHidden.cardType, entityID: recentlyHidden.entityID, eventID: store.bundle.event.id)
                    updated.entityID = recentlyHidden.entityID
                    updated.eventID = store.bundle.event.id
                    updated.isHidden = false
                    userDataStore.setConfiguration(updated)
                    self.recentlyHidden = nil
                } onExpire: {
                    self.recentlyHidden = nil
                }
            }
            if !visibleOrder.isEmpty {
                HiddenCardsFooter(count: hiddenCount) {
                    userDataStore.unhideCards(cardTypes: Self.overviewCardTypes, eventID: store.bundle.event.id)
                    recentlyHidden = nil
                }
            }
        }
        .environment(\.detailCardHideNotification, DetailCardHideNotification { cardType, entityID, title in
            recentlyHidden = (cardType, entityID, title)
        })
    }

    @ViewBuilder
    private func cardView(for cardType: CardType, performance: Performance?) -> some View {
        switch cardType {
        case .assistantSummary:
            AssistantSummaryCard(bundle: store.officialBundle, selectedPerformanceID: store.selectedPerformanceID, coordinator: assistant, userDataStore: userDataStore)
        case .timeAndVenue:
            if let performance {
                TimeAndVenueCard(
                    performance: performance,
                    timeZone: EventFormatting.timeZone(identifier: performance.timeZone ?? store.bundle.event.timeZone, fallback: store.bundle.event.resolvedTimeZone),
                    showsDeviceLocalTime: userDataStore.showsDeviceLocalTime,
                    userDataStore: userDataStore,
                    eventID: store.bundle.event.id
                )
            }
        case .performers:
            if let performance {
                PerformersCard(performance: performance, userDataStore: userDataStore, eventID: store.bundle.event.id)
            }
        case .pricing:
            PricingCard(
                bundle: store.bundle,
                offers: store.bundle.ticketOffers.filter { $0.performanceIDs.contains(store.selectedPerformanceID) },
                userDataStore: userDataStore
            )
        case .admission:
            AdmissionCard(bundle: store.bundle, userDataStore: userDataStore)
        default:
            EmptyView()
        }
    }
}

struct TimeAndVenueCard: View {
    let performance: Performance
    let timeZone: TimeZone
    let showsDeviceLocalTime: Bool
    let userDataStore: UserDataStore
    let eventID: String

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .timeAndVenue, entityID: CardConfiguration.globalEntityID, eventID: eventID)
        let cardKey = TranslationStore.cardKey(eventID: eventID, cardType: .timeAndVenue, entityID: CardConfiguration.globalEntityID)
        DetailCard(title: "时间与会场", cardType: .timeAndVenue, entityID: CardConfiguration.globalEntityID, refreshEntityID: performance.id, userDataStore: userDataStore, eventID: eventID, translationSegments: {
            [performance.venueName, performance.venueCity].filter { !$0.isEmpty }.map {
                TranslationRequestItem(id: "performance|\(performance.id)|venue|\($0)", text: $0)
            }
        }) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 2 : 4) {
                if config.shows(.time) {
                    if let doorsAt = performance.doorsAt {
                        LabeledContent { Text(formatted(doorsAt)).monospacedDigit() } label: { Text("开场", bundle: .kit) }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let startAt = performance.startAt {
                        LabeledContent { Text(formatted(startAt)).monospacedDigit() } label: { Text("开演", bundle: .kit) }
                        if showsDeviceLocalTime {
                            Text("本地时间：\(startAt.formatted(date: .abbreviated, time: .shortened))", bundle: .kit)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if performance.activityKind == .exhibition {
                        Text("开放时间未确认", bundle: .kit)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("开演时间尚未获取或待核验", bundle: .kit)
                            .foregroundStyle(.secondary)
                    }
                    if let start = performance.localDate, let end = performance.localEndDate, end != start {
                        Text("会期 \(start) – \(end)", bundle: .kit)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if config.shows(.place) {
                    if venueValues.isEmpty {
                        Text("会场尚未获取或待核验", bundle: .kit)
                    } else {
                        OfficialTextList(venueValues, separator: " · ", cardKey: cardKey, eventID: eventID)
                    }
                }
            }
        }
    }

    private var venueValues: [String] {
        [performance.venueName, performance.venueCity].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func formatted(_ date: Date) -> String {
        EventFormatting.dateTime(date, in: timeZone)
    }
}

struct PerformersCard: View {
    let performance: Performance
    let userDataStore: UserDataStore
    let eventID: String

    var body: some View {
        let cardKey = TranslationStore.cardKey(eventID: eventID, cardType: .performers, entityID: CardConfiguration.globalEntityID)
        let config = userDataStore.effectiveConfiguration(cardType: .performers, entityID: CardConfiguration.globalEntityID, eventID: eventID)
        let rows = PerformerPresentation.rows(performance.performers)
        let compact = config.density == .compact
        DetailCard(title: "出演", cardType: .performers, entityID: CardConfiguration.globalEntityID, refreshEntityID: performance.id, userDataStore: userDataStore, eventID: eventID, translationSegments: {
            rows.map { row in
                TranslationRequestItem(id: "performance|\(performance.id)|performer|\(row.id)", text: row.text)
            }
        }) {
            if rows.isEmpty {
                Text("出演信息尚未获取或待核验", bundle: .kit).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                    ForEach(rows) { row in
                        OfficialText(row.text, cardKey: cardKey, eventID: eventID)
                            .font(compact ? .footnote : .subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("performer-\(performance.id)-\(row.id)")
                    }
                }
                .id(performance.id)
            }
        }
    }
}

/// One row per stored performer string. Commas stay inside the name.
/// `allowsWrapping` is always true so Dynamic Type is not clipped to one line.
public struct PerformerRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let text: String
    public let allowsWrapping: Bool
}

public enum PerformerPresentation {
    public static func rows(_ performers: [String]) -> [PerformerRow] {
        PerformerLines.expandingNewlines(performers).enumerated().map { index, text in
            PerformerRow(id: String(index), text: text, allowsWrapping: true)
        }
    }

    /// The selected performance id, not the shared date, chooses the roster.
    public static func rows(for performanceID: String, performances: [Performance]) -> [PerformerRow] {
        guard let performance = performances.first(where: { $0.id == performanceID }) else { return [] }
        return rows(performance.performers)
    }
}

struct PricingCard: View {
    let bundle: LiveEventBundle
    let offers: [TicketOffer]
    let userDataStore: UserDataStore

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .pricing, entityID: CardConfiguration.globalEntityID, eventID: bundle.event.id)
        let cardKey = TranslationStore.cardKey(eventID: bundle.event.id, cardType: .pricing, entityID: CardConfiguration.globalEntityID)
        DetailCard(title: "票价", cardType: .pricing, entityID: CardConfiguration.globalEntityID, userDataStore: userDataStore, eventID: bundle.event.id, translationSegments: {
            bundle.ticketTiers.map { TranslationRequestItem(id: "tier|\($0.id)|name", text: $0.name) }
        }) {
            let tierIDs = Set(offers.map(\.tierID))
            let tiers = offers.isEmpty ? bundle.ticketTiers : bundle.ticketTiers.filter { tierIDs.contains($0.id) }
            if !config.shows(.price) {
                EmptyView()
            } else if tiers.isEmpty {
                Text("票价尚未获取或待核验", bundle: .kit).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 6) {
                    if offers.isEmpty { Text("官网公布票价，适用场次请核对官方页面", bundle: .kit).font(.caption).foregroundStyle(.secondary) }
                    ForEach(tiers) { tier in
                        VStack(alignment: .leading, spacing: 2) {
                            ViewThatFits(in: .horizontal) {
                                HStack { tierName(tier, cardKey: cardKey); Spacer(); tierPrice(tier) }
                                VStack(alignment: .leading, spacing: 2) { tierName(tier, cardKey: cardKey); tierPrice(tier) }
                            }
                            if let includes = tier.includes {
                                Text(verbatim: includes).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let fee = tier.feeNote { Text(verbatim: fee).font(.footnote).foregroundStyle(.secondary) }
                            if let tax = tier.taxNote { Text(verbatim: tax).font(.footnote).foregroundStyle(.secondary) }
                            if tier.priceKind != .full {
                                Label {
                                    Text(LocalizedStringKey(priceKindLabel(tier.priceKind)), bundle: .kit)
                                } icon: {
                                    Image(systemName: "exclamationmark.circle")
                                }
                                .font(.caption2)
                                .foregroundStyle(.statusWarning)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tierName(_ tier: TicketTier, cardKey: String) -> some View {
        OfficialText(tier.name, cardKey: cardKey, eventID: bundle.event.id)
    }

    @ViewBuilder
    private func tierPrice(_ tier: TicketTier) -> some View {
        if let amount = tier.amount {
            Text(amount.formatted).monospacedDigit()
        } else if let price = tier.priceJPY {
            Text(EventFormatting.price(price, currencyCode: "JPY")).monospacedDigit()
        } else {
            Text("尚未获取或待核验", bundle: .kit).foregroundStyle(.secondary)
        }
    }

    private func priceKindLabel(_ kind: TicketPriceKind) -> String {
        switch kind {
        case .full: return ""
        case .upgradeDifference: return "升级差额，非完整票价"
        case .streaming: return "直播观看票，非现场票"
        case .under20: return "U20 票价"
        case .other: return "其他价格类型"
        }
    }
}

struct AdmissionCard: View {
    let bundle: LiveEventBundle
    let userDataStore: UserDataStore

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .admission, entityID: CardConfiguration.globalEntityID, eventID: bundle.event.id)
        DetailCard(title: "入场条件", cardType: .admission, entityID: CardConfiguration.globalEntityID, userDataStore: userDataStore, eventID: bundle.event.id) {
            if config.shows(.eligibility) {
                let admission = bundle.evidence.filter { $0.field == "event.admission" }
                if admission.isEmpty {
                    Text("入场条件尚未获取或待核验。请从公演的官方来源确认。", bundle: .kit).font(.subheadline)
                } else {
                    ForEach(admission) { Text(verbatim: $0.quote).font(.subheadline) }
                    let sourceURLs = admission.compactMap { URL(string: $0.sourceURL)?.absoluteString }.reduce(into: [String]()) { result, url in
                        if !result.contains(url) { result.append(url) }
                    }.prefix(3)
                    ForEach(sourceURLs, id: \.self) { raw in
                        if let url = URL(string: raw) {
                            Link(destination: url) { Text("查看官方来源", bundle: .kit) }.font(.footnote)
                        }
                    }
                }
            }
        }
    }
}

/// Shared card chrome: title + trailing `Menu`, used by all four tabs.
public struct DetailCard<Content: View>: View {
    let title: String
    let isVerbatimTitle: Bool
    let cardType: CardType
    let entityID: String
    /// The entity ID passed through to `DetailCardMenu`'s refresh action.
    /// Defaults to `entityID`, but overview cards keyed by
    /// `CardConfiguration.globalEntityID` (e.g. 时间与会场/出演) need their
    /// refresh scoped to the current performance instead.
    let refreshEntityID: String
    let userDataStore: UserDataStore
    let eventID: String?
    /// Segments this card would submit for manual translation; `nil` hides
    /// the "翻译此卡片" menu item.
    let translationSegments: (() -> [TranslationRequestItem])?
    @ViewBuilder let content: Content
    @Environment(\.detailCardRefreshAction) private var refreshAction

    /// For card titles that come from the app's own localized strings (e.g. "票价").
    public init(
        title: String,
        cardType: CardType,
        entityID: String,
        refreshEntityID: String? = nil,
        userDataStore: UserDataStore,
        eventID: String? = nil,
        translationSegments: (() -> [TranslationRequestItem])? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isVerbatimTitle = false
        self.cardType = cardType
        self.entityID = entityID
        self.refreshEntityID = refreshEntityID ?? entityID
        self.userDataStore = userDataStore
        self.eventID = eventID
        self.translationSegments = translationSegments
        self.content = content()
    }

    /// For card titles scraped verbatim from an official source (e.g. a ticket round's `officialName`).
    public init(
        verbatim title: String,
        cardType: CardType,
        entityID: String,
        refreshEntityID: String? = nil,
        userDataStore: UserDataStore,
        eventID: String? = nil,
        translationSegments: (() -> [TranslationRequestItem])? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isVerbatimTitle = true
        self.cardType = cardType
        self.entityID = entityID
        self.refreshEntityID = refreshEntityID ?? entityID
        self.userDataStore = userDataStore
        self.eventID = eventID
        self.translationSegments = translationSegments
        self.content = content()
    }

    private var isRefreshingThisCard: Bool {
        guard let refreshAction, refreshAction.isRefreshing else { return false }
        guard let activeKey = refreshAction.activeCardKey else { return refreshAction.isRefreshing }
        return activeKey == CardConfiguration.Key(cardType: cardType, entityID: refreshEntityID, eventID: nil)
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
                if let translationSegments, let eventID {
                    DetailCardTranslationStatus(eventID: eventID, cardType: cardType, entityID: entityID, segments: translationSegments)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                titleView
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if isRefreshingThisCard {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                DetailCardMenu(title: title, cardType: cardType, entityID: entityID, refreshEntityID: refreshEntityID, userDataStore: userDataStore, eventID: eventID, translationSegments: translationSegments, titleIsLocalizationKey: !isVerbatimTitle)
            }
        }
    }

    @ViewBuilder private var titleView: some View {
        if isVerbatimTitle {
            Text(verbatim: title)
        } else {
            Text(LocalizedStringKey(title), bundle: .kit)
        }
    }
}
