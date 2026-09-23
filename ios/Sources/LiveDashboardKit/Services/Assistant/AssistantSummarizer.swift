import Foundation
import CryptoKit

public struct AssistantSummarizer: Sendable {
    private let client: OpenAIResponsesClient

    public init(client: OpenAIResponsesClient) {
        self.client = client
    }

    public func summarize(bundle: LiveEventBundle, model: String, transport: AssistantTransport, now: Date = Date()) async throws -> AssistantEventSummary {
        guard let sourceText = bundle.sourceText, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantError.missingSourceText
        }
        let input = Self.buildInput(bundle: bundle)
        let allowedURLs = Self.allowedURLs(bundle: bundle, sourceText: sourceText)

        let jsonText = try await client.generateStructured(
            model: model,
            instructions: Self.instructions,
            input: input,
            schemaName: "assistant_event_summary",
            schema: Self.schema(),
            transport: transport
        )

        guard let jsonData = jsonText.data(using: .utf8) else {
            throw AssistantError.invalidOutput("output is not UTF-8")
        }
        let decoded: ModelOutput
        do {
            decoded = try JSONDecoder().decode(ModelOutput.self, from: jsonData)
        } catch {
            throw AssistantError.invalidOutput("\(error)")
        }

        var warnings = decoded.warnings
        var downgradedLinkCount = 0
        let bundlePerformanceIDs = Set(bundle.performances.map(\.id))

        /// Downgrades any `.link` segment whose url is missing or not among
        /// the URLs the official page actually contains, so a hallucinated
        /// link never renders as tappable.
        func downgradeUnallowedLinks(_ richText: AssistantRichText) -> AssistantRichText {
            let segments = richText.segments.map { segment -> AssistantTextSegment in
                guard segment.style == .link else { return segment }
                let trimmedURL = segment.url?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmedURL, !trimmedURL.isEmpty, allowedURLs.contains(trimmedURL) {
                    return segment
                }
                downgradedLinkCount += 1
                return AssistantTextSegment(text: segment.text, style: .bold, url: nil)
            }
            return AssistantRichText(segments: segments)
        }

