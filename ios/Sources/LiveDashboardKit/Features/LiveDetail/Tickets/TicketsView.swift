import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
        let benefits = store.applicableTicketBenefits()
        let showsBenefitPlaceholder = benefits.applicable.isEmpty && benefits.unconfirmed.isEmpty && !store.goodsBundledTiers.isEmpty

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
            ForEach(benefits.applicable) { benefit in
                TicketBenefitCard(benefit: benefit, store: store, userDataStore: userDataStore)
            }
            if showsBenefitPlaceholder {
                TicketBenefitPlaceholderCard(store: store, userDataStore: userDataStore)
            }
            if !benefits.unconfirmed.isEmpty {
                DisclosureGroup("适用日期待确认的特典资料") {
                    ForEach(benefits.unconfirmed) { benefit in
                        TicketBenefitCard(benefit: benefit, store: store, userDataStore: userDataStore)
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
                    if let applyWindowText = round.applyWindowText {
                        Text("受付期间：\(applyWindowText)").font(.footnote)
                    } else {
                        Text("受付期间：\(dateRangeText(round.applyStartAt, round.applyEndAt, status: round.status))")
                    }
                }
                if config.shows(.eligibility) {
                    if let applicationTarget = round.applicationTarget {
                        Text("申请对象：\(applicationTarget)").font(.footnote)
                    }
                    if let quantityLimit = round.quantityLimit {
                        Text("枚数限制：\(quantityLimit)").font(.footnote)
                    }
                    if !round.lotteryProducts.isEmpty {
                        lotteryProductsView
                    } else if let eligibility = round.eligibility {
                        Text("申请条件：\(eligibility)").font(.footnote)
                    }
                }
                if config.shows(.time) {
                    if let resultText = round.resultText {
                        Text("当落发表：\(resultText)").font(.footnote)
                    } else if let resultAt = round.resultAt {
                        Text("当落发表：\(formatted(resultAt))").font(.footnote)
                    }
                    if let paymentWindowText = round.paymentWindowText {
                        Text("入金期间：\(paymentWindowText)").font(.footnote)
                    } else if round.paymentStartAt != nil || round.paymentDeadlineAt != nil {
                        Text("入金期间：\(paymentRangeText(start: round.paymentStartAt, deadline: round.paymentDeadlineAt))").font(.footnote)
                    }
                }
                notesView

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
                    OfficialLinksView(links: applicationRoleLinks, title: "官方申请链接", excluding: [round.applyURL, round.overseasURL].compactMap { $0 })
                    OfficialLinksView(links: supportRoleLinks, title: "服务 / 联系链接")
                    OfficialLinksView(links: productRoleLinks, title: "对象商品链接")
                    OfficialLinksView(links: otherRoleLinks, title: "其他链接")
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

    private var applicationRoleLinks: [OfficialLink] {
        round.links.filter { $0.role == .application || $0.role == .overseasApplication }
    }

    private var supportRoleLinks: [OfficialLink] {
        let noteLinkIDs = Set(round.notes.flatMap { $0.links.map(\.id) })
        return round.links.filter { $0.role == .support && !noteLinkIDs.contains($0.id) }
    }

    private var productRoleLinks: [OfficialLink] {
        round.links.filter { $0.role == .product }
    }

    private var otherRoleLinks: [OfficialLink] {
        round.links.filter { $0.role == nil || $0.role == .other }
    }

    private func paymentRangeText(start: Date?, deadline: Date?) -> String {
        switch (start, deadline) {
        case (let s?, let d?): return "\(formatted(s)) ~ \(formatted(d))"
        case (let s?, nil): return String(localized: "\(formatted(s)) 起", bundle: .kit)
        case (nil, let d?): return formatted(d)
        case (nil, nil): return ""
        }
    }

    @ViewBuilder
    private var lotteryProductsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("抽选用商品").font(.caption).foregroundStyle(.secondary)
            ForEach(round.lotteryProducts, id: \.self) { product in
                HStack {
                    Text(product).font(.footnote).textSelection(.enabled)
                    Spacer()
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = product
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "复制", bundle: .kit))
                }
            }
            if round.lotteryProducts.count >= 2 {
                Button("复制全部") {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = round.lotteryProducts.joined(separator: "\n")
                    #endif
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var notesView: some View {
        if !round.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("重要信息").font(.caption).foregroundStyle(.secondary)
                ForEach(round.notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(noteKindTitle(note.kind), systemImage: noteKindIcon(note.kind))
                            .font(.caption.bold())
                        Text(note.text).font(.footnote)
                        if !note.links.isEmpty {
                            HStack {
                                ForEach(note.links) { link in
                                    if let url = URL(string: link.url) {
                                        Link(destination: url) {
                                            Text(isBareURLLabel(link.label) ? noteKindTitle(note.kind) : link.label)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func isBareURLLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    private func noteKindTitle(_ kind: TicketNoteKind) -> String {
        switch kind {
        case .faceRecognition: return NSLocalizedString("颜认证入场", comment: "")
        case .companionRegistration: return NSLocalizedString("同行者登录", comment: "")
        case .identityCheck: return NSLocalizedString("本人确认", comment: "")
        case .smartTicketOnly: return NSLocalizedString("电子票（スマチケ）", comment: "")
        case .creditCardOnly: return NSLocalizedString("仅限信用卡支付", comment: "")
        case .membershipRequired: return NSLocalizedString("需注册会员", comment: "")
        case .other: return NSLocalizedString("其他注意", comment: "")
        }
    }

    private func noteKindIcon(_ kind: TicketNoteKind) -> String {
        switch kind {
        case .faceRecognition: return "faceid"
        case .companionRegistration: return "person.2"
        case .identityCheck: return "person.text.rectangle"
        case .smartTicketOnly: return "iphone"
        case .creditCardOnly: return "creditcard"
        case .membershipRequired: return "person.crop.circle.badge.plus"
        case .other: return "info.circle"
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
        case (nil, nil): return status == .officiallyTBA ? String(localized: "官方待公布", bundle: .kit) : String(localized: "尚未获取或待核验", bundle: .kit)
        case (let s?, nil): return String(localized: "\(formatter(s)) 起", bundle: .kit)
        case (nil, let e?): return String(localized: "至 \(formatter(e))", bundle: .kit)
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
            reminderMessage = String(localized: "截止时间已过，未设置提醒", bundle: .kit)
            return
        }
        guard await reminderService.requestAuthorizationIfNeeded() else {
            reminderMessage = String(localized: "通知权限未开启", bundle: .kit)
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
            reminderMessage = String(localized: "距离截止不足一分钟，请立即处理", bundle: .kit)
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
                body: dayBefore > now ? String(localized: "申请将于明天截止", bundle: .kit) : String(localized: "申请即将截止", bundle: .kit),
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
                ? String(localized: "已设置截止前一天的本机提醒", bundle: .kit)
                : String(localized: "距截止不足一天，已设置近期本机提醒", bundle: .kit)
        } catch {
            reminderMessage = error.localizedDescription
        }
    }
}

/// One card per official goods-bundled ticket benefit (グッズ付きチケット特典):
/// contents, redemption place/time, the official image, and which tiers
/// include it. An officially-TBA benefit says so instead of showing nothing.
struct TicketBenefitCard: View {
    let benefit: TicketBenefit
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .ticketBenefit, entityID: benefit.id, eventID: benefit.eventID)
        let tiers = store.bundle.ticketTiers.filter { benefit.tierIDs.contains($0.id) }
        DetailCard(title: benefit.officialName, cardType: .ticketBenefit, entityID: benefit.id, userDataStore: userDataStore, eventID: benefit.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 6) {
                scopeLabel

                if benefit.status == .officiallyTBA {
                    Text("特典内容：官方待公布").font(.caption.bold()).foregroundStyle(.orange)
                } else if let detail = benefit.detail {
                    Text("特典内容：\(detail)").font(.body)
                } else {
                    Text("特典内容：尚未获取或待核验").font(.caption.bold()).foregroundStyle(.orange)
                }
                if let notes = benefit.notes { Text(notes).font(.footnote).foregroundStyle(.secondary) }

                if config.shows(.price), !tiers.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("适用票种").font(.caption).foregroundStyle(.secondary)
                        ForEach(tiers) { tier in
                            LabeledContent(tier.name, value: tier.amount?.formatted ?? tier.priceJPY.map { "¥\($0)" } ?? "价格待核验")
                                .font(.footnote)
                        }
                    }
                }

                if config.shows(.place), let location = benefit.redemptionLocation { LabeledContent("领取地点", value: location) }
                if config.shows(.time), let window = benefit.redemptionWindow { LabeledContent("领取时间", value: window) }
                if config.density == .detailed, let note = benefit.redemptionNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }

                ForEach(store.bundle.mediaAssets.filter { benefit.mediaAssetIDs.contains($0.id) }) { asset in
                    OfficialMediaView(asset: asset, compact: config.density == .compact)
                }

                if config.shows(.source) {
                    OfficialLinksView(links: benefit.links, title: "官方链接")
                }
            }
        }
    }

    @ViewBuilder
    private var scopeLabel: some View {
        switch benefit.scope {
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
}

/// Shown when the price list sells グッズ付き tiers but the official page never
/// describes the bonus at all (as opposed to saying 後日公開).
struct TicketBenefitPlaceholderCard: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore

    var body: some View {
        let entityID = "\(store.bundle.event.id)-ticket-benefit-placeholder"
        DetailCard(title: "グッズ付きチケット特典", cardType: .ticketBenefit, entityID: entityID, userDataStore: userDataStore, eventID: store.bundle.event.id) {
            VStack(alignment: .leading, spacing: 6) {
                Text("特典内容：官方尚未公布").font(.caption.bold()).foregroundStyle(.orange)
                Text("官方页面售有グッズ付き票种，但尚未刊登特典内容。").font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("适用票种").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.goodsBundledTiers) { tier in
                        LabeledContent(tier.name, value: tier.amount?.formatted ?? tier.priceJPY.map { "¥\($0)" } ?? "价格待核验")
                            .font(.footnote)
                    }
                }
            }
        }
    }
}
