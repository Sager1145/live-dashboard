import SwiftUI

public struct SeatingView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore

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

        LazyVStack(spacing: 12) {
            ForEach(applicable) { asset in assetCard(asset, readOnly: false) }

            if !unconfirmed.isEmpty {
                Text("适用场次待确认的座位资料").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(unconfirmed) { asset in assetCard(asset, readOnly: true) }
            }

            if applicable.isEmpty && unconfirmed.isEmpty {
                // Cards the user hid are filtered out before this point, so an empty
                // tab must not claim the data was never retrieved.
                if resolved.applicable.filter(isSeatingAsset).isEmpty && resolved.unconfirmed.filter(isSeatingAsset).isEmpty {
                    ContentUnavailableView("尚未获取座位资料", systemImage: "chair.lounge")
                } else {
                    ContentUnavailableView {
                        Label("座位卡片已全部隐藏", systemImage: "eye.slash")
                    } description: {
                        Text("资料已获取，只是这些卡片被你隐藏了。")
                    } actions: {
                        Button("恢复显示") {
                            userDataStore.unhideCards(cardTypes: [.eventSeatingMap, .venueGenericSeatingMap], eventID: store.bundle.event.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func assetCard(_ asset: MediaAsset, readOnly: Bool) -> some View {
        let cardType: CardType = asset.kind == .venueGenericSeatingMap ? .venueGenericSeatingMap : .eventSeatingMap
        let config = userDataStore.effectiveConfiguration(cardType: cardType, entityID: asset.id, eventID: asset.eventID)
        DetailCard(title: title(asset), cardType: cardType, entityID: asset.id, userDataStore: userDataStore, eventID: asset.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 8) {
                if asset.kind == .venueGenericSeatingMap {
                    Text("场馆通用图，不代表本次舞台布局").font(.caption).foregroundStyle(.orange)
                }
                if readOnly {
                    Text("适用场次待确认").font(.caption).foregroundStyle(.orange)
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
