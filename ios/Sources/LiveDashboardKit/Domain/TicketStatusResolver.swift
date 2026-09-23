import Foundation

/// Derived state of a ticket round for display purposes.
public enum TicketRoundComputedStatus: String, Hashable, Sendable {
    case upcoming
    case open
    case closed
    case unknown
}

public struct TicketStatusResolution: Hashable, Sendable {
    /// Status shown to the user: an explicit `officialStatus` wins when it
    /// maps to a known state; otherwise this is the time-based computation.
    public let displayStatus: TicketRoundComputedStatus
    /// Status computed purely from applyStartAt/applyEndAt vs `now`.
    public let computedStatus: TicketRoundComputedStatus
    /// True when the underlying record failed to parse/fetch: rounds must
    /// show a "核对问题" (needs-review) flag, never "官方未公布" (officiallyTBA).
    public let needsReviewFlag: Bool
    /// Raw official status text, if the source published one, shown alongside
    /// the derived state regardless of whether it changed `displayStatus`.
    public let officialStatusText: String?
}

/// Derives upcoming / open / closed / unknown for a `TicketRound` relative to
/// a supplied `now`. See DESIGN.md 三 (DataStatus) and 四.3 (售票 tab).
public enum TicketStatusResolver {
    public static func resolve(round: TicketRound, now: Date) -> TicketStatusResolution {
        // A record that failed to parse/fetch reports unknown + needs-review,
        // regardless of any apply dates the previous confirmed version had.
        if round.status == .parseFailed || round.status == .notFetched || round.status == .needsReview {
            return TicketStatusResolution(
                displayStatus: .unknown,
                computedStatus: .unknown,
                needsReviewFlag: true,
                officialStatusText: round.officialStatus
            )
        }

        let computed = computeFromDates(applyStartAt: round.applyStartAt, applyEndAt: round.applyEndAt, now: now)

        let display: TicketRoundComputedStatus
        if let officialStatus = round.officialStatus, let mapped = mapOfficialStatus(officialStatus) {
            display = mapped
        } else {
            display = computed
        }

        return TicketStatusResolution(
            displayStatus: display,
            computedStatus: computed,
            needsReviewFlag: false,
            officialStatusText: round.officialStatus
        )
    }

    private static func computeFromDates(applyStartAt: Date?, applyEndAt: Date?, now: Date) -> TicketRoundComputedStatus {
        guard let applyStartAt else {
            return .unknown
        }
        if now < applyStartAt {
            return .upcoming
        }
        if let applyEndAt {
            return now <= applyEndAt ? .open : .closed
        }
        // Started, no published end date: treat as still open.
        return .open
    }

    /// Best-effort mapping of common official status text to a known state.
    /// Unrecognized text falls back to the time-based computation, but is
    /// still surfaced verbatim via `officialStatusText`.
    private static func mapOfficialStatus(_ text: String) -> TicketRoundComputedStatus? {
        let openKeywords = ["受付中", "販売中", "open"]
        let closedKeywords = ["受付終了", "終了", "販売終了", "closed", "sold out"]
        let upcomingKeywords = ["受付前", "近日", "upcoming"]

        let lowered = text.lowercased()
        if openKeywords.contains(where: { text.contains($0) || lowered.contains($0.lowercased()) }) {
            return .open
        }
        if closedKeywords.contains(where: { text.contains($0) || lowered.contains($0.lowercased()) }) {
            return .closed
        }
        if upcomingKeywords.contains(where: { text.contains($0) || lowered.contains($0.lowercased()) }) {
            return .upcoming
        }
        return nil
    }
}
