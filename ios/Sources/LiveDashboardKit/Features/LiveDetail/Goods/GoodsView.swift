import SwiftUI

public struct GoodsView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore

    public init(store: LiveDetailStore, userDataStore: UserDataStore) {
        self.store = store
        self.userDataStore = userDataStore
    }

    public var body: some View {
        let resolution = store.applicableGoodsCampaigns()
        let configurations = userDataStore.effectiveConfigurations(eventID: store.bundle.event.id)
        let sections = ImportantInformationPolicy.goodsTabSections(applicableCampaigns: resolution.applicable, configurations: configurations)
        let unconfirmed = ImportantInformationPolicy.goodsTabSections(applicableCampaigns: resolution.unconfirmed, configurations: configurations)

        LazyVStack(spacing: 12) {
            campaignSection("现场／会场领取", campaigns: sections.venue, actionsAllowed: true)
            campaignSection("官方通贩", campaigns: sections.online, actionsAllowed: true)
            campaignSection("其他官方周边资料", campaigns: sections.other, actionsAllowed: true)

            let pending = unconfirmed.venue + unconfirmed.online + unconfirmed.other
            if !pending.isEmpty {
                Text("适用场次待确认的周边资料").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(pending) { campaign in campaignCard(campaign, actionsAllowed: false) }
            }

            if sections.venue.isEmpty && sections.online.isEmpty && sections.other.isEmpty && pending.isEmpty {
                if resolution.applicable.isEmpty && resolution.unconfirmed.isEmpty {
                    ContentUnavailableView("尚未获取周边资料", systemImage: "bag")
                } else {
                    ContentUnavailableView {
                        Label("周边卡片已全部隐藏", systemImage: "eye.slash")
                    } description: {
                        Text("资料已获取，只是这些卡片被你隐藏了。")
                    } actions: {
                        Button("恢复显示") {
                            userDataStore.unhideCards(cardTypes: [.goodsCampaign], eventID: store.bundle.event.id)
                        }
                    }
                }
            }

            if let summary = store.assistantSummary {
                AssistantLinksSection(title: "AI 识别的通贩／贩售链接", links: summary.goodsLinks, selectedPerformanceID: store.selectedPerformanceID)
            }
        }
    }

    @ViewBuilder
    private func campaignSection(_ title: String, campaigns: [GoodsCampaign], actionsAllowed: Bool) -> some View {
        if !campaigns.isEmpty {
            Text(LocalizedStringKey(title)).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(campaigns) { campaign in campaignCard(campaign, actionsAllowed: actionsAllowed) }
        }
    }

    @ViewBuilder
    private func campaignCard(_ campaign: GoodsCampaign, actionsAllowed: Bool) -> some View {
        let config = userDataStore.effectiveConfiguration(cardType: .goodsCampaign, entityID: campaign.id, eventID: campaign.eventID)
        let canPurchase = actionsAllowed && campaign.status == .confirmed && hasExplicitSelectedScope(campaign.scope)
        let products = store.bundle.products.filter { $0.campaignID == campaign.id }

        DetailCard(title: campaign.officialName, cardType: .goodsCampaign, entityID: campaign.id, userDataStore: userDataStore, eventID: campaign.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 7) {
                if campaign.phase != .unknown {
                    Text(LocalizedStringKey(phase(campaign.phase))).font(.caption).foregroundStyle(.secondary)
                }

                if config.shows(.time) {
                    if let start = campaign.salesStartAt { LabeledContent("销售开始", value: format(start)) }
                    if let end = campaign.salesEndAt { LabeledContent("销售截止", value: format(end)) }
                    if let window = campaign.pickupWindow { LabeledContent("领取", value: window) }
                    if config.density == .detailed {
                        ForEach(store.bundle.goodsSessions.filter { $0.campaignID == campaign.id && scopeMatches($0.scope) }) { session in
                            Text(sessionText(session)).font(.footnote)
                        }
                    }
                }

                if config.shows(.place), let location = campaign.location { LabeledContent("地点", value: location) }

                if config.shows(.eligibility) {
                    if let requiresTicket = campaign.requiresTicket { LabeledContent("需持票", value: requiresTicket ? "需要" : "不需要") }
                    if let limit = campaign.purchaseLimit { Text("购买限制：\(limit)").font(.footnote) }
                    if config.density == .detailed, let shipping = campaign.shippingNote { Text("配送：\(shipping)").font(.footnote) }
                    if config.density == .detailed, let methods = campaign.paymentMethods { Text("付款方式：\(methods)").font(.footnote) }
                }

                if config.shows(.price) {
                    ForEach(products) { product in
                        productView(product, detailed: config.density == .detailed, actionsAllowed: canPurchase, showsSource: config.shows(.source))
                    }
                }

                if config.shows(.source) {
                    OfficialLinksView(links: campaign.links, title: "官方贩售链接", prominentFirst: canPurchase, excluding: [])
                }

                ForEach(mediaAssets(for: campaign)) { asset in
                    OfficialMediaView(asset: asset, compact: config.density == .compact)
                }

                if config.shows(.source), let raw = campaign.url, let url = URL(string: raw), !campaign.links.contains(where: { $0.url == raw }) {
                    Link(destination: url) { Text(canPurchase ? "查看官方销售页" : "查看官方来源") }
                }
            }
        }
    }

    @ViewBuilder
    private func productView(_ product: Product, detailed: Bool, actionsAllowed: Bool, showsSource: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(product.name)
                Spacer()
                Text(product.amount?.formatted ?? String(localized: "价格待核对", bundle: .kit)).foregroundStyle(.secondary)
            }
            if detailed {
                ForEach(product.variants) { variant in
                    HStack {
                        Text("· \(variant.name)").font(.footnote)
                        Spacer()
                        if let stock = variant.stockStatus { Text(stock).font(.caption).foregroundStyle(.secondary) }
                        if let amount = variant.amount { Text(amount.formatted).font(.footnote) }
                    }
                }
                if let limit = product.purchaseLimit { Text("商品限制：\(limit)").font(.caption).foregroundStyle(.secondary) }
            }
            if showsSource, let raw = product.url, let url = URL(string: raw) {
                Link(destination: url) { Text(actionsAllowed ? "商品官方页" : "商品来源") }.font(.footnote)
            }
        }
    }

    private func mediaAssets(for campaign: GoodsCampaign) -> [MediaAsset] {
        let IDs = Set(campaign.mediaAssetIDs)
        return store.bundle.mediaAssets.filter { IDs.contains($0.id) && [.goodsList, .venueGoodsNotice, .goodsAreaMap, .product].contains($0.kind) }
    }

    private func sessionText(_ session: GoodsSession) -> String {
        let dates: String
        switch (session.startsAt, session.endsAt) {
        case (let start?, let end?): dates = "\(format(start)) – \(format(end))"
        case (let start?, nil): dates = format(start)
        case (nil, let end?): dates = String(localized: "至 \(format(end))", bundle: .kit)
        case (nil, nil): dates = String(localized: "时间待核对", bundle: .kit)
        }
        return "\(session.location)  \(dates)"
    }

    private func hasExplicitSelectedScope(_ scope: Scope) -> Bool {
        guard case .performances(let ids) = scope else { return false }
        return ids.contains(store.selectedPerformanceID)
    }

    private func scopeMatches(_ scope: Scope) -> Bool {
        switch scope {
        case .performances(let ids): return ids.contains(store.selectedPerformanceID)
        case .wholeEvent: return true
        default: return false
        }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: store.selectedPerformance?.timeZone ?? store.bundle.event.timeZone)
        return formatter.string(from: date)
    }

    private func phase(_ value: GoodsPhase) -> String {
        switch value { case .pre: "事前"; case .during: "会期"; case .post: "事后"; case .unknown: "批次待核验" }
    }

}
