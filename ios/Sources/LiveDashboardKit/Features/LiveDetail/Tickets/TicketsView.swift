import SwiftUI
#if canImport(UIKit)
import UIKit
import LiveIngestionCore
#endif

public struct TicketsView: View {
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let installationService: InstallationService
    @State private var recentlyHidden: (cardType: CardType, entityID: String, title: String)?

    public init(store: LiveDetailStore, userDataStore: UserDataStore, reminderService: ReminderScheduling, installationService: InstallationService) {
        self.store = store
        self.userDataStore = userDataStore
        self.reminderService = reminderService
        self.installationService = installationService
    }

    private static let ticketsCardTypes: [CardType] = [.ticketRound, .ticketBenefit, .streamOffer]

    public var body: some View {
        TimelineView(.everyMinute) { context in
            ticketsContent(now: context.date)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ key: String) -> some View {
        Text(LocalizedStringKey(key), bundle: .kit)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func isHidden(_ type: CardType, _ id: String) -> Bool {
        userDataStore.effectiveConfiguration(cardType: type, entityID: id, eventID: store.bundle.event.id).isHidden
    }

    @ViewBuilder
    private func ticketsContent(now: Date) -> some View {
        let resolution = store.applicableTicketRounds()
        let configurations = userDataStore.effectiveConfigurations(eventID: store.bundle.event.id)
        let grouping = ImportantInformationPolicy.ticketsTabGrouping(
            rounds: resolution.applicable,
            now: now,
            configurations: configurations
        )
        let streams = store.applicableStreamOffers()
        let orderedStreams = ImportantInformationPolicy.orderedStreamOffers(streams.applicable, configurations: configurations)
        let activeStreams = orderedStreams.filter { !isStreamEnded($0, now: now) }
        let endedStreams = orderedStreams.filter { isStreamEnded($0, now: now) }
        let pendingStreams = ImportantInformationPolicy.orderedStreamOffers(streams.unconfirmed, configurations: configurations)
        let pendingRounds = ImportantInformationPolicy.orderedTicketRounds(resolution.unconfirmed, configurations: configurations)
        let benefits = store.applicableTicketBenefits()
        let showsBenefitPlaceholder = benefits.applicable.isEmpty && benefits.unconfirmed.isEmpty && !store.goodsBundledTiers.isEmpty
        let visibleBenefits = benefits.applicable.filter { !isHidden(.ticketBenefit, $0.id) }
        let visibleUnconfirmedBenefits = benefits.unconfirmed.filter { !isHidden(.ticketBenefit, $0.id) }
        let showsVisiblePlaceholder = showsBenefitPlaceholder && !isHidden(.ticketBenefit, "\(store.bundle.event.id)-ticket-benefit-placeholder")
        let hiddenCount = userDataStore.hiddenCardCount(cardTypes: Self.ticketsCardTypes, eventID: store.bundle.event.id)

        let hasAssistantTicketLinks = store.assistantSummary?.ticketLinks.contains { $0.applies(to: store.selectedPerformanceID) } ?? false
        let hasVisibleTicketContent = !grouping.open.isEmpty || !grouping.upcoming.isEmpty || !grouping.closed.isEmpty || !pendingRounds.isEmpty
            || !visibleBenefits.isEmpty || showsVisiblePlaceholder || !visibleUnconfirmedBenefits.isEmpty
            || !activeStreams.isEmpty || !endedStreams.isEmpty || !pendingStreams.isEmpty || hasAssistantTicketLinks
        let hasTicketDataForSelection = !resolution.applicable.isEmpty || !resolution.unconfirmed.isEmpty || !benefits.applicable.isEmpty
            || !benefits.unconfirmed.isEmpty || showsBenefitPlaceholder || !streams.applicable.isEmpty || !streams.unconfirmed.isEmpty
        let bundleHasTicketData = !store.bundle.ticketRounds.isEmpty || !store.bundle.ticketBenefits.isEmpty || !store.bundle.streamOffers.isEmpty

        LazyVStack(spacing: 12) {
            if !grouping.open.isEmpty || !grouping.upcoming.isEmpty || !grouping.closed.isEmpty || !pendingRounds.isEmpty {
                Section {
                    ForEach(grouping.open) { round in
                        TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, now: now)
                    }
                    ForEach(grouping.upcoming) { round in
                        TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, now: now)
                    }
                    if !grouping.closed.isEmpty {
                        DisclosureGroup {
                            ForEach(grouping.closed) { round in
                                TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, now: now)
                            }
                        } label: {
                            Text("已结束的受付（\(grouping.closed.count)）", bundle: .kit)
                        }
                    }
                    if !pendingRounds.isEmpty {
                        DisclosureGroup {
                            ForEach(pendingRounds) { round in
                                TicketRoundCard(round: round, store: store, userDataStore: userDataStore, reminderService: reminderService, now: now)
                            }
                        } label: {
                            Text("适用日期待确认", bundle: .kit)
                        }
                    }
                } header: {
                    sectionHeader("受付")
                }
            }

            if !activeStreams.isEmpty || !endedStreams.isEmpty || !pendingStreams.isEmpty {
                Section {
                    ForEach(activeStreams) { streamCard($0, actionsAllowed: $0.status == .confirmed && hasExplicitSelectedScope($0.scope) && !isStreamEnded($0, now: now)) }
                    if !endedStreams.isEmpty {
                        DisclosureGroup {
                            ForEach(endedStreams) { streamCard($0, actionsAllowed: false) }
                        } label: {
                            Text("已结束的配信（\(endedStreams.count)）", bundle: .kit)
                        }
                    }
                    if !pendingStreams.isEmpty {
                        DisclosureGroup {
                            ForEach(pendingStreams) { streamCard($0, actionsAllowed: false) }
                        } label: {
                            Text("适用场次待确认的配信资料", bundle: .kit)
                        }
                    }
                } header: {
                    sectionHeader("配信")
                }
            }

            if !visibleBenefits.isEmpty || showsVisiblePlaceholder || !visibleUnconfirmedBenefits.isEmpty {
                Section {
                    ForEach(visibleBenefits) { benefit in
                        TicketBenefitCard(benefit: benefit, store: store, userDataStore: userDataStore)
                    }
                    if showsVisiblePlaceholder {
                        TicketBenefitPlaceholderCard(store: store, userDataStore: userDataStore)
                    }
                    if !visibleUnconfirmedBenefits.isEmpty {
                        DisclosureGroup {
                            ForEach(visibleUnconfirmedBenefits) { benefit in
                                TicketBenefitCard(benefit: benefit, store: store, userDataStore: userDataStore)
                            }
                        } label: {
                            Text("适用日期待确认的特典资料", bundle: .kit)
                        }
                    }
                } header: {
                    sectionHeader("特典")
                }
            }

            if let summary = store.assistantSummary {
                AssistantLinksSection(title: "AI 识别的售票链接", links: summary.ticketLinks, selectedPerformanceID: store.selectedPerformanceID)
            }

            if !hasVisibleTicketContent {
                if hasTicketDataForSelection {
                    ContentUnavailableView {
                        Label { Text("票务卡片已全部隐藏", bundle: .kit) } icon: { Image(systemName: "eye.slash") }
                    } description: {
                        Text("资料已获取，只是这些卡片被你隐藏了。", bundle: .kit)
                    } actions: {
                        Button {
                            userDataStore.unhideCards(cardTypes: Self.ticketsCardTypes, eventID: store.bundle.event.id)
                            recentlyHidden = nil
                        } label: {
                            Text("恢复显示", bundle: .kit)
                        }
                    }
                } else if bundleHasTicketData, store.selectedPerformance == nil {
                    ContentUnavailableView {
                        Label { Text("尚无可用场次资料", bundle: .kit) } icon: { Image(systemName: "calendar.badge.exclamationmark") }
                    } description: {
                        Text("官网尚未公布场次，或当前资料来源中没有场次。", bundle: .kit)
                    } actions: {
                        if let url = URL(string: store.bundle.event.primarySourceURL) {
                            Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                        }
                    }
                } else if bundleHasTicketData {
                    ContentUnavailableView {
                        Label { Text("所选场次暂无票务资料", bundle: .kit) } icon: { Image(systemName: "ticket") }
                    } description: {
                        Text("其他场次有资料，请切换场次查看。", bundle: .kit)
                    } actions: {
                        if let url = URL(string: store.bundle.event.primarySourceURL) {
                            Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label { Text("尚未获取票务资料", bundle: .kit) } icon: { Image(systemName: "ticket") }
                    } actions: {
                        if let url = URL(string: store.bundle.event.primarySourceURL) {
                            Link(destination: url) { Text("查看官方公演页面", bundle: .kit) }
                        }
                    }
                }
            }

            if let recentlyHidden {
                UndoHiddenCardRow(id: "\(recentlyHidden.cardType.rawValue)|\(recentlyHidden.entityID)", title: recentlyHidden.title) {
                    var updated = userDataStore.effectiveConfiguration(cardType: recentlyHidden.cardType, entityID: recentlyHidden.entityID, eventID: store.bundle.event.id)
                    updated.entityID = recentlyHidden.entityID
                    updated.eventID = store.bundle.event.id
                    updated.isHidden = false
                    userDataStore.setConfiguration(updated)
                    self.recentlyHidden = nil
                } onExpire: {
                    self.recentlyHidden = nil
                }
            }
            if hasVisibleTicketContent {
                HiddenCardsFooter(count: hiddenCount) {
                    userDataStore.unhideCards(cardTypes: Self.ticketsCardTypes, eventID: store.bundle.event.id)
                    recentlyHidden = nil
                }
            }
        }
        .environment(\.detailCardHideNotification, DetailCardHideNotification { cardType, entityID, title in
            recentlyHidden = (cardType, entityID, title)
        })
    }

