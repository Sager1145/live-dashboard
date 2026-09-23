import SwiftUI

public struct GoodsView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    @State private var recentlyHidden: (cardType: CardType, entityID: String, title: String)?

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
                Label { Text("适用场次待确认的周边资料", bundle: .kit) } icon: { Image(systemName: "questionmark.circle") }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                ForEach(pending) { campaign in campaignCard(campaign, actionsAllowed: false) }
            }

            let hasAssistantGoodsLinks = store.assistantSummary?.goodsLinks.contains { $0.applies(to: store.selectedPerformanceID) } ?? false

            if sections.venue.isEmpty && sections.online.isEmpty && sections.other.isEmpty && pending.isEmpty {
                if resolution.applicable.isEmpty && resolution.unconfirmed.isEmpty {
                    if hasAssistantGoodsLinks {
                        ContentUnavailableView {
                            Label { Text("暂无结构化周边资料", bundle: .kit) } icon: { Image(systemName: "bag") }
                        } description: {
                            Text("可使用下方 AI 识别的链接前往官网查看。", bundle: .kit)
                        }
                    } else if !store.bundle.goodsCampaigns.isEmpty {
                        ContentUnavailableView {
                            Label { Text("所选场次暂无周边资料", bundle: .kit) } icon: { Image(systemName: "bag") }
                        } description: {
                            Text("其他场次有资料，请切换场次查看。", bundle: .kit)
                        } actions: {
                            if let url = URL(string: store.bundle.event.primarySourceURL) {
                                Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                            }
                        }
                    } else {
                        ContentUnavailableView {
                            Label { Text("尚未获取周边资料", bundle: .kit) } icon: { Image(systemName: "bag") }
                        } actions: {
                            if let url = URL(string: store.bundle.event.primarySourceURL) {
                                Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label { Text("周边卡片已全部隐藏", bundle: .kit) } icon: { Image(systemName: "eye.slash") }
                    } description: {
                        Text("资料已获取，只是这些卡片被你隐藏了。", bundle: .kit)
                    } actions: {
                        Button {
                            userDataStore.unhideCards(cardTypes: [.goodsCampaign], eventID: store.bundle.event.id)
                            recentlyHidden = nil
                        } label: {
                            Text("恢复显示", bundle: .kit)
                        }
                    }
                }
            }

            if let summary = store.assistantSummary {
                AssistantLinksSection(title: "AI 识别的通贩／贩售链接", links: summary.goodsLinks, selectedPerformanceID: store.selectedPerformanceID)
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
            HiddenCardsFooter(count: userDataStore.hiddenCardCount(cardTypes: [.goodsCampaign], eventID: store.bundle.event.id)) {
                userDataStore.unhideCards(cardTypes: [.goodsCampaign], eventID: store.bundle.event.id)
                recentlyHidden = nil
            }
        }
        .environment(\.detailCardHideNotification, DetailCardHideNotification { cardType, entityID, title in
            recentlyHidden = (cardType, entityID, title)
        })
    }

    @ViewBuilder
    private func campaignSection(_ title: String, campaigns: [GoodsCampaign], actionsAllowed: Bool) -> some View {
        if !campaigns.isEmpty {
            Text(LocalizedStringKey(title), bundle: .kit)
                .font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ForEach(campaigns) { campaign in campaignCard(campaign, actionsAllowed: actionsAllowed) }
        }
    }

    @ViewBuilder
    private func campaignCard(_ campaign: GoodsCampaign, actionsAllowed: Bool) -> some View {
        let config = userDataStore.effectiveConfiguration(cardType: .goodsCampaign, entityID: campaign.id, eventID: campaign.eventID)
        let canPurchase = actionsAllowed && campaign.status == .confirmed && hasExplicitSelectedScope(campaign.scope)
        let products = store.bundle.products.filter { $0.campaignID == campaign.id }
        let sessions = PerformanceScopeResolver.resolve(
            records: store.bundle.goodsSessions.filter { $0.campaignID == campaign.id },
            selectedPerformanceID: store.selectedPerformanceID,
            stopID: store.stopID(for:)
        )
        let cardKey = TranslationStore.cardKey(eventID: campaign.eventID, cardType: .goodsCampaign, entityID: campaign.id)

        DetailCard(verbatim: campaign.officialName, cardType: .goodsCampaign, entityID: campaign.id, userDataStore: userDataStore, eventID: campaign.eventID, translationSegments: {
            var items = [TranslationRequestItem(id: "campaign|\(campaign.id)|name", text: campaign.officialName)]
            for product in products {
                items.append(TranslationRequestItem(id: "product|\(product.id)|name", text: product.name))
                items += product.variants.map { TranslationRequestItem(id: "product|\(product.id)|variant|\($0.id)|name", text: $0.name) }
            }
            return items
        }) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 7) {
                if campaign.phase != .unknown {
                    Text(LocalizedStringKey(phase(campaign.phase)), bundle: .kit).font(.caption).foregroundStyle(.secondary)
                }

                if config.shows(.time) {
                    if let start = campaign.salesStartAt { LabeledContent { Text(format(start)).monospacedDigit() } label: { Text("销售开始", bundle: .kit) } }
                    if let end = campaign.salesEndAt { LabeledContent { Text(format(end)).monospacedDigit() } label: { Text("销售截止", bundle: .kit) } }
                    if let window = campaign.pickupWindow { LabeledContent { Text(verbatim: window) } label: { Text("领取", bundle: .kit) } }
                    ForEach(sessions.applicable) { session in
                        Text(verbatim: sessionText(session)).font(.footnote)
                    }
                    if !sessions.unconfirmed.isEmpty {
                        DisclosureGroup {
                            ForEach(sessions.unconfirmed) { session in
                                Text(verbatim: sessionText(session)).font(.footnote)
                            }
                        } label: {
                            Text("适用场次待确认的贩售时段", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if config.shows(.place), let location = campaign.location { LabeledContent { Text(verbatim: location) } label: { Text("地点", bundle: .kit) } }

                if config.shows(.eligibility) {
                    if let requiresTicket = campaign.requiresTicket {
                        LabeledContent {
                            Text(requiresTicket ? "需要" : "不需要", bundle: .kit)
                        } label: {
                            Text("需持票", bundle: .kit)
                        }
                    }
                    if let limit = campaign.purchaseLimit { Text("购买限制：\(limit)", bundle: .kit).font(.footnote) }
                }

                if campaign.shippingNote != nil || campaign.paymentMethods != nil {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            if let shipping = campaign.shippingNote { Text("配送：\(shipping)", bundle: .kit).font(.footnote) }
                            if let methods = campaign.paymentMethods { Text("付款方式：\(methods)", bundle: .kit).font(.footnote) }
                        }
                    } label: {
                        Text("购买须知", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if config.shows(.price) {
                    let showsSource = config.shows(.source)
                    if products.count > 5 {
                        ForEach(products.prefix(5)) { product in
                            productView(product, detailed: config.density == .detailed, actionsAllowed: canPurchase, showsSource: showsSource, cardKey: cardKey, eventID: campaign.eventID)
                        }
                        DisclosureGroup {
                            ForEach(products.dropFirst(5)) { product in
                                productView(product, detailed: config.density == .detailed, actionsAllowed: canPurchase, showsSource: showsSource, cardKey: cardKey, eventID: campaign.eventID)
                            }
                        } label: {
                            Text("全部 \(products.count) 件商品", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(products) { product in
                            productView(product, detailed: config.density == .detailed, actionsAllowed: canPurchase, showsSource: showsSource, cardKey: cardKey, eventID: campaign.eventID)
                        }
                    }
                }

                if config.shows(.source) {
                    OfficialLinksView(links: campaign.links, title: "官方贩售链接", prominentFirst: canPurchase, excluding: [], cardKey: cardKey, eventID: campaign.eventID)
                    if let raw = campaign.url, let url = URL(string: raw), !campaign.links.contains(where: { $0.url == raw }) {
                        if canPurchase && campaign.links.isEmpty {
                            Link(destination: url) {
                                Label { Text("查看官方销售页", bundle: .kit) } icon: { Image(systemName: "arrow.up.right.square") }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Link(destination: url) {
                                Label { Text(canPurchase ? "查看官方销售页" : "查看官方来源", bundle: .kit) } icon: { Image(systemName: "arrow.up.right.square") }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                let assets = mediaAssets(for: campaign)
                if let first = assets.first {
                    OfficialMediaView(asset: first, compact: config.density == .compact)
                    if assets.count > 1 {
                        DisclosureGroup {
                            ForEach(assets.dropFirst()) { asset in
                                OfficialMediaView(asset: asset, compact: config.density == .compact)
                            }
                        } label: {
                            Text("查看全部 \(assets.count) 张图片", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func productView(_ product: Product, detailed: Bool, actionsAllowed: Bool, showsSource: Bool, cardKey: String, eventID: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack { productName(product, cardKey: cardKey, eventID: eventID); Spacer(); productPrice(product) }
                VStack(alignment: .leading, spacing: 2) { productName(product, cardKey: cardKey, eventID: eventID); productPrice(product) }
            }
            if let limit = product.purchaseLimit { Text("商品限制：\(limit)", bundle: .kit).font(.caption).foregroundStyle(.secondary) }
            if detailed {
                ForEach(product.variants) { variant in
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(verbatim: "·")
                            OfficialText(variant.name, cardKey: cardKey, eventID: eventID).font(.footnote)
                            Spacer()
                            if let stock = variant.stockStatus { Text(verbatim: stock).font(.caption).foregroundStyle(.secondary) }
                            if let amount = variant.amount { Text(amount.formatted).monospacedDigit().font(.footnote) }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(verbatim: "·")
                                OfficialText(variant.name, cardKey: cardKey, eventID: eventID).font(.footnote)
                            }
                            HStack(spacing: 8) {
                                if let stock = variant.stockStatus { Text(verbatim: stock).font(.caption).foregroundStyle(.secondary) }
                                if let amount = variant.amount { Text(amount.formatted).monospacedDigit().font(.footnote) }
                            }
                            .padding(.leading, 12)
                        }
                    }
                }
            }
            if showsSource, let raw = product.url, let url = URL(string: raw) {
                Link(destination: url) { Text(actionsAllowed ? "商品官方页" : "商品来源", bundle: .kit) }.font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func productName(_ product: Product, cardKey: String, eventID: String) -> some View {
        OfficialText(product.name, cardKey: cardKey, eventID: eventID)
    }

    @ViewBuilder
    private func productPrice(_ product: Product) -> some View {
        Text(product.amount?.formatted ?? String(localized: "价格待核对", bundle: .kit))
            .monospacedDigit()
            .foregroundStyle(.secondary)
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

    private func format(_ date: Date) -> String {
        let timeZone = EventFormatting.timeZone(identifier: store.selectedPerformance?.timeZone ?? store.bundle.event.timeZone, fallback: store.bundle.event.resolvedTimeZone)
        return EventFormatting.dateTime(date, in: timeZone)
    }

    private func phase(_ value: GoodsPhase) -> String {
        switch value { case .pre: "事前"; case .during: "会期"; case .post: "事后"; case .unknown: "批次待核验" }
    }

}
