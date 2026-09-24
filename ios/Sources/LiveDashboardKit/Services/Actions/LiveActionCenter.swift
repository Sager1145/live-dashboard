import Foundation
import LiveIngestionCore

/// Services the UI and App Intents share. Reads use the saved catalog only; this type never starts a model session.
@MainActor
public final class LiveActionCenter {
    public static let shared = LiveActionCenter()

    public let repository: LocalLiveRepository
    public let userDataStore: UserDataStore
    public let reminderService: ReminderService

    public private(set) var router: AppRouter?
    /// Stored so a later organize task can find the coordinator. Not called from this type.
    public private(set) var assistant: AssistantCoordinator?
    public private(set) var dashboard: DashboardStore?

    public var pendingOrganizeEventID: String?

    private init() {
        repository = LocalLiveRepository()
        userDataStore = UserDataStore()
        reminderService = ReminderService()
    }

    public func configure(router: AppRouter, assistant: AssistantCoordinator, dashboard: DashboardStore) {
        self.router = router
        self.assistant = assistant
        self.dashboard = dashboard
    }

    public func takePendingOrganizeEventID() -> String? {
        let value = pendingOrganizeEventID
        pendingOrganizeEventID = nil
        return value
    }

    /// Empty when the catalog cannot be read. Entity queries use this so a throw does not become a guessed match.
    public func savedBundles() async -> [LiveEventBundle] {
        (try? await repository.allBundles()) ?? []
    }

    public func openSpeech(eventID: String, title: String) -> String {
        guard let router else { return "无法在当前进程中打开，演出是\(title)。" }
        router.navigate(to: DeepLinkTarget(eventID: eventID))
        return "已打开\(title)。"
    }

    public func performanceSpeech(eventID: String, performanceID: String, now: Date = Date()) async -> String {
        switch await loadBundle(eventID: eventID) {
        case .failure:
            return Self.catalogUnavailable
        case .success(nil):
            return "本地目录里没有这场演出。"
        case .success(let bundle?):
            guard let answer = DeadlineReadModel.performanceAnswer(bundle: bundle, performanceID: performanceID) else {
                return "本地目录里没有这场演出场次。"
            }
            return DeadlineReadModel.format(answer, now: now)
        }
    }

    public func deadlineSpeech(eventID: String, roundID: String, kind: TicketDeadlineKind, now: Date = Date()) async -> String {
        switch await loadAnswer(eventID: eventID, roundID: roundID, kind: kind) {
        case .message(let message):
            return message
        case .answer(let answer):
            return DeadlineReadModel.format(answer, now: now)
        }
    }

    public func followedSpeech(start: String?, end: String?) async -> String {
        let startBound = Self.dayBound(start)
        let endBound = Self.dayBound(end)
        if case .invalid = startBound { return "开始日期请使用 YYYY-MM-DD。" }
        if case .invalid = endBound { return "结束日期请使用 YYYY-MM-DD。" }
        let bundles: [LiveEventBundle]
        do { bundles = try await repository.allBundles() }
        catch { return Self.catalogUnavailable }
        let followed = Set(userDataStore.eventStates.filter { $0.value.isFollowed }.map(\.key))
        let startDay = startBound.day
        let endDay = endBound.day
        let matched = bundles.filter { bundle in
            guard followed.contains(bundle.event.id) else { return false }
            return Self.performanceFalls(in: bundle, start: startDay, end: endDay)
        }.sorted { $0.event.officialTitle.localizedStandardCompare($1.event.officialTitle) == .orderedAscending }
        guard !matched.isEmpty else {
            return (startDay != nil || endDay != nil) ? "这个日期范围内没有已关注的演出。" : "没有已关注的演出。"
        }
        let titles = matched.map(\.event.officialTitle).joined(separator: "、")
        return "已关注的演出：\(titles)。"
    }

    public func refreshSpeech(eventID: String, title: String) async -> String {
        if let dashboard {
            await dashboard.refresh(eventID: eventID)
            if let message = dashboard.errorMessage, !message.isEmpty {
                return "未能刷新\(title)。\(message)"
            }
            return "已刷新\(title)。"
        }
        do {
            guard try await repository.refresh(eventID: eventID) != nil else {
                return "本地目录里没有\(title)，未刷新。"
            }
            return "已刷新\(title)。"
        } catch {
            return "未能刷新\(title)。"
        }
    }