    private func isStreamEnded(_ offer: StreamOffer, now: Date) -> Bool {
        (offer.archiveAvailableUntil ?? offer.salesEndAt).map { $0 < now } ?? false
    }

    @ViewBuilder private func streamCard(_ offer: StreamOffer, actionsAllowed: Bool) -> some View {
        let config = userDataStore.effectiveConfiguration(cardType: .streamOffer, entityID: offer.id, eventID: offer.eventID)
        let timeZone = EventFormatting.timeZone(identifier: store.selectedPerformance?.timeZone ?? store.bundle.event.timeZone, fallback: store.bundle.event.resolvedTimeZone)
        DetailCard(verbatim: offer.officialName, cardType: .streamOffer, entityID: offer.id, userDataStore: userDataStore, eventID: offer.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 5) {
                if config.shows(.place) { LabeledContent { Text(verbatim: offer.platform) } label: { Text("平台", bundle: .kit) } }
                if config.shows(.price), let amount = offer.amount { LabeledContent { Text(amount.formatted).monospacedDigit() } label: { Text("费用", bundle: .kit) } }
                if config.shows(.time) {
                    if let start = offer.salesStartAt { LabeledContent { Text(format(start, timeZone: timeZone)).monospacedDigit() } label: { Text("销售开始", bundle: .kit) } }
                    if let deadline = offer.salesEndAt { LabeledContent { Text(format(deadline, timeZone: timeZone)).monospacedDigit() } label: { Text("销售截止", bundle: .kit) } }
                    if let archive = offer.archiveAvailableUntil { LabeledContent { Text(format(archive, timeZone: timeZone)).monospacedDigit() } label: { Text("回看截止", bundle: .kit) } }
                }
                if config.shows(.eligibility), let region = offer.regionNote { Text(verbatim: region).font(.footnote) }
                if config.shows(.source), let raw = offer.url, let url = URL(string: raw) {
                    if actionsAllowed {
                        Link(destination: url) {
                            Label { Text("前往官方配信", bundle: .kit) } icon: { Image(systemName: "play.rectangle") }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Link(destination: url) { Text("查看官方来源", bundle: .kit) }
                    }
                }
            }
        }
    }

