import SwiftUI
import UIKit
import ImageIO

public struct LiveEventCard: View {
    public let summary: DashboardEventSummary
    public let showsPrice: Bool

    public init(summary: DashboardEventSummary, showsPrice: Bool = true) {
        self.summary = summary
        self.showsPrice = showsPrice
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashboardThumbnail(summary: summary)
                .padding(.bottom, 6)
            HStack {
                Text(franchiseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if summary.isFollowed {
                    Text("已关注")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }

            Text(summary.officialTitle)
                .font(.headline)
                .multilineTextAlignment(.leading)

            if !summary.ticketBadges.isEmpty {
                TicketBadgeRow(badges: summary.ticketBadges)
                    .accessibilityIdentifier("ticketBadges-\(summary.id)")
            }

            if !summary.groups.isEmpty {
                Text(summary.groups.joined(separator: " × "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if summary.status == .cancelled || summary.status == .postponed {
                Label(summary.status == .cancelled ? "已取消" : "已延期", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            HStack {
                if let first = summary.firstLocalDate {
                    Text(dateRangeText(first: first, last: summary.lastLocalDate))
                } else {
                    Text("日期待公布")
                }
                Text("· 共 \(summary.dayLabels.count) 场")
                if summary.stopCount > 1 {
                    Text("· \(summary.stopCount) 站")
                }
            }
            .font(.subheadline)

            if !summary.venueSummary.isEmpty {
                Text(summary.venueSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let deadline = summary.nextDeadline {
                    Text("下一事项：\(deadlineText(deadline))截止")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showsPrice, let price = summary.minimumPriceJPY {
                    Text("¥\(price)起")
                        .font(.footnote)
                }
            }

            HStack {
                ForEach(uniqueDayLabels, id: \.self) { label in
                    Text(label)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if summary.hasImportantUpdate {
                    Text("有重要更新")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var uniqueDayLabels: [String] {
        var seen = Set<String>()
        return summary.dayLabels.filter { seen.insert($0).inserted }
    }

    private func dateRangeText(first: String, last: String?) -> String {
        guard let last, last != first else { return first }
        return "\(first) ~ \(last)"
    }

    private var franchiseLabel: String {
        switch summary.franchise {
        case .bangdream: "BanG Dream!"
        case .lovelive: "Love Live!"
        case .unknown: String(localized: "其他企划", bundle: .kit)
        }
    }

    private func deadlineText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: summary.timeZoneIdentifier)
        return formatter.string(from: date)
    }
}

/// Row of event-level ticket-phase chips (抽选中 / 一般贩售中 / 已售罄 etc).
private struct TicketBadgeRow: View {
    let badges: [TicketPhaseBadge]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges) { badge in
                Text(badge.text)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(color(for: badge.tone))
                    .background(color(for: badge.tone).opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }
        }
    }

    private func color(for tone: TicketPhaseBadge.Tone) -> Color {
        switch tone {
        case .open: .green
        case .upcoming: .blue
        case .closed: .secondary
        case .soldOut: .red
        }
    }
}

/// Uses the same official request headers as the detail gallery (including
/// Love Live's image.php compatibility), rather than an unconfigured AsyncImage.
private struct DashboardThumbnail: View {
    let summary: DashboardEventSummary
    private var asset: MediaAsset? { summary.officialThumbnail }
    @State private var image: UIImage?
    private let loader = URLSessionOfficialMediaLoader()

    /// The event's official page; the share button shares this link, not the image.
    private var officialURL: URL? {
        guard let url = URL(string: summary.primarySourceURL), url.scheme != nil else { return nil }
        return url
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                coverPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(image == nil ? "\(summary.officialTitle)，默认封面" : "\(summary.officialTitle)，官方公演封面")
        .accessibilityIdentifier("officialThumbnail-\(summary.id)")
        .overlay(alignment: .topTrailing) {
            if let officialURL {
                ShareLink(item: officialURL, subject: Text(summary.officialTitle), message: Text(summary.officialTitle)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.footnote)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .background(.thinMaterial, in: Circle())
                .padding(6)
                .accessibilityIdentifier("thumbnailShare-\(summary.id)")
                .accessibilityLabel("分享官方链接")
            }
        }
        .task(id: asset) {
            image = nil
            guard let asset else { return }
            let candidates = [asset.thumbnailURL, asset.originalURL].compactMap { $0 }.compactMap(URL.init(string:))
            for url in candidates {
                guard !Task.isCancelled else { return }
                if let response = try? await loader.load(url), let decoded = Self.thumbnail(from: response.data) {
                    guard !Task.isCancelled else { return }
                    image = decoded
                    return
                }
            }
        }
    }

    private var coverPlaceholder: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: summary.franchise == .bangdream
                    ? [Color(red: 0.38, green: 0.08, blue: 0.22), Color(red: 0.13, green: 0.12, blue: 0.30)]
                    : [Color(red: 0.10, green: 0.23, blue: 0.48), Color(red: 0.31, green: 0.14, blue: 0.43)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 100, weight: .light))
                .foregroundStyle(.white.opacity(0.12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 24)
            VStack(alignment: .leading, spacing: 8) {
                Label("LIVE", systemImage: "waveform")
                    .font(.caption.bold())
                    .tracking(2)
                Text(summary.officialTitle)
                    .font(.headline)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .accessibilityHidden(true)
    }

    private static func thumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960,
            ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
