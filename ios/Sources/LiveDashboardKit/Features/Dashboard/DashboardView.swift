import SwiftUI

public struct DashboardView: View {
    @Bindable var store: DashboardStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let repository: LiveRepository
    let router: AppRouter
    let installationService: InstallationService
    let assistant: AssistantCoordinator
    @State private var showsFilters = false
    @State private var path: [DetailRoute] = []

    public init(store: DashboardStore, userDataStore: UserDataStore, reminderService: ReminderScheduling, repository: LiveRepository, router: AppRouter, installationService: InstallationService, assistant: AssistantCoordinator) {
        self.store = store
        self.userDataStore = userDataStore
        self.reminderService = reminderService
        self.repository = repository
        self.router = router
        self.installationService = installationService
        self.assistant = assistant
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.visibleSummaries) { summary in
                        Button {
                            path = [DetailRoute(eventID: summary.id)]
                        } label: {
                            LiveEventCard(summary: summary)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            if store.refreshingEventIDs.contains(summary.id) {
                                ProgressView().padding(12).accessibilityLabel("正在重新整理此公演")
                            }
                        }
                        .contextMenu {
                            Button {
                                Task { await store.refresh(eventID: summary.id) }
                            } label: {
                                if store.refreshingEventIDs.contains(summary.id) {
                                    Label("正在重新整理…", systemImage: "arrow.clockwise")
                                } else {
                                    Label("重新整理此公演", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(store.isRefreshing || store.refreshingEventIDs.contains(summary.id))
                            .accessibilityIdentifier("refreshEventButton-\(summary.id)")
                        }
                    }
                }
                .padding()
            }
            .overlay {
                if store.visibleSummaries.isEmpty && !store.isLoading {
                    if store.isRefreshing {
                        ProgressView("正在检查官方资料…")
                    } else if !store.bundles.isEmpty {
                        ContentUnavailableView("没有符合条件的演出", systemImage: "calendar", description: Text("请选择其他年份、月份，或调整筛选条件。"))
                    } else if let error = store.errorMessage {
                        ContentUnavailableView("无法更新公演资料", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        ContentUnavailableView("尚未获取公演资料", systemImage: "calendar.badge.exclamationmark", description: Text("下拉或点击更新按钮，直接检查官方页面。"))
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                dashboardFilters
            }
            .safeAreaInset(edge: .bottom) {
                if let error = store.errorMessage, !store.bundles.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            .navigationTitle("演出")
            .searchable(text: $store.filters.searchText, prompt: "公演或团体")
            .navigationDestination(for: DetailRoute.self) { route in
                if let bundle = store.bundles.first(where: { $0.event.id == route.eventID }) {
                    // Keyed on the route so replacing the stack for a deep link rebuilds the
                    // detail (and its store) instead of reusing the previous event's state.
                    LiveDetailView(bundle: bundle, initialPerformanceID: route.performanceID, initialTab: route.tab, userDataStore: userDataStore, reminderService: reminderService, repository: repository, installationService: installationService, assistant: assistant, onBundleRefresh: store.acceptRefreshedBundle)
                        .id(route)
                } else {
                    ContentUnavailableView("公演资料已不在本机缓存中", systemImage: "calendar.badge.exclamationmark")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await store.refresh()
                            consumeDeepLink()
                        }
                    } label: {
                        if store.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("正在检查官方资料")
                        } else {
                            Label("更新官方资料", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isRefreshing)
                    .accessibilityIdentifier("officialRefreshToolbarButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsFilters = true
                    } label: {
                        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showsFilters) {
                DashboardFiltersView(filters: $store.filters, groups: Array(Set(store.bundles.flatMap { $0.event.groups })).sorted())
            }
            .task {
                await store.load()
                consumeDeepLink()
            }
            .onChange(of: router.deepLinkRequestCount) { _, _ in consumeDeepLink() }
            .refreshable {
                await store.refresh()
                // A link kept because its event was not cached yet may be resolvable now.
                consumeDeepLink()
            }

        }
    }

    private var dashboardFilters: some View {
        HStack(alignment: .top) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HorizontalSelectionStrip(
                    title: "企划",
                    selection: $store.filters.franchise,
                    options: [
                        HorizontalSelectionOption(value: Franchise?.none, title: String(localized: "全部企划")),
                        HorizontalSelectionOption(value: Franchise?.some(.lovelive), title: "Love Live!"),
                        HorizontalSelectionOption(value: Franchise?.some(.bangdream), title: "BanG Dream!")
                    ]
                )
                .accessibilityIdentifier("eventFranchisePicker")

                HorizontalSelectionStrip(
                    title: "年份",
                    selection: $store.filters.year,
                    options: [HorizontalSelectionOption(value: Int?.none, title: String(localized: "全部年份"))] + Array(Set(store.availableYears + [store.filters.year].compactMap { $0 })).sorted().map { year in
                        HorizontalSelectionOption(value: Int?.some(year), title: String(localized: "\(String(year))年"))
                    }
                )
                .accessibilityIdentifier("eventYearPicker")

                HorizontalSelectionStrip(
                    title: "月份",
                    selection: $store.filters.month,
                    options: [HorizontalSelectionOption(value: Int?.none, title: String(localized: "全部月份"))] + (1...12).map { month in
                        HorizontalSelectionOption(value: Int?.some(month), title: String(localized: "\(month)月"))
                    }
                )
                .accessibilityIdentifier("eventMonthPicker")

                if store.filters.year != nil || store.filters.month != nil {
                    Button("重置") {
                        store.filters.year = nil
                        store.filters.month = nil
                    }
                    .font(.subheadline)
                    .accessibilityLabel("重置年份和月份")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    /// Replaces the whole navigation stack so a reminder or notification lands on
    /// its event even when another event's detail is already open, per DESIGN.md 七.3.
    private func consumeDeepLink() {
        // Peek before consuming: a push tapped at cold launch arrives while `store.load()`
        // is still running, and consuming it here would discard it before the bundle exists.
        guard let target = router.pendingDeepLink, store.bundles.contains(where: { $0.event.id == target.eventID }) else { return }
        _ = router.consumePendingDeepLink()
        path = [DetailRoute(eventID: target.eventID, performanceID: target.performanceID, tab: target.tab)]
    }
}

/// One pushed detail screen. Deep links carry their performance and tab in the
/// route itself so replacing the stack rebuilds the detail with the right target,
/// and so an ordinary tap can never inherit a previous deep link's tab.
struct DetailRoute: Hashable {
    let eventID: String
    var performanceID: String?
    var tab: DetailTab = .overview
}

struct DashboardFiltersView: View {
    @Binding var filters: DashboardFilters
    let groups: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("企划") {
                    HorizontalSelectionStrip(
                        title: "企划",
                        selection: $filters.franchise,
                        options: [
                            HorizontalSelectionOption(value: Franchise?.none, title: String(localized: "全部")),
                            HorizontalSelectionOption(value: Franchise?.some(.bangdream), title: "BanG Dream!"),
                            HorizontalSelectionOption(value: Franchise?.some(.lovelive), title: "Love Live!")
                        ]
                    )
                }
                Section("条件") {
                    HorizontalSelectionStrip(
                        title: "团体",
                        selection: $filters.group,
                        options: [HorizontalSelectionOption(value: String?.none, title: String(localized: "全部"))] + groups.map { group in
                            HorizontalSelectionOption(value: String?.some(group), title: group)
                        }
                    )
                    HorizontalSelectionStrip(
                        title: "活动类型",
                        selection: $filters.eventType,
                        options: [
                            HorizontalSelectionOption(value: EventType?.none, title: String(localized: "全部")),
                            HorizontalSelectionOption(value: EventType?.some(.live), title: "Live"),
                            HorizontalSelectionOption(value: EventType?.some(.fanMeeting), title: "Fan Meeting"),
                            HorizontalSelectionOption(value: EventType?.some(.screening), title: String(localized: "上映会")),
                            HorizontalSelectionOption(value: EventType?.some(.other), title: String(localized: "其他"))
                        ]
                    )
                    Toggle("只看关注", isOn: $filters.onlyFollowed)
                    Toggle("只看有待办事项", isOn: $filters.onlyWithPendingAction)
                }
                Section("日期") {
                    Toggle("限制日期范围", isOn: Binding(get: { filters.dateRange != nil }, set: { enabled in
                        filters.dateRange = enabled ? Date()...Calendar.current.date(byAdding: .year, value: 1, to: Date())! : nil
                    }))
                    if let range = filters.dateRange {
                        DatePicker("开始", selection: Binding(get: { range.lowerBound }, set: { value in filters.dateRange = min(value, range.upperBound)...range.upperBound }), displayedComponents: .date)
                        DatePicker("结束", selection: Binding(get: { range.upperBound }, set: { value in filters.dateRange = range.lowerBound...max(value, range.lowerBound) }), displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("筛选")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