    private func hasExplicitSelectedScope(_ scope: Scope) -> Bool {
        PerformanceScopeResolver.allowsAction(
            scope: scope,
            selectedPerformanceID: store.selectedPerformanceID,
            selectedStopID: store.stopID(for: store.selectedPerformanceID)
        )
    }

    private func format(_ date: Date, timeZone: TimeZone) -> String {
        EventFormatting.dateTime(date, in: timeZone)
    }
}

/// A single "most important date" summarizing a round's current status, used
/// as the headline date on `TicketRoundCard` instead of listing every phase.
enum TicketRoundKeyDate: Equatable {
    case applyStart(Date)
    case applyEnd(Date)
    case result(Date)
    case paymentDeadline(Date)

    static func resolve(round: TicketRound, displayStatus: TicketRoundComputedStatus, now: Date) -> TicketRoundKeyDate? {
        switch displayStatus {
        case .upcoming:
            if let start = round.applyStartAt { return .applyStart(start) }
            if let end = round.applyEndAt { return .applyEnd(end) }
            return nil
        case .open:
            return round.applyEndAt.map(TicketRoundKeyDate.applyEnd)
        case .closed, .unknown:
            var candidates: [(Date, TicketRoundKeyDate)] = []
            if let resultAt = round.resultAt, resultAt > now { candidates.append((resultAt, .result(resultAt))) }
            if let paymentDeadlineAt = round.paymentDeadlineAt, paymentDeadlineAt > now { candidates.append((paymentDeadlineAt, .paymentDeadline(paymentDeadlineAt))) }
            return candidates.min { $0.0 < $1.0 }?.1
        }
    }

