import SwiftUI

public struct OverviewView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    let assistant: AssistantCoordinator

    public init(store: LiveDetailStore, userDataStore: UserDataStore, assistant: AssistantCoordinator) {
        self.store = store
        self.userDataStore = userDataStore
        self.assistant = assistant
    }

    public var body: some View {
        let configs = userDataStore.effectiveConfigurations(eventID: store.bundle.event.id)
        let order = ImportantInformationPolicy.overviewCards(configurations: configs)

        LazyVStack(spacing: 12) {
            ForEach(order, id: \.self) { cardType in
                cardView(for: cardType)
            }
        }
    }

    @ViewBuilder
    private func cardView(for cardType: CardType) -> some View {
        if let performance = store.selectedPerformance {
            cardView(for: cardType, performance: performance)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func cardView(for cardType: CardType, performance: Performance) -> some View {

        switch cardType {
        case .assistantSummary:
            AssistantSummaryCard(bundle: store.bundle, selectedPerformanceID: store.selectedPerformanceID, coordinator: assistant, userDataStore: userDataStore)
        case .timeAndVenue:
            TimeAndVenueCard(
                performance: performance,
                timeZone: TimeZone(identifier: performance.timeZone ?? store.bundle.event.timeZone) ?? store.bundle.event.resolvedTimeZone,
                showsDeviceLocalTime: userDataStore.showsDeviceLocalTime,
                userDataStore: userDataStore
            )
        case .performers:
            PerformersCard(performance: performance, userDataStore: userDataStore)
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

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .timeAndVenue, entityID: performance.id, eventID: performance.eventID)
        DetailCard(title: "时间与会场", cardType: .timeAndVenue, entityID: performance.id, userDataStore: userDataStore, eventID: performance.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 2 : 4) {
                if config.shows(.time) {
                    if let startAt = performance.startAt {
                        Text("开演：\(formatted(startAt))")
                        if showsDeviceLocalTime {
                            Text("本地时间：\(startAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("开演时间尚未获取或待核验")
                            .foregroundStyle(.secondary)
                    }
                    if let doorsAt = performance.doorsAt {
                        Text("开场：\(formatted(doorsAt))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if config.shows(.place) {
                    Text(venueText)
                }
            }
        }
    }

    private var venueText: String {
        let values = [performance.venueName, performance.venueCity].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return values.isEmpty ? String(localized: "会场尚未获取或待核验", bundle: .kit) : values.joined(separator: " · ")
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

struct PerformersCard: View {
    let performance: Performance
    let userDataStore: UserDataStore

    var body: some View {
        DetailCard(title: "出演", cardType: .performers, entityID: performance.id, userDataStore: userDataStore, eventID: performance.eventID) {
            if performance.performers.isEmpty {
                Text("出演信息尚未获取或待核验").foregroundStyle(.secondary)
            } else {
                Text(performance.performers.joined(separator: "、"))
            }
        }
    }
}

struct PricingCard: View {
    let bundle: LiveEventBundle
    let offers: [TicketOffer]
    let userDataStore: UserDataStore

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .pricing, entityID: CardConfiguration.globalEntityID, eventID: bundle.event.id)
        DetailCard(title: "票价", cardType: .pricing, entityID: CardConfiguration.globalEntityID, userDataStore: userDataStore, eventID: bundle.event.id) {
            let tiersByID = Dictionary(bundle.ticketTiers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let tierIDs = Set(offers.map(\.tierID))
            let tiers = offers.isEmpty ? bundle.ticketTiers : bundle.ticketTiers.filter { tierIDs.contains($0.id) }
            if !config.shows(.price) {
                EmptyView()
            } else if tiers.isEmpty {
                Text("票价尚未获取或待核验").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 6) {
                    if offers.isEmpty { Text("官网公布票价，适用场次请核对官方页面").font(.caption).foregroundStyle(.secondary) }
                    ForEach(tiers) { tier in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(tier.name)
                                Spacer()
                                if let amount = tier.amount {
                                    Text(amount.formatted)
                                } else if let price = tier.priceJPY {
                                    Text("¥\(price)")
                                } else {
                                    Text("尚未获取或待核验").foregroundStyle(.secondary)
                                }
                            }
                            if let includes = tier.includes {
                                Text(includes).font(.footnote).foregroundStyle(.secondary)
                            }
                            if let fee = tier.feeNote { Text(fee).font(.footnote).foregroundStyle(.secondary) }
                            if let tax = tier.taxNote { Text(tax).font(.footnote).foregroundStyle(.secondary) }
                            if tier.priceKind != .full {
                                Text(LocalizedStringKey(priceKindLabel(tier.priceKind)))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            let _ = tiersByID
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
                    Text("入场条件尚未获取或待核验。请从公演的官方来源确认。").font(.subheadline)
                } else {
                    ForEach(admission) { Text($0.quote).font(.subheadline) }
                }
            }
        }
    }
}

/// Shared card chrome: title + trailing `Menu`, used by all four tabs.
public struct DetailCard<Content: View>: View {
    let title: String
    let cardType: CardType
    let entityID: String
    let userDataStore: UserDataStore
    let eventID: String?
    @ViewBuilder let content: Content
    @State private var showsReminderToggle = false

    public init(
        title: String,
        cardType: CardType,
        entityID: String,
        userDataStore: UserDataStore,
        eventID: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.cardType = cardType
        self.entityID = entityID
        self.userDataStore = userDataStore
        self.eventID = eventID
        self.content = content()
    }

    public var body: some View {
        let config = eventID.map { userDataStore.effectiveConfiguration(cardType: cardType, entityID: entityID, eventID: $0) }
            ?? userDataStore.configuration(cardType: cardType, entityID: entityID)
            ?? CardConfiguration(cardType: cardType, entityID: entityID)
        VStack(alignment: .leading, spacing: config.density == .compact ? 5 : 8) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                Spacer()
                DetailCardMenu(cardType: cardType, entityID: entityID, userDataStore: userDataStore, eventID: eventID)
            }
            content
        }
        .padding(config.density == .compact ? 10 : 16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}
