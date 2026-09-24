import Foundation

public enum OfficialWebsiteHeaders {
    // The public Love Live CDN serves a generic 403 page to app-only agents,
    // including for image.php. Keep the same compatibility signature for both
    // HTML and original images, while identifying the app explicitly.
    public static func compatibleUserAgent(for url: URL) -> String? {
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
        var doorsAt: Date?
        var startsAt: Date?
        var raw: String
        var venue: String? = nil
        var performers: [String]? = nil
        var localEndDate: String? = nil
        var activityKind: PerformanceActivity? = nil
    }

    struct ParsedGoods: Sendable {
        let campaigns: [GoodsCampaign]
        let mediaAssets: [MediaAsset]
        let bodies: [String: String]
    }

    struct ParsedTicketRound: Sendable {
        let round: TicketRound
        let scopeText: String
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
        var loveLiveStreamBlocks: [String] = []
        var bangDreamArticle = ""
        if isBangDream {
            guard html.contains("p-live-event-detail") || html.contains("p-page-detail") else {
                throw OfficialScrapeFailure(url: finalURL, kind: .unsupportedTemplate, message: "Missing BanG Dream detail article")
            }
            let content = HTML.blocks(html, tag: "div", className: "p-live-event-detail__content").max { $0.count < $1.count }
                ?? HTML.blocks(html, tag: "div", className: "p-page-detail__content").max { $0.count < $1.count } ?? ""
            bangDreamArticle = content
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
            // Paid-stream tabs live outside the structured detail article.
            loveLiveStreamBlocks = ["streaming", "stream", "str", "spwn", "haishin", "onlinelive"]
                .compactMap { HTML.blocksWithAttribute(html, attribute: "data-target", value: $0).max { $0.count < $1.count } }
                + HTML.headingSections(completeDetail).filter { $0.heading.contains("配信") && !$0.heading.contains("チケット") }.map(\.html)
        }

