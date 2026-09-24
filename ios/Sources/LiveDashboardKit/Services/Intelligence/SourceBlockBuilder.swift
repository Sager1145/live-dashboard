import Foundation

enum SourceBlockBuilder {
    private static let headingLimit = 40

    static func requests(eventID: String, snapshotID: String, sourceText: String) -> [DateClassificationRequest] {
        let groups = paragraphGroups(in: sourceText)
        var carriedHeading: [String] = []
        var ordinal = 0
        var requests: [DateClassificationRequest] = []
        for group in groups {
            var activeHeading = carriedHeading
            var found: [(lineID: String, raw: String)] = []
            for (index, line) in group.enumerated() {
                if isHeading(line) {
                    activeHeading = [line]
                }
                let lineID = "L\(index + 1)"
                for raw in dateLiterals(in: line) {
                    found.append((lineID, raw))
                }
            }
            carriedHeading = activeHeading
            guard !found.isEmpty else { continue }
            let lines = group.enumerated().map { EvidenceLine(id: "L\($0.offset + 1)", text: $0.element) }
            for chunk in chunks(found, size: 8) {
                ordinal += 1
                let mentions = chunk.enumerated().map { offset, item in
                    DateMention(id: "d\(offset + 1)", rawText: item.raw, lineIDs: [item.lineID])
                }
                requests.append(DateClassificationRequest(
                    snapshotID: snapshotID,
                    eventID: eventID,
                    blockID: "\(snapshotID)-\(ordinal)",
                    headingPath: activeHeading,
                    lines: lines,
                    mentions: mentions
                ))
            }
        }
        return requests
    }

    private static func paragraphGroups(in sourceText: String) -> [[String]] {
        let normalized = sourceText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rows = normalized.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var groups: [[String]] = []
        var current: [String] = []
        for row in rows {
            if row.isEmpty {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
            } else {
                current.append(row)
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func isHeading(_ line: String) -> Bool {
        !line.isEmpty && line.count <= headingLimit && dateLiterals(in: line).isEmpty
    }

    private static func dateLiterals(in line: String) -> [String] {
        // Local rather than stored: Regex is not Sendable under strict concurrency.
        let dated = /\d{4}年\d{1,2}月\d{1,2}日[ \t]*\d{1,2}:\d{2}|\d{4}年\d{1,2}月\d{1,2}日|\d{1,2}月\d{1,2}日[ \t]*\d{1,2}:\d{2}|\d{1,2}月\d{1,2}日/
        var found: [String] = []
        var rest = line[line.startIndex...]
        while let match = rest.firstMatch(of: dated) {
            found.append(String(match.output))
            rest = rest[match.range.upperBound...]
        }
        return found
    }

    private static func chunks<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: items.count, by: size).map { start in
            Array(items[start..<min(start + size, items.count)])
        }
    }
}