    public func organizeSpeech(eventID: String, title: String) -> String {
        pendingOrganizeEventID = eventID
        router?.navigate(to: DeepLinkTarget(eventID: eventID))
        if let assistant {
            Task { await assistant.organizeOnDevice(eventID: eventID) }
        }
        return "应用将显示\(title)的整理任务。"
    }

    public func scheduleTicketReminder(
        eventID: String,
        roundID: String,
        kind: TicketDeadlineKind,
        leadMinutes: Int,
        now: Date = Date()
    ) async -> String {
        let loaded: TicketDeadlineAnswer
        switch await loadAnswer(eventID: eventID, roundID: roundID, kind: kind) {
        case .message(let message):
            return message
        case .answer(let answer):
            loaded = answer
        }
        let planned = TicketReminderPlanner.fireDate(deadline: loaded.deadline, leadMinutes: leadMinutes, now: now)
        let detail = DeadlineReadModel.format(loaded, now: now)
        switch planned {
        case .failure(.invalidLead):
            return "提前分钟必须大于 0，未设置提醒。\(detail)"
        case .failure(.alreadyPast):
            return "提醒时间已过，未设置提醒。\(detail)"
        case .failure(.missingDeadline):
            return detail
        case .success(let fireAt):
            guard await reminderService.requestAuthorizationIfNeeded() else {
                return "通知权限未开启，未设置提醒。\(detail)"
            }
            let key = ReminderRequestKey(roundID: roundID, kind: kind, leadMinutes: leadMinutes)
            let identifier = ReminderRequestKey.identifier(eventID: eventID, key: key)
            let locale = Locale(identifier: "zh_Hans")
            let fireText = DeadlineReadModel.absoluteTime(fireAt, timeZoneIdentifier: loaded.timeZoneIdentifier, locale: locale)
            let deadlineText = loaded.deadline.map { DeadlineReadModel.absoluteTime($0, timeZoneIdentifier: loaded.timeZoneIdentifier, locale: locale) }
            do {
                try await reminderService.scheduleDeadlineReminder(
                    identifier: identifier,
                    title: loaded.roundName,
                    body: "\(DeadlineReadModel.kindLabel(kind))将于\(deadlineText ?? "")截止，时区\(loaded.timeZoneIdentifier)。",
                    fireAt: fireAt
                )
            } catch {
                return "设置提醒失败。\(detail)"
            }
            return "已设置提醒，将在\(fireText)（时区\(loaded.timeZoneIdentifier)）提醒。\(detail)"
        }
    }

    private enum AnswerLoad {
        case answer(TicketDeadlineAnswer)
        case message(String)
    }

    private func loadAnswer(eventID: String, roundID: String, kind: TicketDeadlineKind) async -> AnswerLoad {
        switch await loadBundle(eventID: eventID) {
        case .failure:
            return .message(Self.catalogUnavailable)
        case .success(nil):
            return .message("本地目录里没有这场演出。")
        case .success(let bundle?):
            guard let answer = DeadlineReadModel.answer(bundle: bundle, roundID: roundID, kind: kind) else {
                return .message("本地目录里没有这个售票轮次。")
            }
            return .answer(answer)
        }
    }

    private func loadBundle(eventID: String) async -> Result<LiveEventBundle?, Error> {
        do { return .success(try await repository.bundle(eventID: eventID)) }
        catch { return .failure(error) }
    }

    private static let catalogUnavailable = "无法读取已保存的目录。"

    private enum DayBound {
        case absent
        case day(String)
        case invalid

        var day: String? {
            if case .day(let value) = self { return value }
            return nil
        }
    }

    private static func dayBound(_ raw: String?) -> DayBound {
        guard let raw else { return .absent }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .absent }
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return .invalid }
        return .day(trimmed)
    }

    private static func performanceFalls(in bundle: LiveEventBundle, start: String?, end: String?) -> Bool {
        guard start != nil || end != nil else { return true }
        return bundle.performances.contains { performance in
            guard let day = performance.localDate else { return false }
            if let start, day < start { return false }
            if let end, day > end { return false }
            return true
        }
    }
}
