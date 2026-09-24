import Foundation
import LiveIngestionCore

public enum TicketDeadlineKind: String, Sendable {
    case applicationEnd
    case paymentEnd
}

public struct TicketDeadlineAnswer: Equatable, Sendable {
    public var roundName: String
    public var kind: TicketDeadlineKind
    public var deadline: Date?
    public var timeZoneIdentifier: String
    public var sourceIsStale: Bool
    public var unknown: Bool

    public init(
        roundName: String,
        kind: TicketDeadlineKind,
        deadline: Date?,
        timeZoneIdentifier: String,
        sourceIsStale: Bool,
        unknown: Bool
    ) {
        self.roundName = roundName
        self.kind = kind
        self.deadline = deadline
        self.timeZoneIdentifier = timeZoneIdentifier
        self.sourceIsStale = sourceIsStale
        self.unknown = unknown
    }
}

public struct PerformanceAnswer: Equatable, Sendable {
    public var officialTitle: String
    public var dayLabel: String
    public var localDate: String?
    public var startAt: Date?
    public var venueName: String
    public var timeZoneIdentifier: String
    public var sourceIsStale: Bool

    public init(
        officialTitle: String,
        dayLabel: String,
        localDate: String?,
        startAt: Date?,
        venueName: String,
        timeZoneIdentifier: String,
        sourceIsStale: Bool
    ) {
        self.officialTitle = officialTitle
        self.dayLabel = dayLabel
        self.localDate = localDate
        self.startAt = startAt
        self.venueName = venueName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.sourceIsStale = sourceIsStale
    }
}

/// Idempotency key for a ticket reminder. The same key replaces the pending notification.
public struct ReminderRequestKey: Equatable, Hashable, Sendable {
    public var roundID: String
    public var kind: TicketDeadlineKind
    public var leadMinutes: Int

    public init(roundID: String, kind: TicketDeadlineKind, leadMinutes: Int) {
        self.roundID = roundID
        self.kind = kind
        self.leadMinutes = leadMinutes
    }

    /// `performanceID` is empty: the reminder is for the round, not one show.
    public static func identifier(eventID: String, key: ReminderRequestKey) -> ReminderIdentifier {
        ReminderIdentifier(
            eventID: eventID,
            performanceID: "",
            tab: "tickets",
            cardType: .ticketRound,
            entityID: "\(key.roundID).\(key.kind.rawValue).\(key.leadMinutes)"
        )
    }
}

public enum DeadlineReadModel {
    public static let staleCaveat = "来源已过期，无法确认该时间仍然有效。"

    /// Nil when `roundID` is not in this bundle. A missing date stays missing; the other deadline is not substituted.
    public static func answer(bundle: LiveEventBundle, roundID: String, kind: TicketDeadlineKind) -> TicketDeadlineAnswer? {
        guard let round = bundle.ticketRounds.first(where: { $0.id == roundID }) else { return nil }
        let deadline: Date? = switch kind {
        case .applicationEnd: round.applyEndAt
        case .paymentEnd: round.paymentDeadlineAt
        }
        return TicketDeadlineAnswer(
            roundName: round.officialName,
            kind: kind,
            deadline: deadline,
            timeZoneIdentifier: bundle.event.timeZone,
            sourceIsStale: bundle.sourceHealth != .healthy,
            unknown: deadline == nil
        )
    }

    public static func performanceAnswer(bundle: LiveEventBundle, performanceID: String) -> PerformanceAnswer? {
        guard let performance = bundle.performances.first(where: { $0.id == performanceID }) else { return nil }
        return PerformanceAnswer(
            officialTitle: bundle.event.officialTitle,
            dayLabel: performance.dayLabel,
            localDate: performance.localDate,
            startAt: performance.startAt,
            venueName: performance.venueName,
            timeZoneIdentifier: performance.timeZone ?? bundle.event.timeZone,
            sourceIsStale: bundle.sourceHealth != .healthy
        )
    }

    public static func format(
        _ answer: TicketDeadlineAnswer,
        now: Date,
        locale: Locale = Locale(identifier: "zh_Hans")
    ) -> String {
        let label = kindLabel(answer.kind)
        let caveat = answer.sourceIsStale ? staleCaveat : ""
        guard let deadline = answer.deadline, !answer.unknown else {
            return "\(answer.roundName)没有已保存的\(label)时间。\(caveat)"
        }
        let absolute = absoluteTime(deadline, timeZoneIdentifier: answer.timeZoneIdentifier, locale: locale)
        var text = "\(answer.roundName)的\(label)时间是\(absolute)，时区\(answer.timeZoneIdentifier)。"
        if deadline <= now { text += "该时间已过。" }
        text += caveat
        return text
    }

    public static func format(
        _ answer: PerformanceAnswer,
        now: Date,
        locale: Locale = Locale(identifier: "zh_Hans")
    ) -> String {
        var text = "\(answer.officialTitle)，\(answer.dayLabel)"
        if let localDate = answer.localDate, !localDate.isEmpty {
            text += "，本地日期\(localDate)"
        } else {
            text += "，没有已保存的本地日期"
        }
        if answer.venueName.isEmpty {
            text += "，没有已保存的场地。"
        } else {
            text += "，场地\(answer.venueName)。"
        }
        if let startAt = answer.startAt {
            let absolute = absoluteTime(startAt, timeZoneIdentifier: answer.timeZoneIdentifier, locale: locale)
            text += "开场时间是\(absolute)，时区\(answer.timeZoneIdentifier)。"
            if startAt <= now { text += "该时间已过。" }
        } else {
            text += "没有已保存的开场时间。"
        }
        if answer.sourceIsStale { text += staleCaveat }
        return text
    }

    static func absoluteTime(_ date: Date, timeZoneIdentifier: String, locale: Locale) -> String {
        let zone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func kindLabel(_ kind: TicketDeadlineKind) -> String {
        switch kind {
        case .applicationEnd: "申请截止"
        case .paymentEnd: "支付截止"
        }
    }
}

public enum TicketReminderPlanner {
    public enum PlannerFailure: Error, Equatable, Sendable {
        case invalidLead
        case alreadyPast
        case missingDeadline
    }

    /// Lead is minutes. `fireAt` is the deadline minus that lead. Non-positive leads and a fire date that is not still in the future are rejected.
    public static func fireDate(deadline: Date?, leadMinutes: Int, now: Date) -> Result<Date, PlannerFailure> {
        guard leadMinutes > 0 else { return .failure(.invalidLead) }
        guard let deadline else { return .failure(.missingDeadline) }
        let fireAt = deadline.addingTimeInterval(-Double(leadMinutes) * 60)
        guard fireAt > now else { return .failure(.alreadyPast) }
        return .success(fireAt)
    }
}
