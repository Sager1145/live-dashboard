import Foundation

struct DateRoleValidation: Equatable, Sendable {
    var mentionID: String
    var role: TicketDateRole
    var evidenceLineIDs: [String]
    var rawText: String
    var absoluteDate: Date?
    var needsReview: Bool
    var rejection: String?

    init(
        mentionID: String,
        role: TicketDateRole,
        evidenceLineIDs: [String],
        rawText: String,
        absoluteDate: Date?,
        needsReview: Bool,
        rejection: String?
    ) {
        self.mentionID = mentionID
        self.role = role
        self.evidenceLineIDs = evidenceLineIDs
        self.rawText = rawText
        self.absoluteDate = absoluteDate
        self.needsReview = needsReview
        self.rejection = rejection
    }
}

enum ExtractedFieldValidator {

    static func validate(
        _ proposal: DateClassificationProposal,
        input: DateClassificationRequest,
        timeZone: TimeZone
    ) -> [DateRoleValidation] {
        let mentions = Dictionary(input.mentions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return proposal.assignments.map { assignment in
            guard let mention = mentions[assignment.mentionID] else {
                return DateRoleValidation(
                    mentionID: assignment.mentionID,
                    role: assignment.role,
                    evidenceLineIDs: assignment.evidenceLineIDs,
                    rawText: "",
                    absoluteDate: nil,
                    needsReview: true,
                    rejection: "invalidCandidateID"
                )
            }
            let instant = assignment.role == .unknown
                ? nil
                : absoluteDate(rawText: mention.rawText, input: input, timeZone: timeZone)
            return DateRoleValidation(
                mentionID: assignment.mentionID,
                role: assignment.role,
                evidenceLineIDs: assignment.evidenceLineIDs,
                rawText: mention.rawText,
                absoluteDate: instant,
                needsReview: true,
                rejection: nil
            )
        }
    }

    private static func absoluteDate(
        rawText: String,
        input: DateClassificationRequest,
        timeZone: TimeZone
    ) -> Date? {
        guard let parts = parts(in: rawText), let hour = parts.hour, let minute = parts.minute else {
            return nil
        }
        let year: Int?
        if let ownYear = parts.year {
            year = ownYear
        } else {
            let years = yearsInBlock(input)
            year = years.count == 1 ? years.first : nil
        }
        guard let year else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year,
            month: parts.month,
            day: parts.day,
            hour: hour,
            minute: minute,
            second: 0
        ))
    }

    private static func yearsInBlock(_ input: DateClassificationRequest) -> Set<Int> {
        let yearMark = /\d{4}(?=年)/
        var years = Set<Int>()
        for text in input.headingPath + input.lines.map(\.text) {
            for match in text.matches(of: yearMark) {
                if let year = Int(match.output) {
                    years.insert(year)
                }
            }
        }
        return years
    }

    private static func parts(in rawText: String) -> (year: Int?, month: Int, day: Int, hour: Int?, minute: Int?)? {
        let dated = /(?:(?<year>\d{4})年)?(?<month>\d{1,2})月(?<day>\d{1,2})日(?:[ \t]*(?<hour>\d{1,2}):(?<minute>\d{2}))?/
        guard let match = rawText.firstMatch(of: dated) else { return nil }
        guard let month = Int(match.month), let day = Int(match.day) else { return nil }
        let year = match.year.flatMap { Int($0) }
        let hour = match.hour.flatMap { Int($0) }
        let minute = match.minute.flatMap { Int($0) }
        return (year, month, day, hour, minute)
    }
}