        func filterLinks(_ links: [ModelOutput.Link]) -> [AssistantLink] {
            var dropped: [String] = []
            var kept: [AssistantLink] = []
            var seenIDs = Set<String>()
            for link in links {
                guard allowedURLs.contains(link.url) else {
                    dropped.append(link.label)
                    continue
                }
                let id = "\(link.kind.rawValue)::\(link.url)::\(link.label)"
                guard !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)
                kept.append(AssistantLink(
                    label: link.label,
                    url: link.url,
                    kind: link.kind,
                    note: link.note,
                    performanceIDs: link.performanceIDs.filter { bundlePerformanceIDs.contains($0) },
                    relatedRecordID: link.relatedRecordID
                ))
            }
            if !dropped.isEmpty {
                warnings.append("已忽略模型给出的未在官网出现的链接：\(dropped.joined(separator: "、"))")
            }
            return kept
        }

        let ticketLinks = filterLinks(decoded.ticketLinks)
        let goodsLinks = filterLinks(decoded.goodsLinks)

        var performanceByID: [String: AssistantPerformanceSummary] = [:]
        for performance in decoded.performances where bundlePerformanceIDs.contains(performance.performanceID) {
            guard performanceByID[performance.performanceID] == nil else { continue }
            performanceByID[performance.performanceID] = AssistantPerformanceSummary(
                performanceID: performance.performanceID,
                dayLabel: performance.dayLabel,
                summary: downgradeUnallowedLinks(performance.summary.toRichText()),
                highlights: performance.highlights.map { downgradeUnallowedLinks($0.toRichText()) }
            )
        }
        let performances = bundle.performances
            .sorted { $0.order < $1.order }
            .map { performance -> AssistantPerformanceSummary in
                performanceByID[performance.id] ?? AssistantPerformanceSummary(
                    performanceID: performance.id,
                    dayLabel: performance.dayLabel,
                    summary: AssistantRichText("官网未单独说明本场差异"),
                    highlights: []
                )
            }

        var seenKeyPointIDs = Set<String>()
        let keyPoints = decoded.keyPoints.enumerated().map { index, keyPoint -> AssistantKeyPoint in
            var id = keyPoint.id?.isEmpty == false ? keyPoint.id! : "kp-\(index)"
            if seenKeyPointIDs.contains(id) {
                var candidate = "kp-\(index)"
                var suffix = index
                while seenKeyPointIDs.contains(candidate) {
                    suffix += 1
                    candidate = "kp-\(suffix)"
                }
                id = candidate
            }
            seenKeyPointIDs.insert(id)
            return AssistantKeyPoint(
                id: id,
                category: keyPoint.category,
                importance: keyPoint.importance,
                text: downgradeUnallowedLinks(keyPoint.text.toRichText()),
                performanceIDs: keyPoint.performanceIDs.filter { bundlePerformanceIDs.contains($0) }
            )
        }

        let overview = downgradeUnallowedLinks(decoded.overview.toRichText())

        if downgradedLinkCount > 0 {
            warnings.append("已忽略摘要正文中 \(downgradedLinkCount) 个未在官网出现的链接")
        }

        return AssistantEventSummary(
            eventID: bundle.event.id,
            generatedAt: now,
            model: model,
            sourceFingerprint: Self.fingerprint(of: bundle),
            overview: overview,
            keyPoints: keyPoints,
            performances: performances,
            ticketLinks: ticketLinks,
            goodsLinks: goodsLinks,
            warnings: warnings
        )
    }

    // MARK: - Fingerprint

    public static func fingerprint(of bundle: LiveEventBundle) -> String {
        var parts: [String] = [bundle.event.officialTitle]

        let performances = bundle.performances.sorted { $0.order < $1.order }
        for performance in performances {
            let startISO = performance.startAt.map(Self.isoFormatter.string(from:)) ?? ""
            parts.append("\(performance.id)|\(performance.dayLabel)|\(performance.localDate ?? "")|\(startISO)|\(performance.venueName)")
        }

        let rounds = bundle.ticketRounds.sorted { $0.id < $1.id }
        for round in rounds {
            let start = round.applyStartAt.map(Self.isoFormatter.string(from:)) ?? ""
            let end = round.applyEndAt.map(Self.isoFormatter.string(from:)) ?? ""
            let linkURLs = round.links.map(\.url).joined(separator: ",")
            parts.append("\(round.id)|\(round.officialName)|\(start)|\(end)|\(round.applyURL ?? "")|\(linkURLs)")
        }

        let campaigns = bundle.goodsCampaigns.sorted { $0.id < $1.id }
        for campaign in campaigns {
            let linkURLs = campaign.links.map(\.url).joined(separator: ",")
            parts.append("\(campaign.id)|\(campaign.officialName)|\(campaign.url ?? "")|\(linkURLs)")
        }

        let streams = bundle.streamOffers.sorted { $0.id < $1.id }
        for stream in streams {
            parts.append("\(stream.id)|\(stream.officialName)|\(stream.url ?? "")")
        }

        parts.append(bundle.sourceText ?? "")

        let joined = parts.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Input document

    public static func buildInput(bundle: LiveEventBundle) -> String {
        var lines: [String] = []
        let event = bundle.event

        lines.append("## 公演")
        lines.append("标题：\(event.officialTitle)")
        lines.append("系列：\(event.franchise.rawValue)")
        if !event.groups.isEmpty {
            lines.append("团体：\(event.groups.joined(separator: "、"))")
        }
        lines.append("状态：\(event.status.rawValue)")
        lines.append("官网：\(event.primarySourceURL)")

        let timeZone = event.resolvedTimeZone
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        lines.append("")
        lines.append("## 场次")
        for performance in bundle.performances.sorted(by: { $0.order < $1.order }) {
            var pieces: [String] = [performance.id, performance.dayLabel, performance.localDate ?? "未知日期"]
            var timing: [String] = []
            if let doorsAt = performance.doorsAt {
                timing.append("开场 \(timeFormatter.string(from: doorsAt))")
            }
            if let startAt = performance.startAt {
                timing.append("开演 \(timeFormatter.string(from: startAt))")
            }
            pieces.append(timing.isEmpty ? "时间未定" : timing.joined(separator: " / "))
            pieces.append("\(performance.venueName) \(performance.venueCity)")
            if !performance.performers.isEmpty {
                pieces.append(performance.performers.joined(separator: "、"))
            }
            lines.append(pieces.joined(separator: " | "))
        }

        lines.append("")
        lines.append("## 售票轮次")
        for round in bundle.ticketRounds {
            var pieces: [String] = [round.id, round.officialName, round.kind.rawValue]
            let start = round.applyStartAt.map(timeFormatter.string(from:)) ?? "未定"
            let end = round.applyEndAt.map(timeFormatter.string(from:)) ?? "未定"
            pieces.append("\(start)~\(end)")
            pieces.append(round.applyURL ?? "")
            if !round.links.isEmpty {
                let linksText = round.links.map { "\($0.label)（\($0.url)）" }.joined(separator: " ")
                pieces.append("links: \(linksText)")
            }
            lines.append(pieces.joined(separator: " | "))
        }

        lines.append("")
        lines.append("## 配信")
        for stream in bundle.streamOffers {
            var pieces: [String] = [stream.id, stream.officialName, stream.platform]
            if let url = stream.url { pieces.append(url) }
            lines.append(pieces.joined(separator: " | "))
        }

        lines.append("")
        lines.append("## 周边")
        for campaign in bundle.goodsCampaigns {
            var pieces: [String] = [campaign.id, campaign.officialName, campaign.channel.rawValue, campaign.phase.rawValue]
            pieces.append(campaign.url ?? "")
            if !campaign.links.isEmpty {
                let linksText = campaign.links.map { "\($0.label)（\($0.url)）" }.joined(separator: " ")
                pieces.append("links: \(linksText)")
            }
            lines.append(pieces.joined(separator: " | "))
        }

        lines.append("")
        lines.append("## 官网页面全文")
        lines.append(bundle.sourceText ?? "")

        return lines.joined(separator: "\n")
    }

    public static func allowedURLs(bundle: LiveEventBundle, sourceText: String) -> Set<String> {
        var urls = Set<String>()
        for round in bundle.ticketRounds {
            if let url = round.applyURL { urls.insert(url) }
            if let url = round.overseasURL { urls.insert(url) }
            for link in round.links { urls.insert(link.url) }
        }
        for campaign in bundle.goodsCampaigns {
            if let url = campaign.url { urls.insert(url) }
            for link in campaign.links { urls.insert(link.url) }
        }
        for stream in bundle.streamOffers {
            if let url = stream.url { urls.insert(url) }
        }
        for product in bundle.products {
            if let url = product.url { urls.insert(url) }
        }
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "bmp", "tif", "tiff"]
        func isImageURL(_ candidate: String) -> Bool {
            guard let pathExtension = URL(string: candidate)?.pathExtension, !pathExtension.isEmpty else { return false }
            return imageExtensions.contains(pathExtension.lowercased())
        }
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s（）()<>"']+"#) {
            let range = NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
            let trailingPunctuation = CharacterSet(charactersIn: "。、，．,.;:!?」』】］]")
            regex.enumerateMatches(in: sourceText, range: range) { match, _, _ in
                guard let match, let swiftRange = Range(match.range, in: sourceText) else { return }
                let raw = String(sourceText[swiftRange])
                if !isImageURL(raw) { urls.insert(raw) }
                let trimmed = raw.trimmingCharacters(in: trailingPunctuation)
                if trimmed != raw, !trimmed.isEmpty, !isImageURL(trimmed) {
                    urls.insert(trimmed)
                }
            }
        }
        return urls
    }

    private static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    // MARK: - Instructions

    public static let instructions: String = """
    你正在为一个粉丝仪表盘应用整理官方演出信息。你会收到一个结构化文档，包含公演基本信息、场次列表、售票轮次、配信信息、周边信息，以及官网页面的完整原文。

    请只输出符合给定 JSON Schema 的结果，不要输出任何多余文字。全部使用简体中文书写说明性文字，但保留官方使用的日文专有名词、场馆名、票种名称等原文不译。

    你必须覆盖官网原文的每一个方面，包括但不限于：日程与场次、场馆信息、出演者/阵容、票务轮次与价格、配信信息、周边商品（通販、会场限定販売等）、座位安排、注意事项，以及入场规则。

    对于多日/多场演出，performances 数组必须为给定的每一个 performanceID 各生成一条记录，且每条记录只描述该场次与其他场次不同之处（阵容、场馆、时间、当日限定的周边或票务），绝不能把多场信息混在一起。所有场次共通的信息应放入 overview 和 keyPoints（keyPoints 的 performanceIDs 留空表示适用于全部场次）。

    文本样式（style）的使用规则：
    - important：用于中止/延期/取消、7天内的截止时间、资格限制等关键信息；
    - date：日期与时间；
    - price：金额；
    - warning：需要注意但不是关键信息的提醒；
    - link：带 url 的超链接；
    - bold / normal：一般强调或普通文本。

    ticketLinks 和 goodsLinks 中的每一个链接，其 url 必须原样来自输入文档中出现过的链接，绝不能凭空编造或修改网址。请为每个链接标注其所属的售票/购买渠道名称（label），并在 note 中简要说明它出售的是什么。请根据链接的用途正确分类 kind。

    绝不允许猜测官网没有明确写出的事实。如果某项信息官网没有提及，请直接省略，或者在 warnings 中加入一条说明，而不要编造内容。
    """

    // MARK: - JSON Schema

    public static func schema() -> [String: Any] {
        let richText: [String: Any] = [
            "type": "object",
            "properties": [
                "segments": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "style": [
                                "type": "string",
                                "enum": ["normal", "bold", "important", "date", "price", "link", "warning"]
                            ],
                            "url": ["type": ["string", "null"]]
                        ],
                        "required": ["text", "style", "url"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["segments"],
            "additionalProperties": false
        ]

        let keyPoint: [String: Any] = [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
                "category": [
                    "type": "string",
                    "enum": ["schedule", "ticket", "goods", "seating", "stream", "notice", "other"]
                ],
                "importance": [
                    "type": "string",
                    "enum": ["high", "medium", "low"]
                ],
                "text": richText,
                "performanceIDs": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["id", "category", "importance", "text", "performanceIDs"],
            "additionalProperties": false
        ]

        let performance: [String: Any] = [
            "type": "object",
            "properties": [
                "performanceID": ["type": "string"],
                "dayLabel": ["type": "string"],
                "summary": richText,
                "highlights": ["type": "array", "items": richText]
            ],
            "required": ["performanceID", "dayLabel", "summary", "highlights"],
            "additionalProperties": false
        ]

        let link: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string"],
                "url": ["type": "string"],
                "kind": [
                    "type": "string",
                    "enum": ["ticketSales", "ticketResale", "goodsMailOrder", "goodsVenue", "stream", "other"]
                ],
                "note": ["type": ["string", "null"]],
                "performanceIDs": ["type": "array", "items": ["type": "string"]],
                "relatedRecordID": ["type": ["string", "null"]]
            ],
            "required": ["label", "url", "kind", "note", "performanceIDs", "relatedRecordID"],
            "additionalProperties": false
        ]

        return [
            "type": "object",
            "properties": [
                "overview": richText,
                "keyPoints": ["type": "array", "items": keyPoint],
                "performances": ["type": "array", "items": performance],
                "ticketLinks": ["type": "array", "items": link],
                "goodsLinks": ["type": "array", "items": link],
                "warnings": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["overview", "keyPoints", "performances", "ticketLinks", "goodsLinks", "warnings"],
            "additionalProperties": false
        ]
    }

    // MARK: - Decoding mirror

    private struct ModelOutput: Decodable {
        struct Segment: Decodable {
            let text: String
            let style: AssistantTextSegment.Style
            let url: String?
        }
        struct RichText: Decodable {
            let segments: [Segment]
            func toRichText() -> AssistantRichText {
                AssistantRichText(segments: segments.map { AssistantTextSegment(text: $0.text, style: $0.style, url: $0.url) })
            }
        }
        struct KeyPoint: Decodable {
            let id: String?
            let category: AssistantKeyPoint.Category
            let importance: AssistantKeyPoint.Importance
            let text: RichText
            let performanceIDs: [String]
        }
        struct Performance: Decodable {
            let performanceID: String
            let dayLabel: String
            let summary: RichText
            let highlights: [RichText]
        }
        struct Link: Decodable {
            let label: String
            let url: String
            let kind: AssistantLink.Kind
            let note: String?
            let performanceIDs: [String]
            let relatedRecordID: String?
        }

        let overview: RichText
        let keyPoints: [KeyPoint]
        let performances: [Performance]
        let ticketLinks: [Link]
        let goodsLinks: [Link]
        let warnings: [String]
    }
}
