import SwiftUI
import UIKit

public struct LiveEventCard: View {
    public let summary: DashboardEventSummary
    public let showsPrice: Bool
    public let isRefreshing: Bool
    /// Past-tab cards render a neutral "已结束" badge instead of the upcoming-tab chrome.
    public let scope: DashboardScope

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(summary: DashboardEventSummary, showsPrice: Bool = true, isRefreshing: Bool = false, scope: DashboardScope = .upcoming) {
        self.summary = summary
        self.showsPrice = showsPrice
        self.isRefreshing = isRefreshing
        self.scope = scope
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashboardThumbnail(summary: summary, isRefreshing: isRefreshing)
                .padding(.bottom, 6)

            if let badgeText = statusBadgeText {
                statusBadge(text: badgeText)
            }

            Text(verbatim: summary.officialTitle)
                .font(.headline)
                .multilineTextAlignment(.leading)

            Text(verbatim: metadataLine)
                .font(.subheadline)

            if !summary.venueSummary.isEmpty {
                Text(verbatim: summary.venueSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !summary.ticketBadges.isEmpty {
                TicketBadgeRow(badges: summary.ticketBadges)
                    .accessibilityHidden(true)
            }

            if summary.nextDeadline != nil || (showsPrice && priceText != nil) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        deadlineLabel
                        priceLabel
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        deadlineLabel
                        Spacer(minLength: 8)
                        priceLabel
                    }
                }
            }

            footerRow

            if summary.hasImportantUpdate {
                importantUpdateBadge
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        // `.accessibilityElement(children: .ignore)` above removes the thumbnail's own
        // accessibility node from the tree, so its identifier has to live on this combined
        // element instead to stay reachable from UI tests.
        .accessibilityIdentifier("liveEventCard-\(summary.id)")
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(isRefreshing ? Text("正在更新", bundle: .kit) : Text(verbatim: ""))
    }

