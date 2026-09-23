import Foundation

public struct TicketPhaseBadge: Hashable, Sendable, Identifiable {
    public enum Tone: String, Hashable, Sendable { case open, upcoming, closed, soldOut }
    public let text: String      // user-facing, already localized
    public let tone: Tone
    public var id: String { text }
}

/// Event-level ticket phase badges for the dashboard card. Unlike the
/// day-scoped `currentRoundLabel`, this deliberately includes rounds whose
/// performance scope is `.unconfirmed`, because "which round is open" is not
/// day-specific. Upgrade rounds and non-confirmed records are ignored.
public enum TicketPhaseBadgeBuilder {
    public static func badges(rounds: [TicketRound], now: Date) -> [TicketPhaseBadge] {
        let candidates = rounds.filter { $0.status == .confirmed && $0.kind != .upgrade }
        guard !candidates.isEmpty else { return [] }

        let soldOut = candidates.contains { round in
            guard let officialStatus = round.officialStatus else { return false }
            return officialStatus.contains("完売") || officialStatus.lowercased().contains("sold out")
        }

        var openRounds: [TicketRound] = []
        var upcomingRounds: [TicketRound] = []
        var allResolvedClosed = true
        var sawKnownStatus = false

        for round in candidates {
            let resolution = TicketStatusResolver.resolve(round: round, now: now)
            switch resolution.displayStatus {
            case .open:
                openRounds.append(round)
                sawKnownStatus = true
                allResolvedClosed = false
            case .upcoming:
                upcomingRounds.append(round)
                sawKnownStatus = true
                allResolvedClosed = false
            case .closed:
                sawKnownStatus = true
            case .unknown:
                continue
            }
        }

        openRounds.sort { lhs, rhs in
            switch (lhs.applyEndAt, rhs.applyEndAt) {
            case let (l?, r?): if l != r { return l < r }
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): break
            }
            return lhs.officialName < rhs.officialName
        }

        upcomingRounds.sort { lhs, rhs in
            switch (lhs.applyStartAt, rhs.applyStartAt) {
            case let (l?, r?): if l != r { return l < r }
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): break
            }
            return lhs.officialName < rhs.officialName
        }

        var result: [TicketPhaseBadge] = []
        var seenTexts = Set<String>()
        for round in openRounds {
            let text = String(localized: "\(phaseName(for: round))中", bundle: .kit)
            if seenTexts.insert(text).inserted {
                result.append(TicketPhaseBadge(text: text, tone: .open))
            }
        }

        if let nextUpcoming = upcomingRounds.first {
            let text = "\(String(localized: "即将：", bundle: .kit))\(phaseName(for: nextUpcoming))"
            if seenTexts.insert(text).inserted {
                result.append(TicketPhaseBadge(text: text, tone: .upcoming))
            }
        }

        if result.isEmpty && sawKnownStatus && allResolvedClosed {
            if soldOut {
                result.append(TicketPhaseBadge(text: String(localized: "已售罄", bundle: .kit), tone: .soldOut))
            } else {
                result.append(TicketPhaseBadge(text: String(localized: "受付全部结束", bundle: .kit), tone: .closed))
            }
        } else if !result.isEmpty && soldOut {
            result.append(TicketPhaseBadge(text: String(localized: "已售罄", bundle: .kit), tone: .soldOut))
        }

        if result.count > 3 {
            result = Array(result.prefix(3))
        }
        return result
    }

    /// Normalised phase name, e.g. "第2次先行抽选", "最速先行抽选", "官方先行抽选", "一般贩售", "先着贩售", "官方转售".
    public static func phaseName(for round: TicketRound) -> String {
        let name = round.officialName.precomposedStringWithCompatibilityMapping
        let prefix = ordinalPrefix(from: name) ?? fallbackPrefix(from: name)

        switch round.kind {
        case .lottery:
            return "\(prefix)\(String(localized: "抽选", bundle: .kit))"
        case .firstComeFirstServed:
            if name.contains("一般") {
                return String(localized: "一般贩售", bundle: .kit)
            }
            return "\(prefix)\(String(localized: "先着贩售", bundle: .kit))"
        case .resale:
            return String(localized: "官方转售", bundle: .kit)
        case .upgrade:
            return String(localized: "升级受付", bundle: .kit)
        case .other:
            return prefix.isEmpty ? String(localized: "受付", bundle: .kit) : "\(prefix)\(String(localized: "受付", bundle: .kit))"
        }
    }

    private static func ordinalPrefix(from name: String) -> String? {
        if let range = name.range(of: #"(\d+)次"#, options: .regularExpression) {
            let matched = String(name[range])
            let digits = matched.dropLast() // drop trailing "次"
            if let n = Int(digits) {
                return name.contains("先行")
                    ? String(localized: "第\(n)次先行", bundle: .kit)
                    : String(localized: "第\(n)次", bundle: .kit)
            }
        }

        let kanjiDigits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
        let chars = Array(name)
        for index in chars.indices {
            if let n = kanjiDigits[chars[index]], index + 1 < chars.count, chars[index + 1] == "次" {
                return name.contains("先行")
                    ? String(localized: "第\(n)次先行", bundle: .kit)
                    : String(localized: "第\(n)次", bundle: .kit)
            }
        }
        return nil
    }

    private static func fallbackPrefix(from name: String) -> String {
        if name.contains("最速") { return String(localized: "最速先行", bundle: .kit) }
        if name.contains("最終") { return String(localized: "最终", bundle: .kit) }
        if name.contains("オフィシャル") || name.contains("公式") { return String(localized: "官方先行", bundle: .kit) }
        if name.contains("プレイガイド") { return String(localized: "票务先行", bundle: .kit) }
        if name.contains("ファンクラブ") || name.contains("FC") || name.contains("会員") { return String(localized: "会员先行", bundle: .kit) }
        if name.contains("一般先行") { return String(localized: "一般先行", bundle: .kit) }
        if name.contains("先行") { return String(localized: "先行", bundle: .kit) }
        return ""
    }
}