    var date: Date {
        switch self {
        case .applyStart(let date), .applyEnd(let date), .result(let date), .paymentDeadline(let date): return date
        }
    }

    var titleKey: String {
        switch self {
        case .applyStart: return "受付开始"
        case .applyEnd: return "申请截止"
        case .result: return "当落发表"
        case .paymentDeadline: return "入金截止"
        }
    }
}

struct TicketRoundCard: View {
    let round: TicketRound
    @Bindable var store: LiveDetailStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let now: Date
    private struct Feedback: Equatable { let message: String; let succeeded: Bool }
    @State private var feedback: Feedback?
    @State private var showsDetails = false
    @State private var copyCount = 0

    private var resolution: TicketStatusResolution {
        TicketStatusResolver.resolve(round: round, now: now)
    }

    private var timeZone: TimeZone {
        EventFormatting.timeZone(identifier: store.selectedPerformance?.timeZone ?? store.bundle.event.timeZone, fallback: store.bundle.event.resolvedTimeZone)
    }

    var body: some View {
        let config = userDataStore.effectiveConfiguration(cardType: .ticketRound, entityID: round.id, eventID: round.eventID)
        DetailCard(verbatim: round.officialName, cardType: .ticketRound, entityID: round.id, userDataStore: userDataStore, eventID: round.eventID, translationSegments: {
            var items = [TranslationRequestItem(id: "round|\(round.id)|name", text: round.officialName)]
            items += round.notes.enumerated().map { index, note in TranslationRequestItem(id: "round|\(round.id)|note|\(index)", text: note.text) }
            return items
        }) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 6) {
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                    statusBadge
                    Text(kindLabel).font(.caption).foregroundStyle(.secondary)
                    scopeLabel
                }

