import SwiftUI

public struct CardSettingsView: View {
    let userDataStore: UserDataStore
    private let fields = CardField.allCases

    public init(userDataStore: UserDataStore) { self.userDataStore = userDataStore }

    public var body: some View {
        List {
            ForEach(Array(CardType.allCases.enumerated()), id: \.element) { index, type in
                let value = configuration(type, order: index)
                DisclosureGroup {
                    Toggle("显示", isOn: visibilityBinding(value))
                    Toggle("置顶", isOn: binding(value, \.isPinned))
                    Picker("密度", selection: binding(value, \.density)) {
                        Text("紧凑").tag(CardDensity.compact)
                        Text("详细").tag(CardDensity.detailed)
                    }
                    .pickerStyle(.segmented)
                    Stepper("顺序：\(value.order + 1)", value: binding(value, \.order), in: 0...100)
                    Section("显示字段") {
                        ForEach(fields, id: \.self) { field in
                            Toggle(isOn: Binding(get: { value.shows(field) }, set: { enabled in
                                var changed = value
                                if !changed.visibleFields.contains(CardField.configuredMarker) {
                                    changed.visibleFields = Set(fields.map(\.rawValue))
                                    changed.visibleFields.insert(CardField.configuredMarker)
                                }
                                if enabled { changed.visibleFields.insert(field.rawValue) } else { changed.visibleFields.remove(field.rawValue) }
                                userDataStore.setConfiguration(changed)
                            })) { Text(LocalizedStringKey(field.rawValue)) }
                        }
                    }
                    Button("恢复此卡片默认设置") { userDataStore.removeConfigurations(cardType: type) }
                } label: { Text(LocalizedStringKey(title(type))) }
            }
        }
        .navigationTitle("全局卡片设置")
    }

    private func configuration(_ type: CardType, order: Int) -> CardConfiguration {
        userDataStore.configuration(cardType: type, entityID: CardConfiguration.globalEntityID)
            ?? CardConfiguration(cardType: type, entityID: CardConfiguration.globalEntityID, order: order)
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
        case .assistantSummary: "AI 整理摘要"
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