        let canonical = canonicalURL(finalURL.absoluteString)
        let eventID = cached?.event.id ?? stableID(prefix: candidate.franchise.rawValue, seed: canonical)
        let activityDocument = bangDreamArticle.isEmpty ? nil : parseActivityDocument(bangDreamArticle, eventID: eventID, sourceURL: finalURL.absoluteString)
        var schedules = combinedScheduleHTML.map(parseCombinedSchedules) ?? parseSchedules(scheduleRaw)
        if schedules.isEmpty { schedules = parseSchedules(candidate.scheduleRaw) }
        if let activityDocument, !activityDocument.schedules.isEmpty {
            schedules = activityDocument.schedules
        }
        var stopVenueByDate: [String: String] = [:]
        if let loveLiveOverviewText {
            let stopVenues = loveLiveStopVenues(loveLiveOverviewText)
            stopVenueByDate = stopVenues
            if !stopVenues.isEmpty {
                schedules = schedules.map { schedule in
                    var result = schedule
                    if result.venue == nil { result.venue = stopVenues[schedule.localDate] }
                    return result
                }
            }
        }
        let cleanedSummary = cleanedVenue(venueRaw ?? "", summary: HTML.tableValue(html, label: "場所"))
        // A page-level 場所 cell often lists every hall in one sentence. That
        // string is not a venue for any single day.
        let venue = isMultiVenueSummary(cleanedSummary) ? "" : cleanedSummary
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
            let strictIdentity = item.activityKind != nil || item.localEndDate != nil
            let prior: Performance?
            if strictIdentity {
                prior = oldPerformances.first { candidate in
                    guard unclaimed(candidate), candidate.localDate == item.localDate else { return false }
                    if let end = item.localEndDate {
                        guard (candidate.localEndDate ?? candidate.localDate) == end else { return false }
                    }
                    if let kind = item.activityKind, let priorKind = candidate.activityKind, priorKind != kind { return false }
                    if let venueName = item.venue, !venueName.isEmpty {
                        if isMultiVenueSummary(candidate.venueName) { return false }
                        if !candidate.venueName.isEmpty, !venuesReferToSamePlace(candidate.venueName, venueName) { return false }
                    }
                    return true
                }
            } else {
                prior = oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate && sameLabel($0) && $0.subtitle == item.subtitle }
                    ?? oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate && sameLabel($0) && (item.subtitle == nil || $0.subtitle == nil) }
                    ?? (labelIsUnique ? oldPerformances.first { unclaimed($0) && sameLabel($0) } : nil)
                    ?? oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate && $0.startAt != nil && $0.startAt == reinterpretJapanWallTime(item.startsAt, in: eventTimeZone) }
                    ?? oldPerformances.first { unclaimed($0) && $0.localDate == item.localDate }
                    ?? (index < oldPerformances.count && unclaimed(oldPerformances[index]) && oldPerformances[index].localDate == nil ? oldPerformances[index] : nil)
            }
            if let prior { claimedPriorIDs.insert(prior.id) }
            return ResolvedPerformance(index: index, item: item, label: label, prior: prior)
        }
        var usedPerformanceIDs: Set<String> = []
        func nonempty(_ value: String?) -> String? {
            guard let value else { return nil }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        let hasAnyScheduleVenue = schedules.contains { nonempty($0.venue) != nil }
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
                    ? stableID(prefix: "\(eventID)-performance", seed: "\(item.localDate)|\(item.localEndDate ?? "")|\(label)|\(item.subtitle ?? "")|\(item.venue ?? "")|\(item.activityKind?.rawValue ?? "")")
                    : candidateID
            }
            usedPerformanceIDs.insert(performanceID)
            let associatedVenue = isLoveLive && item.venue != nil ? nil : scopedVenue(venueRaw ?? "", note: overviewNote, date: item.localDate)
            let associatedPerformers = notedPerformers(overviewNote, groups: officialGroups, date: item.localDate, singleDate: Set(schedules.map(\.localDate)).count == 1)
            let loveLiveCast = loveLivePerformers(loveLiveCastBlocks, dayLabel: label, localDate: item.localDate, stop: loveLiveStopByDate[item.localDate])
            let stopName = loveLiveStopByDate[item.localDate]
            let resolvedVenue = nonempty(item.venue)
                ?? nonempty(associatedVenue)
                ?? nonempty(stopVenueByDate[item.localDate])
                ?? (hasAnyScheduleVenue ? nil : nonempty(venue))
                ?? ""
            let parsedDoors = reinterpretJapanWallTime(item.doorsAt, in: eventTimeZone)
            let parsedStart = reinterpretJapanWallTime(item.startsAt, in: eventTimeZone)
            let resolvedPerformers = resolvedPerformerNames(
                explicit: item.performers,
                loveLiveCast: loveLiveCast,
                castBlocks: loveLiveCastBlocks,
                performersRaw: performersRaw,
                performers: performers,
                associatedPerformers: associatedPerformers,
                dayLabel: label
            )
            let cityFromVenue = resolvedVenue.isEmpty ? "" : venueCity(resolvedVenue)
            return Performance(
                id: performanceID, eventID: eventID,
                stopID: stopName.map { stableID(prefix: "\(eventID)-stop", seed: $0) },
                dayLabel: label, subtitle: item.subtitle, localDate: item.localDate,
                doorsAt: parsedDoors,
                startAt: parsedStart,
                venueName: resolvedVenue,
                venueCity: cityFromVenue.isEmpty ? stopCity(stopName) : cityFromVenue,
                performers: PerformerLines.expandingNewlines(resolvedPerformers), order: index,
                editionID: nil, rawDate: item.raw,
                precision: (item.localEndDate != nil && item.localEndDate != item.localDate) ? .range : ((item.startsAt != nil || item.doorsAt != nil) ? .minute : .date),
                timeZone: eventTimeZone, localEndDate: item.localEndDate, activityKind: item.activityKind
            )
        }
        var parsedStops: [LiveStop] = []
        var seenStopNames: [String] = []
        for item in schedules {
            guard let name = loveLiveStopByDate[item.localDate], !seenStopNames.contains(name) else { continue }
            seenStopNames.append(name)
            parsedStops.append(LiveStop(id: stableID(prefix: "\(eventID)-stop", seed: name), eventID: eventID, name: name, order: parsedStops.count))
        }

        let performances = parsedPerformances
        // A page with exactly one performance cannot mean any other date, so
        // its ticket records apply to that performance. With several dates the
        // parser still emits `.unconfirmed` (DESIGN.md: never guess Day2).
        let ticketScope: Scope = performances.count == 1 ? .performances(performanceIDs: [performances[0].id]) : .unconfirmed
        let parsedTiers = parseTicketTiers(ticketHTML, eventID: eventID, cached: cached?.ticketTiers ?? [])
        let baseTiers = parsedTiers.isEmpty ? (cached?.ticketTiers ?? []) : parsedTiers
        let tradeHTML = HTML.sectionHTML(html, heading: "チケットトレード") ?? ""
        let parsedRoundItems: [ParsedTicketRound]
        if isLoveLive {
            let loveLiveRounds = [loveLiveTaggedTickets, loveLiveInlineTickets]
                .compactMap { $0 }
                .map { parseLoveLiveTicketRounds($0, eventID: eventID, cached: cached?.ticketRounds ?? [], timeZone: eventTimeZone, referenceDate: schedules.first?.localDate, sourceURL: finalURL) }
                .first { !$0.isEmpty } ?? []
            parsedRoundItems = loveLiveRounds.isEmpty
                ? parseTicketRounds(ticketHTML + "\n" + tradeHTML, eventID: eventID, cached: cached?.ticketRounds ?? [], timeZone: eventTimeZone, referenceDate: schedules.first?.localDate, sourceURL: finalURL)
                : loveLiveRounds
        } else {
            let salesSection = HTML.sectionHTML(bangDreamTicketHeadingHTML ?? ticketHTML, heading: "販売情報") ?? ""
            let salesPreamble = salesSection.range(of: "<h6", options: [.caseInsensitive]).map { String(salesSection[..<$0.lowerBound]) } ?? salesSection
            let sharedLinks = HTML.links(salesPreamble, relativeTo: finalURL)
            parsedRoundItems = parseTicketRounds(ticketHTML + "\n" + tradeHTML, eventID: eventID, cached: cached?.ticketRounds ?? [], timeZone: eventTimeZone, referenceDate: schedules.first?.localDate, sourceURL: finalURL, sharedLinks: sharedLinks)
        }
        let mappedRounds = parsedRoundItems.map { item in
            item.round.replacingScope(resolvedScope(item.round.scope, text: item.scopeText, performances: performances, fallback: ticketScope))
        }
        let rounds = mappedRounds
        let parsedBenefitsResult = parseTicketBenefits(
            ticketHTML, sourceURL: finalURL, eventID: eventID, tiers: baseTiers, scope: .unconfirmed,
            cached: cached?.ticketBenefits ?? [], cachedMedia: cached?.mediaAssets ?? []
        )
        let recordScope = sharedVenueScope(performances) ?? ticketScope
        let ticketBenefits = parsedBenefitsResult.benefits.map { benefit in
            let text = [benefit.officialName, benefit.detail, benefit.notes, benefit.redemptionNote].compactMap { $0 }.joined(separator: "\n")
            return benefit.replacingScope(resolvedScope(.unconfirmed, text: text, performances: performances, fallback: recordScope))
        }
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
            sourceText = rendered.isEmpty ? nil : cappedSourceText("# \(title)\n" + rendered)
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
            sourceText = rendered.isEmpty ? nil : cappedSourceText("# \(title)\n" + rendered)
        }
        let loveLiveStreams = parseLoveLiveStreams(loveLiveStreamBlocks, sourceURL: finalURL, eventID: eventID, performances: performances, timeZone: eventTimeZone, referenceDate: schedules.first?.localDate)
            .map { offer -> StreamOffer in
                offer.replacingScope(resolvedScope(offer.scope, text: offer.officialName, performances: performances, fallback: recordScope))
            }
        let parsedStreams = parseStreams(
            richContentHTML, sourceURL: finalURL, eventID: eventID,
            performances: performances, ticketScope: recordScope
        ) + loveLiveStreams
        let parsedGoodsResult = parseGoods(
            richContentHTML, sourceURL: finalURL, eventID: eventID,
            cachedCampaigns: cached?.goodsCampaigns ?? [], cachedMedia: cached?.mediaAssets ?? []
        )
        var goodsCampaigns = parsedGoodsResult.campaigns.map { campaign in
            let text = parsedGoodsResult.bodies[campaign.id] ?? campaign.officialName
            return campaign.replacingScope(resolvedScope(.unconfirmed, text: text, performances: performances, fallback: ticketScope))
        }
        let boundActivity = activityDocument.map { bindActivity($0, performances: performances, campaigns: goodsCampaigns) }
        if let boundCampaigns = boundActivity?.campaigns { goodsCampaigns = boundCampaigns }
        let structured = structuredGoods(from: goodsCampaigns, bodies: parsedGoodsResult.bodies, eventID: eventID)
        let products = !(boundActivity?.products.isEmpty ?? true) ? (boundActivity?.products ?? []) : structured.products
        let goodsSessions = !(boundActivity?.sessions.isEmpty ?? true) ? (boundActivity?.sessions ?? []) : structured.sessions
        let notices = boundActivity?.notices ?? []
        var scopeByMediaID: [String: Scope] = [:]
        for campaign in goodsCampaigns {
            for id in campaign.mediaAssetIDs { scopeByMediaID[id] = campaign.scope }
        }
        for benefit in ticketBenefits {
            for id in benefit.mediaAssetIDs { scopeByMediaID[id] = benefit.scope }
        }
        let parsedMedia = parseMediaAssets(
            html, sourceURL: finalURL, eventID: eventID, cached: cached?.mediaAssets ?? [],
            eventCoverURL: candidate.coverURL, eventCoverSourceURL: candidate.coverSourceURL,
            performances: performances, ticketScope: ticketScope
        )
            + parsedGoodsResult.mediaAssets
            + parsedBenefitsResult.mediaAssets
        let mediaAssets = mergeMedia(cached?.mediaAssets ?? [], parsedMedia)
            .map { asset in
                guard let scope = scopeByMediaID[asset.id] else { return asset }
                return asset.replacingScope(scope)
            }
            .sorted { $0.id < $1.id }
        let lastDate = performances.compactMap(\.periodEndLocalDate).max()
        let today = localDate(now)
        let noticeText = statusNoticeText(title: title, html: richContentHTML)
        let status: EventStatus = announcedStatus(in: noticeText)
            ?? (lastDate.map { $0 < today } == true ? .finished : lastDate == nil ? .unknown : .scheduled)
        let sourceHealth: SourceHealthState = .healthy
        let event = LiveEvent(
            id: eventID, franchise: candidate.franchise, officialTitle: title,
            groups: officialGroups.isEmpty ? candidate.groups : officialGroups, eventType: candidate.eventType, status: status,
            primarySourceURL: finalURL.absoluteString, timeZone: eventTimeZone
        )

        var evidence: [SourceEvidence] = []
        evidence.append(makeEvidence(recordID: eventID, field: "event.officialTitle", sourceURL: finalURL, quote: title, now: now))
        if status == .cancelled || status == .postponed {
            evidence.append(makeEvidence(recordID: eventID, field: "event.status", sourceURL: finalURL, quote: clean(noticeText), now: now))
        }
        if let scheduleRaw, !clean(scheduleRaw).isEmpty {
            evidence.append(makeEvidence(recordID: eventID, field: "performance.schedule", sourceURL: finalURL, quote: clean(scheduleRaw), now: now))
        }
        let distinctPerformanceVenues = Set(performances.map(\.venueName).filter { !$0.isEmpty })
        if distinctPerformanceVenues.count > 1 {
            // A tour page's summary cell lists every hall in one string. Evidence
            // has to follow the performance, or the source quote looks like one venue.
            for performance in performances where !performance.venueName.isEmpty {
                evidence.append(makeEvidence(recordID: performance.id, field: "performance.venueName", sourceURL: finalURL, quote: performance.venueName, now: now))
            }
        } else if !venue.isEmpty {
            evidence.append(makeEvidence(recordID: eventID, field: "performance.venueName", sourceURL: finalURL, quote: venue, now: now))
        } else if let onlyVenue = distinctPerformanceVenues.first {
            evidence.append(makeEvidence(recordID: eventID, field: "performance.venueName", sourceURL: finalURL, quote: onlyVenue, now: now))
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
        for round in rounds {
            evidence.append(makeEvidence(recordID: round.id, field: "ticket.round", sourceURL: finalURL, quote: round.officialName, now: now))
        }
        for benefit in ticketBenefits {
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
        for campaign in goodsCampaigns {
            evidence.append(makeEvidence(recordID: campaign.id, field: "goods.campaign", sourceURL: finalURL, quote: campaign.officialName, now: now))
        }

        return LiveEventBundle(
            schemaVersion: 1, revision: cached?.revision, publishedAt: now, event: event,
            stops: parsedStops, performances: performances,
            ticketTiers: tiers, ticketRounds: rounds, ticketOffers: [],
            goodsCampaigns: goodsCampaigns, mediaAssets: mediaAssets,
            notices: notices, evidence: mergeEvidence(cached?.evidence ?? [], evidence),
            editions: [], streamOffers: parsedStreams,
            products: products, goodsSessions: goodsSessions, ticketBenefits: ticketBenefits, sourceHealth: sourceHealth,
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
        let singleSectionHasMultipleVenues = stops.count == 1
            && regex(#"(?:会場[：:]|【会場】|■会場)"#, HTML.text(stops[0].html)).count > 1
        if !stops.isEmpty && !singleSectionHasMultipleVenues {
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
        let parsed = parseSchedules(raw)
        let venuesByDate = venuesPairedWithDates(in: raw)
        let shared = venuesByDate.isEmpty ? venueFromOverview(raw) : nil
        return parsed.map { schedule in
            var result = schedule
            if let own = venuesByDate[schedule.localDate] {
                result.venue = own
            } else if venuesByDate.isEmpty {
                result.venue = shared
            } else {
                result.venue = nil
            }
            return result
        }
    }

    /// Pairs each date with the venue in its own segment. One venue marker is a
    /// shared hall (empty map; the caller applies it to every date). Two or more
    /// markers stay per date, including when they name the same hall. A date that
    /// already has a hall does not donate that hall to a date that does not.
    static func venuesPairedWithDates(in raw: String) -> [String: String] {
        let source = raw.precomposedStringWithCompatibilityMapping
        let dateMatches = regex(#"(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日(?!目)"#, source)
        let venueMatches = regex(#"■会場|【(?:会場|場所)】|(?:会場|開催場所)[：:]"#, source).compactMap { match -> (location: Int, venue: String)? in
            guard let venue = venueValue(after: match.range, in: source) else { return nil }
            return (match.range.location, venue)
        }
        guard venueMatches.count >= 2, !dateMatches.isEmpty else { return [:] }
        var year: Int?
        var month: Int?
        var dated: [(location: Int, end: Int, local: String)] = []
        for match in dateMatches {
            if let value = group(match, 1, in: source).flatMap(Int.init) { year = value }
            if let value = group(match, 2, in: source).flatMap(Int.init) { month = value }
            guard let year, let month, let day = group(match, 3, in: source).flatMap(Int.init),
                  validDate(year: year, month: month, day: day) != nil else { continue }
            dated.append((match.range.location, NSMaxRange(match.range), String(format: "%04d-%02d-%02d", year, month, day)))
        }
        guard let firstDate = dated.first, let firstVenue = venueMatches.first else { return [:] }
        let venueBeforeDate = firstVenue.location < firstDate.location
        var venuesByDate: [String: String] = [:]
        for (index, date) in dated.enumerated() {
            let venue: String?
            if venueBeforeDate {
                let previousEnd = index == 0 ? -1 : dated[index - 1].end
                venue = venueMatches.last(where: { $0.location > previousEnd && $0.location < date.location })?.venue
            } else {
                let nextLocation = index + 1 < dated.count ? dated[index + 1].location : Int.max
                venue = venueMatches.first(where: { $0.location >= date.end && $0.location < nextLocation })?.venue
            }
            if let venue, venuesByDate[date.local] == nil { venuesByDate[date.local] = venue }
        }
        return venuesByDate
    }

    /// The hall named by one venue marker, stopping before the next marker.
    static func venueValue(after marker: NSRange, in raw: String) -> String? {
        let ns = raw as NSString
        let start = NSMaxRange(marker)
        guard start <= ns.length else { return nil }
        let rest = ns.substring(from: start)
        let boundary = rest.range(of: #"■会場|【(?:会場|場所)】|(?:会場|開催場所)[：:]|出演"#, options: .regularExpression)
        let window = boundary.map { String(rest[..<$0.lowerBound]) } ?? rest
        let cleaned = clean(window.replacingOccurrences(of: #"^[：:\s　]+"#, with: "", options: .regularExpression))
        let line = cleaned.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let value = clean(line)
        return value.isEmpty ? nil : value
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
    /// A tour that uses one hall still keeps that pairing. A block with no venue
    /// line is skipped instead of inheriting another stop.
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
        links.map { OfficialLink(label: $0.label, url: $0.url, role: OfficialLink.classify(label: $0.label, url: $0.url), productNames: $0.productNames) }
    }

    /// Pair only source-local product groups or explicit product labels. A
    /// generic link separated by receipt fields stays at round level.
    static func associateProductLinks(_ links: [OfficialLink], products: [String], lines: [(text: String, links: [OfficialLink])]) -> [OfficialLink] {
        func normalized(_ value: String) -> String {
            value.replacingOccurrences(of: #"[\s　]+"#, with: "", options: .regularExpression)
        }
        func matches(_ text: String) -> [String] {
            let value = normalized(text)
            return products.filter { value.contains(normalized($0)) }
        }
        var associations: [String: [String]] = [:]
        var pending: [String] = []
        var applied = false
        for line in lines {
            let named = matches(line.text)
            if !named.isEmpty {
                if applied { pending = []; applied = false }
                for name in named where !pending.contains(name) { pending.append(name) }
            } else if line.text.range(of: #"^(?:[■□◆●※]?\s*(?:受付期間|申込期間|当落発表|入金期間)|[-ー─]{5,}|⟪H⟫)"#, options: .regularExpression) != nil {
                pending = []
                applied = false
            }
            for link in line.links {
                let role = link.role ?? OfficialLink.classify(label: link.label, url: link.url)
                guard role == .application || role == .overseasApplication || role == .product else { continue }
                let explicit = matches(link.label)
                let names = !explicit.isEmpty ? explicit : pending
                guard !names.isEmpty else { continue }
                for name in names where !(associations[link.id] ?? []).contains(name) {
                    associations[link.id, default: []].append(name)
                }
                if role != .product { applied = true }
            }
        }
        return links.map { link in
            OfficialLink(label: link.label, url: link.url, role: link.role,
                         productNames: associations[link.id] ?? link.productNames)
        }
    }

    /// A paragraph/list item/table row may print the receipt before its
    /// product. Use that bounded source context rather than URL order.
    static func associateProductBlocks(_ links: [OfficialLink], products: [String], html: String, sourceURL: URL?) -> [OfficialLink] {
        var namesByLink: [String: [String]] = [:]
        for tag in ["p", "li", "tr"] {
            for block in HTML.blocks(html, tag: tag, className: nil) {
                let text = HTML.text(block).replacingOccurrences(of: #"[\s　]+"#, with: "", options: .regularExpression)
                let names = products.filter {
                    text.contains($0.replacingOccurrences(of: #"[\s　]+"#, with: "", options: .regularExpression))
                }
                let blockLinks = classifiedLinks(HTML.links(block, relativeTo: sourceURL))
                let applications = blockLinks.filter { $0.role == .application || $0.role == .overseasApplication }
                guard !names.isEmpty, names.count == 1 || Set(applications.map(\.url)).count == 1 else { continue }
                for link in blockLinks where link.role == .application || link.role == .overseasApplication || (link.role == .product && names.count == 1) {
                    let explicitNames = names.filter { link.label.contains($0) }
                    let associatedNames = explicitNames.isEmpty ? names : explicitNames
                    for name in associatedNames where !(namesByLink[link.id] ?? []).contains(name) {
                        namesByLink[link.id, default: []].append(name)
                    }
                }
            }
        }
        var seen: Set<String> = []
        return links.map { link in
            OfficialLink(label: link.label, url: link.url, role: link.role,
                productNames: namesByLink[link.id] ?? link.productNames)
        }.filter { link in
            // Generic repeated buttons collapse; distinct product associations
            // remain separate even when they share the same destination.
            seen.insert(link.url + "::" + link.productNames.sorted().joined(separator: "|")).inserted
        }
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
                let rest = line[markerRange.upperBound...].drop { $0 == "：" || $0 == ":" || $0 == " " || $0 == "\u{00a0}" || $0 == "】" || $0 == "　" }
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
            var seenLines: Set<String> = []
            let matchingLines = lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, rule.keywords.contains(where: { trimmed.contains($0) }) else { return nil }
                // 身分証明書番号 in a quantity-limit sentence is not an identity check.
                if rule.kind == .identityCheck, !trimmed.contains("本人確認"), trimmed.contains("番号") { return nil }
                // Section headings (【…】) and link-label lines ("▼スマチケご利用ガイドはこちら",
                // "▼顔認証入場システムのご利用について") are not note text.
                if trimmed.hasPrefix("【") || trimmed.hasPrefix("●") && trimmed.hasSuffix("●") { return nil }
                if trimmed.range(of: #"^[▼●■◆]?[^。]*(こちら|ガイド|について|とは[？?]?)[：:]?$"#, options: .regularExpression) != nil { return nil }
                // A clause that says the requirement does NOT apply is not a requirement;
                // keep only the keyword-bearing clauses that are not negated.
                let clauses = trimmed.components(separatedBy: "。").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let kept = clauses.filter { clause in
                    rule.keywords.contains(where: { clause.contains($0) })
                        && !clause.contains("必要はございません") && !clause.contains("必要ありません") && !clause.contains("不要です")
                }
                guard !kept.isEmpty else { return nil }
                var value = kept.joined(separator: "。") + "。"
                while let first = value.first, "※▼■●".contains(first) { value.removeFirst() }
                let cleaned = value.trimmingCharacters(in: .whitespaces)
                guard !cleaned.isEmpty, seenLines.insert(cleaned).inserted else { return nil }
                return String(cleaned.prefix(400))
            }
            guard !matchingLines.isEmpty else { continue }
            var seenLinkURLs: Set<String> = []
            let matchedLinks = links.filter { link in
                let lowerURL = link.url.lowercased()
                let matches = rule.linkFragments.contains(where: { lowerURL.contains($0) })
                    || (!rule.linkLabelFragments.isEmpty && rule.linkLabelFragments.contains(where: { link.label.contains($0) }))
                return matches && seenLinkURLs.insert(canonicalURL(link.url)).inserted
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

    /// A line reads as a product title (CD / Blu-ray / film ticket) rather than
    /// a sentence about the application itself.
    static func isProductTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return false }
        if trimmed.range(of: #"^(?:受付|各商品|下記|上記|申込券|シリアル|封入|本受付|※)"#, options: .regularExpression) != nil { return false }
        if trimmed.range(of: #"^(?:\d{4}年)?\d{1,2}[月/]\d{1,2}日?(?:（[^）]*）|\([^)]*\))?\s*(?:発売|リリース)$"#, options: .regularExpression) != nil { return false }
        if trimmed.hasSuffix("。") || trimmed.contains("にて受付") || trimmed.contains("ください") || trimmed.contains("いただけます") { return false }
        if trimmed.range(of: #"^【[^】]*(?:期間|発表|方法|制限|URL|注意|対象|お問い?合わ?せ)"#, options: .regularExpression) != nil { return false }
        if trimmed.range(of: #"[「『【]"#, options: .regularExpression) != nil { return true }
        // A bare format word ("Blu-ray", "CD") is not a title.
        guard trimmed.count > 8 else { return false }
        return trimmed.range(of: #"Album|Single|シングル|アルバム|Blu-ray|BD|DVD|CD|ムビチケ|前売券|サウンドトラック|ファンディスク|盤$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Product titles whose bundled application ticket (封入申込券 / シリアル)
    /// grants entry to the round. The title is read from the same line as the
    /// 封入 clause when the page prints it there; otherwise from the product
    /// lines listed just before that clause ("2025年8月6日発売 / <title> /
    /// 封入特典・申込券にて受付") or, for "下記2タイトル"-style wording, just after it.
    static func lotteryProducts(in lines: [String], html: String?) -> [String] {
        var products: [String] = []
        var seen: Set<String> = []
        func add(_ value: String) {
            // "11月5日（水）発売「…」" prints the release date before the title.
            let cleaned = clean(value.replacingOccurrences(of: #"^(?:\d{4}年)?\d{1,2}[月/]\d{1,2}日?(?:（[^）]*）|\([^)]*\))?\s*(?:発売|リリース)\s*"#, with: "", options: .regularExpression))
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return }
            products.append(cleaned)
        }
        let linkLabels = Set(HTML.links(html ?? "", relativeTo: nil).filter {
            let role = OfficialLink.classify(label: $0.label, url: $0.url)
            return role == .application || role == .overseasApplication || role == .support
        }.map(\.label))
        func isListDetail(_ value: String) -> Bool {
            value.isEmpty || linkLabels.contains(value) || value.hasPrefix("https://")
                || value.range(of: #"^(?:\d{4}年)?\d{1,2}[月/]\d{1,2}日?.*(?:発売|リリース)$"#, options: .regularExpression) != nil
        }
        func titlesBefore(_ index: Int) -> [String] {
            var found: [String] = []
            var cursor = index - 1
            while cursor >= 0 {
                let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("★") { break }
                if isListDetail(candidate) { cursor -= 1; continue }
                guard isProductTitle(candidate) else { break }
                found.insert(candidate, at: 0)
                cursor -= 1
            }
            return found
        }
        func titlesAfter(_ index: Int) -> [String] {
            var found: [String] = []
            var cursor = index + 1
            while cursor < lines.count {
                let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^[・①②③④⑤⑥⑦⑧⑨⑩]+"#, with: "", options: .regularExpression)
                if isListDetail(candidate) { cursor += 1; continue }
                guard isProductTitle(candidate) else { break }
                found.append(candidate)
                cursor += 1
            }
            return found
        }
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, trimmed) in trimmedLines.enumerated() {
            guard trimmed.contains("封入"), trimmed.contains("申込券") || trimmed.contains("シリアル") else { continue }
            var value = trimmed
            if value.hasPrefix("※") { value.removeFirst() }
            var prefix: String?
            for marker in ["初回生産分に封入", "初回生産分限定封入", "初回生産分に", "に封入", "封入特典", "封入の", "封入申込券"] {
                if let range = value.range(of: marker) {
                    prefix = String(value[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "、の 　・"))
                    break
                }
            }
            if let prefix, isProductTitle(prefix) {
                // "A・B・C いずれか" lists alternatives on one line; without that
                // word, "「A」/「B」【X盤】・【Y盤】" is one title with its editions.
                if prefix.hasSuffix("いずれか") {
                    let alternatives = prefix.replacingOccurrences(of: #"\s*いずれか$"#, with: "", options: .regularExpression)
                    let parts = alternatives.components(separatedBy: CharacterSet(charactersIn: "・／/")).map { $0.trimmingCharacters(in: .whitespaces) }.filter(isProductTitle)
                    if parts.count > 1 { parts.forEach(add) } else { add(alternatives) }
                } else {
                    add(prefix)
                }
                continue
            }
            let before = titlesBefore(index)
            if !before.isEmpty { before.forEach(add); continue }
            titlesAfter(index).forEach(add)
        }
        return products
    }

    /// The official sentence(s) that say what a round requires (a bundled
    /// application ticket, a film ticket serial, membership). Only the
    /// keyword-bearing clauses are kept so the card shows the condition, not
    /// the whole announcement block.
    static func eligibilitySummary(in lines: [String]) -> String? {
        var clauses: [String] = []
        var seen: Set<String> = []
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            while let first = trimmed.first, "※▼■●★・".contains(first) { trimmed.removeFirst() }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            guard trimmed.range(of: "封入|申込券|ムビチケ|シリアル", options: .regularExpression) != nil else { continue }
            // Field lines (受付期間 / 枚数制限) and the ★target line have their own columns.
            if trimmed.range(of: #"^(?:受付期間|申込期間|当落発表|入金期間|枚数制限|受付URL|お?申し?込み?対象)"#, options: .regularExpression) != nil { continue }
            if trimmed.hasPrefix(HTML.headingLineMarker) { continue }
            for rawClause in trimmed.components(separatedBy: "。") {
                let clause = rawClause.trimmingCharacters(in: .whitespaces)
                guard !clause.isEmpty, clause.range(of: "封入|申込券|ムビチケ|シリアル", options: .regularExpression) != nil,
                      clause.count <= 160, seen.insert(clause).inserted else { continue }
                // A list heading ("抽選申込券封入商品") or a numbered product line is
                // not a condition sentence; the products have their own column.
                if clause.range(of: #"封入商品[：:]?$|^商品[：:]?$"#, options: .regularExpression) != nil { continue }
                // An erratum about earlier wording is not a condition either.
                if clause.range(of: "誤り|訂正|お詫び", options: .regularExpression) != nil { continue }
                // "シリアルの入力は不要です" says the round has no such condition.
                if clause.range(of: "不要|必要ありません|必要ございません|必要はございません|必要はありません", options: .regularExpression) != nil { continue }
                if clause.range(of: #"^[①②③④⑤⑥⑦⑧⑨⑩・]"#, options: .regularExpression) != nil,
                   isProductTitle(clause.replacingOccurrences(of: #"^[①②③④⑤⑥⑦⑧⑨⑩・]+"#, with: "", options: .regularExpression)) { continue }
                clauses.append(clause.hasSuffix("受付") || clause.hasSuffix("可能") ? clause : clause + "。")
            }
            if clauses.count >= 3 { break }
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: "\n")
    }

    static func parseTicketRounds(_ html: String, eventID: String, cached: [TicketRound], timeZone: String = "Asia/Tokyo", referenceDate: String? = nil, sourceURL: URL? = nil, sharedLinks: [OfficialLink] = []) -> [ParsedTicketRound] {
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
            let announcedProductRound = namesRound && raw.contains("封入")
                && raw.range(of: "申込券|シリアル", options: .regularExpression) != nil
                && raw.range(of: "後日|追って|未定", options: .regularExpression) != nil
            return Candidate(links: links, hasApplication: hasApplication, isRound: hasPeriod || buttonRound || announcedProductRound, isLinkCarrier: linkOnly && !buttonRound && !announcedProductRound)
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
        let rounds: [ParsedTicketRound] = headings.enumerated().compactMap { index, section in
            let raw = HTML.text(section.html)
            guard candidates[index].isRound else { return nil }
            // The heading names the round; body text only decides when the
            // heading is silent (a 先行抽選 block that mentions トレード is still a lottery).
            let heading = section.heading
            let kind: TicketRoundKind = heading.contains("抽選") ? .lottery
                : heading.contains("一般発売") || heading.contains("先着") ? .firstComeFirstServed
                : heading.contains("トレード") || heading.contains("リセール") ? .resale
                : heading.contains("アップグレード") ? .upgrade
                : raw.contains("先着") ? .firstComeFirstServed
                : raw.contains("トレード") ? .resale : .lottery
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

            var ownLinks = candidates[index].links + (carrierFor[index].map { candidates[$0].links } ?? [])
            let hasOwnApplication = ownLinks.contains { $0.role == .application || $0.role == .overseasApplication }
            if !hasOwnApplication {
                ownLinks += classifiedSharedLinks.filter { $0.role == .application || $0.role == .overseasApplication }
            }
            let lines = raw.components(separatedBy: "\n")
            let products = lotteryProducts(in: lines, html: section.html)
            let identity = ticketRoundIdentity(section.heading)
            let repeated = headings.filter { ticketRoundIdentity($0.heading) == identity }.count > 1
            let applicationURLs = Set(ownLinks.filter { $0.role == .application || $0.role == .overseasApplication }.map(\.url))
            let discriminator = repeated ? "|" + products.joined(separator: "|") + "|" + (period ?? "") + "|" + applicationURLs.sorted().joined(separator: "|") : ""
            let id = cached.first(where: {
                ticketRoundIdentity($0.officialName) == identity && (!repeated || ($0.lotteryProducts == products && $0.applyStartAt == dates.first && Set($0.allApplicationLinks.map(\.url)) == applicationURLs))
            })?.id ?? "\(eventID)-round-\(stableHash(identity + discriminator))"
            ownLinks = associateProductLinks(ownLinks, products: products,
                lines: HTML.annotatedLines(section.html, relativeTo: sourceURL).map { (text: $0.text, links: $0.links) })

            ownLinks = associateProductBlocks(ownLinks, products: products, html: section.html, sourceURL: sourceURL)
            let paymentWindowText = markedLineText(raw, markers: ["入金期間", "支払期間", "支払期限"])
            let paymentDates = parseExplicitDateTimes(paymentWindowText ?? "")

            return ParsedTicketRound(round: TicketRound(
                id: id, eventID: eventID,
                officialName: section.heading, kind: kind,
                scope: .unconfirmed,
                applyStartAt: dates.first, applyEndAt: dates.dropFirst().first,
                resultAt: reinterpretJapanWallTime(markerDate(raw, marker: "当落発表") ?? markerDate(raw, marker: "当選発表"), in: timeZone),
                paymentDeadlineAt: reinterpretJapanWallTime(paymentDates.last, in: timeZone),
                eligibility: eligibilitySummary(in: lines),
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
                lotteryProducts: products,
                applicationTarget: nil,
                notes: ticketNotes(in: lines, links: ownLinks)
            ), scopeText: section.heading + "\n" + raw)
        }
        var seenRoundIDs: Set<String> = []
        return rounds.filter { seenRoundIDs.insert($0.round.id).inserted }
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
            // The benefit body ends at the first separator rule, 【…】 heading,
            // ▼/▶ guide-link line or bare URL: what follows (contact desk,
            // smart-ticket guide) belongs to the page, not to the bonus.
            let allLines = HTML.text(ownHTML).components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
            var bodyStart = 0
            while bodyStart < allLines.count, allLines[bodyStart].range(of: #"^【[^】]+】$|^[▼▶]"#, options: .regularExpression) != nil { bodyStart += 1 }
            let bodyEnd = allLines[bodyStart...].firstIndex { line in
                line.range(of: #"^[-ー─＿_]{5,}$|^【[^】]+】$|^[▼▶]|^https?://"#, options: .regularExpression) != nil
            } ?? allLines.count
            let lines = Array(allLines[bodyStart..<bodyEnd])
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
                    thumbnailURL: image.thumbnail?.absoluteString,
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
    static func parseLoveLiveTicketRounds(_ html: String, eventID: String, cached: [TicketRound], timeZone: String, referenceDate: String?, sourceURL: URL?) -> [ParsedTicketRound] {
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
        // ★申込対象： / ★申込対象公演： / ★お申込み対象： / 受付対象公演： all start a sub-block.
        let targetRE = #"^[★■●◆]?\s*(?:お?申し?込み?対象(?:公演)?|受付対象(?:公演)?)\s*[：:]\s*(.*)$"#
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
                let resumesRound = regex(roundHeadingRE, text).first.flatMap { group($0, 1, in: text) }
                    .map { inner in roundHeadingKeywords.contains(where: { inner.contains($0) }) } ?? false
                if text.hasPrefix(HTML.headingLineMarker) || resumesRound { inSectionNotes = false } else {
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
                // "【受付期間】2026年…" keeps its closing bracket in the capture.
                var value = (group(match, 2, in: text) ?? "").replacingOccurrences(of: #"^[】\]：:\s　]+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
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
                        if candidateText.hasPrefix("※") { break }
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
                    let valueLines = value.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    let perLineDates = valueLines.map { parseExplicitDateTimes(injectYearIfNeeded($0, referenceDate: referenceDate)) }
                    if valueLines.count >= 2, perLineDates.allSatisfy({ $0.count <= 1 }) {
                        // "Day.1　7月11日 0:00～ / Day.2　7月12日 0:00～": independent start times, not a window.
                        currentBlock?.applyDates = perLineDates.compactMap(\.first).min().map { [$0] } ?? []
                    } else {
                        currentBlock?.applyDates = parseExplicitDateTimes(injectYearIfNeeded(value, referenceDate: referenceDate))
                    }
                case "当落発表", "当選発表", "抽選結果":
                    currentBlock?.resultText = value
                    currentBlock?.resultDates = parseExplicitDateTimes(injectYearIfNeeded(value, referenceDate: referenceDate))
                case "入金期間", "支払期間", "支払い期間", "支払期限":
                    currentBlock?.paymentWindowText = value
                    currentBlock?.paymentDates = parseExplicitDateTimes(injectYearIfNeeded(value, referenceDate: referenceDate))
                case "受付URL", "申込URL":
                    for match in regex(#"https?://[^\s<>]+"#, value) {
                        if let url = group(match, 0, in: value),
                           !(currentBlock?.allLines.flatMap(\.links).contains { $0.url == url } ?? false) {
                            currentBlock?.receiptLinks.append(OfficialLink(label: "受付URL", url: url))
                        }
                    }
                case "対象公演":
                    if currentBlock?.applicationTargetField == nil { currentBlock?.applicationTargetField = value }
                case "枚数制限":
                    currentBlock?.quantityLimit = value
                case "支払い方法", "支払方法":
                    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedValue.isEmpty {
                        let kind: TicketNoteKind = trimmedValue.contains("クレジット") ? .creditCardOnly : .other
                        currentBlock?.extraNotes.append(TicketNote(kind: kind, text: trimmedValue, links: []))
                    }
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

        // A section-level sentence that names rounds ("＜一般発売（先着）＞と＜当日券販売（先着）＞受付で…")
        // applies only to those rounds; unscoped sentences apply to every round.
        func roundReferences(_ text: String) -> [String] {
            regex(#"[＜<]([^＜＞<>]+)[＞>]"#, text).compactMap { group($0, 1, in: text).map(clean) }
                .filter { inner in roundHeadingKeywords.contains(where: { inner.contains($0) }) }
        }
        let sectionLinks = classifiedLinks(sectionNoteLines.flatMap(\.links))
        func sectionNotes(for roundHeading: String) -> [TicketNote] {
            let scoped = sectionNoteLines.filter { line in
                let references = roundReferences(line.text)
                return references.isEmpty || references.contains(clean(roundHeading))
            }
            return ticketNotes(in: scoped.map(\.text), links: sectionLinks)
        }

        func loveLiveLotteryProducts(_ productLines: [Line]) -> [String] {
            var results: [String] = []
            for line in productLines {
                var text = line.text
                if text.hasPrefix("http://") || text.hasPrefix("https://") { continue }
                if !line.links.isEmpty, line.links.allSatisfy({
                    let role = OfficialLink.classify(label: $0.label, url: $0.url)
                    return role == .application || role == .overseasApplication || role == .support
                }), !isProductTitle(text) { continue }
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

        let rounds: [ParsedTicketRound] = blocks.compactMap { block in
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

            let lotteryProducts = loveLiveLotteryProducts(block.productLines)
            let lineLinks = associateProductLinks(
                classifiedLinks(block.allLines.flatMap(\.links) + block.receiptLinks),
                products: lotteryProducts, lines: block.allLines.map { (text: $0.text, links: $0.links) })
            let ownLinks = associateProductBlocks(lineLinks, products: lotteryProducts, html: html, sourceURL: sourceURL)
            let applyDates = block.applyDates.compactMap { reinterpretJapanWallTime($0, in: timeZone) }
            let resultDate = block.resultDates.last.flatMap { reinterpretJapanWallTime($0, in: timeZone) }
            let paymentDates = block.paymentDates.compactMap { reinterpretJapanWallTime($0, in: timeZone) }

            let blockNotes = ticketNotes(in: block.allLines.map(\.text) + block.productLines.map(\.text), links: ownLinks) + block.extraNotes
            var seenNoteIDs: Set<String> = []
            let notes = (blockNotes + sectionNotes(for: block.roundHeading)).filter { seenNoteIDs.insert($0.id).inserted }

            let hasDates = !applyDates.isEmpty || resultDate != nil || !paymentDates.isEmpty
            let isWaiting = !hasDates && nameAndFields.range(of: "後日|追って|未定", options: .regularExpression) != nil

            let identity = ticketRoundIdentity(officialName)
            let repeated = blocks.filter { other in
                let name = other.target.map { "\(other.roundHeading)（\($0)）" } ?? other.roundHeading
                return ticketRoundIdentity(name) == identity
            }.count > 1
            let applicationURLs = Set(ownLinks.filter { $0.role == .application || $0.role == .overseasApplication }.map(\.url))
            let discriminator = repeated ? "|" + lotteryProducts.joined(separator: "|") + "|" + (block.applyWindowText ?? "") + "|" + applicationURLs.sorted().joined(separator: "|") : ""
            let id = cached.first(where: {
                ticketRoundIdentity($0.officialName) == identity && (!repeated || ($0.lotteryProducts == lotteryProducts && $0.applyStartAt == applyDates.first && Set($0.allApplicationLinks.map(\.url)) == applicationURLs))
            })?.id ?? "\(eventID)-round-\(stableHash(identity + discriminator))"

            return ParsedTicketRound(round: TicketRound(
                id: id, eventID: eventID,
                officialName: officialName, kind: kind,
                scope: .unconfirmed,
                applyStartAt: applyDates.first, applyEndAt: applyDates.dropFirst().first,
                resultAt: resultDate,
                paymentDeadlineAt: paymentDates.last,
                eligibility: eligibilitySummary(in: block.allLines.map(\.text) + block.productLines.map(\.text)),
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
            ), scopeText: officialName + "\n" + allText)
        }
        var seenRoundIDs: Set<String> = []
        return rounds.filter { seenRoundIDs.insert($0.round.id).inserted }
    }

    static func parseStreams(
        _ html: String,
        sourceURL: URL,
        eventID: String,
        performances: [Performance],
        ticketScope: Scope
    ) -> [StreamOffer] {
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
                    scope: resolvedScope(.unconfirmed, text: label + "\n" + slice, performances: performances, fallback: ticketScope),
                    amount: amount, salesStartAt: dates.first, salesEndAt: dates.dropFirst().first,
                    archiveAvailableUntil: archive, regionNote: nil, url: url, status: .confirmed))
            }
        }
        return offers
    }

    /// Love Live pages publish paid streams in a tab (`data-target="streaming"`,
    /// `str`, `spwn`) as labelled line groups: 【生配信日程】, 【アーカイブ期間】,
    /// チケット料金 (・1公演視聴券：6,000円), 販売期間 (common or "Day.1　…"
    /// lines) and ＜イープラス＞ / ＜チケットぴあ＞ / ＜SPWN＞ vendor links.
    /// One offer per price tier, split per DAY when the archive deadline
    /// differs by day; a DAY offer is scoped to the performances of that day.
    static func parseLoveLiveStreams(
        _ blocks: [String],
        sourceURL: URL,
        eventID: String,
        performances: [Performance],
        timeZone: String,
        referenceDate: String?
    ) -> [StreamOffer] {
        enum Mode { case none, schedule, archive, price, sales }
        struct Tier { let name: String; let amount: MoneyAmount; var sales: [Date] = [] }
        var offers: [StreamOffer] = []
        var seenNames: Set<String> = []
        func dayKey(_ text: String) -> String? {
            regex(#"(?:^|[◆■●\s　])DAY\.?\s*(\d+)"#, text, options: [.caseInsensitive]).first
                .flatMap { group($0, 1, in: text) }.map { "DAY\($0)" }
        }
        for block in blocks {
            let lines = HTML.annotatedLines(block, relativeTo: sourceURL)
            var mode: Mode = .none
            var currentDay: String?
            var tiers: [Tier] = []
            /// Set right after a price line so "price / window" pairs (SPWN style)
            /// attach their window to that tier; cleared by a 販売期間 header.
            var pendingTier: Int?
            var commonSales: [Date] = []
            var perDaySales: [String: [Date]] = [:]
            var archiveEnds: [String: Date] = [:]
            var links: [OfficialLink] = []
            for line in lines {
                var text = line.text
                if text.hasPrefix(HTML.headingLineMarker) { text = String(text.dropFirst(HTML.headingLineMarker.count)) }
                text = text.trimmingCharacters(in: .whitespaces)
                links += line.links
                let hasDate = text.range(of: #"\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil
                if !hasDate, let day = dayKey(text), text.range(of: #"^[◆■●]?\s*DAY\.?\s*\d+"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    currentDay = day
                    continue
                }
                if text.contains("注意事項") || text.contains("お問合せ") || text.contains("お問い合わせ") || text.contains("特典") {
                    if text.hasPrefix("【") || text.hasPrefix("＜") { mode = .none; continue }
                }
                if text.contains("アーカイブ") || text.contains("配信期間") || text.contains("見逃し") {
                    mode = .archive
                } else if text.contains("販売期間") || text.contains("受付期間") {
                    mode = text.contains("料金") ? .price : .sales
                    pendingTier = nil
                } else if text.contains("料金") {
                    mode = .price
                } else if text.contains("生配信日程") || text.contains("配信日時") || text.contains("配信日程") {
                    mode = .schedule
                }
                if let match = regex(#"^[・■]?\s*(.+?(?:視聴券|視聴チケット|配信チケット|配信視聴))\s*[：:]?\s*(?:各公演)?\s*[¥￥]?([\d,]+)円"#, text).first,
                   let name = group(match, 1, in: text).map({ clean($0.replacingOccurrences(of: #"^[・･■●◆]+"#, with: "", options: .regularExpression)) }),
                   let digits = group(match, 2, in: text)?.replacingOccurrences(of: ",", with: ""), let yen = Int64(digits) {
                    tiers.append(Tier(name: name, amount: MoneyAmount(minorUnits: yen, currency: "JPY")))
                    mode = .sales
                    pendingTier = tiers.count - 1
                    continue
                }
                guard hasDate else { continue }
                let dates = parseExplicitDateTimes(injectYearIfNeeded(text, referenceDate: referenceDate))
                    .compactMap { reinterpretJapanWallTime($0, in: timeZone) }
                guard !dates.isEmpty else { continue }
                let lineDay = dayKey(text) ?? currentDay
                switch mode {
                case .archive:
                    if let end = dates.last { archiveEnds[lineDay ?? "*"] = max(archiveEnds[lineDay ?? "*"] ?? end, end) }
                case .sales:
                    if let lineDay = dayKey(text) {
                        perDaySales[lineDay] = dates
                    } else if let index = pendingTier, text.range(of: #"^[◆■●※]"#, options: .regularExpression) == nil {
                        if tiers[index].sales.isEmpty { tiers[index].sales = dates } else if let last = dates.last, last > (tiers[index].sales.last ?? .distantPast) { tiers[index].sales[tiers[index].sales.count - 1] = last }
                    } else if commonSales.isEmpty { commonSales = dates }
                case .price, .schedule, .none:
                    continue
                }
            }
            let vendorLinks = classifiedLinks(links).filter { $0.role != .support && !isShareLink(URL(string: $0.url) ?? sourceURL) }
            let url = vendorLinks.first { $0.host?.contains("eplus") == true }?.url
                ?? vendorLinks.first { $0.host?.contains("pia.jp") == true }?.url
                ?? vendorLinks.first { $0.host?.contains("spwn") == true }?.url
                ?? vendorLinks.first { $0.host?.contains("bilibili") == false }?.url
            let platform: String = {
                guard let url else { return "公式配信" }
                if url.contains("eplus") { return "Streaming+" }
                if url.contains("pia.jp") { return "PIA LIVE STREAM" }
                if url.contains("spwn") { return "SPWN" }
                return "公式配信"
            }()
            guard !tiers.isEmpty, url != nil || !archiveEnds.isEmpty || !commonSales.isEmpty else { continue }
            let dayKeys = archiveEnds.keys.filter { $0 != "*" }.sorted()
            for tier in tiers {
                let tierSales = tier.sales.isEmpty ? commonSales : tier.sales
                func append(name: String, sales: [Date], archive: Date?, scope: Scope) {
                    guard seenNames.insert(platform + "|" + name).inserted else { return }
                    offers.append(StreamOffer(id: stableID(prefix: "\(eventID)-stream", seed: platform + "|" + name), eventID: eventID,
                        platform: platform, officialName: name, scope: scope, amount: tier.amount,
                        salesStartAt: sales.first, salesEndAt: sales.count > 1 ? sales.last : nil,
                        archiveAvailableUntil: archive, regionNote: nil, url: url, status: .confirmed))
                }
                // A through pass (通し) covers every day; only per-day tickets split.
                let isThroughPass = tier.name.contains("通し") || tier.name.range(of: #"\d+DAYS?"#, options: [.regularExpression, .caseInsensitive]) != nil
                if !isThroughPass, dayKeys.count > 1 || (dayKeys.count == 1 && perDaySales.count > 1) {
                    for day in Set(dayKeys + perDaySales.keys).sorted() {
                        let number = day.dropFirst(3)
                        let ids = performances.filter { $0.dayLabel.uppercased().replacingOccurrences(of: #"[\s\.]"#, with: "", options: .regularExpression) == day }.map(\.id)
                        append(name: "\(tier.name) Day.\(number)", sales: perDaySales[day] ?? tierSales,
                               archive: archiveEnds[day] ?? archiveEnds["*"], scope: ids.isEmpty ? .unconfirmed : .performances(performanceIDs: ids))
                    }
                } else {
                    // A through pass covers the performances of every listed day.
                    let ids = performances.filter { performance in
                        dayKeys.contains(performance.dayLabel.uppercased().replacingOccurrences(of: #"[\s\.]"#, with: "", options: .regularExpression))
                    }.map(\.id)
                    append(name: tier.name, sales: tierSales, archive: archiveEnds.values.max(),
                           scope: isThroughPass && !ids.isEmpty ? .performances(performanceIDs: ids) : .unconfirmed)
                }
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
        eventCoverSourceURL: URL?,
        performances: [Performance],
        ticketScope: Scope
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
                thumbnailURL: nil,
                scope: resolvedScope(.unconfirmed, text: "公演キービジュアル", performances: performances, fallback: ticketScope),
                sourceURL: sourceURL.absoluteString,
                version: (prior?.version ?? 0) + 1, caption: "公演キービジュアル",
                displayPolicy: .remoteDisplay, contentKind: .image
            ))
        }
        let sections = HTML.headingSections(html).filter { $0.heading.contains("座席") || $0.heading.contains("会場エリア") }
        assets.append(contentsOf: sections.flatMap { section in
            let sectionHTML = HTML.sectionHTML(html, heading: section.heading) ?? section.html
            let genericVenueMap = section.heading.contains("汎用")
            let seatingText = section.heading + "\n" + HTML.text(sectionHTML)
            let resolvedSeating = resolvedScope(.unconfirmed, text: seatingText, performances: performances, fallback: ticketScope)
            // One chart for every date at the same hall is that hall's chart.
            // A generic venue diagram, or days at different halls, stays unconfirmed.
            let seatingScope: Scope = genericVenueMap
                ? .unconfirmed
                : (resolvedSeating == .unconfirmed ? (sharedVenueScope(performances) ?? resolvedSeating) : resolvedSeating)
            return extractImages(sectionHTML, relativeTo: sourceURL).map { image in
                let prior = cached.first { canonicalURL($0.originalURL) == canonicalURL(image.original.absoluteString) }
                return MediaAsset(
                    id: prior?.id ?? stableID(prefix: "\(eventID)-media", seed: canonicalURL(image.original.absoluteString)),
                    eventID: eventID, kind: genericVenueMap ? .venueGenericSeatingMap : .eventSeatingMap,
                    originalURL: image.original.absoluteString,
                    thumbnailURL: image.thumbnail?.absoluteString, scope: seatingScope,
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
        let allSections = HTML.headingRegions(html)
        var sections = allSections
            .filter { isGoodsHeading($0.heading) }
            .map { (heading: $0.heading, html: $0.html) }
        if sections.isEmpty, let goods = HTML.blockWithAttribute(html, attribute: "data-target", value: "goods") {
            sections = [(heading: "グッズ", html: goods)]
        }
        // Page-level notices about venue sales (個数制限 / クイックオーダー案内)
        // are not campaigns: their limit text and links extend the venue campaign.
        let sharedLimit = goodsPurchaseLimitText(
            allSections.filter { isGoodsLimitHeading($0.heading) }.map { HTML.text($0.html) }.joined(separator: "\n")
        )
        let sharedVenueLinks = allSections
            .filter { isGoodsVenueGuideHeading($0.heading) }
            .flatMap { HTML.links($0.html, relativeTo: sourceURL) }
        var media: [MediaAsset] = []
        var campaigns: [GoodsCampaign] = []
        var bodies: [String: String] = [:]
        var usedIDs: Set<String> = []
        /// Several sections of one page often share their first link (the goods
        /// X account); a second record on the same link gets a name-qualified ID.
        func uniqueID(_ candidate: String, name: String) -> String {
            let resolved = usedIDs.contains(candidate) ? stableID(prefix: "\(eventID)-goods", seed: candidate + "|" + clean(name)) : candidate
            usedIDs.insert(resolved)
            return resolved
        }
        func parentPerformanceHeading(for sectionHTML: String, sectionHeading: String) -> String? {
            let parents = allSections.filter { other in
                other.heading != sectionHeading
                    && other.html.count > sectionHTML.count
                    && other.html.contains(sectionHeading)
                    && !isGoodsHeading(other.heading)
                    && hasOwnScopeCue(other.heading)
            }
            return parents.min(by: { $0.html.count < $1.html.count })?.heading
        }
        for section in sections {
            // A container heading (グッズ情報 above 会場グッズ販売について / グッズ通販)
            // is not a campaign; its child sections are.
            let childHeadings = HTML.headingSections(section.html).map(\.heading)
            if childHeadings.contains(where: isGoodsHeading) { continue }
            let text = HTML.text(section.html)
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let imageSources = extractImages(section.html, relativeTo: sourceURL)
            let assets = imageSources.map { image -> MediaAsset in
                let prior = cachedMedia.first { canonicalURL($0.originalURL) == canonicalURL(image.original.absoluteString) }
                return MediaAsset(
                    id: prior?.id ?? stableID(prefix: "\(eventID)-media", seed: canonicalURL(image.original.absoluteString)),
                    eventID: eventID, kind: .goodsList, originalURL: image.original.absoluteString,
                    thumbnailURL: image.thumbnail?.absoluteString,
                    scope: .unconfirmed, sourceURL: sourceURL.absoluteString,
                    version: (prior?.version ?? 0) + 1, caption: section.heading,
                    displayPolicy: .remoteDisplay, contentKind: .image
                )
            }
            media.append(contentsOf: assets)
            let sectionLinks = HTML.links(section.html, relativeTo: sourceURL).filter { !isSiteNavigationLink($0) }
            let link = sectionLinks.compactMap { URL(string: $0.url) }.first
            guard link != nil || !text.isEmpty || !assets.isEmpty else { continue }
            // Refresh stability: the same heading on the same link is the same
            // record; failing that the same heading; a link alone only when one
            // cached record carries it (several sections share the goods X account).
            func prior(name: String, url: URL?) -> GoodsCampaign? {
                let sameName = cachedCampaigns.filter { clean($0.officialName) == clean(name) }
                if let url {
                    let canonical = canonicalURL(url.absoluteString)
                    if let both = sameName.first(where: { $0.url.map(canonicalURL) == canonical }) { return both }
                    if let byName = sameName.first { return byName }
                    let sameURL = cachedCampaigns.filter { $0.url.map(canonicalURL) == canonical }
                    return sameURL.count == 1 ? sameURL.first : nil
                }
                return sameName.first
            }

            // "■事前通販受付 / <window> / ※発送…" sub-blocks inside one goods
            // section are separate sales rounds with their own window. The
            // section itself stays as the catalog record (store link, gallery)
            // and the rounds carry the dates, shipping and limits.
            let subCampaigns = childHeadings.isEmpty ? goodsSubCampaigns(in: lines) : []
            if subCampaigns.count >= 1, !subCampaigns.contains(where: { clean($0.name) == clean(section.heading) }) {
                let subLineSet = Set(subCampaigns.flatMap { [$0.name] + $0.lines })
                let catalogLines = lines.filter { !subLineSet.contains($0) && $0.range(of: #"^[■●◆□]?\s*(?:第\d+回)?(?:事前|事後|先行|会場)?(?:グッズ)?(?:通販|物販)(?:受付)?\s*[：:]?$"#, options: .regularExpression) == nil }
                if link != nil || !assets.isEmpty {
                    let key = link.map { canonicalURL($0.absoluteString) } ?? clean(section.heading)
                    let cached = prior(name: section.heading, url: link)
                    let catalogText = catalogLines.joined(separator: "\n")
                    let catalogID = uniqueID(cached?.id ?? stableID(prefix: "\(eventID)-goods", seed: key), name: section.heading)
                    let parent = parentPerformanceHeading(for: section.html, sectionHeading: section.heading)
                    bodies[catalogID] = goodsScopeText(heading: section.heading, body: catalogText, parentHeading: parent)
                    campaigns.append(GoodsCampaign(
                        id: catalogID, eventID: eventID,
                        officialName: section.heading, channel: .online, fulfillment: .shipping, phase: .unknown,
                        scope: .unconfirmed, salesStartAt: nil, salesEndAt: nil, pickupWindow: nil,
                        shippingNote: nil, location: nil, requiresTicket: nil,
                        purchaseLimit: goodsPurchaseLimitText(catalogText), paymentMethods: nil, url: link?.absoluteString,
                        mediaAssetIDs: assets.map(\.id), status: .confirmed, links: sectionLinks
                    ))
                }
                for sub in subCampaigns {
                    let channel: GoodsChannel = sub.name.contains("会場") ? .venue : .online
                    let phase: GoodsPhase = sub.name.contains("事後") ? .post : sub.name.contains("事前") || sub.name.contains("先行") ? .pre : channel == .venue ? .during : .unknown
                    let salesDates = parseExplicitDateTimes(firstDateRangeLine(sub.lines) ?? "")
                    let shipping = sub.lines.filter { $0.contains("発送") || $0.contains("お届け") }
                        .map { $0.replacingOccurrences(of: #"^※"#, with: "", options: .regularExpression) }.joined(separator: "\n")
                    let name = clean(sub.name)
                    let cached = prior(name: name, url: link)
                    let subID = uniqueID(cached?.id ?? stableID(prefix: "\(eventID)-goods", seed: (link.map { canonicalURL($0.absoluteString) } ?? "") + "|" + name), name: name)
                    let parent = parentPerformanceHeading(for: section.html, sectionHeading: section.heading)
                    let inherited = hasOwnScopeCue(section.heading) ? section.heading : parent
                    bodies[subID] = goodsScopeText(heading: name, body: sub.lines.joined(separator: "\n"), parentHeading: inherited)
                    campaigns.append(GoodsCampaign(
                        id: subID,
                        eventID: eventID, officialName: name, channel: channel,
                        fulfillment: channel == .online ? .shipping : .venuePickup, phase: phase,
                        scope: .unconfirmed, salesStartAt: salesDates.first, salesEndAt: salesDates.dropFirst().first,
                        pickupWindow: channel == .venue ? goodsSalesWindowText(sub.lines) : nil,
                        shippingNote: shipping.isEmpty ? nil : shipping, location: nil,
                        requiresTicket: goodsRequiresTicket(sub.lines.joined(separator: "\n")),
                        purchaseLimit: goodsPurchaseLimitText(sub.lines.joined(separator: "\n")),
                        paymentMethods: nil, url: link?.absoluteString,
                        mediaAssetIDs: [], status: .confirmed, links: sectionLinks
                    ))
                }
                continue
            }

            let location = HTML.sectionText(section.html, heading: "販売場所")
                ?? labeledLineValue(lines, labels: ["販売場所", "販売会場"])
            let salesText = ["先行通販開始", "通販期間", "販売期間", "受付期間", "販売日時", "販売時間"]
                .compactMap { HTML.sectionText(section.html, heading: $0) }.first
                ?? labeledLineValue(lines, labels: ["通販期間", "販売期間", "受付期間", "販売日時"])
                ?? firstDateRangeLine(lines)
            var channel: GoodsChannel = section.heading.contains("会場") ? .venue
                : section.heading.contains("通販") ? .online
                : text.contains("会場販売") ? .venue : text.contains("通販") ? .online : .unknown
            if channel == .unknown, location != nil || text.contains("先行物販") || text.contains("開場中物販") { channel = .venue }
            let fulfillment: GoodsFulfillment = channel == .online ? .shipping : channel == .venue ? .venuePickup : .unknown
            let phase: GoodsPhase = section.heading.contains("事後") || text.contains("事後通販") ? .post
                : section.heading.contains("事前") || section.heading.contains("先行") || text.contains("事前通販") || text.contains("先行通販") ? .pre
                : channel == .venue ? .during : .unknown
            let salesDates = parseExplicitDateTimes(salesText ?? "")
            let purchaseLimit = goodsPurchaseLimitText(
                HTML.sectionText(section.html, heading: "購入制限について") ?? HTML.sectionText(section.html, heading: "購入制限")
                    ?? lines.filter { $0.contains("購入制限") || $0.contains("個数制限") || $0.contains("注文点数") || $0.range(of: #"[個点枚]まで"#, options: .regularExpression) != nil }.joined(separator: "\n")
            )
            let shipping = channel == .online ? lines.filter { $0.contains("発送") || $0.contains("お届け") }
                .map { $0.replacingOccurrences(of: #"^※"#, with: "", options: .regularExpression) }.joined(separator: "\n") : ""
            let key = link.map { canonicalURL($0.absoluteString) } ?? clean(section.heading)
            let cached = prior(name: section.heading, url: link)
            let campaignID = uniqueID(cached?.id ?? stableID(prefix: "\(eventID)-goods", seed: key), name: section.heading)
            let parent = parentPerformanceHeading(for: section.html, sectionHeading: section.heading)
            bodies[campaignID] = goodsScopeText(heading: section.heading, body: text, parentHeading: parent)
            campaigns.append(GoodsCampaign(
                id: campaignID, eventID: eventID,
                officialName: section.heading, channel: channel, fulfillment: fulfillment, phase: phase,
                scope: .unconfirmed, salesStartAt: salesDates.first, salesEndAt: salesDates.dropFirst().first,
                pickupWindow: channel == .venue ? goodsSalesWindowText(salesText.map { $0.components(separatedBy: "\n") } ?? lines) : nil,
                shippingNote: shipping.isEmpty ? nil : shipping, location: location.map(clean),
                requiresTicket: goodsRequiresTicket(text), purchaseLimit: purchaseLimit,
                paymentMethods: goodsPaymentMethods(text), url: link?.absoluteString,
                mediaAssetIDs: assets.map(\.id), status: .confirmed,
                links: sectionLinks
            ))
        }
        if sharedLimit != nil || !sharedVenueLinks.isEmpty {
            let venueIndices = campaigns.indices.filter { campaigns[$0].channel == .venue }
            for index in venueIndices {
                let campaign = campaigns[index]
                var links = campaign.links
                let known = Set(links.map { canonicalURL($0.url) })
                links += sharedVenueLinks.filter { !known.contains(canonicalURL($0.url)) }
                campaigns[index] = GoodsCampaign(
                    id: campaign.id, eventID: campaign.eventID, officialName: campaign.officialName, channel: campaign.channel,
                    fulfillment: campaign.fulfillment, phase: campaign.phase, scope: campaign.scope,
                    salesStartAt: campaign.salesStartAt, salesEndAt: campaign.salesEndAt, pickupWindow: campaign.pickupWindow,
                    shippingNote: campaign.shippingNote, location: campaign.location, requiresTicket: campaign.requiresTicket,
                    purchaseLimit: campaign.purchaseLimit ?? sharedLimit, paymentMethods: campaign.paymentMethods, url: campaign.url,
                    mediaAssetIDs: campaign.mediaAssetIDs, status: campaign.status, links: links
                )
            }
        }
        // The same round can appear twice (a page heading whose section runs
        // into the site navigation, and the dated "■…受付" block inside グッズ情報);
        // keep the record that carries the sales window and the store link.
        var byName: [String: GoodsCampaign] = [:]
        var order: [String] = []
        func score(_ campaign: GoodsCampaign) -> Int {
            (campaign.salesStartAt != nil ? 4 : 0) + (campaign.url != nil ? 2 : 0) + (campaign.mediaAssetIDs.isEmpty ? 0 : 1)
        }
        for campaign in campaigns {
            let key = goodsMergeKey(
                name: campaign.officialName, phase: campaign.phase, channel: campaign.channel,
                location: campaign.location, body: bodies[campaign.id] ?? ""
            )
            if let existing = byName[key] {
                if score(campaign) > score(existing) { byName[key] = campaign }
            } else {
                byName[key] = campaign
                order.append(key)
            }
        }
        let uniqueMedia = Dictionary(media.map { (canonicalURL($0.originalURL), $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
        return ParsedGoods(campaigns: uniqueByID(order.compactMap { byName[$0] }), mediaAssets: uniqueMedia, bodies: bodies)
    }

    static func isGoodsHeading(_ heading: String) -> Bool {
        guard !isGoodsLimitHeading(heading), !isGoodsVenueGuideHeading(heading),
              heading.range(of: "ご注意|注意事項|お問い?合わ?せ", options: .regularExpression) == nil else { return false }
        return heading.contains("グッズ通販") || heading.contains("グッズ販売") || heading.contains("販売グッズ") || heading.contains("事前通販") || heading == "グッズ情報" || (heading.hasPrefix("グッズ") && heading.contains("販売"))
    }

    /// Global navigation anchors (LIVE&EVENT LIST / OFFICIAL X / TOP) that a
    /// trailing page section picks up; never a goods link.
    static func isSiteNavigationLink(_ link: OfficialLink) -> Bool {
        link.label.range(of: #"^(?:OFFICIAL\s+(?:X|TWITTER|YOUTUBE|NOTE|INSTAGRAM|TIKTOK|SITE|WEBSITE|HP)\b|LIVE&EVENT|TOP$|HOME$|ホーム$|サイトマップ|プライバシー|お問い?合わ?せ$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isGoodsLimitHeading(_ heading: String) -> Bool {
        heading.contains("グッズ") && (heading.contains("個数制限") || heading.contains("購入制限"))
    }

    static func isGoodsVenueGuideHeading(_ heading: String) -> Bool {
        heading.contains("グッズ") && heading.contains("クイックオーダー")
    }

    /// "■事前通販受付" / "■事後通販受付" / "第2回事前通販受付" marker lines inside a
    /// goods section, each with the lines that follow it up to the next marker.
    static func goodsSubCampaigns(in lines: [String]) -> [(name: String, lines: [String])] {
        let markerPattern = #"^[■●◆□]?\s*((?:第\d+回)?(?:事前|事後|先行|会場)(?:グッズ)?(?:通販|物販)(?:受付)?)\s*[：:]?$"#
        var result: [(name: String, lines: [String])] = []
        for line in lines {
            if let match = regex(markerPattern, line).first, let name = group(match, 1, in: line) {
                result.append((name: name, lines: []))
            } else if !result.isEmpty {
                result[result.count - 1].lines.append(line)
            }
        }
        return result.filter { !$0.lines.isEmpty }
    }

    /// "■販売場所：Zepp Shinjuku" / "販売場所\nZepp Shinjuku": the value of a line
    /// that starts with one of `labels` (inline after the colon, or on the next line).
    static func labeledLineValue(_ lines: [String], labels: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            let stripped = line.replacingOccurrences(of: #"^[■▼●◆【\s]+"#, with: "", options: .regularExpression)
            guard let label = labels.first(where: { stripped.hasPrefix($0) }) else { continue }
            let rest = stripped.dropFirst(label.count).replacingOccurrences(of: #"^[】：:\s　]+"#, with: "", options: .regularExpression)
            if !rest.isEmpty { return String(rest) }
            if index + 1 < lines.count, !lines[index + 1].hasPrefix("※") { return lines[index + 1] }
        }
        return nil
    }

    /// The first line that reads as a date range or a dated time slot.
    static func firstDateRangeLine(_ lines: [String]) -> String? {
        lines.first { line in
            !line.hasPrefix("※") && line.range(of: #"\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil
                && line.range(of: #"[～〜~\-]|\d{1,2}:\d{2}"#, options: .regularExpression) != nil
        }
    }

    /// Only the dated / timed lines of a venue sales notice ("9月25日(金)",
    /// "先行物販：15:00-18:00"), without the ※ caveats around them.
    static func goodsSalesWindowText(_ lines: [String]) -> String? {
        let kept = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.hasPrefix("※") && line.range(of: #"\d{1,2}:\d{2}|\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil
        }.map { $0.replacingOccurrences(of: #"\s*※.*$"#, with: "", options: .regularExpression) }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    static func goodsRequiresTicket(_ text: String) -> Bool? {
        if text.range(of: "チケットをお持ちでない(?:お客様|方)も", options: .regularExpression) != nil { return false }
        if text.range(of: "チケットをお持ちの(?:お客様|方)のみ|チケットをお持ちの(?:お客様|方)に限り", options: .regularExpression) != nil { return true }
        return nil
    }

    /// The lines that state a limit (individual counts, BOX caps, item
    /// exceptions), without the "may change on the day" boilerplate.
    static func goodsPurchaseLimitText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var kept: [String] = []
        for line in lines {
            if line.range(of: "急遽|変更する場合|変更となる場合|ご理解|ご協力|参照ください|ご確認ください|予めご了承|あらかじめご了承", options: .regularExpression) != nil { continue }
            let isLimit = line.range(of: #"[個点枚回]まで|BOX|制限はございません|ご購入とさせて|注文点数|購入制限|個数制限|上限|1回のみ"#, options: .regularExpression) != nil
            let isItem = line.hasPrefix("・") && !kept.isEmpty
            guard isLimit || isItem else { continue }
            var value = line
            if value.hasPrefix("※") { value.removeFirst() }
            kept.append(value.trimmingCharacters(in: .whitespaces))
        }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    /// "現金、クレジットカード（VISA/…）、QRコード決済（PayPay/…）※一括払いのみ"
    /// from a payment paragraph, or nil when the section says nothing about payment.
    static func goodsPaymentMethods(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let relevant = lines.filter { $0.contains("現金") || $0.contains("クレジット") || $0.contains("QR") || $0.contains("PayPay") || $0.contains("電子マネー") || $0.contains("決済") }
        guard !relevant.isEmpty else { return nil }
        var methods: [String] = []
        func detail(after keyword: String, in line: String) -> String? {
            guard let range = line.range(of: keyword) else { return nil }
            let tail = String(line[range.upperBound...])
            guard let match = regex(#"[【（(\[]([^】）)\]]+)[】）)\]]"#, tail).first, let inner = group(match, 1, in: tail) else { return nil }
            return clean(inner)
        }
        let joined = relevant.joined(separator: "\n")
        if joined.contains("現金") && joined.range(of: "現金(?:は|のお取り扱い|でのお支払い|での支払い)?は?(?:ご利用いただけません|ご利用できません|不可|使用できません|お取り扱いしておりません)", options: .regularExpression) == nil { methods.append("現金") }
        for (keyword, label) in [("クレジットカード", "クレジットカード"), ("QRコード決済", "QRコード決済"), ("QR決済", "QRコード決済"), ("電子マネー", "電子マネー"), ("交通系", "交通系IC")] {
            guard let line = relevant.first(where: { $0.contains(keyword) }) else { continue }
            if methods.contains(where: { $0.hasPrefix(label) }) { continue }
            if let detail = detail(after: keyword, in: line) { methods.append("\(label)（\(detail)）") } else { methods.append(label) }
        }
        guard !methods.isEmpty else { return relevant.joined(separator: "\n") }
        var summary = methods.joined(separator: "、")
        if joined.contains("一括払い") { summary += "　※クレジットカードは一括払いのみ" }
        return summary
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

    /// Social "share this page" intents printed next to official content.
    /// They point back at the page itself and are never an official link.
    static func isShareLink(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if (host.hasSuffix("twitter.com") || host == "x.com" || host.hasSuffix(".x.com")) && (path.contains("/intent/") || path.hasPrefix("/share")) { return true }
        if host == "line.me" || host.hasSuffix(".line.me") { return path.contains("/msg/") || path.contains("/share") || host.hasPrefix("social-plugins") }
        if host.hasSuffix("facebook.com") && (path.contains("/sharer") || path.contains("/share")) { return true }
        if host.hasSuffix("hatena.ne.jp") && path.contains("/entry") { return true }
        return false
    }

    static func isDirectImageURL(_ url: URL) -> Bool {
        let value = url.absoluteString.lowercased().removingPercentEncoding ?? url.absoluteString.lowercased()
        if value.range(of: #"\.(?:jpe?g|png|webp|gif|avif)(?:[?#&]|$)"#, options: .regularExpression) != nil {
            return true
        }
        let path = url.path.lowercased()
        guard path.hasSuffix("/image.php") || path.hasSuffix("image.php") else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "img_path" && !($0.value ?? "").isEmpty } == true
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

    /// Parsed campaigns already reuse the cached ID of the record they refresh
    /// (same store link or same heading), so the merge is keyed by ID. Several
    /// records legitimately share one link (catalog + dated receptions, or
    /// venue sales + online store pointing at the same goods account).
    static func mergeGoods(_ cached: [GoodsCampaign], _ parsed: [GoodsCampaign]) -> [GoodsCampaign] {
        Dictionary((cached + parsed).map { ($0.id, $0) }, uniquingKeysWith: { _, fresh in fresh })
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
        return nil
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func notedPerformers(_ note: String, groups: [String], date: String, singleDate: Bool) -> [String] {
        let parts = date.split(separator: "-").map(String.init)
        let contexts = datedContexts(note, year: parts[0], month: parts[1])
        let applicable = contexts.filter { $0.dates.contains(date) }.map(\.context).joined(separator: "\n")
        let mentionedGroups = groups.filter { note.contains($0) }
        let text = (contexts.isEmpty && singleDate) || (mentionedGroups.count == 1 && contexts.contains { $0.dates.contains(date) }) ? note : applicable
        return groups.filter { text.contains($0) }
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

    /// A goods image is media. A `名称：金額円` line becomes a product with that
    /// amount. Lines without an amount are not given a guessed price. A campaign
    /// that states a window or a purchase rule and no priced line still yields
    /// one product with a nil amount so the UI can say the price is unchecked.
    static func structuredGoods(from campaigns: [GoodsCampaign], bodies: [String: String], eventID: String) -> (products: [Product], sessions: [GoodsSession]) {
        var products: [Product] = []
        var sessions: [GoodsSession] = []
        for campaign in campaigns {
            let body = bodies[campaign.id] ?? ""
            let priced = pricedLines(in: body)
            if !priced.isEmpty {
                for (index, line) in priced.enumerated() {
                    products.append(Product(
                        id: stableID(prefix: "\(eventID)-product", seed: "\(campaign.id)|\(index)|\(line.name)|\(line.amount)"),
                        eventID: eventID,
                        campaignID: campaign.id,
                        name: line.name,
                        amount: MoneyAmount(minorUnits: line.amount, currency: "JPY"),
                        url: campaign.url,
                        variants: [],
                        purchaseLimit: campaign.purchaseLimit
                    ))
                }
            } else {
                let hasWindow = campaign.salesStartAt != nil || campaign.salesEndAt != nil || campaign.pickupWindow?.isEmpty == false
                let hasRule = campaign.purchaseLimit != nil || campaign.paymentMethods != nil
                if hasWindow || hasRule, hasRule || campaign.salesStartAt != nil {
                    products.append(Product(
                        id: stableID(prefix: "\(eventID)-product", seed: campaign.id),
                        eventID: eventID,
                        campaignID: campaign.id,
                        name: campaign.officialName,
                        amount: nil,
                        url: campaign.url,
                        variants: [],
                        purchaseLimit: campaign.purchaseLimit
                    ))
                }
            }
            let hasWindow = campaign.salesStartAt != nil || campaign.salesEndAt != nil || campaign.pickupWindow?.isEmpty == false
            if hasWindow {
                sessions.append(GoodsSession(
                    id: stableID(prefix: "\(eventID)-goods-session", seed: campaign.id),
                    eventID: eventID,
                    campaignID: campaign.id,
                    scope: campaign.scope,
                    startsAt: campaign.salesStartAt,
                    endsAt: campaign.salesEndAt,
                    location: campaign.location ?? ""
                ))
            }
        }
        return (products, sessions)
    }

    /// `T シャツ：3,500円` lines. The same name with two amounts stays two products.
    static func pricedLines(in body: String) -> [(name: String, amount: Int64)] {
        var lines: [(name: String, amount: Int64)] = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = regex(#"^[・●■\s　]*([^：:\n]{1,80}?)[：:]\s*([\d,]+)円"#, line).first,
                  let name = group(match, 1, in: line).map(clean), !name.isEmpty,
                  let digits = group(match, 2, in: line)?.replacingOccurrences(of: ",", with: ""),
                  let amount = Int64(digits) else { continue }
            lines.append((name, amount))
        }
        return lines
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
        let hasScopedBlock = blocks.contains { block in
            if case .all = block.scope { return false }
            return true
        }
        // A day/date/stop structure that does not match this performance is
        // empty. Falling back to every block copies other days onto this one.
        let chosen = selected.isEmpty && hasScopedBlock ? [] : (selected.isEmpty ? blocks : selected)
        var seen: Set<String> = []
        return chosen.flatMap(\.names).filter { seen.insert($0).inserted }
    }

    /// Performer names for one performance. Once the page has split cast by
    /// day, an unmatched day stays empty instead of inheriting another day or
    /// the previously cached roster.
    static func resolvedPerformerNames(
        explicit: [String]?,
        loveLiveCast: [String],
        castBlocks: [LoveLiveCastBlock],
        performersRaw: String?,
        performers: [String],
        associatedPerformers: [String],
        dayLabel: String
    ) -> [String] {
        if let explicit { return explicit }
        let castIsScoped = castBlocks.contains { block in
            if case .all = block.scope { return false }
            return true
        }
        if castIsScoped { return loveLiveCast }
        if !loveLiveCast.isEmpty { return loveLiveCast }
        let raw = performersRaw ?? ""
        let rawHasDayLabels = !regex(#"DAY\s*\d+"#, raw).isEmpty
        if performers.isEmpty {
            return rawHasDayLabels ? [] : associatedPerformers
        }
        let forDay = performersForDay(raw, dayLabel: dayLabel)
        if rawHasDayLabels && forDay.isEmpty { return [] }
        return forDay
    }

    /// Binds a record only to a range the heading states. An unconfirmed
    /// record keeps `fallback` (the single performance, or still unconfirmed).
    /// A scope the parser already resolved is left alone.
    static func resolvedScope(_ scope: Scope, text: String, performances: [Performance], fallback: Scope) -> Scope {
        if case .unconfirmed = scope {
            return explicitScope(text: text, performances: performances) ?? fallback
        }
        return scope
    }

    /// Every performance at one non-empty hall. Different halls stay unresolved.
    static func sharedVenueScope(_ performances: [Performance]) -> Scope? {
        guard performances.count > 1 else { return nil }
        let names = Set(performances.map { clean($0.venueName) }.filter { !$0.isEmpty })
        guard names.count == 1 else { return nil }
        return .performances(performanceIDs: performances.map(\.id))
    }

    /// `text` is the record heading, a newline, then that record's section body.
    /// A positive `DAY n` anywhere in that text selects those performances.
    /// A day mentioned only to say it is excluded does not. `各公演` does not
    /// override a day the same text already named. A date and a venue in the
    /// same text must both match. Sale, payment, distribution and archive
    /// dates are not performance dates. The same calendar day at two halls,
    /// with no hall named, stays unresolved.
    static func explicitScope(text: String, performances: [Performance]) -> Scope? {
        let normalized = text.precomposedStringWithCompatibilityMapping
        let heading = normalized.components(separatedBy: "\n").first ?? ""
        // The heading names this record. A later 通し in the same slice is
        // another product, not this record's range.
        if containsAllPerformancesCue(heading) {
            let ids = performances.map(\.id)
            return ids.isEmpty ? nil : .performances(performanceIDs: ids)
        }
        let headingDays = performanceIDs(forDays: positiveDayNumbers(in: heading), performances: performances)
        if !headingDays.isEmpty { return .performances(performanceIDs: headingDays) }
        if containsAllPerformancesCue(normalized) {
            let ids = performances.map(\.id)
            return ids.isEmpty ? nil : .performances(performanceIDs: ids)
        }
        if normalized.contains("両日"), performances.count == 2 {
            return .performances(performanceIDs: performances.map(\.id))
        }
        if let match = regex(#"DAY\s*(\d+)\s*のみ"#, normalized).first,
           let day = group(match, 1, in: normalized).flatMap(Int.init) {
            let ids = performances.filter { performanceMatchesDay($0, day: day) }.map(\.id)
            return ids.isEmpty ? nil : .performances(performanceIDs: ids)
        }
        let dayIDs = performanceIDs(forDays: positiveDayNumbers(in: normalized), performances: performances)
        if !dayIDs.isEmpty { return .performances(performanceIDs: dayIDs) }
        let dateSource = performanceDateSource(normalized)
        let dateEvidence = performanceDateEvidence(dateSource, performances: performances)
        let placeIDs = placePerformanceIDs(in: normalized, performances: performances)
        switch dateEvidence {
        case .absent:
            if containsEventWideCue(normalized) {
                let ids = performances.map(\.id)
                return ids.isEmpty ? nil : .performances(performanceIDs: ids)
            }
            guard let placeIDs, !placeIDs.isEmpty else { return nil }
            return .performances(performanceIDs: placeIDs)
        case .unmatched:
            // The only dates are sale or shipping dates. An explicit event-wide
            // statement still applies; a date that matches nothing does not.
            guard containsEventWideCue(normalized) else { return nil }
            let ids = performances.map(\.id)
            return ids.isEmpty ? nil : .performances(performanceIDs: ids)
        case .matched(let dateIDs):
            var ids = dateIDs
            if let placeIDs {
                let places = Set(placeIDs)
                ids = ids.filter { places.contains($0) }
                if ids.isEmpty { return nil }
            } else if scopeVenuesAmbiguous(ids, performances: performances) {
                return nil
            }
            return ids.isEmpty ? nil : .performances(performanceIDs: ids)
        }
    }

    /// 全公演 / 通し name every performance. 各公演 does not: the per-show
    /// ticket "各公演視聴チケット DAY1" is only DAY1.
    private static func containsAllPerformancesCue(_ text: String) -> Bool {
        text.contains("全公演") || text.contains("通し") || text.contains("全日程")
            || text.contains("全日") || text.contains("両日共通")
    }

    /// The record names the event's own shows and no single day.
    private static func containsEventWideCue(_ text: String) -> Bool {
        text.contains("各公演") || text.contains("本公演") || text.contains("この公演") || text.contains("にて販売")
    }

    /// Day numbers on lines that are not cancelling that day.
    private static func positiveDayNumbers(in text: String) -> [Int] {
        var numbers: [Int] = []
        var seen: Set<Int> = []
        for line in text.components(separatedBy: "\n") {
            if line.range(of: "ございません|ありません|いたしません|対象外|除く|除き", options: .regularExpression) != nil { continue }
            for match in regex(#"DAY\.?\s*(\d+)"#, line) {
                guard let day = group(match, 1, in: line).flatMap(Int.init), seen.insert(day).inserted else { continue }
                numbers.append(day)
            }
        }
        return numbers
    }

    private static func performanceIDs(forDays days: [Int], performances: [Performance]) -> [String] {
        var matched: Set<String> = []
        for day in days {
            for id in performances.filter({ performanceMatchesDay($0, day: day) }).map(\.id) {
                matched.insert(id)
            }
        }
        return performances.map(\.id).filter { matched.contains($0) }
    }

    /// Drops clauses whose date is a sale, application, result, payment,
    /// shipping, distribution or archive deadline.
    static func performanceDateSource(_ text: String) -> String {
        let pattern = #"(?:受付(?:期間|開始|終了|日時)?|申込(?:期間|開始|終了)?|当落(?:発表)?(?:日時)?|入金(?:期間|期限|締切)?|支払(?:期限|締切)?|発送(?:予定|期間)?|配送(?:予定|期間)?|配布(?:開始|期間|日)?|アーカイブ(?:配信)?(?:終了|期限)?|見逃し(?:配信)?(?:期間|期限)?|販売(?:開始|期間|終了)|発売(?:期間|開始|日)|通販(?:期間|開始|終了|受付)|注文(?:期間|開始|終了)?)[^。\n]*"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private enum PerformanceDateEvidence {
        case absent
        case unmatched
        case matched([String])
    }

    private static func performanceDateEvidence(_ text: String, performances: [Performance]) -> PerformanceDateEvidence {
        let matches = regex(#"(?:(\d{4})年\s*)?(\d{1,2})月\s*(\d{1,2})日"#, text)
        if matches.isEmpty { return .absent }
        var matched: Set<String> = []
        for match in matches {
            guard let month = group(match, 2, in: text).flatMap(Int.init),
                  let day = group(match, 3, in: text).flatMap(Int.init) else { continue }
            let year = group(match, 1, in: text).flatMap(Int.init)
            for performance in performances {
                let parts = performance.localDate?.split(separator: "-").compactMap { Int($0) } ?? []
                guard parts.count == 3, parts[1] == month, parts[2] == day else { continue }
                guard year == nil || parts[0] == year else { continue }
                matched.insert(performance.id)
            }
        }
        let ids = performances.map(\.id).filter { matched.contains($0) }
        return ids.isEmpty ? .unmatched : .matched(ids)
    }

    /// Hall names written in the text, and ＜stop＞ tokens, must agree when both appear.
    private static func placePerformanceIDs(in text: String, performances: [Performance]) -> [String]? {
        let namedVenues = performances.filter { performance in
            let name = clean(performance.venueName)
            return name.count >= 2 && text.contains(name)
        }.map(\.id)
        let stopNames = regex(#"[＜<]([^＜＞<>]+)[＞>]"#, text).compactMap { group($0, 1, in: text).map(clean) }
            .filter { name in name.contains("公演") || knownPrefectures.contains { name.hasPrefix($0) } }
        var fromStops: [String] = []
        if !stopNames.isEmpty {
            var matched: Set<String> = []
            for name in stopNames {
                let eventID = performances.first?.eventID ?? ""
                let stopID = stableID(prefix: "\(eventID)-stop", seed: name)
                let city = stopCity(name)
                for performance in performances where performance.stopID == stopID || (!city.isEmpty && performance.venueCity == city) {
                    matched.insert(performance.id)
                }
            }
            fromStops = performances.map(\.id).filter { matched.contains($0) }
        }
        if namedVenues.isEmpty && stopNames.isEmpty { return nil }
        if namedVenues.isEmpty { return fromStops }
        if fromStops.isEmpty { return namedVenues }
        let stops = Set(fromStops)
        return namedVenues.filter { stops.contains($0) }
    }

    /// Same local date at more than one hall is not a license to pick a hall.
    private static func scopeVenuesAmbiguous(_ ids: [String], performances: [Performance]) -> Bool {
        let rows = performances.filter { ids.contains($0.id) }
        let names = Set(rows.map { clean($0.venueName) }.filter { !$0.isEmpty })
        if names.count > 1 { return true }
        let stops = Set(rows.compactMap(\.stopID))
        return names.isEmpty && stops.count > 1
    }

    /// A goods block nested under a dated performance heading inherits that
    /// heading only when the block itself does not restate a range.
    static func goodsScopeText(heading: String, body: String, parentHeading: String?) -> String {
        let own = heading + "\n" + body
        guard let parentHeading, !hasOwnScopeCue(own) else { return own }
        return parentHeading + "\n" + own
    }

    static func hasOwnScopeCue(_ text: String) -> Bool {
        let normalized = text.precomposedStringWithCompatibilityMapping
        if normalized.contains("全公演") || normalized.contains("通し") || normalized.contains("全日程")
            || normalized.contains("各公演") || normalized.contains("全日") || normalized.contains("両日") {
            return true
        }
        if !regex(#"DAY\s*\d+"#, normalized).isEmpty { return true }
        if !regex(#"[＜<][^＜＞<>]+[＞>]"#, normalized).isEmpty { return true }
        let dates = performanceDateSource(normalized)
        return !regex(#"\d{1,2}月\s*\d{1,2}日"#, dates).isEmpty
    }

    /// Same display name at two halls or two batches is not one campaign.
    static func goodsMergeKey(name: String, phase: GoodsPhase, channel: GoodsChannel, location: String?, body: String) -> String {
        let dates = performanceDateSource(body)
        let days = regex(#"(?:(\d{4})年\s*)?(\d{1,2})月\s*(\d{1,2})日"#, dates).compactMap { match -> String? in
            guard let month = group(match, 2, in: dates), let day = group(match, 3, in: dates) else { return nil }
            return (group(match, 1, in: dates) ?? "") + "-" + month + "-" + day
        }
        let dayLabels = regex(#"DAY\s*\d+"#, body).compactMap { group($0, 0, in: body) }
        return [
            clean(name), phase.rawValue, channel.rawValue, clean(location ?? ""),
            days.joined(separator: ","), dayLabels.joined(separator: ",")
        ].joined(separator: "\u{1}")
    }

    static func performanceMatchesDay(_ performance: Performance, day: Int) -> Bool {
        let label = performance.dayLabel.precomposedStringWithCompatibilityMapping
        guard let match = regex(#"DAY\s*(\d+)"#, label).first,
              let value = group(match, 1, in: label).flatMap(Int.init) else { return false }
        return value == day
    }

    /// Title plus status headings. Ticket, goods and footnote sections stay
    /// out, so a conditional refund clause cannot cancel the performance.
    static func statusNoticeText(title: String, html: String) -> String {
        var parts = [title]
        let sections = HTML.headingSections(html)
        for section in sections {
            let heading = section.heading
            let isStatusHeading = heading.contains("開催中止") || heading.contains("開催延期")
                || heading.contains("重要") || heading.contains("お知らせ")
            let isTerms = heading.contains("チケット") || heading.contains("グッズ") || heading.contains("注意")
            guard isStatusHeading, !isTerms else { continue }
            parts.append(heading + "\n" + HTML.text(section.html))
        }
        return parts.joined(separator: "\n")
    }

    static func announcedStatus(in notice: String) -> EventStatus? {
        let sentences = notice.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        func hedged(_ sentence: String) -> Bool {
            sentence.contains("の場合") || sentence.contains("ではない") || sentence.contains("ではありません")
                || sentence.contains("ない場合")
        }
        if sentences.contains(where: { $0.contains("開催中止") && !hedged($0) }) { return .cancelled }
        if sentences.contains(where: { ($0.contains("開催延期") || $0.contains("公演延期")) && !hedged($0) }) { return .postponed }
        return nil
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
        guard !labels.isEmpty else { return splitNames(raw) }
        guard let requested = regex(#"DAY\s*(\d+)"#, dayLabel).first.flatMap({ group($0, 1, in: dayLabel) }),
              let matchIndex = labels.firstIndex(where: { group($0, 1, in: normalized) == requested }) else { return [] }
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

    static let knownPrefectures = ["東京", "神奈川", "大阪", "愛知", "福岡", "石川", "兵庫", "埼玉", "千葉", "北海道", "宮城", "静岡", "京都", "広島", "沖縄", "新潟", "長野", "岡山", "熊本", "香川", "宮崎", "鹿児島", "群馬", "栃木", "茨城", "岐阜", "三重", "奈良", "滋賀", "山梨", "富山", "福井", "青森", "岩手", "秋田", "山形", "福島", "愛媛", "高知", "徳島", "山口", "鳥取", "島根", "佐賀", "長崎", "大分", "和歌山"]

    /// Venue-name fragments that identify the prefecture (or overseas city)
    /// when the official page prints no "都道府県・" prefix.
    static let venueCityHints: [(city: String, fragments: [String])] = [
        ("東京", ["東京", "TOKYO", "Tokyo", "渋谷", "Shibuya", "新宿", "Shinjuku", "有明", "Ariake", "ARIAKE", "武道館", "立川", "TACHIKAWA", "豊洲", "羽田", "Haneda", "代々木", "Yoyogi", "両国", "国立競技場", "お台場", "池袋", "中野", "品川", "DiverCity", "日比谷", "六本木", "秋葉原", "Zepp Shinjuku", "LOVEZ", "大手町", "代官山", "duo MUSIC EXCHANGE", "O-WEST", "O-EAST", "O-Crest", "O-nest", "WWW", "LIQUIDROOM", "恵比寿", "吉祥寺", "下北沢", "赤坂", "汐留", "神田", "上野", "新木場", "蒲田", "片柳記念ホール", "豊島", "文京"]),
        ("神奈川", ["神奈川", "横浜", "Yokohama", "YOKOHAMA", "ぴあアリーナMM", "Kアリーナ", "パシフィコ", "川崎", "Kawasaki", "相模", "藤沢", "横須賀"]),
        ("大阪", ["大阪", "Osaka", "OSAKA", "京セラドーム", "インテックス", "なんば", "Namba", "万博記念公園", "梅田", "心斎橋"]),
        ("愛知", ["愛知", "名古屋", "ナゴヤ", "Nagoya", "NAGOYA", "日本ガイシ", "ポートメッセ", "バンテリンドーム", "豊田", "Aichi"]),
        ("福岡", ["福岡", "Fukuoka", "FUKUOKA", "マリンメッセ", "PayPayドーム", "BEAT STATION", "北九州"]),
        ("兵庫", ["兵庫", "神戸", "Kobe", "KOBE", "ワールド記念ホール", "GLION", "西宮"]),
        ("埼玉", ["埼玉", "さいたま", "Saitama", "SAITAMA", "大宮", "ベルーナドーム", "所沢", "メットライフ"]),
        ("千葉", ["千葉", "幕張", "Makuhari", "MAKUHARI", "舞浜", "松戸", "船橋"]),
        ("北海道", ["北海道", "札幌", "Sapporo", "SAPPORO"]),
        ("宮城", ["宮城", "仙台", "Sendai", "SENDAI"]),
        ("静岡", ["静岡", "沼津", "Numazu", "NUMAZU", "キラメッセぬまづ", "浜松", "Hamamatsu"]),
        ("石川", ["石川", "金沢", "Kanazawa"]),
        ("京都", ["京都", "Kyoto"]), ("広島", ["広島", "Hiroshima"]), ("沖縄", ["沖縄", "那覇", "Okinawa"]),
        ("新潟", ["新潟", "Niigata"]), ("長野", ["長野", "Nagano"]), ("岡山", ["岡山", "Okayama"]),
        ("熊本", ["熊本", "Kumamoto"]), ("香川", ["香川", "高松"]), ("群馬", ["群馬", "高崎"]), ("栃木", ["栃木", "宇都宮"]),
        ("台北", ["台北", "Taipei", "TAIPEI"]), ("香港", ["香港", "Hong Kong", "AsiaWorld"]),
        ("ソウル", ["ソウル", "Seoul", "SEOUL"]), ("韓国", ["韓国", "KINTEX", "Korea"]), ("上海", ["上海", "Shanghai"]),
        ("ロサンゼルス", ["Los Angeles", "ロサンゼルス", "Anaheim", "Crypto.com Arena"]),
    ]

    /// Halls whose official address was checked. Matched by full name, before
    /// loose keyword fragments. An unknown hall stays empty.
    static let verifiedVenueCities: [(name: String, city: String)] = [
        ("Kanadevia Hall", "東京"),
    ]

    static func venueCity(_ venue: String) -> String {
        let prefix = venue.split(separator: "・", maxSplits: 1).first.map(String.init) ?? ""
        if knownPrefectures.contains(prefix) { return prefix }
        // "滋賀県草津市 …" / "国営ひたち海浜公園（茨城県ひたちなか市）"
        if let match = regex(#"(\S{2,3}?)[都道府県](?![立営])"#, venue).first, let name = group(match, 1, in: venue),
           let prefecture = knownPrefectures.first(where: { name.hasSuffix($0) }) { return prefecture }
        let verifiedCities = Set(verifiedVenueCities.filter {
            venue.range(of: $0.name, options: [.caseInsensitive]) != nil
        }.map(\.city))
        if verifiedCities.count == 1 { return verifiedCities.first! }
        if verifiedCities.count > 1 { return "" }
        var cities: Set<String> = []
        for hint in venueCityHints {
            for fragment in hint.fragments where venue.range(of: fragment, options: [.caseInsensitive]) != nil {
                cities.insert(hint.city)
            }
        }
        return cities.count == 1 ? cities.first! : ""
    }

    /// City from a Love Live tour stop header such as "東京公演" / "神奈川Day.1公演".
    static func stopCity(_ stop: String?) -> String {
        guard let stop else { return "" }
        return knownPrefectures.first { stop.hasPrefix($0) } ?? ""
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

// MARK: - Exhibition / handover pages

/// One parent activity (an h3 such as イベント概要 or お渡し会概要) and the
/// sections that belong to it. Duplicate headings stay inside their parent.
fileprivate struct ActivityDocument {
    var schedules: [OfficialEventScraper.ParsedSchedule]
    var products: [Product]
    var sessions: [PendingGoodsSession]
    var notices: [PendingActivityNotice]
    var sourceURL: String
}

fileprivate struct PendingGoodsSession {
    var venueHint: String
    var location: String
}

fileprivate struct PendingActivityNotice {
    enum Audience { case sharedCatalog, handovers }
    var title: String
    var body: String
    var audience: Audience
}

fileprivate struct BoundActivity {
    var campaigns: [GoodsCampaign]
    var products: [Product]
    var sessions: [GoodsSession]
    var notices: [Notice]
}

extension OfficialEventScraper {
    /// Returns nil unless the article has more than one `日程・会場` under
    /// separate parent activities. Ordinary live pages keep the existing parser.
    fileprivate static func parseActivityDocument(_ html: String, eventID: String, sourceURL: String) -> ActivityDocument? {
        let regions = activityRegions(in: html)
        let scheduleCount = regions.reduce(0) { count, region in
            count + HTML.headingSections(region.body).filter { $0.heading == "日程・会場" || $0.heading == "日時・会場" }.count
        }
        guard scheduleCount >= 2 else { return nil }

        var schedules: [ParsedSchedule] = []
        var products: [Product] = []
        var sessions: [PendingGoodsSession] = []
        var notices: [PendingActivityNotice] = []
        for region in regions {
            let kind = activityKind(for: region.title)
            let sections = HTML.headingSections(region.body)
            for section in sections where section.heading == "日程・会場" || section.heading == "日時・会場" {
                schedules.append(contentsOf: schedulesFromVenueLines(HTML.text(section.html), kind: kind))
            }
            if kind == .handover {
                attachHandoverClocks(&schedules, text: HTML.text(region.body))
                sessions.append(contentsOf: distributionSessions(in: HTML.text(region.body)))
            }
            for section in sections where section.heading.contains("販売グッズ") {
                products.append(contentsOf: pricedProducts(in: HTML.text(section.html), eventID: eventID))
            }
            for section in sections where section.heading.contains("購入特典") {
                let body = clean(HTML.text(section.html))
                if !body.isEmpty {
                    notices.append(PendingActivityNotice(title: "先着購入特典", body: body, audience: .sharedCatalog))
                }
            }
            for section in sections where section.heading.contains("参加方法") {
                let lines = HTML.text(section.html).components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
                let eligibility = lines.filter { $0.contains("参加券") && ($0.contains("以上") || $0.contains("ご購入")) }
                if !eligibility.isEmpty {
                    notices.append(PendingActivityNotice(title: "参加资格", body: eligibility.joined(separator: "\n"), audience: .handovers))
                }
            }
        }
        var seen: Set<String> = []
        schedules = schedules.filter { item in
            seen.insert("\(item.activityKind?.rawValue ?? "")|\(item.localDate)|\(item.localEndDate ?? "")|\(item.venue ?? "")|\(item.subtitle ?? "")").inserted
        }
        guard !schedules.isEmpty else { return nil }
        return ActivityDocument(schedules: schedules, products: products, sessions: sessions, notices: notices, sourceURL: sourceURL)
    }

    fileprivate static func bindActivity(_ document: ActivityDocument, performances: [Performance], campaigns: [GoodsCampaign]) -> BoundActivity {
        let eventID = performances.first?.eventID ?? campaigns.first?.eventID ?? document.products.first?.eventID ?? "event"
        let allIDs = performances.map(\.id)
        let sharedScope: Scope = allIDs.isEmpty ? .unconfirmed : .performances(performanceIDs: allIDs)
        let handoverIDs = performances.filter { $0.activityKind == .handover }.map(\.id)
        var campaigns = campaigns
        let catalogID: String
        if let index = campaigns.firstIndex(where: { $0.officialName.contains("販売グッズ") || $0.officialName.contains("グッズ販売") }) {
            catalogID = campaigns[index].id
            campaigns[index] = catalogCampaign(campaigns[index], scope: sharedScope)
        } else if !document.products.isEmpty {
            catalogID = stableID(prefix: "\(eventID)-goods", seed: "販売グッズ")
            campaigns.append(GoodsCampaign(
                id: catalogID, eventID: eventID, officialName: "販売グッズ", channel: .unknown, fulfillment: .unknown,
                phase: .unknown, scope: sharedScope, salesStartAt: nil, salesEndAt: nil, pickupWindow: nil,
                shippingNote: nil, location: nil, requiresTicket: nil, purchaseLimit: nil, paymentMethods: nil,
                url: nil, mediaAssetIDs: [], status: .confirmed, links: []
            ))
        } else {
            catalogID = ""
        }
        let products = document.products.map { product in
            Product(id: product.id, eventID: product.eventID, campaignID: catalogID.isEmpty ? product.campaignID : catalogID,
                    name: product.name, amount: product.amount, url: nil, variants: product.variants, purchaseLimit: nil)
        }
        let sessions = document.sessions.map { session in
            let matches = performances.filter { performance in
                performance.activityKind == .handover && venuesReferToSamePlace(performance.venueName, session.venueHint)
            }
            let scope: Scope = matches.count == 1 ? .performances(performanceIDs: [matches[0].id]) : .unconfirmed
            return GoodsSession(
                id: stableID(prefix: "\(eventID)-goods-session", seed: "\(session.venueHint)|\(session.location)"),
                eventID: eventID, campaignID: catalogID, scope: scope, startsAt: nil, endsAt: nil, location: session.location
            )
        }
        let notices = document.notices.map { pending in
            let ids: [String]
            switch pending.audience {
            case .sharedCatalog: ids = allIDs
            case .handovers: ids = handoverIDs
            }
            let scope: Scope = ids.isEmpty ? .unconfirmed : .performances(performanceIDs: ids)
            return Notice(
                id: stableID(prefix: "\(eventID)-notice", seed: pending.title),
                eventID: eventID, kind: .other, title: pending.title, body: pending.body,
                publishedAt: nil, sourceURL: document.sourceURL, scope: scope
            )
        }
        return BoundActivity(campaigns: campaigns, products: products, sessions: sessions, notices: notices)
    }

    fileprivate static func activityRegions(in html: String) -> [(title: String, body: String)] {
        let html = OfficialPageBlocks.normalizedBody(html) ?? html
        let matches = regex(#"<h3\b[^>]*>(.*?)</h3>"#, html, options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard matches.count >= 2 else { return [] }
        let ns = html as NSString
        return matches.enumerated().compactMap { index, match in
            guard let titleRaw = group(match, 1, in: html) else { return nil }
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            return (HTML.text(titleRaw), ns.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
    }

    fileprivate static func activityKind(for title: String) -> PerformanceActivity {
        if title.contains("お渡し会") { return .handover }
        if title.contains("展") { return .exhibition }
        return .performance
    }

    fileprivate static func schedulesFromVenueLines(_ text: String, kind: PerformanceActivity) -> [ParsedSchedule] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var results: [ParsedSchedule] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let span = leadingDateSpan(in: line), !span.remainder.contains("開店") {
                var venue = span.remainder
                if !isVenueLine(venue), index + 1 < lines.count, isVenueLine(lines[index + 1]) {
                    index += 1
                    venue = lines[index]
                }
                let cleanedVenue = isVenueLine(venue) ? clean(venue) : ""
                if !cleanedVenue.isEmpty {
                    let label = kind == .handover ? "お渡し会" : (kind == .exhibition ? "会期" : nil)
                    results.append(ParsedSchedule(
                        localDate: span.start, dayLabel: label, subtitle: nil, doorsAt: nil, startsAt: nil,
                        raw: clean(line), venue: cleanedVenue, performers: nil,
                        localEndDate: span.end == span.start ? nil : span.end, activityKind: kind
                    ))
                }
            }
            index += 1
        }
        return results
    }

    fileprivate static func attachHandoverClocks(_ schedules: inout [ParsedSchedule], text: String) {
        let lines = text.components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
        var headerDate: String?
        var headerVenue: String?
        for line in lines {
            if let span = leadingDateSpan(in: line), !span.remainder.contains("開店"),
               isVenueLine(span.remainder) || line.contains("【") {
                headerDate = span.start
                if isVenueLine(span.remainder) { headerVenue = clean(span.remainder.replacingOccurrences(of: "】", with: "")) }
            }
            guard let headerDate, let headerVenue,
                  let match = regex(#"開場\s*(\d{1,2}):(\d{2})\s*[／/]\s*開演\s*(\d{1,2}):(\d{2})"#, line).first,
                  let doors = timeDate(headerDate, hour: group(match, 1, in: line), minute: group(match, 2, in: line)),
                  let start = timeDate(headerDate, hour: group(match, 3, in: line), minute: group(match, 4, in: line)),
                  let index = schedules.firstIndex(where: { item in
                      item.activityKind == .handover && item.localDate == headerDate
                          && venuesReferToSamePlace(item.venue ?? "", headerVenue)
                  })
            else { continue }
            schedules[index].doorsAt = doors
            schedules[index].startsAt = start
            schedules[index].raw = schedules[index].raw + " 開場／開演"
        }
    }

    fileprivate static func distributionSessions(in text: String) -> [PendingGoodsSession] {
        let lines = text.components(separatedBy: "\n").map(clean).filter { !$0.isEmpty }
        var sessions: [PendingGoodsSession] = []
        for (index, line) in lines.enumerated() where line.contains("配布期間") {
            let following = lines.dropFirst(index + 1).prefix { !$0.contains("配布期間") && !$0.hasPrefix("【") }
            guard let window = following.first(where: { $0.contains("日") && ($0.contains("～") || $0.contains("〜") || $0.contains("~")) }),
                  let storeLine = following.first(where: { $0.contains("対象店舗") }) else { continue }
            let store = clean(storeLine.replacingOccurrences(of: #"^.*対象店舗\s*[：:]+\s*"#, with: "", options: .regularExpression))
            guard !store.isEmpty else { continue }
            sessions.append(PendingGoodsSession(venueHint: store, location: "\(store)（\(window)）"))
        }
        return sessions
    }

    fileprivate static func pricedProducts(in text: String, eventID: String) -> [Product] {
        let rows = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var products: [Product] = []
        var index = 0
        while index < rows.count {
            let raw = rows[index]
            guard raw.hasPrefix("・") || raw.hasPrefix("●") else { index += 1; continue }
            let name = clean(raw.replacingOccurrences(of: #"^[・●\s　]+"#, with: "", options: .regularExpression))
            index += 1
            var details: [String] = []
            while index < rows.count {
                let next = rows[index]
                if next.hasPrefix("・") || next.hasPrefix("●") || next.hasPrefix("※") { break }
                details.append(next)
                index += 1
            }
            guard !name.isEmpty, !name.contains("参加券"), !name.contains("以上") else { continue }
            let blob = details.joined(separator: " ")
            let variantMatches = regex(#"【([^】]{1,24})】\s*([\d,]+)\s*円"#, blob)
            var variants: [ProductVariant] = []
            for match in variantMatches {
                guard let label = group(match, 1, in: blob)?.trimmingCharacters(in: .whitespaces),
                      let digits = group(match, 2, in: blob)?.replacingOccurrences(of: ",", with: ""),
                      let amount = Int64(digits) else { continue }
                variants.append(ProductVariant(
                    id: stableID(prefix: "\(eventID)-variant", seed: "\(name)|\(label)"),
                    name: label, amount: MoneyAmount(minorUnits: amount, currency: "JPY"), stockStatus: nil
                ))
            }
            let single = variants.isEmpty
                ? regex(#"([\d,]+)\s*円"#, blob).first.flatMap { group($0, 1, in: blob)?.replacingOccurrences(of: ",", with: "") }.flatMap(Int64.init)
                : nil
            guard !variants.isEmpty || single != nil else { continue }
            products.append(Product(
                id: stableID(prefix: "\(eventID)-product", seed: name),
                eventID: eventID, campaignID: "\(eventID)-goods-catalog", name: name,
                amount: single.map { MoneyAmount(minorUnits: $0, currency: "JPY") },
                url: nil, variants: variants, purchaseLimit: nil
            ))
        }
        return products
    }

    fileprivate static func leadingDateSpan(in line: String) -> (start: String, end: String, remainder: String)? {
        let source = clean(line).precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"^[・●■\s　]+"#, with: "", options: .regularExpression)
        let rangePattern = #"(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日(?:\([^)]*\))?\s*[～〜~]\s*(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日(?:\([^)]*\))?"#
        if let match = regex(rangePattern, source).first,
           let start = isoFromGroups(match, year: 1, month: 2, day: 3, in: source, inheritYear: nil, inheritMonth: nil),
           let end = isoFromGroups(match, year: 4, month: 5, day: 6, in: source, inheritYear: start.year, inheritMonth: start.month) {
            guard let span = Range(match.range, in: source) else { return nil }
            return (start.iso, end.iso, clean(String(source[span.upperBound...])))
        }
        let singlePattern = #"(?:(\d{4})年\s*)?(?:(\d{1,2})月\s*)?(\d{1,2})日(?:\([^)]*\))?"#
        guard let match = regex(singlePattern, source).first,
              let start = isoFromGroups(match, year: 1, month: 2, day: 3, in: source, inheritYear: nil, inheritMonth: nil),
              let span = Range(match.range, in: source) else { return nil }
        return (start.iso, start.iso, clean(String(source[span.upperBound...])))
    }

    private static func isoFromGroups(
        _ match: NSTextCheckingResult, year: Int, month: Int, day: Int, in source: String,
        inheritYear: Int?, inheritMonth: Int?
    ) -> (iso: String, year: Int, month: Int)? {
        let resolvedYear = group(match, year, in: source).flatMap(Int.init) ?? inheritYear
        let resolvedMonth = group(match, month, in: source).flatMap(Int.init) ?? inheritMonth
        guard let resolvedYear, let resolvedMonth, let day = group(match, day, in: source).flatMap(Int.init),
              let iso = isoDate(year: resolvedYear, month: resolvedMonth, day: day) else { return nil }
        return (iso, resolvedYear, resolvedMonth)
    }

    private static func isoDate(year: Int, month: Int, day: Int) -> String? {
        guard validDate(year: year, month: month, day: day) != nil else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    fileprivate static func isVenueLine(_ raw: String) -> Bool {
        let line = clean(raw).replacingOccurrences(of: "】", with: "")
        guard !line.isEmpty, !line.hasPrefix("※"), !line.hasPrefix("■") else { return false }
        if line.contains("開場") || line.contains("開演") || line.contains("開店") || line.contains("円") { return false }
        return ["店", "階", "STORE", "ストア", "スペース", "ホール", "会館", "PARCO", "パルコ"].contains { line.range(of: $0, options: .caseInsensitive) != nil }
            || line.range(of: #"\d\s*F\b"#, options: .regularExpression) != nil
    }

    /// A summary such as "A店・B店、C STORE" names more than one hall.
    fileprivate static func isMultiVenueSummary(_ raw: String) -> Bool {
        let text = clean(raw)
        guard text.contains("、") else { return false }
        let markers = ["本店", "STORE", "ストア", "ホール", "会館", "ドーム", "アリーナ", "劇場", "スタジオ", "PARCO", "パルコ", "イベントスペース"]
        let hits = markers.reduce(0) { count, marker in
            count + (text.range(of: marker, options: .caseInsensitive) != nil ? 1 : 0)
        }
        let shops = text.components(separatedBy: "店").count - 1
        let floors = regex(#"\d+\s*(?:階|F\b)"#, text).count
        return shops >= 2 || hits >= 2 || floors >= 2
    }

    fileprivate static func venuesReferToSamePlace(_ lhs: String, _ rhs: String) -> Bool {
        let left = squishedVenue(lhs)
        let right = squishedVenue(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if let floorL = floorToken(left), let floorR = floorToken(right), floorL != floorR { return false }
        guard left.count >= 6, right.count >= 6 else { return false }
        return left.contains(right) || right.contains(left)
    }

    private static func squishedVenue(_ raw: String) -> String {
        clean(raw).replacingOccurrences(of: #"[\s　・]+"#, with: "", options: .regularExpression)
    }

    private static func floorToken(_ squished: String) -> String? {
        guard let match = regex(#"(\d+)(?:階|F)"#, squished).first, let value = group(match, 1, in: squished) else { return nil }
        return value
    }

    private static func catalogCampaign(_ campaign: GoodsCampaign, scope: Scope) -> GoodsCampaign {
        let mentionsMailOrder = campaign.officialName.contains("通販")
        let channel: GoodsChannel = mentionsMailOrder ? campaign.channel : (campaign.channel == .online ? .unknown : campaign.channel)
        let url = campaign.url.flatMap { isProbablyImageURL($0) ? nil : $0 }
        let links = campaign.links.filter { !isProbablyImageURL($0.url) }
        return GoodsCampaign(
            id: campaign.id, eventID: campaign.eventID, officialName: campaign.officialName,
            channel: channel, fulfillment: mentionsMailOrder ? campaign.fulfillment : .unknown,
            phase: campaign.phase, scope: scope, salesStartAt: campaign.salesStartAt, salesEndAt: campaign.salesEndAt,
            pickupWindow: campaign.pickupWindow, shippingNote: mentionsMailOrder ? campaign.shippingNote : nil,
            location: campaign.location, requiresTicket: campaign.requiresTicket, purchaseLimit: campaign.purchaseLimit,
            paymentMethods: campaign.paymentMethods, url: url, mediaAssetIDs: campaign.mediaAssetIDs,
            status: campaign.status, links: links
        )
    }

    private static func isProbablyImageURL(_ raw: String) -> Bool {
        let path = URL(string: raw)?.path.lowercased() ?? raw.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif"].contains(URL(fileURLWithPath: path).pathExtension)
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

extension TicketBenefit {
    func replacingScope(_ scope: Scope) -> TicketBenefit {
        TicketBenefit(id: id, eventID: eventID, officialName: officialName, scope: scope, tierIDs: tierIDs,
            detail: detail, notes: notes, redemptionLocation: redemptionLocation, redemptionWindow: redemptionWindow,
            redemptionNote: redemptionNote, mediaAssetIDs: mediaAssetIDs, status: status, links: links)
    }
}

extension GoodsCampaign {
    func replacingScope(_ scope: Scope) -> GoodsCampaign {
        GoodsCampaign(id: id, eventID: eventID, officialName: officialName, channel: channel, fulfillment: fulfillment,
            phase: phase, scope: scope, salesStartAt: salesStartAt, salesEndAt: salesEndAt, pickupWindow: pickupWindow,
            shippingNote: shippingNote, location: location, requiresTicket: requiresTicket, purchaseLimit: purchaseLimit,
            paymentMethods: paymentMethods, url: url, mediaAssetIDs: mediaAssetIDs, status: status, links: links)
    }
}

extension MediaAsset {
    func replacingScope(_ scope: Scope) -> MediaAsset {
        MediaAsset(id: id, eventID: eventID, kind: kind, originalURL: originalURL, thumbnailURL: thumbnailURL,
            scope: scope, sourceURL: sourceURL, version: version, caption: caption, displayPolicy: displayPolicy,
            contentKind: contentKind)
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
        if let parsed = OfficialPageBlocks.outerBlocks(html, tag: tag, className: className) { return parsed }
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
        if let parsed = OfficialPageBlocks.outerBlocks(attribute: html, attribute: attribute, value: value) { return parsed }
        let pattern = #"<([a-z][a-z0-9]*)\b(?=[^>]*\b\#(attribute)\s*=\s*['\"]\#(NSRegularExpression.escapedPattern(for: value))['\"])[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let tagRange = Range(match.range(at: 1), in: html) else { return nil }
            return balanced(html, tag: String(html[tagRange]), openingRange: match.range)
        }
    }

    static func textForClass(_ html: String, _ className: String) -> String? {
        if let parsed = OfficialPageBlocks.textForClass(html, className) { return OfficialEventScraper.clean(parsed) }
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
        let html = OfficialPageBlocks.normalizedBody(html) ?? html
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

    /// Every heading with the raw HTML that follows it until the next heading
    /// of the same or higher rank. Repeated headings stay separate regions.
    static func headingRegions(_ html: String) -> [(heading: String, html: String, level: Int)] {
        let html = OfficialPageBlocks.normalizedBody(html) ?? html
        let pattern = #"<h([1-6])\b[^>]*>(.*?)</h\1>"#
        let matches = OfficialEventScraper.regex(pattern, html, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        return matches.enumerated().compactMap { index, match in
            guard let headingRaw = OfficialEventScraper.group(match, 2, in: html),
                  let level = OfficialEventScraper.group(match, 1, in: html).flatMap(Int.init) else { return nil }
            let start = NSMaxRange(match.range)
            var end = ns.length
            if index + 1 < matches.count {
                for later in matches[(index + 1)...] {
                    let laterLevel = OfficialEventScraper.group(later, 1, in: html).flatMap(Int.init) ?? 6
                    if laterLevel <= level {
                        end = later.range.location
                        break
                    }
                }
            }
            return (text(headingRaw), ns.substring(with: NSRange(location: start, length: max(0, end - start))), level)
        }
    }

    /// Every heading with the HTML that follows it up to the next heading of
    /// any level, plus the heading level (1–6) so callers can relate siblings.
    static func headingSections(_ html: String) -> [(heading: String, html: String, level: Int)] {
        let html = OfficialPageBlocks.normalizedBody(html) ?? html
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
        if let content = OfficialPageBlocks.metaContent(html, property: property) { return decode(content) }
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
        if let parsed = OfficialPageBlocks.plainText(html) {
            return OfficialEventScraper.clean(parsed)
        }
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
            let bodyText = text(bodyForLinks)
            let strippedText = bodyText.isEmpty ? links.map(\.label).joined(separator: " ") : bodyText
            guard !strippedText.isEmpty else { continue }
            let finalText = isMarker ? headingLineMarker + strippedText : strippedText
            result.append((text: finalText, struck: startDepth > 0 || lineHadOpen, links: links))
        }
        return result
    }

    /// Every `<a href=...>...</a>` in `html`, resolved to an absolute URL and
    /// deduplicated by URL and label, preserving the
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
            if OfficialEventScraper.isDirectImageURL(url) || OfficialEventScraper.isShareLink(url) { continue }
            let body = OfficialEventScraper.group(match, 1, in: html) ?? ""
            var label = text(body)
            if label.isEmpty {
                label = firstAttribute(anchorTag, tag: "a", name: "title").map(decode)
                    ?? firstAttribute(anchorTag, tag: "a", name: "aria-label").map(decode)
                    ?? url.host ?? ""
            }
            let key = "\(url.absoluteString)::\(label)"
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
