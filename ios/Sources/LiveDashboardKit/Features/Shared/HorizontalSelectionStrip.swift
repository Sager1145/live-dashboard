import SwiftUI
import LiveIngestionCore

struct HorizontalSelectionOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

struct HorizontalSelectionStrip<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [HorizontalSelectionOption<Value>]
    /// When true, the scroll content gets a 16pt leading/trailing margin, so the strip can sit
    /// flush in a full-width row while its chips still align to the screen's 16pt page margin.
    /// Defaults to false so existing (LiveDetail) call sites keep their current look exactly.
    var edgeToEdge: Bool = false
    /// The catalog `title` resolves against. Defaults to the kit's own catalog; callers may
    /// override if their title key lives elsewhere.
    var bundle: Bundle = .kit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        SelectionChip(
                            title: option.title,
                            isSelected: selection == option.value,
                            reduceMotion: reduceMotion
                        ) {
                            selection = option.value
                        }
                        .id(option.value)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .modifier(EdgeToEdgeScrollContent(enabled: edgeToEdge))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title, bundle: bundle))
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, value in
                if reduceMotion {
                    proxy.scrollTo(value, anchor: .center)
                } else {
                    withAnimation(.snappy) { proxy.scrollTo(value, anchor: .center) }
                }
            }
        }
    }
}

/// One capsule chip. Kept as its own view so the selected/unselected styles are chosen by a
/// plain `if`, which the type-checker handles easily (a ternary over two ButtonStyle types does not).
private struct SelectionChip: View {
    let title: String
    let isSelected: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        let button = Button {
            if reduceMotion {
                action()
            } else {
                withAnimation(.snappy) { action() }
            }
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
        }
        .buttonBorderShape(.capsule)
        // Only the newly selected chip's `isSelected` flips to `true`; the previously selected
        // chip's flips to `false` at the same time, so gating on the new value keeps this to
        // one haptic per selection instead of two.
        .sensoryFeedback(.selection, trigger: isSelected) { _, newValue in newValue }
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// Applies the 16pt scroll-content margin only, when `edgeToEdge` is requested, so the modifier
/// chain stays a no-op for call sites that pass the default `false`. Content stays clipped to the
/// frame: this strip can sit right of the year menu, and unclipped chips would be able to scroll
/// under it.
private struct EdgeToEdgeScrollContent: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .contentMargins(.horizontal, 16, for: .scrollContent)
        } else {
            content
        }
    }
}
