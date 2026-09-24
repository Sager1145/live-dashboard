import AppIntents
import LiveDashboardKit

enum TicketDeadlineAppEnum: String, AppEnum, CaseIterable {
    case applicationEnd
    case paymentEnd

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "截止类型") }
    static var caseDisplayRepresentations: [TicketDeadlineAppEnum: DisplayRepresentation] {
        [
            .applicationEnd: "申请截止",
            .paymentEnd: "支付截止"
        ]
    }

    var modelKind: TicketDeadlineKind {
        switch self {
        case .applicationEnd: .applicationEnd
        case .paymentEnd: .paymentEnd
        }
    }
}

struct OpenLiveIntent: AppIntent {
    static var title: LocalizedStringResource { "打开演出" }
    static var description: IntentDescription? { IntentDescription("打开已保存目录中的一场演出。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "演出")
    var event: LiveEventEntity

    static var parameterSummary: some ParameterSummary {
        Summary("打开\(\.$event)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speech = await LiveActionCenter.shared.openSpeech(eventID: event.id, title: event.title)
        return .result(dialog: "\(speech)")
    }
}

struct ReadPerformanceIntent: AppIntent {
    static var title: LocalizedStringResource { "查看场次" }
    static var description: IntentDescription? { IntentDescription("根据已保存的目录读出场次时间，不调用模型。") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "场次")
    var performance: PerformanceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("查看\(\.$performance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speech = await LiveActionCenter.shared.performanceSpeech(eventID: performance.eventID, performanceID: performance.id)
        return .result(dialog: "\(speech)")
    }
}

struct ReadTicketDeadlineIntent: AppIntent {
    static var title: LocalizedStringResource { "查看截止时间" }
    static var description: IntentDescription? { IntentDescription("根据已保存的售票轮次读出截止时间，不调用模型。") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "售票轮次")
    var round: TicketRoundEntity

    @Parameter(title: "截止类型", default: .applicationEnd)
    var kind: TicketDeadlineAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("查看\(\.$round)的\(\.$kind)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speech = await LiveActionCenter.shared.deadlineSpeech(eventID: round.eventID, roundID: round.id, kind: kind.modelKind)
        return .result(dialog: "\(speech)")
    }
}

struct ShowFollowedLivesIntent: AppIntent {
    static var title: LocalizedStringResource { "已关注的演出" }
    static var description: IntentDescription? { IntentDescription("列出已关注且仍在本地目录中的演出。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "开始日期")
    var startDate: String?

    @Parameter(title: "结束日期")
    var endDate: String?

    static var parameterSummary: some ParameterSummary {
        Summary("列出已关注的演出")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speech = await LiveActionCenter.shared.followedSpeech(start: startDate, end: endDate)
        return .result(dialog: "\(speech)")
    }
}

struct RefreshLiveIntent: AppIntent {
    static var title: LocalizedStringResource { "刷新演出" }
    static var description: IntentDescription? { IntentDescription("只刷新这一场已保存的演出。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "演出")
    var event: LiveEventEntity

    static var parameterSummary: some ParameterSummary {
        Summary("刷新\(\.$event)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speech = await LiveActionCenter.shared.refreshSpeech(eventID: event.id, title: event.title)
        return .result(dialog: "\(speech)")
    }
}

struct OrganizeLiveIntent: AppIntent {
    static var title: LocalizedStringResource { "整理演出" }
    static var description: IntentDescription? { IntentDescription("打开演出并交给应用显示整理任务，不在快捷指令里启动模型。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "演出")
    var event: LiveEventEntity

    static var parameterSummary: some ParameterSummary {
        Summary("整理\(\.$event)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speech = await LiveActionCenter.shared.organizeSpeech(eventID: event.id, title: event.title)
        return .result(dialog: "\(speech)")
    }
}

struct SetTicketReminderIntent: AppIntent {
    static var title: LocalizedStringResource { "票务提醒" }
    static var description: IntentDescription? { IntentDescription("按已保存的截止时间设置本机提醒。权限被拒绝时不会设置。") }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "售票轮次")
    var round: TicketRoundEntity

    @Parameter(title: "截止类型", default: .applicationEnd)
    var kind: TicketDeadlineAppEnum

    @Parameter(title: "提前分钟", default: 1440)
    var leadMinutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("在\(\.$round)的\(\.$kind)前提醒")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let speech = await LiveActionCenter.shared.scheduleTicketReminder(
            eventID: round.eventID,
            roundID: round.id,
            kind: kind.modelKind,
            leadMinutes: leadMinutes
        )
        return .result(dialog: "\(speech)")
    }
}
