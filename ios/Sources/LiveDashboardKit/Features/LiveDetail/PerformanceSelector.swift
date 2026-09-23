import SwiftUI

/// Session selection: a menu picker for a handful of performances, or a
/// pushed list page once there are too many to fit comfortably in a menu.
public struct PerformanceSelector: View {
    let bundle: LiveEventBundle
    @Binding var selectedPerformanceID: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Above this many performances, a `Menu`-style picker becomes unwieldy;
    /// switch to a pushed list page instead.
    public static let listPageThreshold = 8

    public init(bundle: LiveEventBundle, selectedPerformanceID: Binding<String>) {
        self.bundle = bundle
        self._selectedPerformanceID = selectedPerformanceID
    }

    private var sortedPerformances: [Performance] {
        bundle.performances.sorted { $0.order < $1.order }
    }

    private var selectedPerformance: Performance? {
        sortedPerformances.first { $0.id == selectedPerformanceID }
    }

    public var body: some View {
        if sortedPerformances.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                if sortedPerformances.count > Self.listPageThreshold {
                    Picker(selection: $selectedPerformanceID) {
                        options
                    } label: {
                        Text("场次", bundle: .kit)
                    }
                    .pickerStyle(.navigationLink)
                } else {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        Text("场次", bundle: .kit)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker(selection: $selectedPerformanceID) {
                            options
                        } label: {
                            Text("场次", bundle: .kit)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
                if let selectedPerformance, !subtitleText(for: selectedPerformance).isEmpty {
                    Text(verbatim: subtitleText(for: selectedPerformance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("performancePicker")
        }
    }

    @ViewBuilder
    private var options: some View {
        ForEach(sortedPerformances) { performance in
            Text(verbatim: Self.shortLabel(for: performance, in: bundle)).tag(performance.id)
        }
    }

    private func subtitleText(for performance: Performance) -> String {
        [performance.subtitle, performance.venueName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    public static func shortLabel(for performance: Performance, in bundle: LiveEventBundle) -> String {
        let timeZone = EventFormatting.timeZone(identifier: performance.timeZone ?? bundle.event.timeZone, fallback: bundle.event.resolvedTimeZone)
        let dateText: String?
        if let startAt = performance.startAt {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let includesYear = calendar.component(.year, from: startAt) != calendar.component(.year, from: Date())
            dateText = EventFormatting.date(startAt, in: timeZone, includesYear: includesYear)
        } else {
            dateText = performance.localDate ?? performance.rawDate
        }

        var parts = [dateText]
        if !performance.dayLabel.isEmpty, performance.dayLabel != dateText {
            parts.append(performance.dayLabel)
        }

        let hasMultipleStops = Set(bundle.performances.compactMap(\.stopID)).count > 1
        if hasMultipleStops, let stopName = bundle.stops.first(where: { $0.id == performance.stopID })?.name {
            parts.append(stopName)
        }

        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
