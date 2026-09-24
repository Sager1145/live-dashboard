import SwiftUI
import LiveIngestionCore
#if canImport(Translation)
@preconcurrency import Translation
#endif

public struct LiveDetailView: View {
    @State private var store: LiveDetailStore
    private let userDataStore: UserDataStore
    private let reminderService: ReminderScheduling
    private let repository: LiveRepository
    private let installationService: InstallationService
    private let assistant: AssistantCoordinator
    private let externalStore: ExternalDataStore?
    private let onBundleRefresh: (@MainActor (LiveEventBundle) -> Void)?
    @State private var history: [EventChangeHistory] = []
    @State private var showsHistory = false
    /// Feedback row shown under the action row after a personal-reminder
    /// action completes. `succeeded` drives the icon/colour.
    private struct Feedback: Equatable {
        let message: String
        let succeeded: Bool
    }
    /// Card refresh is not binary: no official payload is informational, not a failure.
    private enum CardRefreshKind: Equatable {
        case success
        case informational
        case failure

        var systemImage: String {
            switch self {
            case .success: "checkmark.circle"
            case .informational: "info.circle"
            case .failure: "exclamationmark.circle"
            }
        }

        var foregroundStyle: Color {
            switch self {
            case .success: .statusPositive
            case .informational: .statusInfo
            case .failure: .statusCritical
            }
        }
    }
    private struct CardRefreshFeedback: Equatable {
        let message: String
        let kind: CardRefreshKind
    }
    @State private var reminderFeedback: Feedback?
    @State private var isRefreshingCard = false
    @State private var cardRefreshFeedback: CardRefreshFeedback?
    @State private var activeRefreshCardKey: CardConfiguration.Key?
    @State private var communityEnrichment: CommunityPerformanceEnrichment?
    @AppStorage("translation.targetLanguage") private var translationTargetRaw = TranslationTargetLanguage.followApp.rawValue
    @State private var translationAlertMessage: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var translationStore: TranslationStore { TranslationStore.shared }

    public init(bundle: LiveEventBundle, initialPerformanceID: String? = nil, initialTab: DetailTab = .overview, userDataStore: UserDataStore, reminderService: ReminderScheduling, repository: LiveRepository, installationService: InstallationService, assistant: AssistantCoordinator, externalStore: ExternalDataStore? = nil, onBundleRefresh: (@MainActor (LiveEventBundle) -> Void)? = nil) {
        let store = LiveDetailStore(bundle: bundle, initialPerformanceID: initialPerformanceID, userDataStore: userDataStore)
        store.selectedTab = initialTab
        _store = State(initialValue: store)
        self.userDataStore = userDataStore
        self.reminderService = reminderService
        self.repository = repository
        self.installationService = installationService
        self.assistant = assistant
        self.externalStore = externalStore
        self.onBundleRefresh = onBundleRefresh
    }

    private var eventID: String { store.bundle.event.id }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                OfficialText(store.bundle.event.officialTitle, cardKey: pageCardKey, eventID: eventID)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if let poster = detailPoster {
                    OfficialMediaView(asset: poster)
                }

