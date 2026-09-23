import Foundation

enum OfficialWebsiteHeaders {
    // The public Love Live CDN serves a generic 403 page to app-only agents,
    // including for image.php. Keep the same compatibility signature for both
    // HTML and original images, while identifying the app explicitly.
    static func compatibleUserAgent(for url: URL) -> String? {
        guard url.host == "www.lovelive-anime.jp" || url.host == "lovelive-anime.jp" else { return nil }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1 LiveDashboard/1.0"
    }
}

public protocol OfficialEventScraping: Sendable {
    func collect(existing: [LiveEventBundle], cutoff: String, now: Date) async throws -> [LiveEventBundle]
    func collect(existing: [LiveEventBundle], window: OfficialDateWindow, now: Date) async throws -> [LiveEventBundle]
    func collect(event: LiveEventBundle, now: Date) async throws -> LiveEventBundle
}

public extension OfficialEventScraping {
    func collect(existing: [LiveEventBundle], cutoff: String, now: Date) async throws -> [LiveEventBundle] {
        try await collect(existing: existing, window: .cutoff(cutoff), now: now)
    }
}

/// An inclusive yyyy-MM-dd date range used to select official events for a
/// manual refresh. `end == nil` means an open-ended daily refresh (everything
/// from `start` onwards, matching the previous `cutoff` behaviour).
public struct OfficialDateWindow: Hashable, Sendable {
    public let start: String
    public let end: String?

    public init(start: String, end: String? = nil) {
        self.start = start
        self.end = end
    }

    public static func cutoff(_ start: String) -> OfficialDateWindow { .init(start: start, end: nil) }

    /// true when any date in `dates` is within [start, end].
    public func overlaps(_ dates: [String]) -> Bool {
        dates.contains { contains($0) }
    }

    public func contains(_ date: String) -> Bool {
        date >= start && (end == nil || date <= end!)
    }

    /// true when the span [min, max] of `dates` intersects [start, end]. Index
    /// summaries usually list only the first and last day of a tour, so a tour
    /// whose middle stops fall inside the window must still be considered.
    public func spanOverlaps(_ dates: [String]) -> Bool {
        guard let first = dates.min(), let last = dates.max() else { return false }
        return last >= start && (end == nil || first <= end!)
    }

    /// A bundle overlaps when performances are empty, any localDate is nil, or
    /// any localDate is inside the window.
    public func overlaps(_ bundle: LiveEventBundle) -> Bool {
        guard !bundle.performances.isEmpty else { return true }
        let dates = bundle.performances.map(\.localDate)
        if dates.contains(where: { $0 == nil }) { return true }
        return overlaps(dates.compactMap { $0 })
    }
}

public struct OfficialScrapeFailure: Error, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case fetch
        case unsupportedTemplate = "unsupported_template"
        case invalidResponse = "invalid_response"
    }

    public let url: URL
    public let kind: Kind
    public let message: String

    public init(url: URL, kind: Kind, message: String) {
        self.url = url
        self.kind = kind
        self.message = message
    }
}

public enum OfficialEventScraperError: Error, Sendable {
    case invalidCutoff(String)
    /// At least one source failed, but `partialBundles` contains every event that was
    /// parsed successfully (plus the prior cached value for a failed detail page).
    case partialFailure(partialBundles: [LiveEventBundle], failures: [OfficialScrapeFailure])
}

extension OfficialEventScraperError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCutoff(let value):
            return "刷新日期格式无效：\(value)"
        case .partialFailure(let bundles, let failures):
            let hosts = Array(Set(failures.compactMap(\.url.host))).sorted().joined(separator: "、")
            return "官网刷新部分失败（成功 \(bundles.count) 项，失败 \(failures.count) 项）\(hosts.isEmpty ? "" : "：\(hosts)")"
        }
    }
}

public struct OfficialEventScraper: OfficialEventScraping, Sendable {
    public static let officialIndexURLs: [URL] = [
        URL(string: "https://bang-dream.com/events/")!,
        URL(string: "https://www.lovelive-anime.jp/uranohoshi/live.php")!,
        URL(string: "https://www.lovelive-anime.jp/nijigasaki/live.php")!,
        URL(string: "https://www.lovelive-anime.jp/yuigaoka/live/")!,
        URL(string: "https://www.lovelive-anime.jp/hasunosora/live-event/")!,
        URL(string: "https://www.lovelive-anime.jp/lovehigh/live/")!,
    ]

    private let session: URLSession
    private let indexURLs: [URL]

    public init(session: URLSession = .shared, indexURLs: [URL] = Self.officialIndexURLs) {
        self.session = session
        self.indexURLs = indexURLs
    }

    public func collect(existing: [LiveEventBundle], cutoff: String, now: Date) async throws -> [LiveEventBundle] {
        try await collect(existing: existing, window: .cutoff(cutoff), now: now)
    }

    public func collect(existing: [LiveEventBundle], window: OfficialDateWindow, now: Date) async throws -> [LiveEventBundle] {
        let cutoff = window.start
        guard Self.validDate(cutoff) != nil else { throw OfficialEventScraperError.invalidCutoff(cutoff) }
        if let end = window.end {
            guard Self.validDate(end) != nil else { throw OfficialEventScraperError.invalidCutoff(end) }
            guard end >= cutoff else { throw OfficialEventScraperError.invalidCutoff("\(cutoff)…\(end)") }
        }
        let isRanged = window.end != nil

        let existingByURL = Dictionary(existing.map { (Self.canonicalURL($0.event.primarySourceURL), $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [String: EventCandidate] = [:]
        var failures: [OfficialScrapeFailure] = []

        var pendingIndexURLs = indexURLs
        var visitedIndexURLs: Set<String> = []
        while !pendingIndexURLs.isEmpty {
            let sourceURL = pendingIndexURLs.removeFirst()
            guard visitedIndexURLs.insert(Self.canonicalURL(sourceURL.absoluteString)).inserted else { continue }
            do {
                let page = try await fetch(sourceURL)
                let parsed = try Self.parseIndex(page.html, finalURL: page.url)
                for candidate in parsed {
                    let key = Self.canonicalURL(candidate.url.absoluteString)
                    if let prior = candidates[key] {
                        candidates[key] = prior.merging(candidate)
                    } else {
                        candidates[key] = candidate
                    }
                }
                // BanG Dream is newest-first and paginated. Follow `next` rather
                // than a fixed page count, stopping only after an entirely dated
                // page falls before the requested window.
                let pageDates = parsed.compactMap(\ .lastKnownDate)
                let pageHasUnknownDate = parsed.contains { $0.lastKnownDate == nil }
                if pageHasUnknownDate || pageDates.max().map({ $0 >= cutoff }) != false,
                   let next = Self.nextOfficialIndexURL(page.html, relativeTo: page.url) {
                    pendingIndexURLs.append(next)
                }
            } catch let failure as OfficialScrapeFailure {
                failures.append(failure)
            } catch {
                failures.append(.init(url: sourceURL, kind: .fetch, message: String(describing: error)))
            }
        }

        var bundles: [LiveEventBundle] = []
        // A branch list can be temporarily truncated or remove an event before its
        // final performance. Keep every active/unknown cached URL in the refresh set.
        // In ranged mode use only what the index pages returned.
        if !isRanged {
            for bundle in existing where !LocalRefreshPolicy.isArchived(bundle, cutoff: cutoff) {
                guard let url = URL(string: bundle.event.primarySourceURL) else { continue }
                let key = Self.canonicalURL(url.absoluteString)
                if candidates[key] == nil {
                    candidates[key] = EventCandidate(
                        url: url, franchise: bundle.event.franchise, title: bundle.event.officialTitle,
                        eventType: bundle.event.eventType, scheduleRaw: nil, venueRaw: nil,
                        groups: bundle.event.groups, coverURL: nil, coverSourceURL: nil
                    )
                }
            }
        }
        for candidate in candidates.values.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) {
            let key = Self.canonicalURL(candidate.url.absoluteString)
            let cached = existingByURL[key]
            // In ranged mode a cached archived event inside the range is re-fetched
            // (explicit manual refresh, like `collect(event:now:)`).
            if !isRanged, let cached, LocalRefreshPolicy.isArchived(cached, cutoff: cutoff) { continue }
            let summaryDates = Self.parseSchedules(candidate.scheduleRaw).map(\.localDate)
            if cached == nil || isRanged, !summaryDates.isEmpty, !window.spanOverlaps(summaryDates) {
                // The list page is authoritative enough to reject an archived item. In
                // particular, do not re-download hundreds of already cached old details.
                continue
            }
            if isRanged, summaryDates.isEmpty, let cached, !window.overlaps(cached) { continue }

            do {
                let detail = try await fetch(candidate.url)
                let parsed = try Self.parseDetail(detail.html, finalURL: detail.url, candidate: candidate, cached: cached, now: now)
                let detailDates = parsed.performances.compactMap(\.localDate)
                if !detailDates.isEmpty, !window.overlaps(detailDates) { continue }
                if detailDates.isEmpty, !summaryDates.isEmpty, !window.spanOverlaps(summaryDates) { continue }
                bundles.append(parsed)
            } catch let failure as OfficialScrapeFailure {
                failures.append(failure)
                if let cached, window.overlaps(cached) {
                    bundles.append(cached.replacingSourceHealth(failure.kind == .unsupportedTemplate ? .parseFailed : .fetchFailed))
                }
            } catch {
                failures.append(.init(url: candidate.url, kind: .fetch, message: String(describing: error)))
                if let cached, window.overlaps(cached) { bundles.append(cached) }
            }
        }

        bundles = Dictionary(bundles.map { ($0.event.id, $0) }, uniquingKeysWith: { newer, _ in newer })
            .values.sorted { $0.event.officialTitle.localizedStandardCompare($1.event.officialTitle) == .orderedAscending }
        if !failures.isEmpty {
            throw OfficialEventScraperError.partialFailure(partialBundles: bundles, failures: failures)
        }
        return bundles
    }

    public func collect(event: LiveEventBundle, now: Date) async throws -> LiveEventBundle {
        guard let url = URL(string: event.event.primarySourceURL) else {
            throw OfficialScrapeFailure(
                url: URL(string: "https://invalid.local/")!, kind: .invalidResponse,
                message: "Event primarySourceURL is invalid"
            )
        }
        let candidate = Self.EventCandidate(
            url: url, franchise: event.event.franchise, title: event.event.officialTitle,
            eventType: event.event.eventType, scheduleRaw: nil, venueRaw: nil,
            groups: event.event.groups, coverURL: nil, coverSourceURL: nil
        )
        let detail = try await fetch(url)
        return try Self.parseDetail(detail.html, finalURL: detail.url, candidate: candidate, cached: event, now: now)
    }

    private func fetch(_ url: URL) async throws -> (html: String, url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let userAgent = OfficialWebsiteHeaders.compatibleUserAgent(for: url)
            ?? "LiveDashboard-iOS/1.0 (+official public event refresh)"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ja,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OfficialScrapeFailure(url: url, kind: .fetch, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            throw OfficialScrapeFailure(url: url, kind: .invalidResponse, message: "HTTP \(status.map(String.init) ?? "non-HTTP")")
        }
        let encoding = String.Encoding.utf8
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .shiftJIS) else {
            throw OfficialScrapeFailure(url: url, kind: .invalidResponse, message: "Response is not decodable HTML")
        }
        return (html, http.url ?? url)
    }
}

private extension OfficialEventScraper {
    struct EventCandidate: Sendable {
        let url: URL
        let franchise: Franchise
        let title: String
        let eventType: EventType
        let scheduleRaw: String?
        let venueRaw: String?
        let groups: [String]
        /// The event-list artwork is intentionally retained separately from
        /// the detail page's poster: it is the official homepage card cover.
        let coverURL: URL?
        let coverSourceURL: URL?

        var lastKnownDate: String? { OfficialEventScraper.parseSchedules(scheduleRaw).map(\.localDate).max() }

        func merging(_ other: EventCandidate) -> EventCandidate {
            EventCandidate(
                url: url,
                franchise: franchise,
                title: title.count >= other.title.count ? title : other.title,
                eventType: eventType == .other ? other.eventType : eventType,
                scheduleRaw: scheduleRaw ?? other.scheduleRaw,
                venueRaw: venueRaw ?? other.venueRaw,
                groups: Array(Set(groups + other.groups)).sorted(),
                coverURL: coverURL ?? other.coverURL,
                coverSourceURL: coverURL != nil ? coverSourceURL : other.coverSourceURL
            )
        }
    }

    struct ParsedSchedule: Sendable {
        let localDate: String
        let dayLabel: String?
        var subtitle: String? = nil
        let doorsAt: Date?
        let startsAt: Date?
        let raw: String
        var venue: String? = nil
        var performers: [String]? = nil
    }

    struct ParsedGoods: Sendable {
        let campaigns: [GoodsCampaign]
        let mediaAssets: [MediaAsset]
    }

    static func parseIndex(_ html: String, finalURL: URL) throws -> [EventCandidate] {
        if finalURL.host == "bang-dream.com" {
            let cards = HTML.blocks(html, tag: "article", className: "p-live-event-list__item")
            guard !cards.isEmpty else {
                throw OfficialScrapeFailure(url: finalURL, kind: .unsupportedTemplate, message: "Missing BanG Dream event cards")
            }
            return cards.compactMap { card in
                guard let href = HTML.firstAttribute(card, tag: "a", name: "href"),
                      let url = URL(string: HTML.decode(href), relativeTo: finalURL)?.absoluteURL,
                      let title = HTML.textForClass(card, "p-live-event-list__item-title"), !title.isEmpty else { return nil }
                let schedule = HTML.valueFollowingHeading(card, headingClass: "p-live-event-list__item-date")
                let venue = HTML.valueFollowingHeading(card, headingClass: "p-live-event-list__item-place")
                let category = HTML.textForClass(card, "p-live-event-list__item-category") ?? ""
                let groups = HTML.allTextForClass(card, "p-live-event-list__item-artist-item")
                let coverURL = HTML.blocks(card, tag: "div", className: "p-live-event-list__item-thumb")
                    .compactMap { bestImageSource(in: $0, relativeTo: finalURL) }
                    .first
                return EventCandidate(
                    url: url, franchise: .bangdream, title: title, eventType: eventType(category + " " + title),
                    scheduleRaw: schedule, venueRaw: venue, groups: groups,
                    coverURL: coverURL, coverSourceURL: coverURL == nil ? nil : finalURL
                )
            }
        }

        if finalURL.host == "www.lovelive-anime.jp" {
            var items = HTML.blocks(html, tag: "li", className: nil).filter {
                $0.contains("live_title") && ($0.contains("live_detail") || $0.contains("/live/"))
            }
            if items.isEmpty {
                items = HTML.blocks(html, tag: "a", className: nil).filter { $0.contains("live_detail") && $0.range(of: "<h2", options: .caseInsensitive) != nil }
            }
            guard !items.isEmpty else {
                throw OfficialScrapeFailure(url: finalURL, kind: .unsupportedTemplate, message: "Missing Love Live event-list items")
            }
            let group = loveLiveGroup(for: finalURL)
            return items.compactMap { item in
                guard let href = HTML.firstAttribute(item, tag: "a", name: "href"),
                      let url = URL(string: HTML.decode(href), relativeTo: finalURL)?.absoluteURL else { return nil }
                let title = HTML.textForClass(item, "live_title") ?? HTML.firstTagText(item, tag: "h2") ?? HTML.firstAttribute(item, tag: "img", name: "alt").map(HTML.decode)
                guard let title, !title.isEmpty else { return nil }
                return EventCandidate(
                    url: url,
                    franchise: .lovelive,
                    title: title,
                    eventType: eventType(title),
                    scheduleRaw: HTML.textForClass(item, "live_date"),
                    venueRaw: HTML.textForClass(item, "live_place"),
                    groups: group.map { [$0] } ?? [], coverURL: nil, coverSourceURL: nil
                )
            }
        }
        throw OfficialScrapeFailure(url: finalURL, kind: .unsupportedTemplate, message: "No official parser for host")
    }

