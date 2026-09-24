import SwiftUI
import LiveIngestionCore

public struct SeatingView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    @State private var recentlyHidden: (cardType: CardType, entityID: String, title: String)?

    public init(store: LiveDetailStore, userDataStore: UserDataStore) {
        self.store = store
        self.userDataStore = userDataStore
    }

    public var body: some View {
        let resolved = store.applicableMediaAssets()
        let configurations = userDataStore.effectiveConfigurations(eventID: store.bundle.event.id)
        let applicable = ImportantInformationPolicy.orderedSeatingAssets(
            resolved.applicable.filter(isSeatingAsset),
            configurations: configurations
        )
        let unconfirmed = ImportantInformationPolicy.orderedSeatingAssets(
            resolved.unconfirmed.filter(isSeatingAsset),
            configurations: configurations
        )
        let hiddenCount = userDataStore.hiddenCardCount(cardTypes: [.eventSeatingMap, .venueGenericSeatingMap], eventID: store.bundle.event.id)

        LazyVStack(spacing: 12) {
            ForEach(applicable) { asset in assetCard(asset, readOnly: false) }

            if !unconfirmed.isEmpty {
                Label { Text("适用场次待确认的座位资料", bundle: .kit) } icon: { Image(systemName: "questionmark.circle") }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                ForEach(unconfirmed) { asset in assetCard(asset, readOnly: true) }
            }

            if applicable.isEmpty && unconfirmed.isEmpty {
                // Cards the user hid are filtered out before this point, so an empty
                // tab must not claim the data was never retrieved.
                if resolved.applicable.filter(isSeatingAsset).isEmpty && resolved.unconfirmed.filter(isSeatingAsset).isEmpty {
                    if store.bundle.mediaAssets.contains(where: isSeatingAsset), store.selectedPerformance == nil {
                        ContentUnavailableView {
                            Label { Text("尚无可用场次资料", bundle: .kit) } icon: { Image(systemName: "calendar.badge.exclamationmark") }
                        } description: {
                            Text("官网尚未公布场次，或当前资料来源中没有场次。", bundle: .kit)
                        } actions: {
                            if let url = URL(string: store.bundle.event.primarySourceURL) {
                                Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                            }
                        }
                    } else if store.bundle.mediaAssets.contains(where: isSeatingAsset) {
                        ContentUnavailableView {
                            Label { Text("所选场次暂无座位资料", bundle: .kit) } icon: { Image(systemName: "chair.lounge") }
                        } description: {
                            Text("其他场次有资料，请切换场次查看。", bundle: .kit)
                        } actions: {
                            if let url = URL(string: store.bundle.event.primarySourceURL) {
                                Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                            }
                        }
                    } else {
                        ContentUnavailableView {
                            Label { Text("尚未获取座位资料", bundle: .kit) } icon: { Image(systemName: "chair.lounge") }
                        } actions: {
                            if let url = URL(string: store.bundle.event.primarySourceURL) {
                                Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label { Text("座位卡片已全部隐藏", bundle: .kit) } icon: { Image(systemName: "eye.slash") }
                    } description: {
                        Text("资料已获取，只是这些卡片被你隐藏了。", bundle: .kit)
                    } actions: {
                        Button {
                            userDataStore.unhideCards(cardTypes: [.eventSeatingMap, .venueGenericSeatingMap], eventID: store.bundle.event.id)
                            recentlyHidden = nil
                        } label: {
                            Text("恢复显示", bundle: .kit)
                        }
                    }
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
            if !applicable.isEmpty || !unconfirmed.isEmpty {
                HiddenCardsFooter(count: hiddenCount) {
                    userDataStore.unhideCards(cardTypes: [.eventSeatingMap, .venueGenericSeatingMap], eventID: store.bundle.event.id)
                    recentlyHidden = nil
                }
            }
        }
        .environment(\.detailCardHideNotification, DetailCardHideNotification { cardType, entityID, title in
            recentlyHidden = (cardType, entityID, title)
        })
    }

    @ViewBuilder
    private func assetCard(_ asset: MediaAsset, readOnly: Bool) -> some View {
        let cardType: CardType = asset.kind == .venueGenericSeatingMap ? .venueGenericSeatingMap : .eventSeatingMap
        let config = userDataStore.effectiveConfiguration(cardType: cardType, entityID: asset.id, eventID: asset.eventID)
        DetailCard(title: title(asset), cardType: cardType, entityID: asset.id, userDataStore: userDataStore, eventID: asset.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 8) {
                if asset.kind == .venueGenericSeatingMap {
                    Label { Text("场馆通用图，不代表本次舞台布局", bundle: .kit) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption)
                        .foregroundStyle(.statusWarning)
                }
                if readOnly {
                    Label { Text("适用场次待确认", bundle: .kit) } icon: { Image(systemName: "questionmark.circle") }
                        .font(.caption)
                        .foregroundStyle(.statusWarning)
                }
                OfficialMediaView(asset: asset, compact: config.density == .compact)
            }
        }
    }

    private func isSeatingAsset(_ asset: MediaAsset) -> Bool {
        [.eventSeatingMap, .venueGenericSeatingMap, .standingArea].contains(asset.kind)
    }

    private func title(_ asset: MediaAsset) -> String {
        switch asset.kind {
        case .eventSeatingMap: "本公演座位图"
        case .venueGenericSeatingMap: "场馆通用座位图"
        case .standingArea: "站席／区域资料"
        default: "座位资料"
        }
    }
}