                if translationStore.isTranslating(.page(eventID: eventID)) {
                    Label {
                        Text(translationStore.phase == .downloading ? String(localized: "正在下载翻译语言", bundle: .kit) : String(localized: "正在翻译", bundle: .kit))
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if translationStore.isShowingTranslation(eventID: eventID, cardKey: nil) {
                    TranslationAttributionFooter(
                        isPartial: !translationStore.isTranslating(eventID: eventID)
                            && translationStore.hasUntranslated(translationStore.sourceSegments(for: store.bundle, performanceID: nil), target: translationTarget)
                    )
                }
                if let failure = translationStore.failure(for: .page(eventID: eventID)) {
                    TranslationFailureRow(message: failure.message) {
                        Task { await startPageTranslation() }
                    }
                } else if case .unsupported = translationStore.phase {
                    TranslationFailureRow(message: String(localized: "当前语言对不受支持", bundle: .kit), isUnsupported: true) {}
                }

                dataSourceBlock

                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        criticalNotices

                        if let url = URL(string: store.bundle.event.primarySourceURL) {
                            Link(destination: url) {
                                Label { Text("查看官方公演页面", bundle: .kit) } icon: { Image(systemName: "arrow.up.right.square") }
                            }
                            .font(.subheadline)
                        }

                        if let current = store.replacedPerformanceID != nil ? store.selectedPerformance : nil {
                            Label {
                                Text("所选场次在当前资料来源中不存在，已改为显示 \(PerformanceSelector.shortLabel(for: current, in: store.bundle))", bundle: .kit)
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        actionRow

                        if let reminderFeedback {
                            Label {
                                Text(reminderFeedback.message)
                            } icon: {
                                Image(systemName: reminderFeedback.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                            }
                            .font(.caption)
                            .foregroundStyle(reminderFeedback.succeeded ? .statusPositive : .statusCritical)
                        }
                        if let cardRefreshFeedback {
                            Label {
                                Text(cardRefreshFeedback.message)
                            } icon: {
                                Image(systemName: cardRefreshFeedback.kind.systemImage)
                            }
                            .font(.caption)
                            .foregroundStyle(cardRefreshFeedback.kind.foregroundStyle)
                        }

                        additionalNotices

                        selectedContent
                            .motionAnimation(store.selectedTab)
                            .transition(.opacity)
                    }
                } header: {
                    selectors
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .padding()
        }
        .navigationTitle(Text(verbatim: store.bundle.event.officialTitle))
        .toolbarTitleDisplayMode(.inline)
        .environment(
            \.detailCardRefreshAction,
            DetailCardRefreshAction(isRefreshing: isRefreshingCard, activeCardKey: activeRefreshCardKey, refresh: refreshCard)
        )
        .environment(
            \.detailCardTranslationUnsupported,
            DetailCardTranslationUnsupportedAction { message in translationAlertMessage = message }
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        let result = await assistant.generate(for: store.officialBundle, force: true)
                        if result == nil, let error = assistant.error(for: eventID) {
                            cardRefreshFeedback = CardRefreshFeedback(message: error, kind: .failure)
                        }
                    }
                } label: {
                    if assistant.generatingEventIDs.contains(eventID) {
                        ProgressView()
                            .accessibilityLabel(Text("正在 AI 整理", bundle: .kit))
                    } else {
                        Label {
                            Text(store.hasAssistantData ? "重新生成 AI 结果" : "AI 整理", bundle: .kit)
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                    }
                }
                .disabled(!assistant.account.isSignedIn)
                .accessibilityIdentifier("assistantGenerateButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsHistory = true
                } label: {
                    Label { Text("更新历史", bundle: .kit) } icon: { Image(systemName: "clock.arrow.circlepath") }
                }
            }
            if showsTranslationToolbarItem {
                ToolbarItem(placement: .topBarTrailing) {
                    translationToolbarButton
                }
            }
        }
        .sheet(isPresented: $showsHistory) { HistoryView(history: history, bundle: store.bundle) }
        .task(id: store.bundle.event.id) {
            history = (try? await repository.changes(eventID: store.bundle.event.id)) ?? []
            store.assistantSummary = assistant.summary(for: store.bundle.event.id)
        }
        .onChange(of: assistant.summaries[eventID]) { old, new in
            let wasUsingAI = store.usesAssistantData
            store.assistantSummary = new
            if new?.organizedBundle != nil, old?.generatedAt != new?.generatedAt {
                store.usesAssistantData = true
                if old != nil || !wasUsingAI {
                    AccessibilityNotification.Announcement(String(localized: "已切换到 AI 整理结果", bundle: .kit)).post()
                }
            }
        }
        .onChange(of: store.selectedTab) { _, _ in cardRefreshFeedback = nil }
        .task(id: store.selectedPerformanceID) { await loadCommunityEnrichment() }
        .onChange(of: store.selectedPerformanceID) { _, _ in
            cardRefreshFeedback = nil
            reminderFeedback = nil
        }
        .alert(
            String(localized: "翻译不可用", bundle: .kit),
            isPresented: Binding(get: { translationAlertMessage != nil }, set: { if !$0 { translationAlertMessage = nil } })
        ) {
            Button(role: .cancel) { translationAlertMessage = nil } label: { Text("好", bundle: .kit) }
        } message: {
            Text(verbatim: translationAlertMessage ?? "")
        }
        #if canImport(Translation)
        .translationTask(translationStore.activeEventID == eventID ? translationStore.configuration : nil) { session in
            await translationStore.perform(with: session)
        }
        #endif
    }