                if config.shows(.time) {
                    if let keyDate = TicketRoundKeyDate.resolve(round: round, displayStatus: resolution.displayStatus, now: now) {
                        LabeledContent {
                            Text(formatted(keyDate.date)).monospacedDigit().fontWeight(.semibold)
                        } label: {
                            Label(String(localized: String.LocalizationValue(keyDate.titleKey), bundle: .kit), systemImage: "calendar.badge.clock")
                        }
                        .font(.subheadline)
                    } else {
                        if let applyWindowText = round.applyWindowText {
                            Text("受付期间：\(applyWindowText)", bundle: .kit).font(.footnote)
                        } else {
                            Text("受付期间：\(dateRangeText(round.applyStartAt, round.applyEndAt, status: round.status))", bundle: .kit)
                        }
                        if resolution.displayStatus == .closed || resolution.displayStatus == .unknown {
                            if let resultText = round.resultText {
                                Text("当落发表：\(resultText)", bundle: .kit).font(.footnote)
                            }
                            if let paymentWindowText = round.paymentWindowText {
                                Text("入金期间：\(paymentWindowText)", bundle: .kit).font(.footnote)
                            }
                        }
                    }
                }
                if config.shows(.eligibility) {
                    if let applicationTarget = round.applicationTarget {
                        Text("申请对象：\(applicationTarget)", bundle: .kit).font(.footnote)
                    }
                    if let quantityLimit = round.quantityLimit {
                        Text("枚数限制：\(quantityLimit)", bundle: .kit).font(.footnote)
                    }
                    if let eligibility = round.eligibility {
                        Text("申请条件：\(eligibility)", bundle: .kit).font(.footnote)
                    }
                }
                if !round.allLotteryProducts.isEmpty { lotteryProductsView }
                OfficialLinksView(links: round.unassignedApplicationLinks, title: round.allLotteryProducts.isEmpty ? "官方申请链接" : "对应商品待确认的申请链接", prominentFirst: officialActionsAllowed)
                notesView

                if isActionable {
                    let manual = userDataStore.state(for: round.eventID).roundRecords.first { $0.roundID == round.id } ?? UserRoundRecord(roundID: round.id)
                    Text("我的进度", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                    ViewThatFits {
                        HStack { manualToggles(manual) }
                        VStack(alignment: .leading, spacing: 4) { manualToggles(manual) }
                    }
                    .font(.footnote)
                    if officialActionsAllowed {
                        Button {
                            Task { await scheduleReminder() }
                        } label: {
                            Text("截止提醒", bundle: .kit)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canScheduleReminder)
                        .accessibilityHint(canScheduleReminder ? Text(verbatim: "") : Text("缺少未来截止时间", bundle: .kit))
                    }
                }
                if let feedback {
                    Label {
                        Text(feedback.message)
                    } icon: {
                        Image(systemName: feedback.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(feedback.succeeded ? .statusPositive : .statusCritical)
                }

                if showsDetailsSection {
                    DisclosureGroup(isExpanded: $showsDetails) {
                        VStack(alignment: .leading, spacing: 6) {
                            if config.shows(.time) {
                                if let applyWindowText = round.applyWindowText {
                                    Text("受付期间：\(applyWindowText)", bundle: .kit).font(.footnote)
                                } else {
                                    Text("受付期间：\(dateRangeText(round.applyStartAt, round.applyEndAt, status: round.status))", bundle: .kit).font(.footnote)
                                }
                                if let resultText = round.resultText {
                                    Text("当落发表：\(resultText)", bundle: .kit).font(.footnote)
                                } else if let resultAt = round.resultAt {
                                    Text("当落发表：\(formatted(resultAt))", bundle: .kit).font(.footnote)
                                }
                                if let paymentWindowText = round.paymentWindowText {
                                    Text("入金期间：\(paymentWindowText)", bundle: .kit).font(.footnote)
                                } else if round.paymentStartAt != nil || round.paymentDeadlineAt != nil {
                                    Text("入金期间：\(paymentRangeText(start: round.paymentStartAt, deadline: round.paymentDeadlineAt))", bundle: .kit).font(.footnote)
                                }
                            }
                            if config.shows(.price) {
                                ForEach(store.offers(for: round)) { offer in
                                    if let tier = store.tier(for: offer) {
                                        LabeledContent {
                                            Text(priceText(offer: offer, tier: tier)).monospacedDigit()
                                        } label: {
                                            Text(verbatim: tier.name)
                                        }
                                    }
                                }
                            }
                            if config.shows(.source) {
                                let linksCardKey = TranslationStore.cardKey(eventID: round.eventID, cardType: .ticketRound, entityID: round.id)
                                OfficialLinksView(links: supportRoleLinks, title: "服务 / 联系链接", cardKey: linksCardKey, eventID: round.eventID)
                                OfficialLinksView(links: productRoleLinks.filter { $0.productNames.isEmpty }, title: "对象商品链接", cardKey: linksCardKey, eventID: round.eventID)
                                OfficialLinksView(links: otherRoleLinks, title: "其他链接", cardKey: linksCardKey, eventID: round.eventID)
                            }
                        }
                    } label: {
                        Text("申请详情", bundle: .kit)
                    }
                }
            }
        }
    }

