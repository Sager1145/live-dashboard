import SwiftUI

/// Direct, horizontally scrollable session selection without placeholder stop groups.
public struct PerformanceSelector: View {
    let bundle: LiveEventBundle
    @Binding var selectedPerformanceID: String

    public init(bundle: LiveEventBundle, selectedPerformanceID: Binding<String>) {
        self.bundle = bundle
        self._selectedPerformanceID = selectedPerformanceID
    }

    private var sortedPerformances: [Performance] {
        bundle.performances.sorted { $0.order < $1.order }
    }

    public var body: some View {
        if sortedPerformances.count > 1 {
            HorizontalSelectionStrip(
                title: "场次",
                selection: $selectedPerformanceID,
                options: sortedPerformances.map { performance in
                    HorizontalSelectionOption(value: performance.id, title: label(for: performance))
                }
            )
            .accessibilityIdentifier("performanceSelectionStrip")
        }
    }

    private func label(for performance: Performance) -> String {
        let edition = bundle.editions.first { $0.id == performance.editionID }?.name
        let stop = bundle.stops.first { $0.id == performance.stopID }?.name
        let parts = [edition, stop, performance.localDate ?? performance.rawDate,
                     performance.dayLabel, performance.subtitle]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