    /// Renders nothing when there's no next deadline, so the horizontal branch's `HStack` and
    /// vertical branch's `VStack` both collapse cleanly instead of leaving a stray gap.
    @ViewBuilder
    private var deadlineLabel: some View {
        if let deadline = summary.nextDeadline {
            Text(verbatim: nextActionText(deadline))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var priceLabel: some View {
        if showsPrice, let priceText {
            Text("\(priceText)起", bundle: .kit)
                .font(.footnote)
        }
    }

    /// Franchise + groups, refresh state and follow state — supplementary info that trails
    /// the ticket/deadline/price content rather than competing with it up top.
    private var footerRow: some View {
        HStack(alignment: .top) {
            Text(verbatim: footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            if summary.isFollowed {
                Text("已关注", bundle: .kit)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }

    private var footerText: String {
        guard !summary.groups.isEmpty else { return franchiseLabel }
        return "\(franchiseLabel) · \(summary.groups.joined(separator: " × "))"
    }

    private var importantUpdateBadge: some View {
        Label {
            Text("有重要更新", bundle: .kit)
        } icon: {
            Image(systemName: "bell.badge")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.statusCritical.opacity(0.18), in: Capsule())
    }

    /// "下一事项：ラウンド名称締切" — factored so the visual label and `accessibilitySummary`
    /// (VoiceOver) render exactly the same text, round label included.
    private func nextActionText(_ deadline: Date) -> String {
        // Official round label is verbatim scraped text, not a localizable string, so it is
        // joined in directly rather than interpolated into a `String(localized:)` key.
        let label = summary.currentRoundLabel.map { $0 + "：" } ?? ""
        return String(localized: "下一事项：\(label)\(deadlineText(deadline))截止", bundle: .kit)
    }

    /// Date range · 共 N 场 · N 站, concatenated into one Text so it wraps as a single
    /// line-breaking unit at accessibility text sizes instead of three separate Texts
    /// fighting for space in an HStack.
    private var metadataLine: String {
        var parts: [String] = []
        if let first = summary.firstLocalDate {
            parts.append(dateRangeText(first: first, last: summary.lastLocalDate))
        } else {
            parts.append(String(localized: "日期待公布", bundle: .kit))
        }
        parts.append(String(localized: "共 \(summary.dayLabels.count) 场", bundle: .kit))
        if summary.stopCount > 1 {
            parts.append(String(localized: "\(summary.stopCount) 站", bundle: .kit))
        }
        return parts.joined(separator: " · ")
    }

    private func dateRangeText(first: String, last: String?) -> String {
        let zone = EventFormatting.timeZone(identifier: summary.timeZoneIdentifier, fallback: .current)
        guard let firstDate = EventFormatting.parseISODate(first, in: zone) else {
            guard let last, last != first else { return first }
            return "\(first) ~ \(last)"
        }
        guard let last, last != first, let lastDate = EventFormatting.parseISODate(last, in: zone) else {
            var zonedCalendar = Calendar(identifier: .gregorian)
            zonedCalendar.timeZone = zone
            let includesYear = scope == .past
                || zonedCalendar.component(.year, from: firstDate) != zonedCalendar.component(.year, from: Date())
            return EventFormatting.date(firstDate, in: zone, includesYear: includesYear)
        }
        return EventFormatting.dateRange(firstDate, lastDate, in: zone)
    }

    private var franchiseLabel: String {
        switch summary.franchise {
        case .bangdream: "BanG Dream!"
        case .lovelive: "Love Live!"
        case .unknown: String(localized: "其他企划", bundle: .kit)
        }
    }

    private var priceText: String? {
        guard let price = summary.minimumPriceJPY else { return nil }
        return EventFormatting.price(price, currencyCode: "JPY")
    }

    private func deadlineText(_ date: Date) -> String {
        let zone = EventFormatting.timeZone(identifier: summary.timeZoneIdentifier, fallback: .current)
        return EventFormatting.dateTime(date, in: zone)
    }

    private var statusBadgeText: String? {
        switch summary.status {
        case .cancelled: String(localized: "已取消", bundle: .kit)
        case .postponed: String(localized: "已延期", bundle: .kit)
        case .finished: scope == .past ? String(localized: "已结束", bundle: .kit) : nil
        case .scheduled, .unknown: nil
        }
    }

    private func statusBadge(text: String) -> some View {
        let isNeutral = summary.status == .finished
        return Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: isNeutral ? "checkmark.circle" : "exclamationmark.triangle.fill")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((isNeutral ? Color.secondary : Color.statusWarning).opacity(isNeutral ? 0.12 : 0.18), in: Capsule())
    }

    /// Everything a VoiceOver user needs from one swipe: title, series/group, status,
    /// ticket-phase badges, date range, venue, next action and its deadline (with time zone),
    /// price, and follow state.
    var accessibilitySummary: String {
        var parts: [String] = [summary.officialTitle]
        if !summary.groups.isEmpty { parts.append(summary.groups.joined(separator: "、")) }
        if let statusBadgeText { parts.append(statusBadgeText) }
        if !summary.ticketBadges.isEmpty { parts.append(summary.ticketBadges.map(\.text).joined(separator: "、")) }
        if let first = summary.firstLocalDate {
            parts.append(dateRangeText(first: first, last: summary.lastLocalDate))
        } else {
            parts.append(String(localized: "日期待公布", bundle: .kit))
        }
        if !summary.venueSummary.isEmpty { parts.append(summary.venueSummary) }
        if let deadline = summary.nextDeadline {
            parts.append(nextActionText(deadline))
        }
        if showsPrice, let priceText { parts.append(String(localized: "\(priceText)起", bundle: .kit)) }
        if summary.hasImportantUpdate { parts.append(String(localized: "有重要更新", bundle: .kit)) }
        if summary.isFollowed { parts.append(String(localized: "已关注", bundle: .kit)) }
        return parts.joined(separator: "，")
    }
}

/// Row of event-level ticket-phase chips (抽选中 / 一般贩售中 / 已售罄 etc).
private struct TicketBadgeRow: View {
    let badges: [TicketPhaseBadge]

    var body: some View {
        FlowLayout {
            ForEach(badges) { badge in
                Text(verbatim: badge.text)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.primary)
                    .background(color(for: badge.tone).opacity(0.18), in: Capsule())
            }
        }
    }

    private func color(for tone: TicketPhaseBadge.Tone) -> Color {
        switch tone {
        case .open: .statusPositive
        case .upcoming: .statusInfo
        case .closed: .secondary
        case .soldOut: .statusCritical
        }
    }
}

/// Loads through `OfficialImagePipeline` (same request headers and cache as the detail
/// gallery) instead of an unconfigured AsyncImage.
private struct DashboardThumbnail: View {
    let summary: DashboardEventSummary
    let isRefreshing: Bool
    // Tuples aren't Equatable so `.task(id:)`/state can't key on `(url, image)` directly; these
    // three states play that role instead, keeping the displayed image tied to its own URL so a
    // stale image from a previous `summary` never flashes before the new one loads.
    @State private var image: UIImage?
    @State private var imageURL: URL?
    @State private var failedURL: URL?
    /// Bumped when a per-card refresh finishes after a failed load, so `.task(id:)` reruns and
    /// retries even though the candidate URLs themselves haven't changed.
    @State private var retryToken = 0

    private struct TaskID: Hashable {
        let urls: [URL]
        let retryToken: Int
    }

    /// Thumbnail URL first, then the original asset URL as a fallback (mirrors
    /// `OfficialMediaView.loadPreview`'s candidate order).
    private var candidateURLs: [URL] {
        guard let asset = summary.officialThumbnail else { return [] }
        var urls: [URL] = []
        if let thumbnail = asset.thumbnailURL.flatMap(URL.init(string:)) { urls.append(thumbnail) }
        if let original = URL(string: asset.originalURL), !urls.contains(original) { urls.append(original) }
        return urls
    }

    private var displayedImage: UIImage? {
        guard let imageURL, candidateURLs.contains(imageURL) else { return nil }
        return image
    }

    private var isFailed: Bool {
        guard let failedURL else { return false }
        return candidateURLs.contains(failedURL)
    }

    var body: some View {
        LinearGradient(colors: [Color(uiColor: .tertiarySystemFill), Color(uiColor: .quaternarySystemFill)], startPoint: .topLeading, endPoint: .bottomTrailing)
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        // The cover fills the reserved bounds without contributing to card sizing.
        .overlay {
            GeometryReader { geometry in
                if let displayedImage {
                    // `.scaledToFit()` keeps the whole poster visible (including any text near
                    // its edges) instead of cropping it to fill the 16:9 frame.
                    Image(uiImage: displayedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                } else {
                    placeholder
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .motionAnimation(displayedImage != nil)
        // Label and identifier are dead here: the card's `.accessibilityElement(children:
        // .ignore)` drops this subview from the accessibility tree entirely, so both now live
        // on the card's own combined element instead.
        .task(id: TaskID(urls: candidateURLs, retryToken: retryToken)) {
            let urls = candidateURLs
            guard !urls.isEmpty else { image = nil; imageURL = nil; return }
            if let imageURL, urls.contains(imageURL) { return } // already loaded, avoid a flash on re-appear
            for url in urls {
                guard let loaded = try? await OfficialImagePipeline.shared.image(for: url, maxPixelSize: 1200) else { continue }
                guard !Task.isCancelled else { return }
                image = loaded
                imageURL = url
                failedURL = nil
                return
            }
            if !Task.isCancelled { failedURL = urls.last }
        }
        // A per-card refresh that just finished retries a previously failed image even though
        // its candidate URLs haven't changed.
        .onChange(of: isRefreshing) { wasRefreshing, nowRefreshing in
            if wasRefreshing, !nowRefreshing, isFailed { retryToken += 1 }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            // The `.task(id:)` above reruns whenever this view reappears with the same
            // failed URLs, which doubles as the retry — no separate retry action needed.
            Image(systemName: isFailed ? "photo.badge.exclamationmark" : "music.note")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            if let series = summary.groups.first {
                Text(verbatim: series)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The cover image URL a card can share, when the event has an official thumbnail.
extension DashboardEventSummary {
    public var coverURL: URL? {
        guard let asset = officialThumbnail else { return nil }
        return URL(string: asset.originalURL) ?? asset.thumbnailURL.flatMap(URL.init(string:))
    }
}