    private var showsDetailsSection: Bool {
        let config = userDataStore.effectiveConfiguration(cardType: .ticketRound, entityID: round.id, eventID: round.eventID)
        if config.shows(.time) { return true }
        if config.shows(.price), !store.offers(for: round).isEmpty { return true }
        if config.shows(.source) {
            if !supportRoleLinks.isEmpty { return true }
            if !productRoleLinks.filter({ $0.productNames.isEmpty }).isEmpty { return true }
            if !otherRoleLinks.isEmpty { return true }
        }
        return false
    }

    @ViewBuilder
    private func manualToggles(_ manual: UserRoundRecord) -> some View {
        Toggle(isOn: Binding(get: { manual.applied }, set: { value in var changed = manual; changed.applied = value; userDataStore.setRoundRecord(changed, eventID: round.eventID) })) {
            Text("已申请", bundle: .kit)
        }
        Toggle(isOn: Binding(get: { manual.paid }, set: { value in var changed = manual; changed.paid = value; userDataStore.setRoundRecord(changed, eventID: round.eventID) })) {
            Text("已付款", bundle: .kit)
        }
    }

    private var config: CardConfiguration {
        userDataStore.effectiveConfiguration(cardType: .ticketRound, entityID: round.id, eventID: round.eventID)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if resolution.needsReviewFlag {
            statusCapsule(text: String(localized: "核对问题", bundle: .kit), systemImage: "exclamationmark.triangle", color: .statusWarning)
        } else {
            statusCapsule(text: statusLabel, systemImage: statusSystemImage, color: statusColor)
        }
    }

    private func statusCapsule(text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
    }

    private func priceText(offer: TicketOffer, tier: TicketTier) -> String {
        if let amount = offer.amount ?? tier.amount { return amount.formatted }
        if let price = offer.priceJPY ?? tier.priceJPY { return EventFormatting.price(price, currencyCode: "JPY") }
        return String(localized: "价格待核验", bundle: .kit)
    }

    private var supportRoleLinks: [OfficialLink] {
        let noteLinkIDs = Set(round.notes.flatMap { $0.links.map(\.id) })
        return round.links.filter { $0.role == .support && !noteLinkIDs.contains($0.id) }
    }

    private var productRoleLinks: [OfficialLink] {
        round.links.filter { ($0.role ?? OfficialLink.classify(label: $0.label, url: $0.url)) == .product }
    }

