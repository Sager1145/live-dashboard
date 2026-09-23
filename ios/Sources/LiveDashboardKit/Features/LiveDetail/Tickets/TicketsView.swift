import SwiftUI

public struct TicketsView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let installationService: InstallationService

    public init(store: LiveDetailStore, userDataStore: UserDataStore, reminderService: ReminderScheduling, installationService: InstallationService) {
        self.store = store
        self.userDataStore = userDataStore
        self.reminderService = reminderService
        self.installationService = installationService
    }

    public var body: some View {
        let resolution = store.applicableTicketRounds()
        let configurations = userDataStore.effectiveConfigurations(eventID: store.bundle.event.id)
        let grouping = ImportantInformationPolicy.ticketsTabGrouping(
            rounds: resolution.applicable,
            now: Date(),
            configurations: configurations
        )
        let streams = store.applicableStreamOffers()
        let applicableStreams = ImportantInformationPolicy.orderedStreamOffers(streams.applicable, configurations: configurations)
        let pendingStreams = ImportantInformationPolicy.orderedStreamOffers(streams.unconfirmed, configurations: configurations)
        let pendingRounds = ImportantInformationPolicy.orderedTicketRounds(resolution.unconfirmed, configurations: configurations)

        LazyVStack(spacing: 12) {
            ForEach(grouping.open) { round in
                TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, isCollapsedByDefault: false)
            }
            ForEach(grouping.upcoming) { round in
                TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, isCollapsedByDefault: false)
            }
            if !grouping.closed.isEmpty {
                DisclosureGroup("已结束的受付（\(grouping.closed.count)）") {
                    ForEach(grouping.closed) { round in
                        TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, isCollapsedByDefault: true)
                    }
                }
            }
            if !pendingRounds.isEmpty {
                DisclosureGroup("适用日期待确认") {
                    ForEach(pendingRounds) { round in
                        TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, isCollapsedByDefault: true)
                    }
                }
            }
            ForEach(applicableStreams) { streamCard($0, actionsAllowed: $0.status == .confirmed && hasExplicitSelectedScope($0.scope)) }
            if !pendingStreams.isEmpty {
                DisclosureGroup("适用场次待确认的配信资料") {
                    ForEach(pendingStreams) { streamCard($0, actionsAllowed: false) }
                }
            }
            if let summary = store.assistantSummary {
                AssistantLinksSection(title: "AI 识别的售票链接", links: summary.ticketLinks, selectedPerformanceID: store.selectedPerformanceID)
            }
        }
    }

    @ViewBuilder private func streamCard(_ offer: StreamOffer, actionsAllowed: Bool) -> some View {
        let config = userDataStore.effectiveConfiguration(cardType: .streamOffer, entityID: offer.id, eventID: offer.eventID)
        DetailCard(title: offer.officialName, cardType: .streamOffer, entityID: offer.id, userDataStore: userDataStore, eventID: offer.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 5) {
                if config.shows(.place) { LabeledContent("平台", value: offer.platform) }
                if config.shows(.price), let amount = offer.amount { LabeledContent("费用", value: amount.formatted) }
                if config.shows(.time) {
                    if let start = offer.salesStartAt { LabeledContent("销售开始", value: format(start)) }
                    if let deadline = offer.salesEndAt { LabeledContent("销售截止", value: format(deadline)) }
                    if let archive = offer.archiveAvailableUntil { LabeledContent("回看截止", value: format(archive)) }
                }
                if config.shows(.eligibility), let region = offer.regionNote { Text(region).font(.footnote) }
                if config.shows(.source), let raw = offer.url, let url = URL(string: raw) {
                    Link(destination: url) { Text(actionsAllowed ? "前往官方配信" : "查看官方来源") }
                }
            }
        }
    }

    private func hasExplicitSelectedScope(_ scope: Scope) -> Bool {
        guard case .performances(let ids) = scope else { return false }
        return ids.contains(store.selectedPerformanceID)
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: store.selectedPerformance?.timeZone ?? store.bundle.event.timeZone)
        return formatter.string(from: date)
    }
}

struct TicketRoundCard: View {
    let round: TicketRound
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let isCollapsedByDefault: Bool
    @State private var reminderMessage: String?