    @ViewBuilder
    private var dataSourcePicker: some View {
        Picker(selection: $store.usesAssistantData) {
            Text("官网资料", bundle: .kit).tag(false)
            Text("AI 整理结果", bundle: .kit).tag(true)
        } label: {
            Text("资料来源", bundle: .kit)
        }
        .accessibilityIdentifier("detailDataSourcePicker")
    }

    @ViewBuilder
    private var dataSourceBlock: some View {
        if store.hasAssistantData {
            VStack(alignment: .leading, spacing: 4) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("资料来源", bundle: .kit).font(.subheadline).foregroundStyle(.secondary)
                        dataSourcePicker.pickerStyle(.menu).labelsHidden()
                    }
                } else {
                    dataSourcePicker.pickerStyle(.segmented)
                }
                Text(
                    store.usesAssistantData ? "下方各分区显示已保存的 AI 整理结果，非官方资料" : "下方各分区显示官网抓取资料",
                    bundle: .kit
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var pageCardKey: String { "" }

    private var detailPoster: MediaAsset? {
        let media = store.applicableMediaAssets()
        let images = (media.applicable + media.unconfirmed).filter(\.isImage)
        return images.filter { $0.kind == .keyVisual }.max { $0.version < $1.version }
            ?? images.filter { $0.kind == .eventCover }.max { $0.version < $1.version }
    }

    private var translationTarget: TranslationTargetLanguage {
        TranslationTargetLanguage(rawValue: translationTargetRaw) ?? .followApp
    }

    private var showsTranslationToolbarItem: Bool {
        translationTarget != .off && !translationTarget.resolvesToJapanese
    }

    @ViewBuilder
    private var translationToolbarButton: some View {
        if translationStore.isTranslating(eventID: eventID) {
            ProgressView()
                .accessibilityLabel(Text(translationStore.phase == .downloading ? String(localized: "正在下载翻译语言", bundle: .kit) : String(localized: "正在翻译", bundle: .kit)))
        } else {
            let isShowing = translationStore.isShowingTranslation(eventID: eventID, cardKey: nil)
            Button {
                if isShowing {
                    translationStore.togglePage(eventID: eventID)
                    translationStore.clearFailure(.page(eventID: eventID))
                } else {
                    Task { await startPageTranslation() }
                }
            } label: {
                Label(isShowing ? String(localized: "显示原文", bundle: .kit) : String(localized: "翻译", bundle: .kit), systemImage: "translate")
            }
        }
    }

    private func startPageTranslation() async {
        let target = translationTarget
        let availability = await translationStore.availability(target: target)
        switch availability {
        case .unsupported:
            translationAlertMessage = String(localized: "当前语言对不受支持", bundle: .kit)
        case .installed, .needsDownload:
            // Idempotent: only toggle the page on if it isn't already —
            // retrying a failed batch must never toggle translation off.
            if !translationStore.isShowingTranslation(eventID: eventID, cardKey: nil) {
                translationStore.togglePage(eventID: eventID)
            }
            let segments = translationStore.sourceSegments(for: store.bundle, performanceID: nil)
            translationStore.request(items: segments, target: target, eventID: eventID, scope: .page(eventID: eventID))
        }
    }

    @ViewBuilder private var selectors: some View {
        VStack(alignment: .leading, spacing: 8) {
            PerformanceSelector(bundle: store.bundle, selectedPerformanceID: $store.selectedPerformanceID)
            tabPicker
            if store.hasAssistantData {
                Label(
                    store.usesAssistantData ? String(localized: "AI 整理结果", bundle: .kit) : String(localized: "官网资料", bundle: .kit),
                    systemImage: store.usesAssistantData ? "sparkles" : "building.columns"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tabPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text("分区", bundle: .kit).font(.subheadline).foregroundStyle(.secondary)
                Picker(selection: $store.selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text(verbatim: $0.titleZH).tag($0) }
                } label: {
                    Text("分区", bundle: .kit)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("detailTabPicker")
            }
        } else {
            Picker(selection: $store.selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { Text(verbatim: $0.titleZH).tag($0) }
            } label: {
                Text("分区", bundle: .kit)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("detailTabPicker")
        }
    }

    @ViewBuilder private var actionRow: some View {
        let state = userDataStore.state(for: eventID)
        let layout: AnyLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            actionRowButtons(state: state)
        }
    }

    @ViewBuilder
    private func actionRowButtons(state: UserEventState) -> some View {
        Toggle(isOn: Binding(
            get: { state.isFollowed },
            set: { userDataStore.setFollowed($0, eventID: eventID) }
        )) {
            Label { Text(state.isFollowed ? "已关注" : "关注", bundle: .kit) } icon: { Image(systemName: state.isFollowed ? "star.fill" : "star") }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)

        Toggle(isOn: Binding(
            get: { state.planningToAttend },
            set: { userDataStore.setPlanningToAttend($0, eventID: eventID) }
        )) {
            Label { Text(state.planningToAttend ? "计划参加" : "标记参加", bundle: .kit) } icon: { Image(systemName: "person.crop.circle.badge.checkmark") }
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)

        if store.selectedPerformance?.startAt != nil {
            Button {
                Task { await schedulePersonalReminder() }
            } label: {
                Label { Text("行程提醒", bundle: .kit) } icon: { Image(systemName: "bell") }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var selectedContent: some View {
        switch store.selectedTab {
        case .overview: OverviewView(store: store, userDataStore: userDataStore, assistant: assistant)
        case .tickets: TicketsView(store: store, userDataStore: userDataStore, reminderService: reminderService, installationService: installationService)
        case .seating: SeatingView(store: store, userDataStore: userDataStore)
        case .goods: GoodsView(store: store, userDataStore: userDataStore)
        case .community: CommunityEnrichmentView(enrichment: communityEnrichment)
        }
    }

    private func loadCommunityEnrichment() async {
        guard let externalStore, let performance = store.selectedPerformance else {
            communityEnrichment = nil
            return
        }
        let catalog = try? await externalStore.communityCatalog()
        let references = (try? await externalStore.references()) ?? []
        communityEnrichment = CommunityIngestor.enrichment(performance: performance, event: store.bundle.event, catalog: catalog, references: references)
    }

    @ViewBuilder private var criticalNotices: some View {
        ForEach(store.criticalNotices()) { item in
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    if item.isAssistantOnly {
                        Text(verbatim: item.notice.title)
                    } else {
                        OfficialText(item.notice.title, cardKey: pageCardKey, eventID: eventID)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.headline)
                if item.isAssistantOnly {
                    Text(verbatim: item.notice.body).font(.subheadline)
                } else {
                    OfficialText(item.notice.body, cardKey: pageCardKey, eventID: eventID).font(.subheadline)
                }
                if item.isScopeUnconfirmed {
                    Text("适用日期待确认", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                }
                if item.isAssistantOnly {
                    Text("来自 AI 整理结果", bundle: .kit).font(.caption).foregroundStyle(.secondary)
                }
                if let publishedAt = item.notice.publishedAt {
                    Text(verbatim: EventFormatting.date(publishedAt, in: store.bundle.event.resolvedTimeZone, includesYear: true))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let url = URL(string: item.notice.sourceURL) { Link(destination: url) { Text("查看官方来源", bundle: .kit) } }
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.statusCritical.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var additionalNotices: some View {
        let resolution = store.applicableNotices()
        let notices = resolution.applicable.filter { !LiveDetailStore.criticalNoticeKinds.contains($0.kind) }
        let unconfirmed = resolution.unconfirmed.filter { !LiveDetailStore.criticalNoticeKinds.contains($0.kind) }
        if !notices.isEmpty || !unconfirmed.isEmpty {
            DisclosureGroup {
                ForEach(notices) { notice in noticeContent(notice) }
                if !unconfirmed.isEmpty {
                    Text("适用日期待确认", bundle: .kit).font(.headline)
                    ForEach(unconfirmed) { notice in noticeContent(notice) }
                }
            } label: {
                Text("公演公告", bundle: .kit).font(.headline)
            }
        }
    }

    private func noticeContent(_ notice: Notice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: notice.title).font(.subheadline.weight(.semibold))
            Text(verbatim: notice.body).font(.subheadline).textSelection(.enabled)
            if let url = URL(string: notice.sourceURL) {
                Link(destination: url) { Text("查看官方来源", bundle: .kit) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func schedulePersonalReminder() async {
        guard let performance = store.selectedPerformance, let start = performance.startAt else { return }
        guard await reminderService.requestAuthorizationIfNeeded() else {
            reminderFeedback = Feedback(message: String(localized: "通知权限未开启", bundle: .kit), succeeded: false)
            return
        }
        let identifier = ReminderIdentifier(eventID: eventID, performanceID: performance.id, tab: DetailTab.overview.rawValue, cardType: .timeAndVenue, entityID: performance.id)
        let fireAt = start.addingTimeInterval(-2 * 3600)
        do {
            try await reminderService.scheduleDeadlineReminder(identifier: identifier, title: store.bundle.event.officialTitle, body: String(localized: "演出将在两小时后开始", bundle: .kit), fireAt: fireAt)
            userDataStore.saveReminder(PersonalReminderRecord(stableID: identifier.stableID, eventID: eventID, performanceID: performance.id, entityID: performance.id, fireAt: fireAt))
            let message = fireAt > Date() ? String(localized: "已设置本地行程提醒", bundle: .kit) : String(localized: "演出时间已过，未设置提醒", bundle: .kit)
            reminderFeedback = Feedback(message: message, succeeded: fireAt > Date())
        } catch {
            reminderFeedback = Feedback(message: error.localizedDescription, succeeded: false)
        }
        if let reminderFeedback {
            AccessibilityNotification.Announcement(reminderFeedback.message).post()
        }
    }

    private func refreshCard(cardType: CardType, entityID: String) async {
        guard !isRefreshingCard else { return }
        isRefreshingCard = true
        activeRefreshCardKey = CardConfiguration.Key(cardType: cardType, entityID: entityID, eventID: nil)
        cardRefreshFeedback = nil
        defer {
            isRefreshingCard = false
            activeRefreshCardKey = nil
            if let cardRefreshFeedback {
                AccessibilityNotification.Announcement(cardRefreshFeedback.message).post()
            }
        }

        if store.hasAssistantData, store.usesAssistantData {
            let result = await assistant.generate(for: store.officialBundle, force: true)
            if result != nil {
                cardRefreshFeedback = CardRefreshFeedback(
                    message: String(localized: "AI 字段已重新整理并保存", bundle: .kit),
                    kind: .success
                )
            } else if let error = assistant.error(for: store.officialBundle.event.id) {
                cardRefreshFeedback = CardRefreshFeedback(message: error, kind: .failure)
            }
            return
        }

        do {
            guard let updated = try await repository.refresh(
                eventID: eventID,
                cardType: cardType,
                entityID: entityID
            ) else {
                // refresh returns nil only when this event is missing from the catalog.
                cardRefreshFeedback = CardRefreshFeedback(
                    message: String(localized: "重新整理失败：此公演在当前资料来源中不存在", bundle: .kit),
                    kind: .failure
                )
                return
            }
            store.replaceBundle(updated)
            onBundleRefresh?(updated)
            cardRefreshFeedback = CardRefreshFeedback(
                message: String(localized: "此卡片已更新", bundle: .kit),
                kind: .success
            )
            if assistant.autoSummarizeAfterRefresh, assistant.account.isSignedIn, assistant.isStale(updated) {
                Task { await assistant.generate(for: updated) }
            }
        } catch {
            if case .unavailable = error as? CardRefreshError {
                cardRefreshFeedback = CardRefreshFeedback(
                    message: error.localizedDescription,
                    kind: .informational
                )
            } else {
                cardRefreshFeedback = CardRefreshFeedback(
                    message: String(localized: "重新整理失败：\(error.localizedDescription)", bundle: .kit),
                    kind: .failure
                )
            }
        }
    }
}

private struct HistoryView: View {
    let history: [EventChangeHistory]
    let bundle: LiveEventBundle
    @State private var showsAllEvidence = false
    @Environment(\.dismiss) private var dismiss

    private var timeZone: TimeZone { bundle.event.resolvedTimeZone }

    private func sourceHealthLabel(_ state: SourceHealthState) -> String {
        switch state {
        case .healthy: String(localized: "正常", bundle: .kit)
        case .stale: String(localized: "可能过期", bundle: .kit)
        case .blocked: String(localized: "访问受阻", bundle: .kit)
        case .fetchFailed: String(localized: "抓取失败", bundle: .kit)
        case .parseFailed: String(localized: "解析失败", bundle: .kit)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    ContentUnavailableView {
                        Label { Text("暂无已发布变更", bundle: .kit) } icon: { Image(systemName: "clock") }
                    }
                } else {
                    ForEach(history) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: item.title).font(.headline)
                            if let body = item.body { Text(verbatim: body).font(.subheadline) }
                            Text(verbatim: EventFormatting.date(item.publishedAt, in: timeZone, includesYear: true))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent { Text(verbatim: bundle.revision.map(String.init) ?? "v1") } label: { Text("资料版本", bundle: .kit) }
                    LabeledContent { Text(verbatim: sourceHealthLabel(bundle.sourceHealth)) } label: { Text("来源状态", bundle: .kit) }
                    LabeledContent { Text(verbatim: EventFormatting.dateTime(bundle.publishedAt, in: timeZone)) } label: { Text("发布时间", bundle: .kit) }
                    let visibleEvidence = showsAllEvidence ? bundle.evidence : Array(bundle.evidence.prefix(20))
                    ForEach(visibleEvidence) { evidence in
                        DisclosureGroup(evidence.field) {
                            Text(verbatim: evidence.quote).textSelection(.enabled)
                            if let url = URL(string: evidence.sourceURL) { Link(destination: url) { Text("打开官方来源", bundle: .kit) } }
                        }
                    }
                    if bundle.evidence.count > 20, !showsAllEvidence {
                        Button {
                            showsAllEvidence = true
                        } label: {
                            Text("显示全部 \(bundle.evidence.count) 条证据", bundle: .kit)
                        }
                    }
                    if bundle.evidence.isEmpty { Text("来源证据尚未获取或待核验", bundle: .kit).foregroundStyle(.secondary) }
                } header: {
                    Text("来源核对", bundle: .kit)
                }
            }
            .navigationTitle(Text("更新与来源", bundle: .kit))
            .toolbar {
                Button {
                    dismiss()
                } label: {
                    Text("完成", bundle: .kit)
                }
            }
        }
    }
}
