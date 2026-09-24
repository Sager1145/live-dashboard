import Foundation
import LiveIngestionCore

public enum EventernoteHTMLParser {
    public static let origin = URL(string: "https://www.eventernote.com")!

    public static func crumb(in html: String) throws -> String {
        guard let match = firstMatch(#"meta[^>]*id=["']crumb["'][^>]*content=["']([^"']+)["']|meta[^>]*content=["']([^"']+)["'][^>]*id=["']crumb["']"#, in: html) else {
            throw EventernoteClientError.parse
        }
        let value = match[1].isEmpty ? match[2] : match[1]
        guard !value.isEmpty else { throw EventernoteClientError.parse }
        return value
    }

    public static func eventList(in html: String) throws -> [EventernoteEventSummary] {
        try rejectErrorPage(html)
        let items = html.components(separatedBy: "clearfix").dropFirst()
        return items.compactMap { slice in
            guard let href = firstMatch(#"href=["'](/events/(\d+))["']"#, in: slice),
                  let name = anchorText(href[1], in: slice) else { return nil }
            let dateText = firstMatch(#"(\d{4}-\d{2}-\d{2})"#, in: slice)?[1]
            let times = clockTimes(in: slice)
            let place = entityLink(#"/places/(\d+)"#, in: slice)
            let actors = allLinks(#"/actors/(\d+)"#, in: slice)
            return EventernoteEventSummary(
                id: href[2], name: name, date: dateText, weekday: weekday(in: slice),
                openTime: times.open, startTime: times.start, endTime: times.end,
                place: place, actors: actors, imageURL: nil,
                url: absolute("/events/\(href[2])"), isPast: slice.contains("past"), noteCount: nil
            )
        }
    }

    public static func eventDetail(in html: String, pageURL: URL) throws -> EventernoteEventDetail {
        try rejectErrorPage(html)
        guard let id = pageURL.path.split(separator: "/").last.map(String.init), Int(id) != nil else {
            throw EventernoteClientError.parse
        }
        let title = heading(html, classHint: "gb_events_detail_title") ?? heading(html, classHint: nil)
        guard let title, !title.isEmpty else { throw EventernoteClientError.parse }
        let rows = tableRows(in: html)
        let dateText = rows["開催日時"] ?? ""
        let times = clockTimes(in: rows["時間"] ?? "")
        let place = entityLink(#"/places/(\d+)"#, in: rowHTML(label: "開催場所", html: html) ?? "")
        let actors = allLinks(#"/actors/(\d+)"#, in: rowHTML(label: "出演者", html: html) ?? "")
        let links = allHrefs(in: rowHTML(label: "関連リンク", html: html) ?? "")
        let summary = EventernoteEventSummary(
            id: id, name: title,
            date: firstMatch(#"(\d{4}-\d{2}-\d{2})"#, in: dateText)?[1],
            weekday: weekday(in: dateText),
            openTime: times.open, startTime: times.start, endTime: times.end,
            place: place, actors: actors,
            imageURL: firstMatch(#"property=["']og:image["'][^>]*content=["']([^"']+)["']"#, in: html)?[1],
            url: absolute("/events/\(id)"), isPast: false, noteCount: nil
        )
        return EventernoteEventDetail(event: summary, links: links.map(absolute), hashtag: plain(rows["Twitterハッシュタグ"]), description: nil, participantsCount: nil)
    }

    public static func placeDetail(in html: String, pageURL: URL) throws -> EventernotePlaceSummary {
        try rejectErrorPage(html)
        guard let id = pageURL.path.split(separator: "/").last.map(String.init), Int(id) != nil else {
            throw EventernoteClientError.parse
        }
        guard let name = heading(html, classHint: "gb_place_detail_title") else { throw EventernoteClientError.parse }
        let rows = tableRows(in: html)
        let addressRaw = rows["所在地"]
        let seat = href(in: rowHTML(label: "座席情報", html: html) ?? "")
        return EventernotePlaceSummary(
            id: id, name: name,
            address: addressRaw?.replacingOccurrences(of: #"〒\d{3}-\d{4}\s*"#, with: "", options: .regularExpression),
            postalCode: firstMatch(#"(〒\d{3}-\d{4})"#, in: addressRaw ?? "")?[1],
            telephone: rows["電話番号"],
            capacity: rows["収容人数"],
            webURL: href(in: rowHTML(label: "公式サイト", html: html) ?? ""),
            seatURL: seat.map(absolute),
            latitude: double(firstMatch(#"var\s+lat\s*=\s*'([^']+)'"#, in: html)?[1]),
            longitude: double(firstMatch(#"var\s+lon\s*=\s*'([^']+)'"#, in: html)?[1]),
            url: absolute("/places/\(id)")
        )
    }

    public static func actors(fromJSON data: Data) throws -> [EventernoteActorSummary] {
        try records(fromJSON: data).compactMap { raw in
            guard let id = raw["id"].map(stringify), let name = raw["name"] as? String else { return nil }
            return EventernoteActorSummary(id: id, name: name, kana: raw["kana"] as? String, url: absolute("/actors/\(id)"))
        }
    }

    public static func places(fromJSON data: Data) throws -> [EventernotePlaceSummary] {
        try records(fromJSON: data).compactMap { raw in
            guard let id = raw["id"].map(stringify), let name = (raw["place_name"] as? String) ?? (raw["name"] as? String) else { return nil }
            return EventernotePlaceSummary(
                id: id, name: name,
                address: raw["address"] as? String,
                postalCode: raw["postalcode"] as? String,
                telephone: raw["tel"] as? String,
                capacity: raw["capacity"].map(stringify),
                webURL: raw["web_url"] as? String,
                seatURL: raw["seat_url"] as? String,
                latitude: raw["latitude"] as? Double,
                longitude: raw["longitude"] as? Double,
                url: absolute("/places/\(id)")
            )
        }
    }

    private static func rejectErrorPage(_ html: String) throws {
        let title = heading(html, classHint: nil) ?? ""
        if title.localizedCaseInsensitiveContains("404") || html.localizedCaseInsensitiveContains("ページが見つかりません") {
            throw EventernoteClientError.parse
        }
    }

    private static func records(fromJSON data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data)
        if let rows = json as? [[String: Any]] { return rows }
        if let object = json as? [String: Any] {
            if object["ok"] as? Bool == false { throw EventernoteClientError.parse }
            if let rows = object["data"] as? [[String: Any]] { return rows }
        }
        throw EventernoteClientError.parse
    }

    private static func tableRows(in html: String) -> [String: String] {
        var rows: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"<tr[\s\S]*?<td[^>]*>([\s\S]*?)</td>[\s\S]*?<td[^>]*>([\s\S]*?)</td>"#, options: [.caseInsensitive]) else { return rows }
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: html), let valueRange = Range(match.range(at: 2), in: html) else { continue }
            let key = strip(String(html[keyRange]))
            let value = strip(String(html[valueRange]))
            if !key.isEmpty { rows[key] = value }
        }
        return rows
    }

    private static func rowHTML(label: String, html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<tr[\s\S]*?<td[^>]*>\s*\#(label)\s*</td>[\s\S]*?<td[^>]*>([\s\S]*?)</td>"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), let value = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[value])
    }

    private static func clockTimes(in text: String) -> (open: String?, start: String?, end: String?) {
        (firstMatch(#"開場\s*([0-9:]+)"#, in: text)?[1], firstMatch(#"開演\s*([0-9:]+)"#, in: text)?[1], firstMatch(#"終演\s*([0-9:]+)"#, in: text)?[1])
    }

    private static func weekday(in text: String) -> String? { firstMatch(#"\(([^)]+)\)"#, in: text)?[1] }

    private static func entityLink(_ pattern: String, in html: String) -> EventernoteEntityLink? {
        allLinks(pattern, in: html).first
    }

    private static func allLinks(_ pattern: String, in html: String) -> [EventernoteEntityLink] {
        guard let regex = try? NSRegularExpression(pattern: #"href=["'](\#(pattern))["'][^>]*>([\s\S]*?)</a>"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let href = Range(match.range(at: 1), in: html), let id = Range(match.range(at: 2), in: html), let name = Range(match.range(at: 3), in: html) else { return nil }
            let path = String(html[href])
            return EventernoteEntityLink(id: String(html[id]), name: strip(String(html[name])), url: absolute(path))
        }
    }

    private static func allHrefs(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"href=["']([^"']+)["']"#) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private static func href(in html: String) -> String? { allHrefs(in: html).first }

    private static func anchorText(_ path: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: path)
        return firstMatch(#"href=["']\#(escaped)["'][^>]*>([\s\S]*?)</a>"#, in: html).map { strip($0[1]) }
    }

    private static func heading(_ html: String, classHint: String?) -> String? {
        if let classHint, let match = firstMatch(#"\#(classHint)[\s\S]*?<h2[^>]*>([\s\S]*?)</h2>"#, in: html) {
            return strip(match[1])
        }
        return firstMatch(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: html).map { strip($0[1]) }
    }

    private static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plain(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func absolute(_ path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        return origin.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path).absoluteString
    }

    private static func double(_ value: String?) -> Double? { value.flatMap(Double.init) }

    private static func stringify(_ value: Any) -> String {
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
