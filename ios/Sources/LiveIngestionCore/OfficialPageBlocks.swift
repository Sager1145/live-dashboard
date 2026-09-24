import Foundation
import SwiftSoup

/// DOM slices shared by the rule parser and the dev-machine crawl comparison.
/// `blockID` identifies a block inside one snapshot. It is not a permanent event id.
public enum OfficialPageBlocks {
    public struct Link: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var rawURL: String
        public var resolvedURL: String?
    }

    public struct Image: Codable, Equatable, Sendable {
        public var id: String
        public var rawURL: String
        public var resolvedURL: String?
        public var alt: String
        public var source: String
    }

    public struct SourceBlock: Codable, Equatable, Sendable {
        public var snapshotID: String
        public var blockID: String
        public var parentBlockID: String?
        public var headingPath: [String]
        public var pane: String?
        public var htmlFragment: String
        public var rawLines: [String]
        public var tableRows: [[String]]
        public var links: [Link]
        public var images: [Image]
        public var locator: String
        public var scopeHints: [String]
    }

    /// Element outer HTML in document order. `nil` means the markup could not be parsed.
    static func outerBlocks(_ html: String, tag: String, className: String?) -> [String]? {
        guard let document = parse(html) else { return nil }
        let wanted = tag.lowercased()
        guard let elements = try? document.select(wanted) else { return nil }
        return elements.array().compactMap { element in
            if let className, !element.hasClass(className) { return nil }
            return try? element.outerHtml()
        }
    }

    static func outerBlocks(attribute html: String, attribute: String, value: String) -> [String]? {
        guard let document = parse(html) else { return nil }
        guard let elements = try? document.getElementsByAttributeValue(attribute, value) else { return nil }
        return elements.array().compactMap { try? $0.outerHtml() }
    }

    static func textForClass(_ html: String, _ className: String) -> String? {
        guard let document = parse(html) else { return nil }
        guard let element = (try? document.getElementsByClass(className))?.first() else { return nil }
        guard let outer = try? element.outerHtml() else { return nil }
        return plainText(outer)
    }

    static func metaContent(_ html: String, property: String) -> String? {
        guard let document = parse(html) else { return nil }
        guard let metas = try? document.select("meta") else { return nil }
        for meta in metas.array() {
            let name = (try? meta.attr("property")) ?? ""
            guard name.caseInsensitiveCompare(property) == .orderedSame else { continue }
            let content = (try? meta.attr("content")) ?? ""
            guard !content.isEmpty else { continue }
            return content
        }
        return nil
    }

    /// Body inner HTML after the DOM parser has repaired the tree. `nil` if parsing fails.
    static func normalizedBody(_ html: String) -> String? {
        guard let document = parse(html), let body = document.body() else { return nil }
        return try? body.html()
    }

    static func plainText(_ html: String) -> String? {
        guard let document = parse(html), let body = document.body() else { return nil }
        var output = ""
        for child in body.getChildNodes() {
            appendText(child, into: &output)
        }
        return output
    }

    public static func sourceBlocks(html: String, baseURL: URL, snapshotID: String) -> [SourceBlock] {
        guard let document = parse(html, baseURL.absoluteString), let body = document.body() else { return [] }
        let bodyHTML = (try? body.html()) ?? ""
        let headings = headingSpans(in: bodyHTML)
        let headingElements = (try? document.select("h1, h2, h3, h4, h5, h6").array()) ?? []
        var stack: [(level: Int, blockID: String, title: String)] = []
        var blocks: [SourceBlock] = []
        for (index, heading) in headings.enumerated() {
            while let last = stack.last, last.level >= heading.level { stack.removeLast() }
            let parentID = stack.last?.blockID
            let blockID = "b\(index)"
            let path = stack.map(\.title) + [heading.title]
            let fragmentEnd = index + 1 < headings.count ? headings[index + 1].start : bodyHTML.endIndex
            let fragment = String(bodyHTML[heading.end..<fragmentEnd])
            let pane = index < headingElements.count ? ancestorPane(of: headingElements[index]) : nil
            let links = anchorLinks(in: fragment, baseURL: baseURL, prefix: blockID)
            let images = imageCandidates(in: fragment, baseURL: baseURL, prefix: blockID)
            let lines = (plainText(fragment) ?? "").components(separatedBy: "\n").map(cleanLine).filter { !$0.isEmpty }
            blocks.append(SourceBlock(
                snapshotID: snapshotID,
                blockID: blockID,
                parentBlockID: parentID,
                headingPath: path,
                pane: pane,
                htmlFragment: fragment,
                rawLines: lines,
                tableRows: tableRows(in: fragment),
                links: links,
                images: images,
                locator: locator(pane: pane, path: path, index: index),
                scopeHints: scopeHints(pane: pane, path: path)
            ))
            stack.append((heading.level, blockID, heading.title))
        }
        return blocks
    }

    private struct HeadingSpan {
        var level: Int
        var title: String
        var start: String.Index
        var end: String.Index
    }

    private static func parse(_ html: String, _ baseURL: String = "") -> Document? {
        try? SwiftSoup.parse(html, baseURL)
    }

    private static func headingSpans(in html: String) -> [HeadingSpan] {
        guard let expression = try? NSRegularExpression(
            pattern: #"<h([1-6])\b[^>]*>(.*?)</h\1>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let whole = Range(match.range, in: html),
                  let levelRange = Range(match.range(at: 1), in: html),
                  let inner = Range(match.range(at: 2), in: html),
                  let level = Int(html[levelRange]) else { return nil }
            let title = cleanLine(stripTags(String(html[inner])))
            guard !title.isEmpty else { return nil }
            return HeadingSpan(level: level, title: title, start: whole.lowerBound, end: whole.upperBound)
        }
    }

    private static func appendText(_ node: Node, into output: inout String) {
        if let text = node as? TextNode {
            output += text.getWholeText()
            return
        }
        guard let element = node as? Element else { return }
        let tag = element.tagName().lowercased()
        if tag == "script" || tag == "style" { return }
        if tag == "br" {
            output += "\n"
            return
        }
        for child in element.getChildNodes() {
            appendText(child, into: &output)
        }
        if ["p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) {
            output += "\n"
        }
    }

    private static func anchorLinks(in html: String, baseURL: URL, prefix: String) -> [Link] {
        guard let document = parse(html, baseURL.absoluteString) else { return [] }
        guard let anchors = try? document.select("a[href]") else { return [] }
        var links: [Link] = []
        for (index, anchor) in anchors.array().enumerated() {
            let raw = ((try? anchor.attr("href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.lowercased().hasPrefix("javascript:"), !raw.hasPrefix("#") else { continue }
            let label = cleanLine((try? anchor.text()) ?? "")
            let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL
            let absolute = (resolved?.scheme == "http" || resolved?.scheme == "https") ? resolved?.absoluteString : nil
            links.append(Link(id: "\(prefix)-link-\(index)", label: label, rawURL: raw, resolvedURL: absolute))
        }
        return links
    }

    private static func imageCandidates(in html: String, baseURL: URL, prefix: String) -> [Image] {
        guard let document = parse(html, baseURL.absoluteString) else { return [] }
        guard let images = try? document.select("img") else { return [] }
        var results: [Image] = []
        var seen: Set<String> = []
        for image in images.array() {
            let alt = ((try? image.attr("alt")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var candidates: [(String, String)] = []
            for name in ["src", "data-src", "data-lazy-src"] {
                let raw = ((try? image.attr(name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { candidates.append((raw, name)) }
            }
            let srcset = (try? image.attr("srcset")) ?? ""
            for part in srcset.split(separator: ",") {
                let raw = part.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !raw.isEmpty { candidates.append((raw, "srcset")) }
            }
            for (raw, source) in candidates where seen.insert("\(source)::\(raw)").inserted {
                let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL
                let absolute = (resolved?.scheme == "http" || resolved?.scheme == "https") ? resolved?.absoluteString : nil
                results.append(Image(
                    id: "\(prefix)-image-\(results.count)",
                    rawURL: raw,
                    resolvedURL: absolute,
                    alt: alt,
                    source: source
                ))
            }
        }
        return results
    }

    private static func tableRows(in html: String) -> [[String]] {
        guard let document = parse(html) else { return [] }
        guard let rows = try? document.select("tr") else { return [] }
        return rows.array().compactMap { row in
            let cells = ((try? row.select("th, td").array()) ?? []).map { cleanLine((try? $0.text()) ?? "") }
            return cells.allSatisfy(\.isEmpty) ? nil : cells
        }
    }

    private static func ancestorPane(of heading: Element) -> String? {
        var node: Element? = heading
        while let current = node {
            let pane = (try? current.attr("data-target")) ?? ""
            if !pane.isEmpty { return pane }
            node = current.parent()
        }
        return nil
    }

    private static func locator(pane: String?, path: [String], index: Int) -> String {
        let headings = path.enumerated().map { "h\($0.offset + 1)[\($0.element)]" }.joined(separator: "/")
        if let pane, !pane.isEmpty { return "pane:\(pane)/\(headings)#\(index)" }
        return "\(headings)#\(index)"
    }

    private static func scopeHints(pane: String?, path: [String]) -> [String] {
        var hints = path
        if let pane, !pane.isEmpty { hints.append("pane:\(pane)") }
        return hints
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func cleanLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"[ \t\r]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
