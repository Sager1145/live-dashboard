import SwiftUI

struct HorizontalSelectionOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

struct HorizontalSelectionStrip<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [HorizontalSelectionOption<Value>]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        Button {
                            selection = option.value
                        } label: {
                            Text(option.title)
                                .font(.subheadline)
                                .fontWeight(selection == option.value ? .semibold : .regular)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .foregroundStyle(selection == option.value ? Color.white : Color.primary)
                                .background(selection == option.value ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                        .id(option.value)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, value in
                proxy.scrollTo(value, anchor: .center)
            }
        }
    }
}