    private var otherRoleLinks: [OfficialLink] {
        round.links.filter { ($0.role ?? OfficialLink.classify(label: $0.label, url: $0.url)) == .other }
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
            Text("抽选用商品", bundle: .kit).font(.caption).foregroundStyle(.secondary)
            ForEach(round.allLotteryProducts, id: \.self) { product in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(verbatim: product).font(.footnote).textSelection(.enabled)
                        Spacer()
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = product
                            #endif
                            copyCount += 1
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "复制", bundle: .kit))
                    }
                    OfficialLinksView(links: round.applicationLinks(forProduct: product), title: "官方申请链接", prominentFirst: officialActionsAllowed)
                    OfficialLinksView(links: productRoleLinks.filter { $0.productNames.contains(product) }, title: "对象商品链接")
                }
            }
            if round.allLotteryProducts.count >= 2 {
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = round.allLotteryProducts.joined(separator: "\n")
                    #endif
                    copyCount += 1
                } label: {
                    Text("复制全部", bundle: .kit)
                }
                .buttonStyle(.bordered)
            }
        }
        .sensoryFeedback(.success, trigger: copyCount)
    }

    @ViewBuilder
    private var notesView: some View {
        if !round.notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("重要信息", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                ForEach(round.notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(noteKindTitle(note.kind), systemImage: noteKindIcon(note.kind))
                            .font(.caption.bold())
                        OfficialText(note.text, cardKey: TranslationStore.cardKey(eventID: round.eventID, cardType: .ticketRound, entityID: round.id), eventID: round.eventID)
                            .font(.footnote)
                        if !note.links.isEmpty {
                            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                ForEach(note.links) { link in
                                    if let url = URL(string: link.url) {
                                        Link(destination: url) {
                                            Text(verbatim: isBareURLLabel(link.label) ? noteKindTitle(note.kind) : link.label)
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
        case .faceRecognition: return String(localized: "颜认证入场", bundle: .kit)
        case .companionRegistration: return String(localized: "同行者登录", bundle: .kit)
        case .identityCheck: return String(localized: "本人确认", bundle: .kit)
        case .smartTicketOnly: return String(localized: "电子票（スマチケ）", bundle: .kit)
        case .creditCardOnly: return String(localized: "仅限信用卡支付", bundle: .kit)
        case .membershipRequired: return String(localized: "需注册会员", bundle: .kit)
        case .other: return String(localized: "其他注意", bundle: .kit)
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
            Text("全日共通", bundle: .kit).font(.caption2).foregroundStyle(.secondary)
        case .stop, .performances:
            if let performance = store.selectedPerformance {
                Text("适用：\(performance.dayLabel)", bundle: .kit).font(.caption2).foregroundStyle(.secondary)
            }
        case .unconfirmed:
            Text("适用日期待确认", bundle: .kit).font(.caption2).foregroundStyle(.statusWarning)
        }
    }

    private var kindLabel: String {
        switch round.kind {
        case .lottery: return String(localized: "抽选", bundle: .kit)
        case .firstComeFirstServed: return String(localized: "先到先得", bundle: .kit)
        case .resale: return String(localized: "官方转售", bundle: .kit)
        case .upgrade: return String(localized: "升级受付", bundle: .kit)
        case .other: return String(localized: "其他", bundle: .kit)
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
        return deadline > now
    }

    private var statusLabel: String {
        switch resolution.displayStatus {
        case .upcoming: return String(localized: "即将开始", bundle: .kit)
        case .open: return String(localized: "受付中", bundle: .kit)
        case .closed: return String(localized: "已结束", bundle: .kit)
        case .unknown: return String(localized: "状态未知", bundle: .kit)
        }
    }

    private var statusSystemImage: String {
        switch resolution.displayStatus {
        case .upcoming: return "clock"
        case .open: return "checkmark.circle"
        case .closed: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch resolution.displayStatus {
        case .upcoming: return .statusWarning
        case .open: return .statusPositive
        case .closed: return .statusCritical
        case .unknown: return .statusInfo
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
        EventFormatting.dateTime(date, in: timeZone)
    }

    private func scheduleReminder() async {
        guard let deadline = round.applyEndAt, deadline > Date() else {
            feedback = Feedback(message: String(localized: "截止时间已过，未设置提醒", bundle: .kit), succeeded: false)
            return
        }
        guard await reminderService.requestAuthorizationIfNeeded() else {
            feedback = Feedback(message: String(localized: "通知权限未开启", bundle: .kit), succeeded: false)
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
            feedback = Feedback(message: String(localized: "距离截止不足一分钟，请立即处理", bundle: .kit), succeeded: false)
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
            feedback = Feedback(
                message: dayBefore > now
                    ? String(localized: "已设置截止前一天的本机提醒", bundle: .kit)
                    : String(localized: "距截止不足一天，已设置近期本机提醒", bundle: .kit),
                succeeded: true
            )
        } catch {
            feedback = Feedback(message: error.localizedDescription, succeeded: false)
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
        DetailCard(verbatim: benefit.officialName, cardType: .ticketBenefit, entityID: benefit.id, userDataStore: userDataStore, eventID: benefit.eventID) {
            VStack(alignment: .leading, spacing: config.density == .compact ? 3 : 6) {
                scopeLabel

                if benefit.status == .officiallyTBA {
                    Text("特典内容：官方待公布", bundle: .kit).font(.caption.bold()).foregroundStyle(.statusWarning)
                } else if let detail = benefit.detail {
                    Text("特典内容：\(detail)", bundle: .kit).font(.body)
                } else {
                    Text("特典内容：尚未获取或待核验", bundle: .kit).font(.caption.bold()).foregroundStyle(.statusWarning)
                }
                if config.shows(.price), !tiers.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("适用票种", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                        ForEach(tiers) { tier in
                            LabeledContent {
                                Text(tier.amount?.formatted ?? tier.priceJPY.map { EventFormatting.price($0, currencyCode: "JPY") } ?? String(localized: "价格待核验", bundle: .kit)).monospacedDigit()
                            } label: {
                                Text(verbatim: tier.name)
                            }
                            .font(.footnote)
                        }
                    }
                }

                if config.shows(.place), let location = benefit.redemptionLocation { LabeledContent { Text(verbatim: location) } label: { Text("领取地点", bundle: .kit) } }
                if config.shows(.time), let window = benefit.redemptionWindow { LabeledContent { Text(verbatim: window) } label: { Text("领取时间", bundle: .kit) } }

                if benefit.notes != nil || benefit.redemptionNote != nil {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            if let notes = benefit.notes { Text(verbatim: notes).font(.footnote).foregroundStyle(.secondary) }
                            if let note = benefit.redemptionNote { Text(verbatim: note).font(.footnote).foregroundStyle(.secondary) }
                        }
                    } label: {
                        Text("完整说明", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                    }
                }

                ForEach(store.bundle.mediaAssets.filter { benefit.mediaAssetIDs.contains($0.id) }) { asset in
                    OfficialMediaView(asset: asset, fitsWidth: true)
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
            Text("全日共通", bundle: .kit).font(.caption2).foregroundStyle(.secondary)
        case .stop, .performances:
            if let performance = store.selectedPerformance {
                Text("适用：\(performance.dayLabel)", bundle: .kit).font(.caption2).foregroundStyle(.secondary)
            }
        case .unconfirmed:
            Text("适用日期待确认", bundle: .kit).font(.caption2).foregroundStyle(.statusWarning)
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
                Text("特典内容：官方尚未公布", bundle: .kit).font(.caption.bold()).foregroundStyle(.statusWarning)
                Text("官方页面售有グッズ付き票种，但尚未刊登特典内容。", bundle: .kit).font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("适用票种", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                    ForEach(store.goodsBundledTiers) { tier in
                        LabeledContent {
                            Text(tier.amount?.formatted ?? tier.priceJPY.map { EventFormatting.price($0, currencyCode: "JPY") } ?? String(localized: "价格待核验", bundle: .kit)).monospacedDigit()
                        } label: {
                            Text(verbatim: tier.name)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
    }
}