    static func parseDetail(
        _ html: String,
        finalURL: URL,
        candidate: EventCandidate,
        cached: LiveEventBundle?,
        now: Date
    ) throws -> LiveEventBundle {
        let isBangDream = finalURL.host == "bang-dream.com"
        let isLoveLive = finalURL.host == "www.lovelive-anime.jp"
        guard isBangDream || isLoveLive else {
            throw OfficialScrapeFailure(url: finalURL, kind: .unsupportedTemplate, message: "Detail host is not supported")
        }

        let title: String
        let scheduleRaw: String?
        let venueRaw: String?
        let performersRaw: String?
        let ticketHTML: String
        var combinedScheduleHTML: String?
        var loveLiveDetailHTML: String?
        var loveLiveOverviewText: String?
        var loveLiveCastBlocks: [LoveLiveCastBlock] = []
        var loveLiveTaggedTickets: String?
        var loveLiveInlineTickets: String?
        var bangDreamTicketHeadingHTML: String?
        if isBangDream {
            guard html.contains("p-live-event-detail") || html.contains("p-page-detail") else {
                throw OfficialScrapeFailure(url: finalURL, kind: .unsupportedTemplate, message: "Missing BanG Dream detail article")
            }
            let content = HTML.blocks(html, tag: "div", className: "p-live-event-detail__content").max { $0.count < $1.count }
                ?? HTML.blocks(html, tag: "div", className: "p-page-detail__content").max { $0.count < $1.count } ?? ""
            title = HTML.textForClass(html, "p-live-event-detail__header-title")
                ?? HTML.textForClass(html, "p-page-detail__header-title") ?? candidate.title
            combinedScheduleHTML = HTML.sectionHTML(content, heading: "日程・会場")
                ?? HTML.sectionHTML(content, heading: "日時・会場")
                ?? HTML.sectionHTML(content, heading: "開催概要")
            scheduleRaw = HTML.sectionText(content, heading: "日程")
                ?? combinedScheduleHTML.map(HTML.text) ?? HTML.tableValue(html, label: "開催日") ?? candidate.scheduleRaw
            venueRaw = HTML.sectionText(content, heading: "会場")
                ?? combinedScheduleHTML.flatMap { venueFromOverview(HTML.text($0)) } ?? HTML.tableValue(html, label: "場所") ?? candidate.venueRaw
            performersRaw = HTML.sectionText(content, heading: "出演")
                ?? HTML.headingSections(content).first(where: { $0.heading.hasPrefix("出演（") }).flatMap { HTML.sectionText(content, heading: $0.heading) }
            let ticketHeading = HTML.headingSections(content).first {
                $0.heading == "会場チケット" || $0.heading == "チケット" || $0.heading.range(of: #"^チケット[\s　]*※"#, options: .regularExpression) != nil
            }?.heading
            ticketHTML = ticketHeading.flatMap { HTML.sectionHTML(content, heading: $0) } ?? ""
            bangDreamTicketHeadingHTML = ticketHTML
        } else {
            // LoveHigh's description is the series slogan; its og:title carries
            // the actual event name followed by the site's navigation suffix.
            let eventPageTitle = finalURL.path.hasPrefix("/lovehigh/")
                ? HTML.metaContent(html, property: "og:title")?.replacingOccurrences(of: #"\s+\|.*$"#, with: "", options: .regularExpression)
                : nil
            title = eventPageTitle ?? HTML.metaContent(html, property: "og:description")?.replacingOccurrences(of: "｜.*$", with: "", options: .regularExpression)
                ?? HTML.metaContent(html, property: "og:title")?.replacingOccurrences(of: "｜.*$", with: "", options: .regularExpression)
                ?? candidate.title
            let top = HTML.blockWithAttribute(html, attribute: "data-target", value: "top") ?? ""
            let detail = loveLiveStructuredDetail(in: html)
            guard !top.isEmpty || detail != nil else {
                throw OfficialScrapeFailure(url: finalURL, kind: .unsupportedTemplate, message: "Missing Love Live structured detail body")
            }
            loveLiveDetailHTML = detail
            let overview = !top.isEmpty ? top : detail.flatMap(loveLiveOverviewHTML) ?? ""
            let overviewText = HTML.text(overview)
            loveLiveOverviewText = overviewText
            scheduleRaw = ["日程", "公演日時", "開催日程", "日程・場所", "公演日・出演"]
                .compactMap { HTML.sectionText(overview, heading: $0) }.first
                ?? (overviewText.isEmpty ? candidate.scheduleRaw : overviewText)
            let completeDetail = detail ?? overview
            venueRaw = HTML.sectionText(completeDetail, heading: "会場")
                ?? candidate.venueRaw ?? venueFromOverview(overviewText)
            performersRaw = HTML.sectionText(overview, heading: "出演者")
                ?? HTML.sectionText(overview, heading: "出演")
                ?? detail.flatMap { HTML.sectionText($0, heading: "出演者") }.map { raw in
                    raw.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("※") }.joined(separator: "\n")
                }
                ?? stackedLabelValue(overviewText, labels: ["出演", "出演者"])
                // Editor pages style section titles as `ke-live_text` blocks: a sibling
                // `h4` outside the overview (FLOWER LIVE), a plain `div` (8th Live), or a
                // combined title such as 開催概要・出演者 / 公演日・出演 (地元愛まつり).
                ?? loveLiveTitledSection(completeDetail) { $0 == "出演" || $0 == "出演者" }
                ?? loveLiveTitledSection(completeDetail) { $0.hasSuffix("・出演") || $0.hasSuffix("・出演者") }
            loveLiveCastBlocks = loveLiveCast(performersRaw ?? "", stops: loveLiveStopHeaders(overviewText))
            let taggedTickets = ["ticket", "ticket2"]
                .compactMap { HTML.blockWithAttribute(html, attribute: "data-target", value: $0) }
                .joined(separator: "\n")
            let inlineTickets = ["チケット料金", "チケット"]
                .compactMap { HTML.sectionHTML(completeDetail, heading: $0) }
                .filter { !overview.contains($0) }
                .joined(separator: "\n")
            ticketHTML = overview + "\n" + inlineTickets + "\n" + taggedTickets
            loveLiveTaggedTickets = taggedTickets
            loveLiveInlineTickets = inlineTickets
        }

        let canonical = canonicalURL(finalURL.absoluteString)
        let eventID = cached?.event.id ?? stableID(prefix: candidate.franchise.rawValue, seed: canonical)
        var schedules = combinedScheduleHTML.map(parseCombinedSchedules) ?? parseSchedules(scheduleRaw)
        if schedules.isEmpty { schedules = parseSchedules(candidate.scheduleRaw) }
        if let loveLiveOverviewText {
            let stopVenues = loveLiveStopVenues(loveLiveOverviewText)
            if !stopVenues.isEmpty {
                schedules = schedules.map { schedule in
                    var result = schedule
                    if result.venue == nil { result.venue = stopVenues[schedule.localDate] }
                    return result
                }
            }
        }
        let venue = cleanedVenue(venueRaw ?? "", summary: HTML.tableValue(html, label: "場所"))
        let eventTimeZone = officialTimeZone(title + " " + venue)
        let performers = splitNames(performersRaw)
        let officialGroups = HTML.blocks(html, tag: "a", className: "p-news-detail__related-artist-link").map(HTML.text)
        let loveLiveStopByDate = loveLiveOverviewText.map(loveLiveStopDates) ?? [:]
        let overviewNote = HTML.tableValue(html, label: "概要") ?? scheduleRaw ?? ""
        let oldPerformances = cached?.performances ?? []
        let cachedPerformanceIDs = Set(oldPerformances.map(\.id))
        func scheduleLabel(_ index: Int, _ item: ParsedSchedule) -> String {
            item.dayLabel ?? (schedules.count == 1 ? "公演" : "Day \(index + 1)")
        }
        var claimedPriorIDs: Set<String> = []
        struct ResolvedPerformance { let index: Int; let item: ParsedSchedule; let label: String; let prior: Performance? }
        let resolved: [ResolvedPerformance] = schedules.enumerated().map { index, item in
            let label = scheduleLabel(index, item)
            func unclaimed(_ p: Performance) -> Bool { !claimedPriorIDs.contains(p.id) }
            func sameLabel(_ p: Performance) -> Bool { p.dayLabel.caseInsensitiveCompare(label) == .orderedSame }
            let labelIsUnique = oldPerformances.filter(sameLabel).count == 1
                && schedules.enumerated().filter { scheduleLabel($0.offset, $0.element).caseInsensitiveCompare(label) == .orderedSame }.count == 1
            let prior = oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate && sameLabel($0) && $0.subtitle == item.subtitle }
                ?? oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate && sameLabel($0) && (item.subtitle == nil || $0.subtitle == nil) }
                ?? (labelIsUnique ? oldPerformances.first { unclaimed($0) && sameLabel($0) } : nil)
                ?? oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate && $0.startAt != nil && $0.startAt == reinterpretJapanWallTime(item.startsAt, in: eventTimeZone) }
                ?? oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate }
                ?? (index < oldPerformances.count && unclaimed(oldPerformances[index]) && oldPerformances[index].localDate == nil ? oldPerformances[index] : nil)
            if let prior { claimedPriorIDs.insert(prior.id) }
            return ResolvedPerformance(index: index, item: item, label: label, prior: prior)
        }
        var usedPerformanceIDs: Set<String> = []
        let parsedPerformances = resolved.map { resolvedItem -> Performance in
            let index = resolvedItem.index
            let item = resolvedItem.item
            let label = resolvedItem.label
            let prior = resolvedItem.prior
            let performanceID: String
            if let prior {
                performanceID = prior.id
            } else {
                let candidateID = "\(eventID)-performance-\(index + 1)"
                performanceID = (cachedPerformanceIDs.contains(candidateID) || usedPerformanceIDs.contains(candidateID))
                    ? stableID(prefix: "\(eventID)-performance", seed: "\(item.localDate)|\(label)|\(item.subtitle ?? "")")
                    : candidateID
            }
            usedPerformanceIDs.insert(performanceID)
            let associatedVenue = isLoveLive && item.venue != nil ? nil : scopedVenue(venueRaw ?? "", note: overviewNote, date: item.localDate)
            let associatedPerformers = notedPerformers(overviewNote, groups: officialGroups, date: item.localDate, singleDate: Set(schedules.map(\.localDate)).count == 1)
            let loveLiveCast = loveLivePerformers(loveLiveCastBlocks, dayLabel: label, localDate: item.localDate, stop: loveLiveStopByDate[item.localDate])
            let resolvedVenue = associatedVenue ?? item.venue ?? (venue.isEmpty ? (prior?.venueName ?? "") : venue)
            return Performance(
                id: performanceID, eventID: eventID, stopID: prior?.stopID,
                dayLabel: label, subtitle: item.subtitle ?? prior?.subtitle, localDate: item.localDate,
                doorsAt: reinterpretJapanWallTime(item.doorsAt, in: eventTimeZone) ?? prior?.doorsAt, startAt: reinterpretJapanWallTime(item.startsAt, in: eventTimeZone) ?? prior?.startAt,
                venueName: resolvedVenue,
                venueCity: resolvedVenue.isEmpty ? (prior?.venueCity ?? "") : venueCity(resolvedVenue),
                performers: item.performers ?? (loveLiveCast.isEmpty ? nil : loveLiveCast) ?? (performers.isEmpty ? (associatedPerformers.isEmpty ? (prior?.performers ?? []) : associatedPerformers) : performersForDay(performersRaw ?? "", dayLabel: label)), order: index,
                editionID: prior?.editionID, rawDate: item.raw, precision: (item.startsAt != nil || item.doorsAt != nil) ? .minute : .date,
                timeZone: eventTimeZone
            )
        }

        let performances = parsedPerformances.isEmpty ? oldPerformances : parsedPerformances
        // A page with exactly one performance cannot mean any other date, so
        // its ticket records apply to that performance. With several dates the
        // parser still emits `.unconfirmed` (DESIGN.md: never guess Day2).
        let ticketScope: Scope = performances.count == 1 ? .performances(performanceIDs: [performances[0].id]) : .unconfirmed
        let parsedTiers = parseTicketTiers(ticketHTML, eventID: eventID, cached: cached?.ticketTiers ?? [])
        let baseTiers = parsedTiers.isEmpty ? (cached?.ticketTiers ?? []) : parsedTiers
        let tradeHTML = HTML.sectionHTML(html, heading: "チケットトレード") ?? ""
        var parsedRounds: [TicketRound] = []
        if isLoveLive {
            let loveLiveRounds = [loveLiveTaggedTickets, loveLiveInlineTickets]
                .compactMap { $0 }
                .map { parseLoveLiveTicketRounds($0, eventID: eventID, cached: cached?.ticketRounds ?? [], timeZone: eventTimeZone, referenceDate: schedules.first?.localDate, sourceURL: finalURL) }
                .first { !$0.isEmpty } ?? []
            parsedRounds = loveLiveRounds.isEmpty
                ? parseTicketRounds(ticketHTML + "\n" + tradeHTML, eventID: eventID, cached: cached?.ticketRounds ?? [], timeZone: eventTimeZone, referenceDate: schedules.first?.localDate, sourceURL: finalURL)
                : loveLiveRounds
        } else {
            let salesSection = HTML.sectionHTML(bangDreamTicketHeadingHTML ?? ticketHTML, heading: "販売情報") ?? ""
            let salesPreamble = salesSection.range(of: "<h6", options: [.caseInsensitive]).map { String(salesSection[..<$0.lowerBound]) } ?? salesSection
            let sharedLinks = HTML.links(salesPreamble, relativeTo: finalURL)
            parsedRounds = parseTicketRounds(ticketHTML + "\n" + tradeHTML, eventID: eventID, cached: cached?.ticketRounds ?? [], timeZone: eventTimeZone, referenceDate: schedules.first?.localDate, sourceURL: finalURL, sharedLinks: sharedLinks)
        }
        parsedRounds = parsedRounds.map { $0.replacingScope(ticketScope) }
        let rounds = parsedRounds.isEmpty ? (cached?.ticketRounds ?? []) : parsedRounds
        let parsedBenefitsResult = parseTicketBenefits(
            ticketHTML, sourceURL: finalURL, eventID: eventID, tiers: baseTiers, scope: ticketScope,
            cached: cached?.ticketBenefits ?? [], cachedMedia: cached?.mediaAssets ?? []
        )
        let parsedBenefits = parsedBenefitsResult.benefits
        let ticketBenefits = parsedBenefits.isEmpty ? (cached?.ticketBenefits ?? []) : parsedBenefits
        let tiers = tiersWithBenefitContents(baseTiers, benefits: ticketBenefits)
        let richContentHTML: String
        if isBangDream {
            richContentHTML = HTML.blocks(html, tag: "div", className: "p-live-event-detail__content").max(by: { $0.count < $1.count })
                ?? HTML.blocks(html, tag: "div", className: "p-page-detail__content").max(by: { $0.count < $1.count })
                ?? ""
        } else {
            richContentHTML = loveLiveDetailHTML
                ?? HTML.blocks(html, tag: "article", className: nil)
                    .filter { $0.range(of: "data-target", options: .caseInsensitive) != nil }
                    .max(by: { $0.count < $1.count })
                ?? ""
        }
        func cappedSourceText(_ value: String) -> String {
            value.count > 80_000 ? String(value.prefix(80_000)) + "…" : value
        }
        let sourceText: String?
        if isBangDream {
            let rendered = HTML.linkedText(richContentHTML, relativeTo: finalURL)
            sourceText = rendered.isEmpty ? cached?.sourceText : cappedSourceText("# \(title)\n" + rendered)
        } else {
            let sourceTextTop = HTML.blockWithAttribute(html, attribute: "data-target", value: "top") ?? ""
            let sourceTextTicket = HTML.blockWithAttribute(html, attribute: "data-target", value: "ticket") ?? ""
            let sourceTextTicket2 = HTML.blockWithAttribute(html, attribute: "data-target", value: "ticket2") ?? ""
            let sourceTextGoods = HTML.blockWithAttribute(html, attribute: "data-target", value: "goods") ?? ""
            let candidateBlocks = [sourceTextTop, loveLiveDetailHTML ?? "", sourceTextTicket, sourceTextTicket2, sourceTextGoods].filter { !$0.isEmpty }
            let includedBlocks = candidateBlocks.enumerated().filter { index, block in
                !candidateBlocks.enumerated().contains { otherIndex, other in
                    otherIndex != index && other.count != block.count && other.contains(block)
                }
            }.map(\.element)
            let rendered = HTML.linkedText(includedBlocks.joined(separator: "\n\n"), relativeTo: finalURL)
            sourceText = rendered.isEmpty ? cached?.sourceText : cappedSourceText("# \(title)\n" + rendered)
        }
        let parsedStreams = parseStreams(richContentHTML, sourceURL: finalURL, eventID: eventID).map { $0.replacingScope(ticketScope) }
        let parsedGoodsResult = parseGoods(
            richContentHTML, sourceURL: finalURL, eventID: eventID,
            cachedCampaigns: cached?.goodsCampaigns ?? [], cachedMedia: cached?.mediaAssets ?? []
        )
        // The event key visual normally lives outside the rich-content body
        // (in the page head or the BanG Dream eyecatch). Pass the complete
        // document so media parsing can refresh it alongside seating maps.
        let parsedMedia = parseMediaAssets(
            html, sourceURL: finalURL, eventID: eventID, cached: cached?.mediaAssets ?? [],
            eventCoverURL: candidate.coverURL, eventCoverSourceURL: candidate.coverSourceURL
        )
            + parsedGoodsResult.mediaAssets
            + parsedBenefitsResult.mediaAssets
        let mediaAssets = parsedMedia.isEmpty ? (cached?.mediaAssets ?? []) : mergeMedia(cached?.mediaAssets ?? [], parsedMedia)
        let parsedGoods = parsedGoodsResult.campaigns
        let goodsCampaigns = parsedGoods.isEmpty ? (cached?.goodsCampaigns ?? []) : mergeGoods(cached?.goodsCampaigns ?? [], parsedGoods)
        let lastDate = performances.compactMap(\.localDate).max()
        let today = localDate(now)
        let bodyText = HTML.text(html)
        let status: EventStatus = bodyText.contains("開催中止") || title.contains("開催中止") || title.contains("中止") ? .cancelled
            : bodyText.contains("開催延期") || title.contains("延期") ? .postponed
            : lastDate.map { $0 < today } == true ? .finished
            : lastDate == nil ? .unknown : .scheduled
        let event = LiveEvent(
            id: eventID, franchise: candidate.franchise, officialTitle: title,
            groups: officialGroups.isEmpty ? candidate.groups : officialGroups, eventType: candidate.eventType, status: status,
            primarySourceURL: finalURL.absoluteString, timeZone: eventTimeZone
        )

        var evidence: [SourceEvidence] = []
        evidence.append(makeEvidence(recordID: eventID, field: "event.officialTitle", sourceURL: finalURL, quote: title, now: now))
        if let scheduleRaw, !clean(scheduleRaw).isEmpty {
            evidence.append(makeEvidence(recordID: eventID, field: "performance.schedule", sourceURL: finalURL, quote: clean(scheduleRaw), now: now))
        }
        if !venue.isEmpty {
            evidence.append(makeEvidence(recordID: eventID, field: "performance.venueName", sourceURL: finalURL, quote: venue, now: now))
        }
        if let performersRaw, !performers.isEmpty {
            evidence.append(makeEvidence(recordID: eventID, field: "performance.performers", sourceURL: finalURL, quote: clean(performersRaw), now: now))
        }
        for performance in performances where !performance.performers.isEmpty {
            evidence.append(makeEvidence(recordID: performance.id, field: "performance.performers", sourceURL: finalURL, quote: performance.performers.joined(separator: "、"), now: now))
        }
        for tier in parsedTiers {
            evidence.append(makeEvidence(recordID: tier.id, field: "ticket.price", sourceURL: finalURL, quote: "\(tier.name): \(tier.amount?.formatted ?? String(tier.priceJPY ?? 0))", now: now))
        }
        for round in parsedRounds {
            evidence.append(makeEvidence(recordID: round.id, field: "ticket.round", sourceURL: finalURL, quote: round.officialName, now: now))
        }
        for benefit in parsedBenefits {
            evidence.append(makeEvidence(recordID: benefit.id, field: "ticket.benefit", sourceURL: finalURL, quote: "\(benefit.officialName): \(benefit.detail ?? benefit.notes ?? "")", now: now))
        }
        if let admission = HTML.headingSections(html).first(where: { $0.heading.contains("入場") }), !HTML.text(admission.html).isEmpty {
            evidence.append(makeEvidence(recordID: eventID, field: "event.admission", sourceURL: finalURL, quote: "\(admission.heading)\n\(HTML.text(admission.html))", now: now))
        }
        for asset in parsedMedia {
            evidence.append(makeEvidence(recordID: asset.id, field: "media.asset", sourceURL: finalURL, quote: asset.caption ?? asset.originalURL, now: now))
        }
        for stream in parsedStreams {
            evidence.append(makeEvidence(recordID: stream.id, field: "stream.offer", sourceURL: finalURL, quote: stream.officialName, now: now))
        }
        for campaign in parsedGoods {
            evidence.append(makeEvidence(recordID: campaign.id, field: "goods.campaign", sourceURL: finalURL, quote: campaign.officialName, now: now))
        }

        return LiveEventBundle(
            schemaVersion: 1, revision: cached?.revision, publishedAt: now, event: event,
            stops: cached?.stops ?? [], performances: performances,
            ticketTiers: tiers, ticketRounds: rounds, ticketOffers: cached?.ticketOffers ?? [],
            goodsCampaigns: goodsCampaigns, mediaAssets: mediaAssets,
            notices: cached?.notices ?? [], evidence: mergeEvidence(cached?.evidence ?? [], evidence),
            editions: cached?.editions ?? [], streamOffers: parsedStreams.isEmpty ? (cached?.streamOffers ?? []) : parsedStreams,
            products: cached?.products ?? [], goodsSessions: cached?.goodsSessions ?? [], ticketBenefits: ticketBenefits, sourceHealth: .healthy,
            sourceText: sourceText
        )
    }

    /// Newer Love Live branches render the event overview as editor components
    /// and use `data-target` only for optional tabs such as tickets. Require the
    /// official editor structure plus a known overview heading so an error page
    /// or navigation-only article can never be accepted as event detail.
    static func loveLiveStructuredDetail(in html: String) -> String? {
        let overviewHeadings = Set(["日程・会場", "イベント概要", "ライブTOP", "開催概要", "開催概要・出演者"])
        let articles = HTML.blocks(html, tag: "article", className: nil)
        let namedContainers = HTML.blocksWithAttribute(html, attribute: "id", value: "event-detail")
        return (articles + namedContainers)
            .filter { article in
                article.range(of: #"data-type\s*=\s*['\"]component-livetext['\"]"#, options: [.regularExpression, .caseInsensitive]) != nil
                    && article.range(of: #"data-textbody(?:\s*=\s*['\"][^'\"]*['\"])?"#, options: [.regularExpression, .caseInsensitive]) != nil
                    && HTML.headingSections(article).contains { overviewHeadings.contains($0.heading) }
            }
            .max(by: { $0.count < $1.count })
    }

    static func loveLiveOverviewHTML(_ detail: String) -> String? {
        ["日程・会場", "イベント概要", "開催概要・出演者", "開催概要", "ライブTOP"]
            .compactMap { HTML.sectionHTML(detail, heading: $0) }
            .first
    }

    /// Combined overview blocks repeat a venue per stop; never assign the final
    /// tour venue to every date merely because it was the last venue in the text.
    static func parseCombinedSchedules(_ html: String) -> [ParsedSchedule] {
        let sections = HTML.headingSections(html)
        let stops = sections.filter { !parseSchedules(HTML.text($0.html)).isEmpty }
        if !stops.isEmpty {
            return stops.flatMap { stop in
                let raw = HTML.text(stop.html)
                return parseSchedules(raw).map { schedule in
                    var result = schedule
                    result.venue = venueFromOverview(raw)
                    result.performers = inlinePerformers(raw)
                    if result.dayLabel == nil, stop.heading.hasSuffix("公演") {
                        result = ParsedSchedule(localDate: result.localDate, dayLabel: stop.heading, subtitle: result.subtitle, doorsAt: result.doorsAt, startsAt: result.startsAt, raw: result.raw, venue: result.venue, performers: result.performers)
                    }
                    return result
                }
            }
        }
        let paragraphs = HTML.blocks(html, tag: "p", className: nil)
            .map(HTML.text).filter { !parseSchedules($0).isEmpty && venueFromOverview($0) != nil }
        if paragraphs.count > 1 {
            return paragraphs.flatMap { raw in parseSchedules(raw).map { schedule in
                var result = schedule
                result.venue = venueFromOverview(raw)
                result.performers = inlinePerformers(raw)
                return result
            } }
        }
        let raw = HTML.text(html)
        return parseSchedules(raw).map { schedule in
            var result = schedule
            result.venue = venueFromOverview(raw)
            return result
        }
    }

    static func parseSchedules(_ raw: String?) -> [ParsedSchedule] {
        guard let raw, !raw.isEmpty else { return [] }
        let source = clean(raw).precomposedStringWithCompatibilityMapping
        let matches = regex(#"(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日(?!目)(?:\([^)]*\))?"#, source)
        let ns = source as NSString
        var year: Int?
        var month: Int?
        var results: [ParsedSchedule] = []
        for (index, match) in matches.enumerated() {
            if let value = group(match, 1, in: source).flatMap(Int.init) { year = value }
            if let value = group(match, 2, in: source).flatMap(Int.init) { month = value }
            guard let year, let month, let day = group(match, 3, in: source).flatMap(Int.init),
                  validDate(year: year, month: month, day: day) != nil else { continue }
            let local = String(format: "%04d-%02d-%02d", year, month, day)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            var tail = ns.substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
            // A shared time after a list of dates applies to every date in that list.
            var sharedIndex = index
            while tail.range(of: #"^[・、,\s]+$"#, options: .regularExpression) != nil, sharedIndex + 1 < matches.count {
                sharedIndex += 1
                let nextEnd = sharedIndex + 1 < matches.count ? matches[sharedIndex + 1].range.location : ns.length
                tail = ns.substring(with: NSRange(location: NSMaxRange(matches[sharedIndex].range), length: nextEnd - NSMaxRange(matches[sharedIndex].range)))
            }
            let prefixStart = index > 0 ? NSMaxRange(matches[index - 1].range) : 0
            let prefix = ns.substring(with: NSRange(location: prefixStart, length: match.range.location - prefixStart))
            let dayMatch = regex(#"DAY\.?\s*(\d+)|(\d+)日目"#, prefix).last
            let dayLabel = dayMatch.flatMap { group($0, 1, in: prefix) ?? group($0, 2, in: prefix) }.map { "DAY\($0)" }
            let sessionPattern = #"昼(?:公演|の部)|夜(?:公演|の部)|第[一二三四五六七八九十\d]+(?:部|回公演)"#
            let linePrefix = prefix.components(separatedBy: "\n").last ?? ""
            let lineSession = regex(sessionPattern, linePrefix).last.flatMap { group($0, 0, in: linePrefix) }
            func labels(_ session: String?) -> (day: String?, subtitle: String?) {
                guard let session else { return (dayLabel, nil) }
                return dayLabel == nil ? (session, nil) : (dayLabel, session)
            }
            let pairPattern = #"(?:開場\s*[:：]?\s*)?(\d{1,2}):(\d{2})\s*(?:開場)?\s*[／/]\s*(?:開演\s*[:：]?\s*)?(\d{1,2}):(\d{2})\s*(?:開演)?"#
            let tailNS = tail as NSString
            let pairs = regex(pairPattern, tail).filter { pair in
                tailNS.substring(with: tailNS.lineRange(for: pair.range))
                    .range(of: #"開場|開演|OPEN|START"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if pairs.isEmpty {
                let start = regex(#"開演\s*[:：]?\s*(\d{1,2}):(\d{2})"#, tail).first
                let names = labels(lineSession)
                results.append(.init(localDate: local, dayLabel: names.day, subtitle: names.subtitle, doorsAt: nil,
                    startsAt: start.flatMap { timeDate(local, hour: group($0, 1, in: tail), minute: group($0, 2, in: tail)) },
                    raw: group(match, 0, in: source) ?? local))
            } else {
                for (pairIndex, pair) in pairs.enumerated() {
                    let from = pairIndex == 0 ? 0 : NSMaxRange(pairs[pairIndex - 1].range)
                    let before = tailNS.substring(with: NSRange(location: from, length: pair.range.location - from))
                    let own = regex(sessionPattern, before).last.flatMap { group($0, 0, in: before) }
                    let session = own ?? (pairIndex == 0 ? lineSession : nil) ?? (pairs.count > 1 ? "第\(pairIndex + 1)部" : nil)
                    let names = labels(session)
                    results.append(.init(localDate: local, dayLabel: names.day, subtitle: names.subtitle,
                        doorsAt: timeDate(local, hour: group(pair, 1, in: tail), minute: group(pair, 2, in: tail)),
                        startsAt: timeDate(local, hour: group(pair, 3, in: tail), minute: group(pair, 4, in: tail)),
                        raw: (group(match, 0, in: source) ?? local) + " " + (group(pair, 0, in: tail) ?? "")))
                }
            }
        }
        var seen: Set<String> = []
        return results.filter { seen.insert("\($0.localDate)|\($0.dayLabel ?? "")|\($0.subtitle ?? "")").inserted }
    }

    /// Love Live tour overviews list every stop inside one text body:
    /// `＜東京公演＞ / Day.1 …日 / 会場：… / ＜兵庫公演＞ / …`. Split that text at
    /// whole-line `＜…＞` stop headers and map each date to its own stop's venue.
    /// Returns an empty map unless at least two dated stops name distinct venues.
    static func loveLiveStopVenues(_ overviewText: String) -> [String: String] {
        var blocks: [[String]] = [[]]
        for line in overviewText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^[＜<][^＜＞<>]+[＞>]$"#, options: .regularExpression) != nil, !blocks[blocks.count - 1].isEmpty {
                blocks.append([])
            }
            blocks[blocks.count - 1].append(line)
        }
        guard blocks.count > 1 else { return [:] }
        var year: Int?
        var month: Int?
        var stops: [(dates: [String], venue: String)] = []
        for block in blocks {
            let text = block.joined(separator: "\n")
            let source = clean(text).precomposedStringWithCompatibilityMapping
            var dates: [String] = []
            for match in regex(#"(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日(?!目)"#, source) {
                if let value = group(match, 1, in: source).flatMap(Int.init) { year = value }
                if let value = group(match, 2, in: source).flatMap(Int.init) { month = value }
                guard let year, let month, let day = group(match, 3, in: source).flatMap(Int.init),
                      validDate(year: year, month: month, day: day) != nil else { continue }
                dates.append(String(format: "%04d-%02d-%02d", year, month, day))
            }
            guard !dates.isEmpty, let venue = venueFromOverview(text).map(clean), !venue.isEmpty else { continue }
            stops.append((dates, venue))
        }
        guard Set(stops.map(\.venue)).count > 1 else { return [:] }
        var result: [String: String] = [:]
        for stop in stops {
            for date in stop.dates where result[date] == nil { result[date] = stop.venue }
        }
        return result
    }

    static func parseTicketTiers(_ html: String, eventID: String, cached: [TicketTier]) -> [TicketTier] {
        let priceArea = HTML.sectionHTML(html, heading: "料金") ?? html
        let raw = HTML.text(priceArea).precomposedStringWithCompatibilityMapping
        let pattern = #"([^\n:：]{1,60}?)[：:]\s*(?:\+|＋)?\s*([\d,]+)円"#
        let yen: [TicketTier] = regex(pattern, raw).enumerated().compactMap { index, match in
            guard let name = group(match, 1, in: raw).map(clean),
                  let amountRaw = group(match, 2, in: raw)?.replacingOccurrences(of: ",", with: ""),
                  let amount = Int(amountRaw),
                  !name.isEmpty else { return nil }
            let kind: TicketPriceKind = name.range(of: "U-?20", options: .regularExpression) != nil ? .under20
                : name.contains("アップグレード") ? .upgradeDifference : .full
            let id = cached.first(where: { clean($0.name) == name })?.id ?? "\(eventID)-tier-\(stableHash(name))"
            return TicketTier(id: id, eventID: eventID, name: name, priceJPY: amount, priceKind: kind, amount: MoneyAmount(minorUnits: Int64(amount), currency: "JPY"), includes: nil, feeNote: nil, taxNote: raw.contains("税込") ? "税込" : nil)
        }
        let foreign: [TicketTier] = regex(#"([^\n:：]{1,80})[：:]\s*(HK\$|NT\$)\s*([\d,]+)([^\n]*)"#, raw).compactMap { match in
            guard let name = group(match, 1, in: raw).map(clean), let unit = group(match, 2, in: raw),
                  let digits = group(match, 3, in: raw)?.replacingOccurrences(of: ",", with: ""), let amount = Int64(digits) else { return nil }
            let currency = unit == "HK$" ? "HKD" : "TWD"
            let id = cached.first { clean($0.name) == name }?.id ?? "\(eventID)-tier-\(stableHash(name))"
            return TicketTier(id: id, eventID: eventID, name: name, priceJPY: nil, priceKind: .full,
                amount: MoneyAmount(minorUnits: amount * 100, currency: currency), includes: group(match, 4, in: raw).map(clean), feeNote: nil, taxNote: nil)
        }
        var additional: [TicketTier] = []
        for section in HTML.headingSections(priceArea) {
            let text = HTML.text(section.html).precomposedStringWithCompatibilityMapping
            guard section.heading.contains("チケット"),
                  let match = regex(#"[¥￥]\s*([\d,]+)"#, text).first,
                  let digits = group(match, 1, in: text)?.replacingOccurrences(of: ",", with: ""), let value = Int(digits) else { continue }
            let name = clean(section.heading).precomposedStringWithCompatibilityMapping
            additional.append(TicketTier(id: cached.first { clean($0.name) == name }?.id ?? "\(eventID)-tier-\(stableHash(name))",
                eventID: eventID, name: name, priceJPY: value, priceKind: .full,
                amount: MoneyAmount(minorUnits: Int64(value), currency: "JPY"), includes: nil, feeNote: nil, taxNote: text.contains("税込") ? "税込" : nil))
        }
        if raw.contains("チケット代無料") || raw.contains("チケット代金は無料") {
            additional.append(TicketTier(id: "\(eventID)-tier-free", eventID: eventID, name: "チケット代", priceJPY: 0, priceKind: .full,
                amount: MoneyAmount(minorUnits: 0, currency: "JPY"), includes: nil,
                feeNote: HTML.text(html).contains("システム利用料") ? "別途システム利用料が発生します。" : nil, taxNote: nil))
        }
        // Love Live pages repeat the same ticket block inside several containers
        // (overview, inline チケット section, data-target tabs); keep one record per ID.
        return uniqueByID(yen + foreign + additional)
    }

    /// Keeps the first record for each ID. Duplicate IDs would otherwise trap the
    /// UI's `Dictionary(uniqueKeysWithValues:)` lookups.
    static func uniqueByID<T: Identifiable>(_ items: [T]) -> [T] {
        var seen = Set<T.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    static func ticketRoundIdentity(_ name: String) -> String {
        clean(name.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"\s*\((?:受付)?終了\)\s*$"#, with: "", options: .regularExpression))
    }

    // MARK: - Link classification / notes / structured field helpers (shared by BD & LL parsers)

    static func classifiedLinks(_ links: [OfficialLink]) -> [OfficialLink] {
        links.map { OfficialLink(label: $0.label, url: $0.url, role: OfficialLink.classify(label: $0.label, url: $0.url)) }
    }

    static func applicationURL(in links: [OfficialLink]) -> String? {
        links.first { ($0.role ?? OfficialLink.classify(label: $0.label, url: $0.url)) == .application }?.url
    }

    static func overseasApplicationURL(in links: [OfficialLink]) -> String? {
        links.first { ($0.role ?? OfficialLink.classify(label: $0.label, url: $0.url)) == .overseasApplication }?.url
    }

    /// Injects the year into a date-only value ("4月26日（日）23:59") using
    /// `referenceDate` (yyyy-MM-dd) the same way the BanG Dream round parser
    /// does: the year rolls back one when the value's month is after the
    /// reference month (a round announced late in one year for an event
    /// early the next).
    static func injectYearIfNeeded(_ value: String, referenceDate: String?) -> String {
        guard !value.contains("年"), let referenceDate,
              let monthMatch = regex(#"(\d{1,2})月"#, value).first,
              let month = group(monthMatch, 1, in: value).flatMap(Int.init) else { return value }
        let parts = referenceDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return value }
        let year = parts[0] - (month > parts[1] ? 1 : 0)
        let ns = value as NSString
        return ns.substring(to: monthMatch.range.location) + "\(year)年" + ns.substring(from: monthMatch.range.location)
    }

    /// Verbatim text on the same line as the first matching marker, up to the
    /// end of that line (a `raw` value uses `"\n"` line breaks).
    static func markedLineText(_ raw: String, markers: [String]) -> String? {
        for line in raw.components(separatedBy: "\n") {
            for marker in markers {
                guard let markerRange = line.range(of: marker) else { continue }
                let rest = line[markerRange.upperBound...].drop { $0 == "：" || $0 == ":" || $0 == " " || $0 == "\u{00a0}" }
                let value = String(rest).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                return value
            }
        }
        return nil
    }

    static func ticketNotes(in lines: [String], links: [OfficialLink]) -> [TicketNote] {
        struct Rule { let kind: TicketNoteKind; let keywords: [String]; let linkFragments: [String]; let linkLabelFragments: [String] }
        let rules: [Rule] = [
            .init(kind: .faceRecognition, keywords: ["顔認証", "顔写真登録"], linkFragments: ["faceticket"], linkLabelFragments: []),
            .init(kind: .companionRegistration, keywords: ["同行者登録", "同行者"], linkFragments: ["fellow", "dokosha"], linkLabelFragments: []),
            .init(kind: .identityCheck, keywords: ["本人確認", "身分証"], linkFragments: [], linkLabelFragments: ["本人確認"]),
            .init(kind: .smartTicketOnly, keywords: ["スマチケ", "電子チケット"], linkFragments: ["spticket", "smartticket"], linkLabelFragments: []),
            .init(kind: .creditCardOnly, keywords: ["クレジットカード決済のみ", "クレジットカードのみ"], linkFragments: [], linkLabelFragments: ["決済"]),
            .init(kind: .membershipRequired, keywords: ["会員登録"], linkFragments: [], linkLabelFragments: ["会員登録"]),
        ]
        var notes: [TicketNote] = []
        for rule in rules {
            let matchingLines = lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, rule.keywords.contains(where: { trimmed.contains($0) }) else { return nil }
                // A pure link-label line ("▼スマチケご利用ガイドはこちら") is not note text.
                guard trimmed.range(of: #"^[▼●■◆]?.*(こちら|ガイド)[：:]?$"#, options: .regularExpression) == nil || rule.keywords.contains(where: { !trimmed.hasSuffix("こちら") && !trimmed.hasSuffix("ガイド") && trimmed.contains($0) }) else { return nil }
                var value = trimmed
                while let first = value.first, "※▼■●".contains(first) { value.removeFirst() }
                let cleaned = value.trimmingCharacters(in: .whitespaces)
                guard !cleaned.isEmpty else { return nil }
                return String(cleaned.prefix(400))
            }
            guard !matchingLines.isEmpty else { continue }
            let matchedLinks = links.filter { link in
                let lowerURL = link.url.lowercased()
                if rule.linkFragments.contains(where: { lowerURL.contains($0) }) { return true }
                if !rule.linkLabelFragments.isEmpty, rule.linkLabelFragments.contains(where: { link.label.contains($0) }) { return true }
                return false
            }
            notes.append(TicketNote(kind: rule.kind, text: matchingLines.joined(separator: "\n"), links: matchedLinks))
        }
        return notes
    }

    static func quantityLimitText(in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["※枚数制限：", "枚数制限：", "■枚数制限："] where trimmed.hasPrefix(marker) {
                let value = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
            guard trimmed.contains("枚まで") || trimmed.contains("枚数まで") || trimmed.contains("購入制限") else { continue }
            var value = trimmed
            if value.hasPrefix("※") { value.removeFirst() }
            var result = [value.trimmingCharacters(in: .whitespaces)]
            var next = index + 1
            while next < lines.count {
                let candidate = lines[next]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("\u{3000}") || candidate.hasPrefix("・")
                    || candidateTrimmed.range(of: #"^.+：\d+枚まで$"#, options: .regularExpression) != nil {
                    result.append(candidateTrimmed)
                    next += 1
                } else { break }
            }
            return result.joined(separator: "\n")
        }
        return nil
    }

    static func lotteryProducts(in lines: [String], html: String?) -> [String] {
        var products: [String] = []
        var seen: Set<String> = []
        func add(_ value: String) {
            let cleaned = clean(value)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return }
            products.append(cleaned)
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("封入"), trimmed.contains("申込券") || trimmed.contains("シリアル") else { continue }
            var value = trimmed
            if value.hasPrefix("※") { value.removeFirst() }
            for marker in ["初回生産分に封入", "に封入", "封入の"] {
                if let range = value.range(of: marker) {
                    let prefix = String(value[..<range.lowerBound])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "、の "))
                    if !prefix.isEmpty, !prefix.hasPrefix("封入") { add(prefix) }
                    break
                }
            }
        }
        return products
    }

    static func parseTicketRounds(_ html: String, eventID: String, cached: [TicketRound], timeZone: String = "Asia/Tokyo", referenceDate: String? = nil, sourceURL: URL? = nil, sharedLinks: [OfficialLink] = []) -> [TicketRound] {
        let classifiedSharedLinks = classifiedLinks(sharedLinks)
        let headings = HTML.headingSections(html)
        struct Candidate {
            let links: [OfficialLink]
            let hasApplication: Bool
            /// The section describes a sales round on its own.
            let isRound: Bool
            /// The section only points at a vendor page (受付はこちら / 受付URL)
            /// and belongs to the sibling round that carries the period.
            let isLinkCarrier: Bool
        }
        let candidates: [Candidate] = headings.enumerated().map { index, section in
            let raw = HTML.text(section.html)
            let links = classifiedLinks(HTML.links(section.html, relativeTo: sourceURL))
            let hasApplication = links.contains { $0.role == .application || $0.role == .overseasApplication }
            let hasPeriod = raw.contains("受付期間") || raw.contains("申込期間") || section.heading.contains("受付期間")
            let namesRound = section.heading.range(of: "先行|発売|抽選|受付|申込|申し込み|販売", options: .regularExpression) != nil
            let pointsElsewhere = section.heading.range(of: "こちら|URL|リンク", options: .regularExpression) != nil
            let linkOnly = !hasPeriod && hasApplication && parseExplicitDateTimes(raw).isEmpty
            // A container heading (販売情報) whose only content is the shared
            // vendor button is not a round: its child headings are the rounds,
            // and parseDetail already hands that button to them as sharedLinks.
            let hasChildHeadings = index + 1 < headings.count && headings[index + 1].level > section.level
            // A vendor button (e.g. 受付はこちら) under a round heading is a sales
            // entry even when the page prints no period next to it.
            let buttonRound = linkOnly && namesRound && !pointsElsewhere && !hasChildHeadings
            return Candidate(links: links, hasApplication: hasApplication, isRound: hasPeriod || buttonRound, isLinkCarrier: linkOnly && !buttonRound)
        }
        // Official pages sometimes split a round into a button-only heading and
        // a period-only heading at the same level (トレード申し込み・詳細はこちら /
        // トレード受付期間). Attach the carrier to its round, preferring the
        // preceding heading because the button is printed first on those pages.
        var carrierFor: [Int: Int] = [:]
        var consumed: Set<Int> = []
        for offset in [-1, 1] {
            for index in headings.indices where candidates[index].isRound && !candidates[index].hasApplication && carrierFor[index] == nil {
                let neighbor = index + offset
                guard headings.indices.contains(neighbor), !consumed.contains(neighbor),
                      candidates[neighbor].isLinkCarrier, headings[neighbor].level == headings[index].level else { continue }
                carrierFor[index] = neighbor
                consumed.insert(neighbor)
            }
        }
        let rounds: [TicketRound] = headings.enumerated().compactMap { index, section in
            let raw = HTML.text(section.html)
            guard candidates[index].isRound else { return nil }
            let kind: TicketRoundKind = raw.contains("先着") || section.heading.contains("一般発売") ? .firstComeFirstServed
                : (raw + section.heading).contains("トレード") ? .resale : section.heading.contains("アップグレード") ? .upgrade : .lottery
            var period = markedText(raw, markers: ["受付期間", "申込期間"])
                ?? (section.heading.contains("受付期間") ? raw : nil)
            if let value = period, !value.contains("年"), let referenceDate,
               let monthMatch = regex(#"(\d{1,2})月"#, value).first,
               let month = group(monthMatch, 1, in: value).flatMap(Int.init) {
                let parts = referenceDate.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3 {
                    let year = parts[0] - (month > parts[1] ? 1 : 0)
                    let ns = value as NSString
                    period = ns.substring(to: monthMatch.range.location) + "\(year)年" + ns.substring(from: monthMatch.range.location)
                }
            }
            let dates = parseExplicitDateTimes(period ?? "").compactMap { reinterpretJapanWallTime($0, in: timeZone) }
            let waiting = dates.isEmpty && raw.range(of: "後日|追って|未定", options: .regularExpression) != nil
            let id = cached.first(where: { ticketRoundIdentity($0.officialName) == ticketRoundIdentity(section.heading) })?.id
                ?? "\(eventID)-round-\(stableHash(ticketRoundIdentity(section.heading)))"

            var ownLinks = candidates[index].links + (carrierFor[index].map { candidates[$0].links } ?? [])
            let hasOwnApplication = ownLinks.contains { $0.role == .application || $0.role == .overseasApplication }
            if !hasOwnApplication {
                ownLinks += classifiedSharedLinks.filter { $0.role == .application || $0.role == .overseasApplication }
            }
            let lines = raw.components(separatedBy: "\n")

            let paymentWindowText = markedLineText(raw, markers: ["入金期間", "支払期間", "支払期限"])
            let paymentDates = parseExplicitDateTimes(paymentWindowText ?? "")

            return TicketRound(
                id: id, eventID: eventID,
                officialName: section.heading, kind: kind,
                scope: .unconfirmed,
                applyStartAt: dates.first, applyEndAt: dates.dropFirst().first,
                resultAt: reinterpretJapanWallTime(markerDate(raw, marker: "当落発表") ?? markerDate(raw, marker: "当選発表"), in: timeZone),
                paymentDeadlineAt: reinterpretJapanWallTime(paymentDates.last, in: timeZone),
                eligibility: raw.range(of: "封入|申込券|ムビチケ", options: .regularExpression) != nil ? raw : nil,
                announcementURL: nil,
                applyURL: applicationURL(in: ownLinks),
                overseasURL: overseasApplicationURL(in: ownLinks),
                officialStatus: (section.heading + raw).contains("受付終了") || section.heading.contains("（終了）") || section.heading.contains("(終了)") ? "受付終了" : nil,
                status: waiting ? .officiallyTBA : .confirmed,
                links: ownLinks,
                applyWindowText: markedLineText(raw, markers: ["受付期間", "受付時間", "申込期間", "発売日時", "発売日"]),
                resultText: markedLineText(raw, markers: ["当落発表", "当選発表"]),
                paymentStartAt: paymentDates.count >= 2 ? reinterpretJapanWallTime(paymentDates.first, in: timeZone) : nil,
                paymentWindowText: paymentWindowText,
                quantityLimit: quantityLimitText(in: lines),
                lotteryProducts: lotteryProducts(in: lines, html: section.html),
                applicationTarget: nil,
                notes: ticketNotes(in: lines, links: ownLinks)
            )
        }
        return uniqueByID(rounds)
    }

    struct ParsedTicketBenefits: Sendable {
        var benefits: [TicketBenefit]
        var mediaAssets: [MediaAsset]
    }

    /// "グッズ付きチケット特典" / "チケット特典": the bonus bundled with specific
    /// tiers. Headings about handing the bonus over (お渡し / 引換) are not
    /// benefits themselves; they extend the preceding benefit.
    static func isTicketBenefitHeading(_ heading: String) -> Bool {
        let value = clean(heading)
        guard value.contains("特典"), !isTicketBenefitRedemptionHeading(value) else { return false }
        return value.contains("チケット") || value.contains("グッズ付")
    }

    static func isTicketBenefitRedemptionHeading(_ heading: String) -> Bool {
        heading.contains("特典") && heading.range(of: "お渡し|引換|引き換え|受け取り|受取", options: .regularExpression) != nil
    }

    static func parseTicketBenefits(
        _ html: String,
        sourceURL: URL,
        eventID: String,
        tiers: [TicketTier],
        scope: Scope,
        cached: [TicketBenefit],
        cachedMedia: [MediaAsset]
    ) -> ParsedTicketBenefits {
        let sections = HTML.headingSections(html)
        let bundledTierIDs = tiers.filter { $0.name.contains("グッズ付") }.map(\.id)
        let upgradeTierIDs = tiers.filter { $0.name.contains("アップグレード") }.map(\.id)
        var media: [MediaAsset] = []
        var benefits: [TicketBenefit] = []
        for (index, section) in sections.enumerated() where isTicketBenefitHeading(section.heading) {
            // Some pages put the item itself in child headings under the
            // benefit heading (an h3 特典 with an h6 item name); fold those
            // children into the body so they are never mistaken for "TBA".
            var ownHTML = section.html
            var next = index + 1
            while next < sections.count, sections[next].level > section.level, !isTicketBenefitRedemptionHeading(sections[next].heading) {
                ownHTML += "\n<p>" + sections[next].heading + "</p>\n" + sections[next].html
                next += 1
            }
            let lines = HTML.text(ownHTML).components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
            let remarks = lines.filter { $0.hasPrefix("※") }
            let body = lines.filter { !$0.hasPrefix("※") }
            let bodyText = body.joined(separator: "\n")
            // "後日公開いたします。" is an official statement that nothing is
            // announced yet; keep the sentence, but never present it as contents.
            // An empty section is not a statement, so it is flagged for review.
            let officiallyTBA = bodyText.range(of: "後日|追って|未定|決まり次第", options: .regularExpression) != nil
            let status: DataStatus = officiallyTBA ? .officiallyTBA : body.isEmpty ? .needsReview : .confirmed
            let notes = ((officiallyTBA ? body : []) + remarks).joined(separator: "\n")
            let tierIDs = section.heading.contains("アップグレード") ? upgradeTierIDs : bundledTierIDs

            var redemptionHTML = ""
            while next < sections.count, isTicketBenefitRedemptionHeading(sections[next].heading) {
                redemptionHTML += sections[next].html + "\n"
                next += 1
            }
            let redemptionLines = HTML.text(redemptionHTML).components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
            func labeled(_ labels: [String]) -> (value: String?, consumed: Set<Int>) {
                for (lineIndex, line) in redemptionLines.enumerated() {
                    let label = line.trimmingCharacters(in: CharacterSet(charactersIn: "▼■【】：: "))
                    guard labels.contains(where: { label.hasPrefix($0) }) else { continue }
                    let inline = clean(String(line.drop { $0 != "：" && $0 != ":" }.dropFirst()))
                    if !inline.isEmpty { return (inline, [lineIndex]) }
                    if lineIndex + 1 < redemptionLines.count, !redemptionLines[lineIndex + 1].hasPrefix("※") {
                        return (redemptionLines[lineIndex + 1], [lineIndex, lineIndex + 1])
                    }
                    return (nil, [lineIndex])
                }
                return (nil, [])
            }
            let location = labeled(["引換場所", "引き換え場所", "お渡し場所", "受取場所", "受け取り場所"])
            let window = labeled(["引換日時", "引換時間", "引き換え日時", "引き換え時間", "お渡し日時", "お渡し時間", "受取時間", "受取日時"])
            let used = location.consumed.union(window.consumed)
            let redemptionNote = redemptionLines.enumerated().filter { !used.contains($0.offset) }.map(\.element).joined(separator: "\n")

            let assets = extractImages(ownHTML, relativeTo: sourceURL).map { image -> MediaAsset in
                let prior = cachedMedia.first { canonicalURL($0.originalURL) == canonicalURL(image.original.absoluteString) }
                return MediaAsset(
                    id: prior?.id ?? stableID(prefix: "\(eventID)-media", seed: canonicalURL(image.original.absoluteString)),
                    eventID: eventID, kind: .product, originalURL: image.original.absoluteString,
                    thumbnailURL: image.thumbnail?.absoluteString ?? prior?.thumbnailURL,
                    scope: scope, sourceURL: sourceURL.absoluteString,
                    version: (prior?.version ?? 0) + 1, caption: section.heading,
                    displayPolicy: .remoteDisplay, contentKind: .image
                )
            }
            media.append(contentsOf: assets)
            let name = clean(section.heading)
            benefits.append(TicketBenefit(
                id: cached.first { clean($0.officialName) == name }?.id ?? stableID(prefix: "\(eventID)-ticket-benefit", seed: name),
                eventID: eventID, officialName: name, scope: scope, tierIDs: tierIDs,
                detail: status == .confirmed ? bodyText : nil, notes: notes.isEmpty ? nil : notes,
                redemptionLocation: location.value, redemptionWindow: window.value,
                redemptionNote: redemptionNote.isEmpty ? nil : redemptionNote,
                mediaAssetIDs: assets.map(\.id), status: status,
                links: classifiedLinks(HTML.links(ownHTML + "\n" + redemptionHTML, relativeTo: sourceURL))
            ))
        }
        let uniqueMedia = Dictionary(media.map { (canonicalURL($0.originalURL), $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
        return ParsedTicketBenefits(benefits: uniqueByID(benefits), mediaAssets: uniqueMedia)
    }

    /// Goods-bundled tiers inherit the announced bonus contents so the price
    /// list can show what the surcharge buys.
    static func tiersWithBenefitContents(_ tiers: [TicketTier], benefits: [TicketBenefit]) -> [TicketTier] {
        tiers.map { tier in
            guard tier.includes == nil, tier.name.contains("グッズ付"),
                  let detail = benefits.first(where: { $0.tierIDs.contains(tier.id) && $0.detail != nil })?.detail else { return tier }
            return TicketTier(id: tier.id, eventID: tier.eventID, name: tier.name, priceJPY: tier.priceJPY, priceKind: tier.priceKind,
                amount: tier.amount, includes: detail, feeNote: tier.feeNote, taxNote: tier.taxNote)
        }
    }

    /// Love Live ticket pages have no per-round heading tags: rounds are
    /// `＜最速先行抽選＞`-style marker lines, each with one or more
    /// `★申込対象：` sub-blocks that carry their own product list and
    /// `■label：value` fields.
    static func parseLoveLiveTicketRounds(_ html: String, eventID: String, cached: [TicketRound], timeZone: String, referenceDate: String?, sourceURL: URL?) -> [TicketRound] {
        struct Line { let text: String; let struck: Bool; let links: [OfficialLink] }
        let lines: [Line] = HTML.annotatedLines(html, relativeTo: sourceURL).map { Line(text: $0.text, struck: $0.struck, links: $0.links) }

        struct Block {
            var roundHeading: String
            var target: String?
            var productLines: [Line] = []
            var allLines: [Line] = []
            var fieldStruckFlags: [Bool] = []
            var targetLine: Line?
            var applyWindowText: String?
            var applyDates: [Date] = []
            var resultText: String?
            var resultDates: [Date] = []
            var paymentWindowText: String?
            var paymentDates: [Date] = []
            var quantityLimit: String?
            var applicationTargetField: String?
            var receiptLinks: [OfficialLink] = []
            var extraNotes: [TicketNote] = []
        }

        let roundHeadingRE = #"^[＜<〈]([^＜＞<>〈〉]+)[＞>〉]$"#
        let roundHeadingKeywords = ["先行", "抽選", "発売", "販売", "受付", "トレード", "リセール", "当日券", "先着", "アップグレード"]
        let targetRE = #"^[★■]\s*申込対象[：:]\s*(.*)$"#
        let separatorRE = #"^[-ー─]{5,}$"#
        let fieldRE = #"^[■□◆●※]?\s*(受付期間|受付時間|申込期間|発売日時|発売日|当落発表|当選発表|抽選結果|入金期間|支払期間|支払い期間|支払期限|受付URL|申込URL|対象公演|枚数制限|支払い方法|支払方法)\s*[：:]\s*(.*)$"#
        let sectionHeadingRE = #"^【([^】]+)】"#

        var blocks: [Block] = []
        var currentBlock: Block?
        var currentRoundHeading: String?
        var startedAnyRound = false
        var inProductRegion = false
        var sectionNoteLines: [Line] = []
        var inSectionNotes = false

        func flush() {
            if let block = currentBlock { blocks.append(block) }
            currentBlock = nil
        }

        var index = 0
        outer: while index < lines.count {
            let line = lines[index]
            let text = line.text

            if inSectionNotes {
                if text.hasPrefix(HTML.headingLineMarker) { inSectionNotes = false } else {
                    sectionNoteLines.append(line)
                    index += 1
                    continue
                }
            }

            if text.hasPrefix(HTML.headingLineMarker) {
                if startedAnyRound { flush(); break outer }
                index += 1
                continue
            }

            if regex(sectionHeadingRE, text).first != nil, regex(fieldRE, text).first == nil {
                flush()
                inSectionNotes = true
                sectionNoteLines.append(line)
                index += 1
                continue
            }

            if let match = regex(roundHeadingRE, text).first, let inner = group(match, 1, in: text),
               roundHeadingKeywords.contains(where: { inner.contains($0) }) {
                flush()
                startedAnyRound = true
                currentRoundHeading = clean(inner)
                inProductRegion = false
                index += 1
                continue
            }

            guard let roundHeading = currentRoundHeading else { index += 1; continue }

            if let match = regex(targetRE, text).first {
                flush()
                let rawTarget = group(match, 1, in: text) ?? ""
                let stripped = rawTarget.replacingOccurrences(of: #"^[＜<]|[＞>]$"#, with: "", options: .regularExpression)
                var block = Block(roundHeading: roundHeading)
                block.target = clean(stripped)
                block.targetLine = line
                block.allLines.append(line)
                currentBlock = block
                inProductRegion = true
                index += 1
                continue
            }

            if currentBlock == nil {
                currentBlock = Block(roundHeading: roundHeading)
                inProductRegion = true
            }

            if regex(separatorRE, text).first != nil {
                inProductRegion = false
                currentBlock?.allLines.append(line)
                index += 1
                continue
            }

            if let match = regex(fieldRE, text).first, let label = group(match, 1, in: text) {
                inProductRegion = false
                var value = (group(match, 2, in: text) ?? "").trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    var gathered: [String] = []
                    var lookahead = index + 1
                    while lookahead < lines.count {
                        let candidateText = lines[lookahead].text
                        if candidateText.hasPrefix(HTML.headingLineMarker) { break }
                        if regex(fieldRE, candidateText).first != nil { break }
                        if regex(separatorRE, candidateText).first != nil { break }
                        if regex(targetRE, candidateText).first != nil { break }
                        if regex(roundHeadingRE, candidateText).first != nil { break }
                        if regex(sectionHeadingRE, candidateText).first != nil { break }
                        gathered.append(candidateText)
                        currentBlock?.allLines.append(lines[lookahead])
                        lookahead += 1
                    }
                    value = gathered.joined(separator: "\n")
                    index = lookahead - 1
                }
                currentBlock?.allLines.append(line)
                currentBlock?.fieldStruckFlags.append(line.struck)

                switch label {
                case "受付期間", "受付時間", "申込期間", "発売日時", "発売日":
                    currentBlock?.applyWindowText = value
                    currentBlock?.applyDates = parseExplicitDateTimes(injectYearIfNeeded(value, referenceDate: referenceDate))
                case "当落発表", "当選発表", "抽選結果":
                    currentBlock?.resultText = value
                    currentBlock?.resultDates = parseExplicitDateTimes(injectYearIfNeeded(value, referenceDate: referenceDate))
                case "入金期間", "支払期間", "支払い期間", "支払期限":
                    currentBlock?.paymentWindowText = value
                    currentBlock?.paymentDates = parseExplicitDateTimes(injectYearIfNeeded(value, referenceDate: referenceDate))
                case "受付URL", "申込URL":
                    let url = line.links.first?.url ?? regex(#"https?://\S+"#, value).first.flatMap { group($0, 0, in: value) }
                    if let url { currentBlock?.receiptLinks.append(OfficialLink(label: "受付URL", url: url)) }
                case "対象公演":
                    if currentBlock?.applicationTargetField == nil { currentBlock?.applicationTargetField = value }
                case "枚数制限":
                    currentBlock?.quantityLimit = value
                case "支払い方法", "支払方法":
                    let kind: TicketNoteKind = value.contains("クレジット") ? .creditCardOnly : .other
                    currentBlock?.extraNotes.append(TicketNote(kind: kind, text: value, links: []))
                default: break
                }
                index += 1
                continue
            }

            if inProductRegion {
                currentBlock?.productLines.append(line)
            }
            currentBlock?.allLines.append(line)
            index += 1
        }
        flush()

        let sectionNotes = ticketNotes(
            in: sectionNoteLines.map(\.text),
            links: classifiedLinks(sectionNoteLines.flatMap(\.links))
        )

        func loveLiveLotteryProducts(_ productLines: [Line]) -> [String] {
            var results: [String] = []
            for line in productLines {
                var text = line.text
                if regex(targetRE, text).first != nil { continue }
                if regex(separatorRE, text).first != nil { continue }
                if regex(#"^\d{4}年\d{1,2}月\d{1,2}日.*発売$"#, text).first != nil { continue }
                if text.contains("にて受付") { continue }
                if text.hasPrefix("※") { continue }
                if text.contains("下記いずれか") || text.contains("ご好評につき") || text.contains("機材席")
                    || text.contains("販売が決定") || text.hasSuffix("。") { continue }
                text = text.replacingOccurrences(of: #"^[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳・]+"#, with: "", options: .regularExpression)
                text = text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if text.hasPrefix("「") || text.hasPrefix("『"), let lastIndex = results.indices.last,
                   !(results[lastIndex].contains("「") || results[lastIndex].contains("『")) {
                    results[lastIndex] += " " + text
                } else {
                    results.append(text)
                }
            }
            var seen: Set<String> = []
            return results.map(clean).filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        let rounds: [TicketRound] = blocks.compactMap { block in
            let officialName = block.target.map { "\(block.roundHeading)（\($0)）" } ?? block.roundHeading
            let allText = block.allLines.map(\.text).joined(separator: "\n") + "\n" + block.productLines.map(\.text).joined(separator: "\n")
            let nameAndFields = officialName + allText

            let kind: TicketRoundKind = nameAndFields.contains("先着") || nameAndFields.contains("当日券") ? .firstComeFirstServed
                : nameAndFields.contains("トレード") || nameAndFields.contains("リセール") ? .resale
                : nameAndFields.contains("アップグレード") ? .upgrade
                : (nameAndFields.contains("抽選") || block.resultText != nil) ? .lottery
                : .other

            let structFlags = block.fieldStruckFlags.isEmpty ? [block.targetLine?.struck ?? false] : block.fieldStruckFlags
            let allStruck = !structFlags.isEmpty && structFlags.allSatisfy { $0 }
            let headingClosed = block.roundHeading.contains("（終了）") || block.roundHeading.contains("(終了)") || block.roundHeading.contains("受付終了")
            let officialStatus: String? = (allStruck || headingClosed) ? "受付終了" : nil

            let ownLinks = classifiedLinks(block.allLines.flatMap(\.links) + block.productLines.flatMap(\.links) + block.receiptLinks)
            let applyDates = block.applyDates.compactMap { reinterpretJapanWallTime($0, in: timeZone) }
            let resultDate = block.resultDates.last.flatMap { reinterpretJapanWallTime($0, in: timeZone) }
            let paymentDates = block.paymentDates.compactMap { reinterpretJapanWallTime($0, in: timeZone) }

            let blockNotes = ticketNotes(in: block.allLines.map(\.text) + block.productLines.map(\.text), links: ownLinks) + block.extraNotes
            var seenNoteIDs: Set<String> = []
            let notes = (blockNotes + sectionNotes).filter { seenNoteIDs.insert($0.id).inserted }

            let hasDates = !applyDates.isEmpty || resultDate != nil || !paymentDates.isEmpty
            let isWaiting = !hasDates && nameAndFields.range(of: "後日|追って|未定", options: .regularExpression) != nil

            let lotteryProducts = loveLiveLotteryProducts(block.productLines)
            let identity = ticketRoundIdentity(officialName)
            let id = cached.first(where: { ticketRoundIdentity($0.officialName) == identity })?.id
                ?? "\(eventID)-round-\(stableHash(identity))"

            return TicketRound(
                id: id, eventID: eventID,
                officialName: officialName, kind: kind,
                scope: .unconfirmed,
                applyStartAt: applyDates.first, applyEndAt: applyDates.dropFirst().first,
                resultAt: resultDate,
                paymentDeadlineAt: paymentDates.last,
                eligibility: allText.range(of: "封入|申込券|ムビチケ", options: .regularExpression) != nil ? allText : nil,
                announcementURL: nil,
                applyURL: applicationURL(in: ownLinks),
                overseasURL: overseasApplicationURL(in: ownLinks),
                officialStatus: officialStatus,
                status: isWaiting ? .officiallyTBA : .confirmed,
                links: ownLinks,
                applyWindowText: block.applyWindowText,
                resultText: block.resultText,
                paymentStartAt: block.paymentDates.count >= 2 ? paymentDates.first : nil,
                paymentWindowText: block.paymentWindowText,
                quantityLimit: block.quantityLimit,
                lotteryProducts: lotteryProducts,
                applicationTarget: block.target ?? block.applicationTargetField,
                notes: notes
            )
        }
        return uniqueByID(rounds)
    }

    static func parseStreams(_ html: String, sourceURL: URL, eventID: String) -> [StreamOffer] {
        guard let heading = HTML.headingSections(html).first(where: { $0.heading.hasPrefix("配信チケット") }),
              let section = HTML.sectionHTML(html, heading: heading.heading) else { return [] }
        let raw = HTML.text(section)
        let links = HTML.allAttributes(section, tag: "a", name: "href").compactMap { URL(string: HTML.decode($0), relativeTo: sourceURL)?.absoluteURL }
        let url = links.first { $0.host?.contains("eplus") == true }?.absoluteString
        let prices = parseTicketTiers(section, eventID: eventID, cached: [])
        var offers: [StreamOffer] = []
        let allDates = parseExplicitDateTimes(raw)
        let year = allDates.first.map { japanCalendar.component(.year, from: $0) }
        let priceRows: [(String, MoneyAmount?)] = prices.isEmpty ? [("配信チケット", regex(#"([\d,]+)円"#, raw).first.flatMap { group($0, 1, in: raw)?.replacingOccurrences(of: ",", with: "") }.flatMap(Int64.init).map { MoneyAmount(minorUnits: $0, currency: "JPY") })] : prices.map { ($0.name, $0.amount) }
        for (name, amount) in priceRows {
            let detail = HTML.sectionText(section, heading: name) ?? raw
            // A DAY label makes each archive deadline an independent offer.
            let dayMatches = regex(#"[・●]?\s*DAY\s*\d+"#, detail)
            var slices: [(String, String)] = []
            if dayMatches.count > 1 {
                let ns = detail as NSString
                for (index, match) in dayMatches.enumerated() {
                    let end = index + 1 < dayMatches.count ? dayMatches[index + 1].range.location : ns.length
                    slices.append((name + " " + (group(match, 0, in: detail) ?? ""), ns.substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))))
                }
            } else { slices = [(name, detail)] }
            for (label, slice) in slices {
                let sales = slice.range(of: "販売期間").map { String(slice[$0.upperBound...]) }
                let salesPart = sales.map { $0.components(separatedBy: "配信期間")[0] } ?? ""
                let dates = parseExplicitDateTimes(salesPart)
                var archiveText = slice.range(of: "配信期間").map { String(slice[$0.upperBound...]).components(separatedBy: "\n")[0] } ?? ""
                if !archiveText.contains("年"), let year { archiveText = archiveText.replacingOccurrences(of: #"^[：:\s～〜]+"#, with: "", options: .regularExpression); archiveText = "\(year)年" + archiveText }
                let archive = parseExplicitDateTimes(archiveText).last
                guard amount != nil || url != nil || !dates.isEmpty else { continue }
                offers.append(StreamOffer(id: stableID(prefix: "\(eventID)-stream", seed: label), eventID: eventID,
                    platform: url?.contains("eplus") == true ? "Streaming+" : "公式配信", officialName: label,
                    scope: .unconfirmed, amount: amount, salesStartAt: dates.first, salesEndAt: dates.dropFirst().first,
                    archiveAvailableUntil: archive, regionNote: nil, url: url, status: .confirmed))
            }
        }
        return offers
    }

    static func parseMediaAssets(
        _ html: String,
        sourceURL: URL,
        eventID: String,
        cached: [MediaAsset],
        eventCoverURL: URL?,
        eventCoverSourceURL: URL?
    ) -> [MediaAsset] {
        var assets: [MediaAsset] = []
        if let eventCoverURL {
            let prior = cached
                .filter { $0.kind == .eventCover }
                .max { $0.version < $1.version }
            assets.append(MediaAsset(
                id: prior?.id ?? stableID(prefix: "\(eventID)-event-cover", seed: eventID),
                eventID: eventID, kind: .eventCover, originalURL: eventCoverURL.absoluteString,
                thumbnailURL: nil, scope: .unconfirmed, sourceURL: (eventCoverSourceURL ?? sourceURL).absoluteString,
                version: (prior?.version ?? 0) + 1, caption: "公演一覧サムネイル",
                displayPolicy: .remoteDisplay, contentKind: .image
            ))
        }
        if let visual = eventKeyVisual(in: html, relativeTo: sourceURL) {
            let prior = cached
                .filter { $0.kind == .keyVisual }
                .max { $0.version < $1.version }
            assets.append(MediaAsset(
                id: prior?.id ?? stableID(prefix: "\(eventID)-key-visual", seed: eventID),
                eventID: eventID, kind: .keyVisual, originalURL: visual.absoluteString,
                thumbnailURL: nil, scope: .unconfirmed, sourceURL: sourceURL.absoluteString,
                version: (prior?.version ?? 0) + 1, caption: "公演キービジュアル",
                displayPolicy: .remoteDisplay, contentKind: .image
            ))
        }
        let sections = HTML.headingSections(html).filter { $0.heading.contains("座席") || $0.heading.contains("会場エリア") }
        assets.append(contentsOf: sections.flatMap { section in
            extractImages(HTML.sectionHTML(html, heading: section.heading) ?? section.html, relativeTo: sourceURL).map { image in
                let prior = cached.first { canonicalURL($0.originalURL) == canonicalURL(image.original.absoluteString) }
                return MediaAsset(
                    id: prior?.id ?? stableID(prefix: "\(eventID)-media", seed: canonicalURL(image.original.absoluteString)),
                    eventID: eventID, kind: .eventSeatingMap, originalURL: image.original.absoluteString,
                    thumbnailURL: image.thumbnail?.absoluteString ?? prior?.thumbnailURL, scope: .unconfirmed,
                    sourceURL: sourceURL.absoluteString, version: (prior?.version ?? 0) + 1,
                    caption: section.heading, displayPolicy: .remoteDisplay, contentKind: .image
                )
            }
        })
        return assets
    }

    static func eventKeyVisual(in html: String, relativeTo sourceURL: URL) -> URL? {
        let ogImage = HTML.metaContent(html, property: "og:image")
            .flatMap { resolvedImageURL($0, relativeTo: sourceURL) }
            .flatMap { isGenericSocialImage($0) ? nil : $0 }

        if sourceURL.host == "bang-dream.com" {
            let eyecatch = HTML.blocks(html, tag: "div", className: "p-live-event-detail__eyecatch")
                .compactMap { bestImageSource(in: $0, relativeTo: sourceURL) }
                .first
            return eyecatch ?? ogImage
        }

        guard sourceURL.host == "www.lovelive-anime.jp" else { return nil }
        let articleVisuals = loveLiveStructuredDetail(in: html).map { detail in
            HTML.blocks(detail, tag: "div", className: "main-img")
                .compactMap { bestImageSource(in: $0, relativeTo: sourceURL) }
        } ?? []
        if let ogImage, let ogImagePath = officialImagePath(ogImage),
           let renderedVisual = articleVisuals.first(where: { officialImagePath($0) == ogImagePath }) {
            // Liella pages currently publish an og:image endpoint that returns
            // 404, while the article renders the same img_path through its
            // working ../common/api/image.php endpoint. Preserve that official
            // body URL instead of synthesizing a replacement.
            return renderedVisual
        }
        if let ogImage { return ogImage }
        // Some branches publish one site-wide OGP image on every page. The
        // first photo in the structured event article is the event artwork;
        // later photos include seating diagrams, benefits and merchandise.
        return articleVisuals.first
    }

    static func officialImagePath(_ url: URL) -> String? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "img_path" })?.value else { return nil }
        // A few OGP tags append their cache key as a second '?' inside the
        // img_path query value. It is not part of the stored image identity.
        return value.split(separator: "?", maxSplits: 1).first.map(String.init)
    }

    static func isGenericSocialImage(_ url: URL) -> Bool {
        let value = url.path.lowercased()
        let filename = url.deletingPathExtension().lastPathComponent
        return ["ogp", "og-image", "og_image", "default-og", "default_og", "logo", "favicon", "webclip"]
            .contains(filename)
            || value.contains("/common/og")
            || value.contains("/shared/og")
    }

    static func parseGoods(
        _ html: String,
        sourceURL: URL,
        eventID: String,
        cachedCampaigns: [GoodsCampaign],
        cachedMedia: [MediaAsset]
    ) -> ParsedGoods {
        var sections = HTML.headingSections(html)
            .filter { isGoodsHeading($0.heading) }
            .map { heading in
                (heading: heading.heading, html: HTML.sectionHTML(html, heading: heading.heading) ?? heading.html)
            }
        if sections.isEmpty, let goods = HTML.blockWithAttribute(html, attribute: "data-target", value: "goods") {
            sections = [(heading: "グッズ", html: goods)]
        }
        var media: [MediaAsset] = []
        let campaigns = sections.compactMap { section -> GoodsCampaign? in
            let text = HTML.text(section.html)
            let imageSources = extractImages(section.html, relativeTo: sourceURL)
            let assets = imageSources.map { image -> MediaAsset in
                let prior = cachedMedia.first { canonicalURL($0.originalURL) == canonicalURL(image.original.absoluteString) }
                return MediaAsset(
                    id: prior?.id ?? stableID(prefix: "\(eventID)-media", seed: canonicalURL(image.original.absoluteString)),
                    eventID: eventID, kind: .goodsList, originalURL: image.original.absoluteString,
                    thumbnailURL: image.thumbnail?.absoluteString ?? prior?.thumbnailURL,
                    scope: .unconfirmed, sourceURL: sourceURL.absoluteString,
                    version: (prior?.version ?? 0) + 1, caption: section.heading,
                    displayPolicy: .remoteDisplay, contentKind: .image
                )
            }
            media.append(contentsOf: assets)
            let link = HTML.allAttributes(section.html, tag: "a", name: "href")
                .compactMap { URL(string: HTML.decode($0), relativeTo: sourceURL)?.absoluteURL }
                .first { ($0.scheme == "https" || $0.scheme == "http") && !isDirectImageURL($0) }
            guard link != nil || !text.isEmpty || !assets.isEmpty else { return nil }
            let channel: GoodsChannel = section.heading.contains("会場") ? .venue
                : section.heading.contains("通販") ? .online
                : text.contains("会場販売") ? .venue : text.contains("通販") ? .online : .unknown
            let fulfillment: GoodsFulfillment = channel == .online ? .shipping : channel == .venue ? .venuePickup : .unknown
            let phase: GoodsPhase = section.heading.contains("事後") || text.contains("事後通販") ? .post
                : section.heading.contains("事前") || section.heading.contains("先行") || text.contains("事前通販") || text.contains("先行通販") ? .pre
                : channel == .venue ? .during : .unknown
            let salesText = ["先行通販開始", "通販期間", "販売期間", "受付期間", "販売日時"]
                .compactMap { HTML.sectionText(section.html, heading: $0) }.first
            let salesDates = parseExplicitDateTimes(salesText ?? "")
            let location = HTML.sectionText(section.html, heading: "販売場所")
            let purchaseLimit = HTML.sectionText(section.html, heading: "購入制限について")
                ?? HTML.sectionText(section.html, heading: "購入制限")
            let payment = text.split(separator: "\n").filter {
                $0.contains("現金") || $0.contains("クレジット") || $0.contains("QR決済") || $0.contains("PayPay")
            }.joined(separator: "\n")
            let key = link.map { canonicalURL($0.absoluteString) } ?? clean(section.heading)
            let prior = cachedCampaigns.first { campaign in
                if let lhs = campaign.url, let link { return canonicalURL(lhs) == canonicalURL(link.absoluteString) }
                return clean(campaign.officialName) == clean(section.heading)
            }
            return GoodsCampaign(
                id: prior?.id ?? stableID(prefix: "\(eventID)-goods", seed: key), eventID: eventID,
                officialName: section.heading, channel: channel, fulfillment: fulfillment, phase: phase,
                scope: .unconfirmed, salesStartAt: salesDates.first, salesEndAt: salesDates.dropFirst().first, pickupWindow: channel == .venue ? salesText : nil,
                shippingNote: nil, location: location, requiresTicket: nil, purchaseLimit: purchaseLimit,
                paymentMethods: payment.isEmpty ? nil : payment, url: link?.absoluteString,
                mediaAssetIDs: assets.map(\.id), status: .confirmed,
                links: HTML.links(section.html, relativeTo: sourceURL)
            )
        }
        let uniqueMedia = Dictionary(media.map { (canonicalURL($0.originalURL), $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
        return ParsedGoods(campaigns: campaigns, mediaAssets: uniqueMedia)
    }

    static func isGoodsHeading(_ heading: String) -> Bool {
        heading.contains("グッズ通販") || heading.contains("グッズ販売") || heading.contains("事前通販") || heading == "グッズ情報" || (heading.hasPrefix("グッズ") && heading.contains("販売"))
    }

    static func extractImages(_ html: String, relativeTo baseURL: URL) -> [(original: URL, thumbnail: URL?)] {
        var results: [(URL, URL?)] = []
        var anchorImages: Set<String> = []
        for anchor in HTML.blocks(html, tag: "a", className: nil) {
            guard let rawHref = HTML.firstAttribute(anchor, tag: "a", name: "href"),
                  let href = resolvedImageURL(rawHref, relativeTo: baseURL),
                  isDirectImageURL(href) else { continue }
            let thumbnail = bestImageSource(in: anchor, relativeTo: baseURL)
            results.append((href, thumbnail == href ? nil : thumbnail))
            anchorImages.formUnion(HTML.startTags(anchor, tag: "img"))
        }
        for imageTag in HTML.startTags(html, tag: "img") where !anchorImages.contains(imageTag) {
            guard let source = bestImageSource(in: imageTag, relativeTo: baseURL) else { continue }
            results.append((source, nil))
        }
        var seen: Set<String> = []
        return results.filter { seen.insert(canonicalURL($0.0.absoluteString)).inserted }
    }

    static func bestImageSource(in html: String, relativeTo baseURL: URL) -> URL? {
        for attribute in ["data-src", "data-lazy-src"] {
            if let raw = HTML.firstAttribute(html, tag: "img", name: attribute),
               let url = resolvedImageURL(raw, relativeTo: baseURL) { return url }
        }
        if let srcset = HTML.firstAttribute(html, tag: "img", name: "srcset") {
            let candidates = srcset.split(separator: ",").compactMap { entry -> (URL, Int)? in
                let parts = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
                guard let raw = parts.first, let url = resolvedImageURL(String(raw), relativeTo: baseURL) else { return nil }
                let width = parts.dropFirst().first.flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789").inverted)) } ?? 0
                return (url, width)
            }
            if let best = candidates.max(by: { $0.1 < $1.1 })?.0 { return best }
        }
        if let raw = HTML.firstAttribute(html, tag: "img", name: "src"),
           let url = resolvedImageURL(raw, relativeTo: baseURL) {
            return url
        }
        return nil
    }

    static func resolvedImageURL(_ raw: String, relativeTo baseURL: URL) -> URL? {
        let value = HTML.decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isPlaceholderImage(value),
              let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    static func isPlaceholderImage(_ raw: String) -> Bool {
        let value = raw.lowercased()
        return value.hasPrefix("data:") || ["placeholder", "spacer", "transparent", "blank.gif", "1x1", "loading.gif"]
            .contains(where: value.contains)
    }

    static func isDirectImageURL(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased().removingPercentEncoding ?? url.absoluteString.lowercased()
        return value.range(of: #"\.(?:jpe?g|png|webp|gif|avif)(?:[?#&]|$)"#, options: .regularExpression) != nil
    }

    static func mergeMedia(_ cached: [MediaAsset], _ parsed: [MediaAsset]) -> [MediaAsset] {
        let refreshedCoverKinds = Set(parsed.compactMap { asset -> MediaAssetKind? in
            switch asset.kind {
            case .eventCover, .keyVisual: return asset.kind
            default: return nil
            }
        })
        let cachedForMerge = cached.filter { !refreshedCoverKinds.contains($0.kind) }
        return Dictionary((cachedForMerge + parsed).map { (canonicalURL($0.originalURL), $0) }, uniquingKeysWith: { _, fresh in fresh })
            .values.sorted { $0.id < $1.id }
    }

    static func mergeGoods(_ cached: [GoodsCampaign], _ parsed: [GoodsCampaign]) -> [GoodsCampaign] {
        func key(_ value: GoodsCampaign) -> String { value.url.map(canonicalURL) ?? clean(value.officialName) }
        return Dictionary((cached + parsed).map { (key($0), $0) }, uniquingKeysWith: { _, fresh in fresh })
            .values.sorted { $0.id < $1.id }
    }

    static func parseExplicitDateTime(_ raw: String) -> Date? { parseExplicitDateTimes(raw).first }

    static func parseExplicitDateTimes(_ raw: String) -> [Date] {
        let source = raw.precomposedStringWithCompatibilityMapping
        let pattern = #"(?:(\d{4})年)?(?:(\d{1,2})月)?(\d{1,2})日(?:\([^)]*\))?\s*(\d{1,2})(?::|時)(\d{2})(?:分)?"#
        var year: Int?
        var month: Int?
        return regex(pattern, source).compactMap { match in
            let explicitYear = group(match, 1, in: source).flatMap(Int.init)
            if let explicitYear { year = explicitYear }
            if let m = group(match, 2, in: source).flatMap(Int.init) {
                if explicitYear == nil, let previousMonth = month, m < previousMonth, let previousYear = year { year = previousYear + 1 }
                month = m
            }
            guard let year, let month, let day = group(match, 3, in: source).flatMap(Int.init),
                  validDate(year: year, month: month, day: day) != nil else { return nil }
            return timeDate(String(format: "%04d-%02d-%02d", year, month, day), hour: group(match, 4, in: source), minute: group(match, 5, in: source))
        }
    }

    static func markedText(_ raw: String, markers: [String]) -> String? {
        guard let range = markers.compactMap({ raw.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let tail = String(raw[range.upperBound...])
        // Allow a range to wrap, but don't consume a result/payment date as its end.
        let boundary = tail.range(of: #"当落|当選発表|結果|入金|支払|受付URL|申込URL|※"#, options: .regularExpression)
        return boundary.map { String(tail[..<$0.lowerBound]) } ?? tail
    }

    static func markerDate(_ raw: String, marker: String) -> Date? {
        guard let range = raw.range(of: marker) else { return nil }
        return parseExplicitDateTime(String(raw[range.lowerBound...]))
    }

    static func makeEvidence(recordID: String, field: String, sourceURL: URL, quote: String, now: Date) -> SourceEvidence {
        SourceEvidence(id: stableID(prefix: "evidence", seed: "\(recordID)|\(field)|\(quote)"), recordID: recordID, field: field, sourceURL: sourceURL.absoluteString, quote: String(quote.prefix(2_000)), sourcePublishedAt: nil, verifiedAt: now, verification: .confirmed)
    }

    static func eventType(_ raw: String) -> EventType {
        if raw.contains("ファンミ") { return .fanMeeting }
        if raw.contains("上映") || raw.localizedCaseInsensitiveContains("FILM LIVE") { return .screening }
        if raw.contains("ライブ") || raw.localizedCaseInsensitiveContains("live") { return .live }
        return .other
    }

    static func loveLiveGroup(for url: URL) -> String? {
        let path = url.path.lowercased()
        if path.contains("uranohoshi") { return "Aqours" }
        if path.contains("nijigasaki") { return "虹ヶ咲学園スクールアイドル同好会" }
        if path.contains("yuigaoka") { return "Liella!" }
        if path.contains("hasunosora") { return "蓮ノ空女学院スクールアイドルクラブ" }
        if path.contains("lovehigh") { return "いきづらい部！" }
        return nil
    }

    static func nextOfficialIndexURL(_ html: String, relativeTo baseURL: URL) -> URL? {
        HTML.allAttributes(html, tag: "a", name: "href")
            .compactMap { URL(string: HTML.decode($0), relativeTo: baseURL)?.absoluteURL }
            .first { url in
                guard url.host == baseURL.host else { return false }
                if url.host == "bang-dream.com",
                   url.path.range(of: #"^/events/page/\d+/$"#, options: .regularExpression) != nil {
                    let current = Int(baseURL.path.split(separator: "/").last(where: { Int($0) != nil }) ?? "1") ?? 1
                    let candidate = Int(url.path.split(separator: "/").last(where: { Int($0) != nil }) ?? "0") ?? 0
                    return candidate == current + 1
                }
                guard url.host == "www.lovelive-anime.jp", url.path == baseURL.path else { return false }
                let current = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? 1
                let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "page" })?.value.flatMap(Int.init)
                return candidate == current + 1
            }
    }

    static func mergeEvidence(_ old: [SourceEvidence], _ new: [SourceEvidence]) -> [SourceEvidence] {
        Dictionary((old + new).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            .values.sorted { $0.id < $1.id }
    }

    static func datedContexts(_ text: String, year: String, month: String) -> [(dates: [String], context: String)] {
        let source = text.precomposedStringWithCompatibilityMapping
        let matches = regex(#"(?:(\d{4})年)?(?:(\d{1,2})月)?(\d{1,2})日(?:\([^)]*\))?"#, source)
        var y = Int(year) ?? 0
        var m = Int(month) ?? 0
        var pending: [String] = []
        var result: [(dates: [String], context: String)] = []
        for (index, match) in matches.enumerated() {
            if let value = group(match, 1, in: source).flatMap(Int.init) { y = value }
            if let value = group(match, 2, in: source).flatMap(Int.init) { m = value }
            guard let d = group(match, 3, in: source).flatMap(Int.init), validDate(year: y, month: m, day: d) != nil else { continue }
            pending.append(String(format: "%04d-%02d-%02d", y, m, d))
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (source as NSString).length
            let tail = (source as NSString).substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
            if tail.range(of: #"[^・、,\s]"#, options: .regularExpression) != nil {
                result.append((pending, tail))
                pending = []
            }
        }
        return result
    }

    static func scopedVenue(_ rawVenue: String, note: String, date: String) -> String? {
        let lines = rawVenue.split(separator: "\n").map(String.init)
        let venues = lines.compactMap { line -> (String, String)? in
            guard let match = regex(#"^(.+?)[（(]([^）)]+?)(?:公演|会場)[）)]"#, line).first,
                  let venue = group(match, 1, in: line), let city = group(match, 2, in: line) else { return nil }
            return (clean(venue), city)
        }
        guard venues.count > 1 else { return nil }
        let parts = date.split(separator: "-").map(String.init)
        let contexts = datedContexts(note, year: parts[0], month: parts[1])
        for context in contexts where context.dates.contains(date) {
            if let venue = venues.first(where: { context.context.contains($0.1) }) { return venue.0 }
        }
        return ""
    }

    static func notedPerformers(_ note: String, groups: [String], date: String, singleDate: Bool) -> [String] {
        let parts = date.split(separator: "-").map(String.init)
        let contexts = datedContexts(note, year: parts[0], month: parts[1])
        let applicable = contexts.filter { $0.dates.contains(date) }.map(\.context).joined(separator: "\n")
        let mentionedGroups = groups.filter { note.contains($0) }
        let text = (contexts.isEmpty && singleDate) || (mentionedGroups.count == 1 && contexts.contains { $0.dates.contains(date) }) ? note : applicable
        return groups.filter { text.contains($0) }.map { group in
            // The official notice names an individual guest from this group.
            if group == "夢限大みゅーたいぷ", text.contains("千石ユノ") { return "千石ユノ（夢限大みゅーたいぷ）" }
            return group
        }
    }

    static func cleanedVenue(_ raw: String, summary: String?) -> String {
        let value = clean(raw).replacingOccurrences(of: #"^【(?:会場|場所)】\s*"#, with: "", options: .regularExpression)
        if value.contains("http"), let summary, !summary.isEmpty { return clean(summary) }
        return value
    }

    static func venueFromOverview(_ raw: String) -> String? {
        if let marker = raw.range(of: "■会場", options: .backwards) {
            var value = String(raw[marker.upperBound...])
            if let boundary = value.range(of: #"(?:■|出演)"#, options: .regularExpression) {
                value = String(value[..<boundary.lowerBound])
            }
            let cleaned = clean(value.replacingOccurrences(of: #"^[：:\s]+"#, with: "", options: .regularExpression))
            if !cleaned.isEmpty { return cleaned }
        }
        // Love Live editor text often stacks the label and value ("【会場】<br> 東京・日本武道館"),
        // so an explicit label (bracketed or with a colon) may carry its value on the
        // immediately following line; a bare 会場 keeps same-line only; the ■会場 branch above is unchanged.
        guard let match = regex(#"(?:^|\n)[\s　]*(?:(?:【(?:会場|場所)】|(?:会場|開催場所)[：:])[ \t　]*(?:\n[ \t　]*)?|(?:会場|開催場所)[ \t　]*)([^\n■【]+)"#, raw).first else { return nil }
        return group(match, 1, in: raw).map(clean)
    }

    /// Some Love Live branches (LL03/04/05/10/15/17) put the cast after an inline
    /// `【出演】` line inside the overview text, with the value on the following
    /// line(s) until the next `【…】`/`■` label or blank line.
    static func stackedLabelValue(_ raw: String, labels: [String]) -> String? {
        let lines = raw.components(separatedBy: "\n")
        let labelSet = Set(labels)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isLabelLine: Bool
            if trimmed.hasPrefix("【"), trimmed.hasSuffix("】") {
                let inner = String(trimmed.dropFirst().dropLast())
                isLabelLine = labelSet.contains(inner)
            } else if let colonRange = trimmed.range(of: "：") ?? trimmed.range(of: ":") {
                isLabelLine = labelSet.contains(String(trimmed[..<colonRange.lowerBound]))
            } else {
                isLabelLine = false
            }
            guard isLabelLine else { continue }
            var values: [String] = []
            for nextLine in lines[(index + 1)...] {
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if ["【", "■", "＜", "※"].contains(where: { nextTrimmed.hasPrefix($0) }) { break }
                values.append(nextTrimmed)
            }
            if !values.isEmpty { return values.joined(separator: "\n") }
        }
        return nil
    }

    static func inlinePerformers(_ raw: String) -> [String]? {
        guard let match = regex(#"(?:^|\n)出演[：:]([^\n]+)"#, raw).first, let value = group(match, 1, in: raw) else { return nil }
        let names = splitNames(value).filter { !$0.localizedCaseInsensitiveContains("and more") }
        return names.isEmpty ? nil : names
    }

    /// Text between the first Love Live editor section title (`ke-live_text`, on
    /// an `h3`/`h4` or a plain `div`) accepted by `matches` and the next title.
    static func loveLiveTitledSection(_ html: String, matches: (String) -> Bool) -> String? {
        let pattern = #"<([a-z][a-z0-9]*)\b(?=[^>]*\bclass\s*=\s*['\"][^'\"]*\bke-live_text\b[^'\"]*['\"])[^>]*>"#
        let titles = regex(pattern, html)
        let ns = html as NSString
        for (index, title) in titles.enumerated() {
            guard let tagRange = Range(title.range(at: 1), in: html),
                  let block = HTML.balanced(html, tag: String(html[tagRange]), openingRange: title.range),
                  matches(HTML.text(block)) else { continue }
            let start = title.range.location + (block as NSString).length
            let end = index + 1 < titles.count ? titles[index + 1].range.location : ns.length
            guard end > start else { continue }
            let text = HTML.text(ns.substring(with: NSRange(location: start, length: end - start)))
            if !text.isEmpty { return text }
        }
        return nil
    }

    struct LoveLiveCastBlock: Sendable, Equatable {
        enum Scope: Sendable, Equatable {
            case all
            case days(Set<Int>)
            case date(year: Int?, month: Int?, day: Int)
            case stops(Set<String>)
        }
        let scope: Scope
        var names: [String]
    }

    static let loveLiveCastLabels: Set<String> = ["出演", "出演者", "応援出演", "ゲスト出演", "ゲスト", "特別出演", "スペシャルゲスト"]

    /// Splits Love Live cast text into name blocks scoped by the markers the
    /// official editors use: `＜Day.1＞` / `〈DAY.1〉` / `■1日目` lines, date
    /// sub-headings (`10日（土）公演`), `★対象公演：＜stop＞、…` lines and an
    /// inline day list (`【応援出演】DAY.1&DAY.2 name`). Schedule lines, notes,
    /// sentences, URLs and non-cast `【…】` blocks never become names.
    static func loveLiveCast(_ raw: String, stops: Set<String>) -> [LoveLiveCastBlock] {
        var blocks: [LoveLiveCastBlock] = []
        var scope: LoveLiveCastBlock.Scope = .all
        var collecting = true
        func append(_ text: String, _ target: LoveLiveCastBlock.Scope) {
            let names = loveLiveCastNames(text)
            guard !names.isEmpty else { return }
            if blocks.last?.scope == target { blocks[blocks.count - 1].names += names } else { blocks.append(.init(scope: target, names: names)) }
        }
        for rawLine in raw.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let normalized = line.precomposedStringWithCompatibilityMapping
            if let (days, rest) = loveLiveDayList(line) {
                if rest.isEmpty { scope = .days(days); collecting = true }
                else if collecting, !isLoveLiveScheduleLine(rest.precomposedStringWithCompatibilityMapping) { append(rest, .days(days)) }
                continue
            }
            if let date = loveLiveDateHeading(normalized) { scope = date; collecting = true; continue }
            if line.range(of: #"対象公演[：:]"#, options: .regularExpression) != nil {
                let targets = regex(#"[＜<]([^＜＞<>]+)[＞>]"#, line).compactMap { group($0, 1, in: line).map(clean) }
                scope = targets.isEmpty ? .all : .stops(Set(targets)); collecting = true
                continue
            }
            if let header = regex(#"^[＜<]([^＜＞<>]+)[＞>]$"#, line).first.flatMap({ group($0, 1, in: line) }).map(clean) {
                scope = stops.contains(header) ? .stops([header]) : .all; collecting = true
                continue
            }
            if let match = regex(#"^【([^】]+)】\s*(.*)$"#, line).first, let label = group(match, 1, in: line).map(clean) {
                collecting = loveLiveCastLabels.contains(label)
                let value = group(match, 2, in: line) ?? ""
                guard collecting, !value.isEmpty else { continue }
                if let (days, rest) = loveLiveDayList(value), !rest.isEmpty {
                    append(rest, .days(days))
                } else {
                    append(value, scope)
                }
                continue
            }
            if line.hasPrefix("■") {
                // ■ lines are team/section titles; only a ■cast label reopens collection.
                if loveLiveCastLabels.contains(clean(String(line.dropFirst()))) { collecting = true }
                continue
            }
            let unwrapped = line.replacingOccurrences(of: #"^[★☆]+(.+?)[★☆]+$"#, with: "$1", options: .regularExpression)
            guard collecting, !isLoveLiveScheduleLine(normalized), !isLoveLiveCastNote(unwrapped),
                  !loveLiveCastLabels.contains(line) else { continue }
            append(unwrapped, scope)
        }
        return blocks
    }

    /// `Day.1`, `＜Day.1＞`, `〈DAY.1〉`, `■1日目 昼の部・夜の部`, `DAY.1&DAY.2 name`
    /// → day numbers plus any trailing text (in its original width).
    static func loveLiveDayList(_ line: String) -> (Set<Int>, String)? {
        let pattern = #"^[<＜〈《\[［(（【■●◆・]?\s*((?:(?:(?:DAY|ＤＡＹ)[.．]?\s*[0-9０-９]+|[0-9０-９]+日目)\s*(?:[&＆・、,，/／]\s*)?)+)[>＞〉》\]］)）】]?\s*[:：]?\s*(.*)$"#
        guard let match = regex(pattern, line).first,
              let list = group(match, 1, in: line)?.precomposedStringWithCompatibilityMapping else { return nil }
        let days = Set(regex(#"(?:DAY\.?\s*(\d+)|(\d+)日目)"#, list).compactMap { (group($0, 1, in: list) ?? group($0, 2, in: list)).flatMap(Int.init) })
        guard !days.isEmpty else { return nil }
        let rest = (group(match, 2, in: line) ?? "")
            .replacingOccurrences(of: #"^(?:(?:昼|夜)(?:の部|公演)?|[・、/\s])*$"#, with: "", options: .regularExpression)
        return (days, clean(rest))
    }

    /// A line that is only a date (optionally `（曜）公演`), e.g. `10日（土）公演`
    /// or `2027年3月20日（土）` (compatibility-normalized input).
    static func loveLiveDateHeading(_ line: String) -> LoveLiveCastBlock.Scope? {
        let pattern = #"^[●■]?\s*(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日\s*(?:\([^)]*\))?\s*(?:公演)?$"#
        guard let match = regex(pattern, line).first, let day = group(match, 3, in: line).flatMap(Int.init) else { return nil }
        return .date(year: group(match, 1, in: line).flatMap(Int.init), month: group(match, 2, in: line).flatMap(Int.init), day: day)
    }

    static func isLoveLiveScheduleLine(_ line: String) -> Bool {
        line.range(of: #"\d{1,2}:\d{2}|開場|開演"#, options: .regularExpression) != nil
    }

    static func isLoveLiveCastNote(_ text: String) -> Bool {
        ["※", "＊", "*", "▼", "◆", "→", "★", "☆"].contains { text.hasPrefix($0) }
            || text.range(of: #"https?://|。|ます|です|ください|ません|こちら|^(?:作品|公式|特設)サイト$"#, options: .regularExpression) != nil
    }

    static func loveLiveCastNames(_ text: String) -> [String] {
        var value = text
        // A pairing/unit label (`タンポポ：`) or `応援出演：` before role-annotated names.
        if let match = regex(#"^([^：:（(、,]{1,20})[：:]\s*(.+役[）)].*)$"#, value).first, let rest = group(match, 2, in: value) { value = rest }
        return splitNames(value).flatMap { name -> [String] in
            // `「作品」相良茉優（中須かすみ役）` → group title and member.
            if let match = regex(#"^([「『][^」』]+[」』])\s*(.+役[）)])$"#, name).first,
               let title = group(match, 1, in: name), let member = group(match, 2, in: name) { return [title, member] }
            return [name]
        }.filter { !isLoveLiveCastNote($0) && !loveLiveCastLabels.contains($0) }
    }

    static func loveLivePerformers(_ blocks: [LoveLiveCastBlock], dayLabel: String, localDate: String, stop: String?) -> [String] {
        guard !blocks.isEmpty else { return [] }
        let day = regex(#"DAY\s*(\d+)"#, dayLabel).first.flatMap { group($0, 1, in: dayLabel) }.flatMap(Int.init)
        let parts = localDate.split(separator: "-").compactMap { Int($0) }
        let selected = blocks.filter { block in
            switch block.scope {
            case .all: return true
            case .days(let days): return day.map(days.contains) ?? false
            case .date(let year, let month, let dayOfMonth):
                return parts.count == 3 && parts[2] == dayOfMonth && (month ?? parts[1]) == parts[1] && (year ?? parts[0]) == parts[0]
            case .stops(let names): return stop.map(names.contains) ?? false
            }
        }
        var seen: Set<String> = []
        return (selected.isEmpty ? blocks : selected).flatMap(\.names).filter { seen.insert($0).inserted }
    }

    /// Whole-line `＜stop＞` headers of a Love Live overview mapped from each date
    /// listed under them (same block split as `loveLiveStopVenues`).
    static func loveLiveStopDates(_ overviewText: String) -> [String: String] {
        var result: [String: String] = [:]
        var header: String?
        var year: Int?
        var month: Int?
        for line in overviewText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = regex(#"^[＜<]([^＜＞<>]+)[＞>]$"#, trimmed).first {
                header = group(match, 1, in: trimmed).map(clean)
                continue
            }
            let source = clean(trimmed).precomposedStringWithCompatibilityMapping
            for match in regex(#"(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日(?!目)"#, source) {
                if let value = group(match, 1, in: source).flatMap(Int.init) { year = value }
                if let value = group(match, 2, in: source).flatMap(Int.init) { month = value }
                guard let header, let year, let month, let day = group(match, 3, in: source).flatMap(Int.init),
                      validDate(year: year, month: month, day: day) != nil else { continue }
                let date = String(format: "%04d-%02d-%02d", year, month, day)
                if result[date] == nil { result[date] = header }
            }
        }
        return result
    }

    static func loveLiveStopHeaders(_ overviewText: String) -> Set<String> {
        Set(loveLiveStopDates(overviewText).values)
    }

    static func performersForDay(_ raw: String, dayLabel: String) -> [String] {
        let normalized = raw.precomposedStringWithCompatibilityMapping
        let labels = regex(#"DAY\s*(\d+)"#, normalized)
        guard let requested = regex(#"DAY\s*(\d+)"#, dayLabel).first.flatMap({ group($0, 1, in: dayLabel) }),
              let matchIndex = labels.firstIndex(where: { group($0, 1, in: normalized) == requested }) else { return splitNames(raw) }
        let ns = normalized as NSString
        let prefix = ns.substring(to: labels[0].range.location)
        let match = labels[matchIndex]
        let end = matchIndex + 1 < labels.count ? labels[matchIndex + 1].range.location : ns.length
        let selected = ns.substring(with: NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range)))
        return splitNames(prefix + "\n" + selected)
    }

    static func splitNames(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var depth = 0
        var current = ""
        var parts: [String] = []
        for character in raw {
            if "（([".contains(character) { depth += 1 }
            if "）)]".contains(character) { depth = max(0, depth - 1) }
            if character == "\n" || (depth == 0 && "、,，／/×".contains(character)) {
                parts.append(current); current = ""
            } else { current.append(character) }
        }
        parts.append(current)
        return parts.map { clean($0).trimmingCharacters(in: CharacterSet(charactersIn: "・<>＜＞：: ")) }.filter {
            !$0.isEmpty && !$0.hasPrefix("※") && !$0.hasPrefix("【") && !$0.hasPrefix("オープニングアクト")
                && $0.range(of: #"^DAY\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    static func venueCity(_ venue: String) -> String {
        let prefix = venue.split(separator: "・", maxSplits: 1).first.map(String.init) ?? ""
        return ["東京", "神奈川", "大阪", "愛知", "福岡", "石川", "兵庫", "埼玉", "千葉", "北海道", "宮城"].contains(prefix) ? prefix : ""
    }

    static func officialTimeZone(_ context: String) -> String {
        if context.contains("香港") || context.contains("AsiaWorld-Expo") { return "Asia/Hong_Kong" }
        if context.contains("台北") || context.contains("台湾") || context.contains("TAIPEI") { return "Asia/Taipei" }
        if context.contains("韓国") || context.contains("ソウル") || context.contains("Seoul") { return "Asia/Seoul" }
        if context.contains("Crypto.com Arena") { return "America/Los_Angeles" }
        if context.contains("上海") { return "Asia/Shanghai" }
        return "Asia/Tokyo"
    }

    static func reinterpretJapanWallTime(_ date: Date?, in zone: String) -> Date? {
        guard let date else { return nil }
        var target = japanCalendar
        target.timeZone = TimeZone(identifier: zone) ?? japanCalendar.timeZone
        return target.date(from: japanCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date))
    }

    static var japanCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func validDate(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return validDate(year: parts[0], month: parts[1], day: parts[2])
    }

    static func validDate(year: Int, month: Int, day: Int) -> Date? {
        guard let date = japanCalendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let c = japanCalendar.dateComponents([.year, .month, .day], from: date)
        return c.year == year && c.month == month && c.day == day ? date : nil
    }

    static func timeDate(_ date: String, hour: String?, minute: String?) -> Date? {
        guard let base = validDate(date), let hour = hour.flatMap(Int.init), let minute = minute.flatMap(Int.init),
              (0 ... 24).contains(hour), (0 ... 59).contains(minute), hour < 24 || minute == 0 else { return nil }
        return japanCalendar.date(byAdding: .minute, value: hour * 60 + minute, to: base)
    }

    static func localDate(_ date: Date) -> String {
        let c = japanCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func canonicalURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.fragment = nil
        components.host = components.host?.lowercased()
        if components.path.count > 1 { components.path = components.path.replacingOccurrences(of: #"/+$"#, with: "/", options: .regularExpression) }
        components.queryItems = components.queryItems?.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return components.string ?? raw
    }

    static func stableID(prefix: String, seed: String) -> String { "\(prefix)-\(stableHash(seed))" }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"[ \t\r]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func regex(_ pattern: String, _ value: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
    }

    static func group(_ match: NSTextCheckingResult, _ index: Int, in value: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: value) else { return nil }
        return String(value[range])
    }
}

extension TicketRound {
    func replacingScope(_ scope: Scope) -> TicketRound {
        TicketRound(id: id, eventID: eventID, officialName: officialName, kind: kind, scope: scope,
            applyStartAt: applyStartAt, applyEndAt: applyEndAt, resultAt: resultAt, paymentDeadlineAt: paymentDeadlineAt,
            eligibility: eligibility, announcementURL: announcementURL, applyURL: applyURL, overseasURL: overseasURL,
            officialStatus: officialStatus, status: status, links: links, applyWindowText: applyWindowText,
            resultText: resultText, paymentStartAt: paymentStartAt, paymentWindowText: paymentWindowText,
            quantityLimit: quantityLimit, lotteryProducts: lotteryProducts, applicationTarget: applicationTarget, notes: notes)
    }
}

extension StreamOffer {
    func replacingScope(_ scope: Scope) -> StreamOffer {
        StreamOffer(id: id, eventID: eventID, platform: platform, officialName: officialName, scope: scope, amount: amount,
            salesStartAt: salesStartAt, salesEndAt: salesEndAt, archiveAvailableUntil: archiveAvailableUntil,
            regionNote: regionNote, url: url, status: status)
    }
}

private enum HTML {
    static func startTags(_ html: String, tag: String) -> [String] {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            return String(html[range])
        }
    }

    static func blocks(_ html: String, tag: String, className: String?) -> [String] {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let opening = className.map { "<\(escapedTag)\\b(?=[^>]*\\bclass\\s*=\\s*['\"][^'\"]*\\b\(NSRegularExpression.escapedPattern(for: $0))\\b[^'\"]*['\"])[^>]*>" }
            ?? "<\(escapedTag)\\b[^>]*>"
        guard let re = try? NSRegularExpression(pattern: opening, options: [.caseInsensitive]) else { return [] }
        let sourceRange = NSRange(html.startIndex..., in: html)
        return re.matches(in: html, range: sourceRange).compactMap { match in balanced(html, tag: tag, openingRange: match.range) }
    }

    static func balanced(_ html: String, tag: String, openingRange: NSRange) -> String? {
        guard let start = Range(openingRange, in: html)?.lowerBound else { return nil }
        let pattern = "</?\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let tail = NSRange(location: openingRange.location, length: (html as NSString).length - openingRange.location)
        var depth = 0
        for token in re.matches(in: html, range: tail) {
            let value = (html as NSString).substring(with: token.range)
            if value.hasPrefix("</") { depth -= 1 } else if !value.hasSuffix("/>") { depth += 1 }
            if depth == 0, let end = Range(token.range, in: html)?.upperBound { return String(html[start..<end]) }
        }
        return nil
    }

    static func blockWithAttribute(_ html: String, attribute: String, value: String) -> String? {
        blocksWithAttribute(html, attribute: attribute, value: value).max { $0.count < $1.count }
    }

    static func blocksWithAttribute(_ html: String, attribute: String, value: String) -> [String] {
        let pattern = #"<([a-z][a-z0-9]*)\b(?=[^>]*\b\#(attribute)\s*=\s*['\"]\#(NSRegularExpression.escapedPattern(for: value))['\"])[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let tagRange = Range(match.range(at: 1), in: html) else { return nil }
            return balanced(html, tag: String(html[tagRange]), openingRange: match.range)
        }
    }

    static func textForClass(_ html: String, _ className: String) -> String? {
        let pattern = #"<([a-z][a-z0-9]*)\b(?=[^>]*\bclass\s*=\s*['\"][^'\"]*\b\#(NSRegularExpression.escapedPattern(for: className))\b[^'\"]*['\"])[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let tagRange = Range(match.range(at: 1), in: html),
              let block = balanced(html, tag: String(html[tagRange]), openingRange: match.range) else { return nil }
        return text(block)
    }

    static func allTextForClass(_ html: String, _ className: String) -> [String] {
        let tags = ["span", "div", "p", "li"]
        return tags.flatMap { blocks(html, tag: $0, className: className).map(text) }.filter { !$0.isEmpty }
    }

    static func tableValue(_ html: String, label: String) -> String? {
        for table in blocks(html, tag: "div", className: "p-live-event-detail__table") {
            for row in blocks(table, tag: "tr", className: nil) where firstTagText(row, tag: "th") == label {
                return firstTagText(row, tag: "td")
            }
        }
        return nil
    }

    static func firstTagText(_ html: String, tag: String) -> String? { blocks(html, tag: tag, className: nil).first.map(text) }

    static func firstAttribute(_ html: String, tag: String, name: String) -> String? { allAttributes(html, tag: tag, name: name).first }

    static func allAttributes(_ html: String, tag: String, name: String) -> [String] {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(['\"])(.*?)\\1"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 2), in: html) else { return nil }
            return String(html[range])
        }
    }

    static func valueFollowingHeading(_ html: String, headingClass: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: headingClass)
        let pattern = #"<h[1-6]\b(?=[^>]*class\s*=\s*['\"][^'\"]*\b\#(escaped)\b[^'\"]*['\"])[^>]*>.*?</h[1-6]>\s*<p\b[^>]*>(.*?)</p>"#
        guard let match = OfficialEventScraper.regex(pattern, html, options: [.caseInsensitive, .dotMatchesLineSeparators]).first,
              let raw = OfficialEventScraper.group(match, 1, in: html) else { return nil }
        return text(raw)
    }

    static func sectionHTML(_ html: String, heading: String) -> String? {
        let matches = OfficialEventScraper.regex(#"<h([1-6])\b[^>]*>(.*?)</h\1>"#, html, options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let match = matches.first(where: { match in
            OfficialEventScraper.group(match, 2, in: html).map(text) == OfficialEventScraper.clean(heading)
        }), let level = OfficialEventScraper.group(match, 1, in: html).flatMap(Int.init) else { return nil }
        let ns = html as NSString
        let start = NSMaxRange(match.range)
        let tail = NSRange(location: start, length: ns.length - start)
        let next = try? NSRegularExpression(pattern: "<h[1-\(level)]\\b", options: [.caseInsensitive])
        let end = next?.firstMatch(in: html, range: tail)?.range.location ?? ns.length
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    static func sectionText(_ html: String, heading: String) -> String? { sectionHTML(html, heading: heading).map(text) }

    /// Every heading with the HTML that follows it up to the next heading of
    /// any level, plus the heading level (1–6) so callers can relate siblings.
    static func headingSections(_ html: String) -> [(heading: String, html: String, level: Int)] {
        let pattern = #"<h([1-6])\b[^>]*>(.*?)</h\1>"#
        let matches = OfficialEventScraper.regex(pattern, html, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        return matches.enumerated().compactMap { index, match in
            guard let headingRaw = OfficialEventScraper.group(match, 2, in: html) else { return nil }
            let level = OfficialEventScraper.group(match, 1, in: html).flatMap(Int.init) ?? 6
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            return (text(headingRaw), ns.substring(with: NSRange(location: start, length: max(0, end - start))), level)
        }
    }

    static func metaContent(_ html: String, property: String) -> String? {
        let tags = blocks(html, tag: "meta", className: nil)
        for tag in tags where firstAttribute(tag, tag: "meta", name: "property")?.caseInsensitiveCompare(property) == .orderedSame {
            return firstAttribute(tag, tag: "meta", name: "content").map(decode)
        }
        // meta is a void element, so balanced blocks intentionally cannot see it.
        let pattern = #"<meta\b(?=[^>]*\bproperty\s*=\s*['\"]\#(NSRegularExpression.escapedPattern(for: property))['\"])[^>]*\bcontent\s*=\s*(['\"])(.*?)\1[^>]*>"#
        guard let match = OfficialEventScraper.regex(pattern, html, options: [.caseInsensitive, .dotMatchesLineSeparators]).first,
              let raw = OfficialEventScraper.group(match, 2, in: html) else { return nil }
        return decode(raw)
    }

    static func text(_ html: String) -> String {
        var value = html.replacingOccurrences(of: #"<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"<(?:br|/p|/div|/li|/h[1-6]|/tr)\b[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return OfficialEventScraper.clean(decode(value))
    }

    /// A `⟪H⟫`-prefixed line marks where a `<h1-6>` heading started (its
    /// stripped text follows the marker), so callers can detect a section
    /// boundary in minified HTML that has no other structural break.
    static let headingLineMarker = "⟪H⟫"

    /// Line-oriented view of `html` used by the Love Live ticket parser:
    /// `<br>`/block-closing tags become newlines, `<h1-6>` openings become a
    /// newline plus a `⟪H⟫heading` marker line, `<s>`/`<strike>`/`<del>` spans
    /// mark every line they cover as struck, and each line keeps the anchors
    /// found in its own (pre tag-stripping) source.
    static func annotatedLines(_ html: String, relativeTo base: URL?) -> [(text: String, struck: Bool, links: [OfficialLink])] {
        var value = html.replacingOccurrences(of: #"<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])

        if let re = try? NSRegularExpression(pattern: #"<h([1-6])\b[^>]*>(.*?)</h\1>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = re.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: value), let inner = Range(match.range(at: 2), in: value) else { continue }
                let innerHTML = String(value[inner])
                value.replaceSubrange(full, with: "\n\(headingLineMarker)" + innerHTML + "\n")
            }
        }
        value = value.replacingOccurrences(of: #"<(?:br|/p|/div|/li|/tr)\b[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])

        var struckDepth = 0
        var result: [(text: String, struck: Bool, links: [OfficialLink])] = []
        guard let strikeTagRE = try? NSRegularExpression(pattern: #"</?(?:s|strike|del)\b[^>]*>"#, options: [.caseInsensitive]) else { return [] }
        for rawLine in value.components(separatedBy: "\n") {
            let startDepth = struckDepth
            var lineHadOpen = false
            for tag in strikeTagRE.matches(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)) {
                guard let range = Range(tag.range, in: rawLine) else { continue }
                if rawLine[range].hasPrefix("</") { struckDepth = max(0, struckDepth - 1) }
                else { struckDepth += 1; lineHadOpen = true }
            }
            let isMarker = rawLine.hasPrefix(headingLineMarker)
            let bodyForLinks = isMarker ? String(rawLine.dropFirst(headingLineMarker.count)) : rawLine
            let links = links(bodyForLinks, relativeTo: base)
            let strippedText = text(bodyForLinks)
            guard !strippedText.isEmpty else { continue }
            let finalText = isMarker ? headingLineMarker + strippedText : strippedText
            result.append((text: finalText, struck: startDepth > 0 || lineHadOpen, links: links))
        }
        return result
    }

    /// Every `<a href=...>...</a>` in `html`, resolved to an absolute URL and
    /// deduplicated by `OfficialEventScraper.canonicalURL`, preserving the
    /// order they first appear in the document. Direct image links, empty
    /// hrefs, and `javascript:`/fragment-only hrefs are never links.
    static func links(_ html: String, relativeTo base: URL?) -> [OfficialLink] {
        guard let re = try? NSRegularExpression(pattern: #"<a\b[^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let matches = re.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var results: [OfficialLink] = []
        var seen: Set<String> = []
        for match in matches {
            guard let fullRange = Range(match.range, in: html) else { continue }
            let anchorTag = String(html[fullRange])
            guard let hrefRaw = firstAttribute(anchorTag, tag: "a", name: "href") else { continue }
            let decodedHref = decode(hrefRaw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decodedHref.isEmpty, !decodedHref.lowercased().hasPrefix("javascript:"), !decodedHref.hasPrefix("#") else { continue }
            guard let url = URL(string: decodedHref, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https" else { continue }
            if OfficialEventScraper.isDirectImageURL(url) { continue }
            let body = OfficialEventScraper.group(match, 1, in: html) ?? ""
            var label = text(body)
            if label.isEmpty {
                label = firstAttribute(anchorTag, tag: "a", name: "title").map(decode)
                    ?? firstAttribute(anchorTag, tag: "a", name: "aria-label").map(decode)
                    ?? url.host ?? ""
            }
            let key = OfficialEventScraper.canonicalURL(url.absoluteString)
            guard seen.insert(key).inserted else { continue }
            results.append(OfficialLink(label: label, url: url.absoluteString))
        }
        return results
    }

    /// Like `text(_:)`, but keeps a plain-text trace of every link and image
    /// so an on-device assistant can reference them without re-fetching HTML:
    /// `<a href="X">body</a>` becomes `body（X）` and `<img alt="A" src="S">`
    /// becomes `[图片:A S]` (or `[图片 S]` when `alt` is empty).
    static func linkedText(_ html: String, relativeTo base: URL?) -> String {
        var value = html.replacingOccurrences(of: #"<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: [.regularExpression, .caseInsensitive])

        if let re = try? NSRegularExpression(pattern: #"<a\b[^>]*>(.*?)</a>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let matches = re.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: value) else { continue }
                let anchorTag = String(value[fullRange])
                let body = OfficialEventScraper.group(match, 1, in: value) ?? ""
                let bodyText = text(body)
                var replacement = bodyText
                if let hrefRaw = firstAttribute(anchorTag, tag: "a", name: "href") {
                    let decodedHref = decode(hrefRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !decodedHref.isEmpty, !decodedHref.lowercased().hasPrefix("javascript:"), !decodedHref.hasPrefix("#"),
                       let url = URL(string: decodedHref, relativeTo: base)?.absoluteURL,
                       url.scheme == "http" || url.scheme == "https", url.absoluteString != bodyText {
                        replacement = "\(bodyText)（\(url.absoluteString)）"
                    }
                }
                value.replaceSubrange(fullRange, with: replacement)
            }
        }

        if let re = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]) {
            let matches = re.matches(in: value, range: NSRange(value.startIndex..., in: value))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: value) else { continue }
                let imgTag = String(value[fullRange])
                guard let rawSrc = ["data-src", "data-lazy-src", "src"].compactMap({ firstAttribute(imgTag, tag: "img", name: $0) }).first,
                      let source = resolvedLinkedTextImageURL(rawSrc, relativeTo: base) else { continue }
                let alt = firstAttribute(imgTag, tag: "img", name: "alt").map(decode)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let replacement = alt.isEmpty ? "[图片 \(source.absoluteString)]" : "[图片:\(alt) \(source.absoluteString)]"
                value.replaceSubrange(fullRange, with: replacement)
            }
        }

        value = value.replacingOccurrences(of: #"<(?:br|/p|/div|/li|/h[1-6]|/tr)\b[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return OfficialEventScraper.clean(decode(value))
    }

    private static func resolvedLinkedTextImageURL(_ raw: String, relativeTo base: URL?) -> URL? {
        let value = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !OfficialEventScraper.isPlaceholderImage(value),
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    static func decode(_ value: String) -> String {
        var result = value
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        for (name, replacement) in named { result = result.replacingOccurrences(of: "&\(name);", with: replacement) }
        let matches = OfficialEventScraper.regex(#"&#(?:x([0-9a-f]+)|(\d+));"#, result)
        for match in matches.reversed() {
            let hex = OfficialEventScraper.group(match, 1, in: result)
            let decimal = OfficialEventScraper.group(match, 2, in: result)
            let scalar = hex.flatMap { UInt32($0, radix: 16) } ?? decimal.flatMap(UInt32.init)
            guard let scalar, let unicode = UnicodeScalar(scalar), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: String(Character(unicode)))
        }
        return result
    }
}
