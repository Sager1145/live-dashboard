import SwiftUI

public struct LiveDetailView: View {
    @State private var store: LiveDetailStore
    private let userDataStore: UserDataStore
    private let reminderService: ReminderScheduling
    private let repository: LiveRepository
    private let installationService: InstallationService
    private let assistant: AssistantCoordinator
    private let onBundleRefresh: (@MainActor (LiveEventBundle) -> Void)?
    @State private var history: [EventChangeHistory] = []
    @State private var showsHistory = false
    @State private var reminderMessage: String?
    @State private var isRefreshingCard = false
    @State private var cardRefreshMessage: String?

    public init(bundle: LiveEventBundle, initialPerformanceID: String? = nil, initialTab: DetailTab = .overview, userDataStore: UserDataStore, reminderService: ReminderScheduling, repository: LiveRepository, installationService: InstallationService, assistant: AssistantCoordinator, onBundleRefresh: (@MainActor (LiveEventBundle) -> Void)? = nil) {
        let store = LiveDetailStore(bundle: bundle, initialPerformanceID: initialPerformanceID, userDataStore: userDataStore)
        store.selectedTab = initialTab
        _store = State(initialValue: store)
        self.userDataStore = userDataStore
        self.reminderService = reminderService
        self.repository = repository
        self.installationService = installationService
        self.assistant = assistant
        self.onBundleRefresh = onBundleRefresh
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.bundle.event.officialTitle)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    let state = userDataStore.state(for: store.bundle.event.id)
                    Button(state.isFollowed ? "已关注" : "关注", systemImage: state.isFollowed ? "star.fill" : "star") {
                        userDataStore.setFollowed(!state.isFollowed, eventID: store.bundle.event.id)
                    }.buttonStyle(.bordered)
                    Button(state.planningToAttend ? "计划参加" : "标记参加", systemImage: "person.crop.circle.badge.checkmark") {
                        userDataStore.setPlanningToAttend(!state.planningToAttend, eventID: store.bundle.event.id)
                    }.buttonStyle(.bordered)
                    if store.selectedPerformance?.startAt != nil {
                        Button("行程提醒", systemImage: "bell") { Task { await schedulePersonalReminder() } }.buttonStyle(.bordered)
                    }
                }
                if let reminderMessage { Text(reminderMessage).font(.caption).foregroundStyle(.secondary) }
                if isRefreshingCard {
                    Label("正在重新整理此卡片…", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let cardRefreshMessage {
                    Text(cardRefreshMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let url = URL(string: store.bundle.event.primarySourceURL) {
                    Link("查看官方公演页面", destination: url)
                        .font(.subheadline)
                }

                criticalNotices

                if store.sortedPerformances.count > 1 {
                    PerformanceSelector(bundle: store.bundle, selectedPerformanceID: $store.selectedPerformanceID)
                }

                Picker("分区", selection: $store.selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text(LocalizedStringKey($0.titleZH)).tag($0) }
                }
                .pickerStyle(.segmented)

                selectedContent
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .environment(
            \.detailCardRefreshAction,
            DetailCardRefreshAction(isRefreshing: isRefreshingCard, refresh: refreshCard)
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await assistant.generate(for: store.bundle, force: true) }
                } label: {
                    if assistant.generatingEventIDs.contains(store.bundle.event.id) {
                        ProgressView()
                    } else {
                        Label("AI 整理", systemImage: "sparkles")
                    }
                }
                .disabled(!assistant.account.isSignedIn)
                .accessibilityIdentifier("assistantGenerateButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("更新历史", systemImage: "clock.arrow.circlepath") { showsHistory = true }
            }
        }
        .sheet(isPresented: $showsHistory) { HistoryView(history: history, bundle: store.bundle) }
        .task(id: store.bundle.event.id) {
            history = (try? await repository.changes(eventID: store.bundle.event.id)) ?? []
            store.assistantSummary = assistant.summary(for: store.bundle.event.id)
        }
        .onChange(of: assistant.summaries[store.bundle.event.id]) { _, new in
            store.assistantSummary = new
        }
    }

    @ViewBuilder private var selectedContent: some View {
        switch store.selectedTab {
        case .overview: OverviewView(store: store, userDataStore: userDataStore, assistant: assistant)
        case .tickets: TicketsView(store: store, userDataStore: userDataStore, reminderService: reminderService, installationService: installationService)
        case .seating: SeatingView(store: store, userDataStore: userDataStore)
        case .goods: GoodsView(store: store, userDataStore: userDataStore)
        }
    }

    @ViewBuilder private var criticalNotices: some View {
        let notices = store.applicableNotices().applicable.filter { [.cancellation, .postponement, .refund].contains($0.kind) }
        ForEach(notices) { notice in
            VStack(alignment: .leading, spacing: 4) {
                Label(notice.title, systemImage: "exclamationmark.triangle.fill").font(.headline)
                Text(notice.body).font(.subheadline)
                if let url = URL(string: notice.sourceURL) { Link("查看官方来源", destination: url) }
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func schedulePersonalReminder() async {
        guard let performance = store.selectedPerformance, let start = performance.startAt else { return }
        guard await reminderService.requestAuthorizationIfNeeded() else { reminderMessage = String(localized: "通知权限未开启"); return }
        let identifier = ReminderIdentifier(eventID: store.bundle.event.id, performanceID: performance.id, tab: DetailTab.overview.rawValue, cardType: .timeAndVenue, entityID: performance.id)
        let fireAt = start.addingTimeInterval(-2 * 3600)
        do {
            try await reminderService.scheduleDeadlineReminder(identifier: identifier, title: store.bundle.event.officialTitle, body: String(localized: "演出将在两小时后开始"), fireAt: fireAt)
            userDataStore.saveReminder(PersonalReminderRecord(stableID: identifier.stableID, eventID: store.bundle.event.id, performanceID: performance.id, entityID: performance.id, fireAt: fireAt))
            reminderMessage = fireAt > Date() ? String(localized: "已设置本地行程提醒") : String(localized: "演出时间已过，未设置提醒")
        } catch { reminderMessage = error.localizedDescription }
    }

    private func refreshCard(cardType: CardType, entityID: String) async {
        guard !isRefreshingCard else { return }
        isRefreshingCard = true
        cardRefreshMessage = nil
        defer { isRefreshingCard = false }

        do {
            guard let updated = try await repository.refresh(
                eventID: store.bundle.event.id,
                cardType: cardType,
                entityID: entityID
            ) else {
                cardRefreshMessage = String(localized: "此卡片暂无可更新的官方资料")
                return
            }
            store.replaceBundle(updated)
            onBundleRefresh?(updated)
            cardRefreshMessage = String(localized: "此卡片已更新")
            if assistant.autoSummarizeAfterRefresh, assistant.account.isSignedIn, assistant.isStale(updated) {
                Task { await assistant.generate(for: updated) }
            }
        } catch {
            cardRefreshMessage = String(localized: "重新整理失败：\(error.localizedDescription)")
        }
    }
}

private struct HistoryView: View {
    let history: [EventChangeHistory]
    let bundle: LiveEventBundle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    ContentUnavailableView("暂无已发布变更", systemImage: "clock")
                } else {
                    ForEach(history) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            if let body = item.body { Text(body).font(.subheadline) }
                            Text(item.publishedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("来源核对") {
                    LabeledContent("资料版本", value: bundle.revision.map(String.init) ?? "v1")
                    LabeledContent("来源状态", value: bundle.sourceHealth.rawValue)
                    LabeledContent("发布时间", value: bundle.publishedAt.formatted())
                    ForEach(bundle.evidence.prefix(20)) { evidence in
                        DisclosureGroup(evidence.field) {
                            Text(evidence.quote).textSelection(.enabled)
                            if let url = URL(string: evidence.sourceURL) { Link("打开官方来源", destination: url) }
                        }
                    }
                    if bundle.evidence.isEmpty { Text("来源证据尚未获取或待核验").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("更新与来源")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
