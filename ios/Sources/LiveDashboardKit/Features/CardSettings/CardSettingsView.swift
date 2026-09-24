import SwiftUI
import LiveIngestionCore

/// Global (cross-event) card layout settings, grouped by the tab each card
/// type belongs to. Only the Overview tab's cards are true singletons (one
/// instance per event, keyed by `CardConfiguration.globalEntityID`), so only
/// that group supports reordering and pinning; the other tabs hold one card
/// per record and only expose visibility/density/field overrides here.
public struct CardSettingsView: View {
    let userDataStore: UserDataStore

    @State private var overviewOrder: [CardType] = ImportantInformationPolicy.overviewDefaultOrder
    @State private var restoreTarget: CardType?

    private static let ticketsTypes: [CardType] = [.ticketRound, .streamOffer, .ticketBenefit]
    private static let seatingTypes: [CardType] = [.eventSeatingMap, .venueGenericSeatingMap]
    private static let goodsTypes: [CardType] = [.goodsCampaign]

    public init(userDataStore: UserDataStore) {
        self.userDataStore = userDataStore
    }

    public var body: some View {
        List {
            Section {
                ForEach(overviewOrder, id: \.self) { type in
                    row(for: type, order: overviewOrder.firstIndex(of: type) ?? 0, reorderable: true)
                }
                .onMove { indices, destination in
                    overviewOrder.move(fromOffsets: indices, toOffset: destination)
                    userDataStore.reorderGlobalConfigurations(overviewOrder)
                }
            } header: {
                Text("总览", bundle: .kit)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("置顶的卡片始终排在最前，其余按此顺序显示。", bundle: .kit)
                    Text("以上为全局默认设置，单场公演可在其详情页的卡片菜单中单独覆盖。", bundle: .kit)
                }
            }

            Section {
                ForEach(Self.ticketsTypes, id: \.self) { type in
                    row(for: type, order: 0, reorderable: false)
                }
            } header: {
                Text("售票", bundle: .kit)
            }

            Section {
                ForEach(Self.seatingTypes, id: \.self) { type in
                    row(for: type, order: 0, reorderable: false)
                }
            } header: {
                Text("座位图", bundle: .kit)
            }

            Section {
                ForEach(Self.goodsTypes, id: \.self) { type in
                    row(for: type, order: 0, reorderable: false)
                }
            } header: {
                Text("周边", bundle: .kit)
            }
        }
        .navigationTitle(Text("全局卡片设置", bundle: .kit))
        .toolbar { EditButton() }
        .onAppear { reloadOverviewOrder() }
        .confirmationDialog(
            Text("恢复此卡片默认设置？", bundle: .kit),
            isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button {
                if let type = restoreTarget {
                    userDataStore.restoreCardTypeDefaults(type)
                    reloadOverviewOrder()
                }
                restoreTarget = nil
            } label: {
                Text("恢复默认", bundle: .kit)
            }
            Button(role: .cancel) { restoreTarget = nil } label: {
                Text("取消", bundle: .kit)
            }
        } message: {
            Text("将恢复显示、显示密度、字段及置顶设置，并清除该卡片在各场演出中的单独覆盖。", bundle: .kit)
        }
    }

    private func reloadOverviewOrder() {
        let configs = ImportantInformationPolicy.overviewDefaultOrder.enumerated().map { index, type in
            (type, userDataStore.globalConfiguration(cardType: type, defaultOrder: index))
        }
        overviewOrder = configs
            .sorted { lhs, rhs in
                if lhs.1.isPinned != rhs.1.isPinned { return lhs.1.isPinned && !rhs.1.isPinned }
                return lhs.1.order < rhs.1.order
            }
            .map(\.0)
    }

    @ViewBuilder
    private func row(for type: CardType, order: Int, reorderable: Bool) -> some View {
        let value = userDataStore.globalConfiguration(cardType: type, defaultOrder: order)
        DisclosureGroup {
            Toggle(isOn: visibilityBinding(value)) { Text("显示", bundle: .kit) }
                .accessibilityIdentifier("cardVisibilityToggle-\(type.rawValue)")
            if reorderable {
                Toggle(isOn: binding(value, \.isPinned)) { Text("置顶", bundle: .kit) }
            }
            LabeledContent {
                Picker(selection: binding(value, \.density)) {
                    Text("精简", bundle: .kit).tag(CardDensity.compact)
                    Text("完整", bundle: .kit).tag(CardDensity.detailed)
                } label: {
                    Text("密度", bundle: .kit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } label: {
                Text("密度", bundle: .kit)
            }
            let fields = Self.offeredFields(for: type)
            if !fields.isEmpty {
                fieldTogglesSection(value, fields: fields)
            }
            Button {
                restoreTarget = type
            } label: {
                Text("恢复本卡片默认设置", bundle: .kit)
            }
        } label: {
            HStack {
                Text(LocalizedStringKey(title(type)), bundle: .kit)
                Spacer()
                let summary = nonDefaultSummary(value, reorderable: reorderable)
                if !summary.isEmpty {
                    Text(summary.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            // Identifier lives on the label only (not the whole DisclosureGroup): in a List,
            // an identifier on the group propagates to its children and can shadow the inner
            // Toggle's own identifier once expanded.
            .accessibilityIdentifier("cardSettingsGroup-\(type.rawValue)")
        }
    }

    /// Trailing summary shown on the collapsed row for any non-default state,
    /// reusing the exact wording the sub-controls use (隐藏/精简/置顶) so the
    /// collapsed and expanded copy never drift apart.
    private func nonDefaultSummary(_ value: CardConfiguration, reorderable: Bool) -> [String] {
        var parts: [String] = []
        if value.isHidden { parts.append(String(localized: "隐藏", bundle: .kit)) }
        if value.density == .compact { parts.append(String(localized: "精简", bundle: .kit)) }
        if reorderable && value.isPinned { parts.append(String(localized: "置顶", bundle: .kit)) }
        return parts
    }

    /// Field toggles for one card type. This is `CardType.supportedFields`
    /// (the keys that card's view actually passes to `shows(_:)`), not
    /// `CardField.allCases`.
    static func offeredFields(for type: CardType) -> [CardField] {
        type.supportedFields
    }

    @ViewBuilder
    private func fieldTogglesSection(_ value: CardConfiguration, fields: [CardField]) -> some View {
        ForEach(fields, id: \.self) { field in
            Toggle(isOn: Binding(
                get: { value.shows(field) },
                set: { enabled in
                    var changed = value
                    changed.setShows(field, enabled: enabled)
                    userDataStore.setConfiguration(changed)
                }
            )) {
                Text(LocalizedStringKey(field.rawValue), bundle: .kit)
            }
        }
    }

    private func binding<Value>(_ value: CardConfiguration, _ keyPath: WritableKeyPath<CardConfiguration, Value>) -> Binding<Value> {
        Binding(get: { value[keyPath: keyPath] }, set: { newValue in
            var changed = value
            changed[keyPath: keyPath] = newValue
            userDataStore.setConfiguration(changed)
        })
    }

    private func visibilityBinding(_ value: CardConfiguration) -> Binding<Bool> {
        Binding(get: { !value.isHidden }, set: { isVisible in var changed = value; changed.isHidden = !isVisible; userDataStore.setConfiguration(changed) })
    }

    private func title(_ type: CardType) -> String {
        switch type {
        case .assistantSummary: "AI 整理结果"
        case .timeAndVenue: "时间与会场"
        case .performers: "出演"
        case .pricing: "票价"
        case .admission: "入场条件"
        case .ticketRound: "售票轮次"
        case .streamOffer: "配信"
        case .ticketBenefit: "票券特典"
        case .eventSeatingMap: "公演座位图"
        case .venueGenericSeatingMap: "场馆座位图"
        case .goodsCampaign: "周边批次"
        }
    }
}

extension CardType: CaseIterable {
    public static var allCases: [CardType] { [.assistantSummary, .timeAndVenue, .performers, .pricing, .admission, .ticketRound, .streamOffer, .ticketBenefit, .eventSeatingMap, .venueGenericSeatingMap, .goodsCampaign] }
}
