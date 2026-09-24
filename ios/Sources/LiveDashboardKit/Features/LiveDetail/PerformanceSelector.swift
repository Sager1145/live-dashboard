import SwiftUI
import LiveIngestionCore

public struct PerformanceSessionRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let localDate: String
    public let sessionLabel: String
    public let venueName: String

    public var label: String {
        [localDate, sessionLabel, venueName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Session selection: a menu picker for a handful of performances, or a
/// pushed list page once there are too many to fit comfortably in a menu.
public struct PerformanceSelector: View {
    let bundle: LiveEventBundle
    @Binding var selectedPerformanceID: String
    var selectedLocalDate: Binding<String>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Above this many performances, a `Menu`-style picker becomes unwieldy;
    /// switch to a pushed list page instead.
    public static let listPageThreshold = 8

    public init(bundle: LiveEventBundle, selectedPerformanceID: Binding<String>, selectedLocalDate: Binding<String>? = nil) {
        self.bundle = bundle
        self._selectedPerformanceID = selectedPerformanceID
        self.selectedLocalDate = selectedLocalDate
    }

    private var sortedPerformances: [Performance] {
        bundle.performances.sorted { $0.order < $1.order }
    }

    private var selectedPerformance: Performance? {
        sortedPerformances.first { $0.id == selectedPerformanceID }
    }

    private var dates: [String] {
        var seen: Set<String> = []
        var values: [String] = []
        for performance in sortedPerformances {
            guard let start = performance.localDate else { continue }
            let end = performance.localEndDate ?? start
            var day = start
            while day <= end {
                if seen.insert(day).inserted { values.append(day) }
                guard let next = Self.nextDay(day), next != day else { break }
                day = next
                if values.count > 400 { break }
            }
        }
        return values.sorted()
    }

    private var performancesOnDate: [Performance] {
        guard let date = selectedLocalDate?.wrappedValue, !date.isEmpty else { return sortedPerformances }
        return sortedPerformances.filter { $0.covers(localDate: date) }
    }

    public var body: some View {
        if sortedPerformances.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                if let selectedLocalDate, dates.count > 1 {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        Text("日期", bundle: .kit)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker(selection: selectedLocalDate) {
                            ForEach(dates, id: \.self) { date in
                                Text(verbatim: date).tag(date)
                            }
                        } label: {
                            Text("日期", bundle: .kit)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    .accessibilityIdentifier("datePicker")
                }
                if performancesOnDate.count > 1 {
                    if performancesOnDate.count > Self.listPageThreshold {
                        Picker(selection: $selectedPerformanceID) {
                            options
                        } label: {
                            Text("场馆", bundle: .kit)
                        }
                        .pickerStyle(.navigationLink)
                    } else {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(spacing: 8))
                        layout {
                            Text("场馆", bundle: .kit)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Picker(selection: $selectedPerformanceID) {
                                options
                            } label: {
                                Text("场馆", bundle: .kit)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                } else if performancesOnDate.isEmpty {
                    Text("这一天没有仍在进行的会期", bundle: .kit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private static func nextDay(_ day: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day), let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return formatter.string(from: next)
    }

    private var visibleSessionRows: [PerformanceSessionRow] {
        let allowed = Set(performancesOnDate.map(\.id))
        return Self.sessionRows(in: bundle).filter { allowed.contains($0.id) }
    }

    @ViewBuilder
    private var options: some View {
        if selectedPerformanceID.isEmpty {
            Text("请选择场馆", bundle: .kit).tag("")
        }
        ForEach(visibleSessionRows) { row in
            Text(verbatim: row.label).tag(row.id)
        }
    }

    /// One row per performance id. Same-day day and night shows stay two rows:
    /// date, day/night (or session) label, and venue. Rows are not keyed by the date string.
    public static func sessionRows(in bundle: LiveEventBundle) -> [PerformanceSessionRow] {
        bundle.performances.sorted { $0.order < $1.order }.map { performance in
            let sessionParts = [performance.dayLabel, performance.subtitle ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var seen = Set<String>()
            let sessionLabel = sessionParts.filter { seen.insert($0).inserted }.joined(separator: " · ")
            let date = performance.localDate ?? performance.rawDate ?? ""
            return PerformanceSessionRow(
                id: performance.id,
                localDate: date,
                sessionLabel: sessionLabel,
                venueName: performance.venueName
            )
        }
    }

    public static func optionLabel(for performance: Performance, in bundle: LiveEventBundle, dateAlreadyShown: Bool) -> String {
        guard dateAlreadyShown else { return shortLabel(for: performance, in: bundle) }
        var parts: [String] = []
        switch performance.activityKind {
        case .exhibition: parts.append("展览")
        case .handover: parts.append("お渡し会")
        case .performance, nil:
            if !performance.dayLabel.isEmpty { parts.append(performance.dayLabel) }
            if let subtitle = performance.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        }
        if !performance.venueName.isEmpty { parts.append(performance.venueName) }
        let label = parts.joined(separator: " · ")
        return label.isEmpty ? shortLabel(for: performance, in: bundle) : label
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
        let venues = Set(bundle.performances.map(\.venueName).filter { !$0.isEmpty })
        if venues.count > 1, !performance.venueName.isEmpty {
            parts.append(performance.venueName)
        }

        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
