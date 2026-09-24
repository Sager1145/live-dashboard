import Foundation
import LiveIngestionCore

public struct SessionCandidate: Equatable, Sendable {
    public var localDate: String?
    public var startTime: String?
    public var dayPartLabel: String?
    public var title: String?
    public var parentOfficialURL: String?
    public var performanceID: String

    public init(
        localDate: String?,
        startTime: String?,
        dayPartLabel: String?,
        title: String?,
        parentOfficialURL: String?,
        performanceID: String
    ) {
        self.localDate = localDate
        self.startTime = startTime
        self.dayPartLabel = dayPartLabel
        self.title = title
        self.parentOfficialURL = parentOfficialURL
        self.performanceID = performanceID
    }
}

public enum SessionConflictReason: Equatable, Sendable {
    case sameDayDifferentStart
    case sameDayDifferentDayPart
    case sameDayDifferentSessionLabel
}

public enum SessionIdentityDecision: Equatable, Sendable {
    case stableIdentity(String)
    case hardConflict(SessionConflictReason)
    case sameParentActivity
    case unresolvedCandidate
}

public enum SessionIdentityGuard {
    /// Title similarity never produces a same-session decision. A shared tour
    /// URL only identifies the parent activity. An already assigned performance
    /// id stays put when the date changes.
    public static func compare(_ lhs: SessionCandidate, _ rhs: SessionCandidate) -> SessionIdentityDecision {
        if lhs.performanceID == rhs.performanceID {
            return .stableIdentity(lhs.performanceID)
        }
        if lhs.localDate != nil, lhs.localDate == rhs.localDate, let conflict = sameDayConflict(lhs, rhs) {
            return .hardConflict(conflict)
        }
        if let left = canonicalParentURL(lhs.parentOfficialURL),
           left == canonicalParentURL(rhs.parentOfficialURL),
           lhs.localDate != rhs.localDate || normalizedLabel(lhs.dayPartLabel) != normalizedLabel(rhs.dayPartLabel) {
            return .sameParentActivity
        }
        return .unresolvedCandidate
    }

    static func normalizedClock(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func sameDayConflict(_ lhs: SessionCandidate, _ rhs: SessionCandidate) -> SessionConflictReason? {
        let leftClock = normalizedClock(lhs.startTime)
        let rightClock = normalizedClock(rhs.startTime)
        if let leftClock, let rightClock, leftClock != rightClock {
            return .sameDayDifferentStart
        }
        if let left = dayPart(in: lhs.dayPartLabel), let right = dayPart(in: rhs.dayPartLabel), left != right {
            return .sameDayDifferentDayPart
        }
        if let left = sessionDiscriminator(lhs.dayPartLabel), let right = sessionDiscriminator(rhs.dayPartLabel), left != right {
            return .sameDayDifferentSessionLabel
        }
        return nil
    }

    private enum DayPart: Equatable { case daytime, nighttime }

    private static func dayPart(in label: String?) -> DayPart? {
        guard let folded = folded(label) else { return nil }
        let night = folded.contains("夜") || folded.contains("ソワレ") || folded.contains("night") || folded.contains("soiree") || folded.contains("soirée")
        let day = folded.contains("昼") || folded.contains("日中") || folded.contains("マチネ") || folded.contains("matinee") || folded.contains("matinée")
        if night && !day { return .nighttime }
        if day && !night { return .daytime }
        return nil
    }

    private static func sessionDiscriminator(_ label: String?) -> String? {
        guard let folded = folded(label) else { return nil }
        if let match = folded.range(of: #"day\s*([0-9]+)"#, options: .regularExpression) {
            return "day\(folded[match].filter(\.isNumber))"
        }
        if let match = folded.range(of: #"([0-9]+)\s*部"#, options: .regularExpression) {
            return "part\(folded[match].filter(\.isNumber))"
        }
        return nil
    }

    private static func folded(_ label: String?) -> String? {
        guard let label else { return nil }
        let value = label.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedLabel(_ label: String?) -> String? {
        folded(label)
    }

    static func canonicalParentURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else { return nil }
        var path = url.path.lowercased()
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let query = url.query.map { "?\($0)" } ?? ""
        return host.lowercased() + path + query
    }
}