    private var resolution: TicketStatusResolution {
        TicketStatusResolver.resolve(round: round, now: Date())
    }

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .ticketRound, entityID: round.id, eventID: round.eventID)
        DetailCard(title: round.officialName, cardType: .ticketRound, entityID: round.id, userDataStore: userDataStore, eventID: round.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 6) {
                scopeLabel

                Text("类型：\(kindLabel)")
                    .font(.footnote)

                if resolution.needsReviewFlag {
                    Label("核对问题", systemImage: "exclamationmark.triangle")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                } else {
                    Text(LocalizedStringKey(statusLabel))
                        .font(.caption.bold())
                        .foregroundStyle(statusColor)
                }

                if config.shows(.time) {
                    Text("申请期间：\(dateRangeText(round.applyStartAt, round.applyEndAt, status: round.status))")
                }
                if config.shows(.eligibility), let eligibility = round.eligibility {
                    Text("申请条件：\(eligibility)").font(.footnote)
                }
                if config.shows(.time) {
                    if let resultAt = round.resultAt { Text("结果公布：\(formatted(resultAt))").font(.footnote) }
                    if let paymentDeadlineAt = round.paymentDeadlineAt { Text("付款期限：\(formatted(paymentDeadlineAt))").font(.footnote) }
                }

                if config.shows(.price) {
                    ForEach(store.offers(for: round)) { offer in
                        if let tier = store.tier(for: offer) {
                            LabeledContent(tier.name, value: (offer.amount ?? tier.amount)?.formatted ?? offer.priceJPY.map { "¥\($0)" } ?? tier.priceJPY.map { "¥\($0)" } ?? "价格待核验")
                        }
                    }
                }

                if officialActionsAllowed { HStack {
                    if config.shows(.source), let applyURL = round.applyURL, let url = URL(string: applyURL) {
                        Link("前往官方申请", destination: url)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("截止提醒") {
                        Task { await scheduleReminder() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canScheduleReminder)
                } }

                if !officialActionsAllowed, config.shows(.source), let applyURL = round.applyURL, let url = URL(string: applyURL) {
                    Link("查看官方来源", destination: url)
                }

                if config.shows(.source) {
                    OfficialLinksView(links: round.links, title: "官方售票链接", excluding: [round.applyURL, round.overseasURL].compactMap { $0 })
                }

                if isActionable {
                    let manual = userDataStore.state(for: round.eventID).roundRecords.first { $0.roundID == round.id } ?? UserRoundRecord(roundID: round.id)
                    HStack {
                        Toggle("已申请", isOn: Binding(get: { manual.applied }, set: { value in var changed = manual; changed.applied = value; userDataStore.setRoundRecord(changed, eventID: round.eventID) }))
                        Toggle("已付款", isOn: Binding(get: { manual.paid }, set: { value in var changed = manual; changed.paid = value; userDataStore.setRoundRecord(changed, eventID: round.eventID) }))
                    }.font(.footnote)
                }
                if let reminderMessage { Text(reminderMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var scopeLabel: some View {
        switch round.scope {
        case .wholeEvent:
            Text("全日共通").font(.caption2).foregroundStyle(.secondary)
        case .stop, .performances:
            if let performance = store.selectedPerformance {
                Text("适用：\(performance.dayLabel)").font(.caption2).foregroundStyle(.secondary)
            }
        case .unconfirmed:
            Text("适用日期待确认").font(.caption2).foregroundStyle(.orange)
        }
    }

    private var kindLabel: String {
        switch round.kind {
        case .lottery: return NSLocalizedString("抽选", comment: "")
        case .firstComeFirstServed: return NSLocalizedString("先到先得", comment: "")
        case .resale: return NSLocalizedString("官方转售", comment: "")
        case .upgrade: return NSLocalizedString("升级受付", comment: "")
        case .other: return NSLocalizedString("其他", comment: "")
        }
    }

    private var isActionable: Bool {
        guard round.status == .confirmed, case .performances(let ids) = round.scope else { return false }
        return ids.contains(store.selectedPerformanceID)
    }

    private var officialActionsAllowed: Bool {
        isActionable && (resolution.displayStatus == .open || resolution.displayStatus == .upcoming)
    }

    private var canScheduleReminder: Bool {
        guard officialActionsAllowed, let deadline = round.applyEndAt else { return false }
        return deadline > Date()
    }

    private var statusLabel: String {
        switch resolution.displayStatus {
        case .upcoming: return NSLocalizedString("即将开始", comment: "")
        case .open: return NSLocalizedString("受付中", comment: "")
        case .closed: return NSLocalizedString("已结束", comment: "")
        case .unknown: return NSLocalizedString("状态未知", comment: "")
        }
    }

    private var statusColor: Color {
        switch resolution.displayStatus {
        case .upcoming: return .blue
        case .open: return .green
        case .closed: return .secondary
        case .unknown: return .orange
        }
    }

    private func dateRangeText(_ start: Date?, _ end: Date?, status: DataStatus) -> String {
        let formatter: (Date) -> String = { formatted($0) }
        switch (start, end) {
        case (nil, nil): return status == .officiallyTBA ? String(localized: "官方待公布") : String(localized: "尚未获取或待核验")
        case (let s?, nil): return String(localized: "\(formatter(s)) 起")
        case (nil, let e?): return String(localized: "至 \(formatter(e))")
        case (let s?, let e?): return "\(formatter(s)) ~ \(formatter(e))"
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: store.selectedPerformance?.timeZone ?? store.bundle.event.timeZone)
        return formatter.string(from: date)
    }

    private func scheduleReminder() async {
        guard let deadline = round.applyEndAt, deadline > Date() else {
            reminderMessage = String(localized: "截止时间已过，未设置提醒")
            return
        }
        guard await reminderService.requestAuthorizationIfNeeded() else {
            reminderMessage = String(localized: "通知权限未开启")
            return
        }
        let identifier = ReminderIdentifier(
            eventID: store.bundle.event.id,
            performanceID: store.selectedPerformanceID,
            tab: DetailTab.tickets.rawValue,
            cardType: .ticketRound,
            entityID: round.id
        )
        let now = Date()
        guard deadline.timeIntervalSince(now) >= 60 else {
            reminderMessage = String(localized: "距离截止不足一分钟，请立即处理")
            return
        }
        let dayBefore = deadline.addingTimeInterval(-24 * 3600)
        let reminderTime = dayBefore > now
            ? dayBefore
            : now.addingTimeInterval(min(60, max(1, deadline.timeIntervalSince(now) / 2)))
        do {
            try await reminderService.scheduleDeadlineReminder(
                identifier: identifier,
                title: round.officialName,
                body: dayBefore > now ? String(localized: "申请将于明天截止") : String(localized: "申请即将截止"),
                fireAt: reminderTime
            )
            userDataStore.saveReminder(PersonalReminderRecord(
                stableID: identifier.stableID,
                eventID: round.eventID,
                performanceID: store.selectedPerformanceID,
                entityID: round.id,
                fireAt: reminderTime
            ))
            reminderMessage = dayBefore > now
                ? String(localized: "已设置截止前一天的本机提醒")
                : String(localized: "距截止不足一天，已设置近期本机提醒")
        } catch {
            reminderMessage = error.localizedDescription
        }
    }
}
