import SwiftUI

public struct DashboardView: View {
    @Bindable var store: DashboardStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let repository: LiveRepository
    let router: AppRouter
    let installationService: InstallationService
    let assistant: AssistantCoordinator
    /// `.upcoming` is the main "演出" tab; `.past` is the "往期" tab showing ended events.
    let scope: DashboardScope
    @State private var showsFilters = false
    @State private var path: [DetailRoute] = []
    @State private var isErrorExpanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(store: DashboardStore, userDataStore: UserDataStore, reminderService: ReminderScheduling, repository: LiveRepository, router: AppRouter, installationService: InstallationService, assistant: AssistantCoordinator, scope: DashboardScope = .upcoming) {
        self.store = store
        self.userDataStore = userDataStore
        self.reminderService = reminderService
        self.repository = repository
        self.router = router
        self.installationService = installationService
        self.assistant = assistant
        self.scope = scope
    }

    /// The scope's own filter state on the shared store.
    private var filters: Binding<DashboardFilters> {
        Binding(get: { store.filters(for: scope) }, set: { store.setFilters($0, for: scope) })
    }

    /// A single flexible column at accessibility text sizes, so an oversized card never has to
    /// share a row; otherwise an adaptive grid of regular-width cards.
    private var gridColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 280, maximum: 520), spacing: 16)]
    }

    public var body: some View {
        let summaries = store.visibleSummaries(in: scope)
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(summaries) { summary in
                        NavigationLink(value: DetailRoute(eventID: summary.id)) {
                            LiveEventCard(summary: summary, isRefreshing: store.refreshingEventIDs.contains(summary.id), scope: scope)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                Task { await store.refresh(eventID: summary.id) }
                            } label: {
                                if store.refreshingEventIDs.contains(summary.id) {
                                    Label { Text("正在重新整理…", bundle: .kit) } icon: { Image(systemName: "arrow.clockwise") }
                                } else {
                                    Label { Text("重新整理此公演", bundle: .kit) } icon: { Image(systemName: "arrow.clockwise") }
                                }
                            }
                            .disabled(store.isRefreshing || store.refreshingEventIDs.contains(summary.id))
                            .accessibilityIdentifier("refreshEventButton-\(summary.id)")

                            if let coverURL = summary.coverURL {
                                ShareLink(item: OfficialImageTransfer(url: coverURL, caption: summary.officialTitle), preview: SharePreview(Text(verbatim: summary.officialTitle))) {
                                    Label { Text("分享封面图", bundle: .kit) } icon: { Image(systemName: "square.and.arrow.up") }
                                }
                                .accessibilityIdentifier("thumbnailShare-\(summary.id)")
                            }
                        }
                    }
                }
                .padding()
            }
            .motionAnimation(summaries.map(\.id))
            .overlay {
                dashboardEmptyState(summaries: summaries)
            }
            .modifier(FilterBarInset(filterContent: dashboardFilters(matchCount: summaries.count)))
            .safeAreaInset(edge: .bottom) {
                if let error = store.errorMessage, !store.bundles.isEmpty {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                errorLabel(error)
                                HStack(spacing: 12) {
                                    errorRetryButton
                                    errorDismissButton
                                }
                            }
                        } else {
                            HStack(spacing: 12) {
                                errorLabel(error)
                                Spacer(minLength: 8)
                                errorRetryButton
                                errorDismissButton
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .motionAnimation(store.errorMessage)
            .navigationTitle(Text(scope == .past ? "往期" : "演出", bundle: .kit))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: filters.searchText, prompt: Text("公演或团体", bundle: .kit))
            .navigationDestination(for: DetailRoute.self) { route in
                if let bundle = store.bundles.first(where: { $0.event.id == route.eventID }) {
                    // Keyed on the route so replacing the stack for a deep link rebuilds the
                    // detail (and its store) instead of reusing the previous event's state.
                    LiveDetailView(bundle: bundle, initialPerformanceID: route.performanceID, initialTab: route.tab, userDataStore: userDataStore, reminderService: reminderService, repository: repository, installationService: installationService, assistant: assistant, onBundleRefresh: store.acceptRefreshedBundle)
                        .id(route)
                } else if store.isLoading || store.isRefreshing {
                    ProgressView { Text("正在载入资料…", bundle: .kit) }
                } else {
                    ContentUnavailableView {
                        Label { Text("公演资料已不在本机缓存中", bundle: .kit) } icon: { Image(systemName: "calendar.badge.exclamationmark") }
                    } description: {
                        Text("资料可能已被移除，或尚未载入。", bundle: .kit)
                    } actions: {
                        Button(String(localized: "重新检查资料", bundle: .kit)) { Task { await store.refresh() } }
                    }
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
                                .accessibilityLabel(Text("正在检查官方资料", bundle: .kit))
                        } else {
                            Label { Text("更新官方资料", bundle: .kit) } icon: { Image(systemName: "arrow.clockwise") }
                        }
                    }
                    .disabled(store.isRefreshing)
                    .accessibilityIdentifier("officialRefreshToolbarButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsFilters = true
                    } label: {
                        Label {
                            Text("筛选", bundle: .kit)
                        } icon: {
                            Image(systemName: sheetFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                    }
                    .accessibilityIdentifier("dashboardFilterButton")
                    .accessibilityValue(sheetFilterCount > 0 ? Text("已应用 \(sheetFilterCount) 个筛选条件", bundle: .kit) : Text(verbatim: ""))
                }
            }
            .sheet(isPresented: $showsFilters) {
                DashboardFiltersView(filters: filters, scope: scope, groupsByFranchise: groupsByFranchise)
                    .presentationDetents([.medium, .large])
            }
            .task {
                // The upcoming tab owns the daily refresh; the past tab only fills an empty store.
                if scope == .upcoming || store.bundles.isEmpty { await store.load() }
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

    private func errorLabel(_ error: String) -> some View {
        Label {
            Text(verbatim: error)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(isErrorExpanded ? nil : 2)
        .contentShape(.rect)
        .onTapGesture { isErrorExpanded.toggle() }
    }

    @ViewBuilder
    private var errorRetryButton: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Group {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("正在检查官方资料", bundle: .kit))
                } else {
                    Text("重试", bundle: .kit)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .font(.footnote)
        .disabled(store.isRefreshing)
    }

    private var errorDismissButton: some View {
        Button {
            isErrorExpanded = false
            store.dismissError()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text("关闭", bundle: .kit))
    }

    @ViewBuilder
    private func dashboardEmptyState(summaries: [DashboardEventSummary]) -> some View {
        if store.isLoading && store.bundles.isEmpty {
            ProgressView { Text("正在载入资料…", bundle: .kit) }
        } else if summaries.isEmpty {
            if store.bundles.isEmpty {
                if store.isRefreshing {
                    ProgressView {
                        Text("正在检查官方资料…", bundle: .kit)
                    }
                } else if let error = store.errorMessage {
                    ContentUnavailableView {
                        Label { Text("无法更新公演资料", bundle: .kit) } icon: { Image(systemName: "exclamationmark.triangle") }
                    } description: {
                        Text(verbatim: error)
                    } actions: {
                        Button(String(localized: "重试", bundle: .kit)) { Task { await store.refresh() } }
                    }
                } else {
                    ContentUnavailableView {
                        Label { Text("尚未获取公演资料", bundle: .kit) } icon: { Image(systemName: "calendar.badge.exclamationmark") }
                    } description: {
                        Text("下拉或点击更新按钮，直接检查官方页面。", bundle: .kit)
                    }
                }
            } else if !filters.wrappedValue.searchText.isEmpty {
                ContentUnavailableView.search(text: filters.wrappedValue.searchText)
            } else if scope == .past, !store.bundles.contains(where: { store.scope(of: $0) == .past }) {
                ContentUnavailableView {
                    Label { Text("还没有已结束的演出", bundle: .kit) } icon: { Image(systemName: "clock.arrow.circlepath") }
                } description: {
                    Text("演出结束后会移到这里。", bundle: .kit)
                }
            } else {
                ContentUnavailableView {
                    Label { Text(scope == .past ? "没有符合条件的往期演出" : "没有符合条件的演出", bundle: .kit) } icon: { Image(systemName: "calendar") }
                } description: {
                    Text("请选择其他年份、月份，或调整筛选条件。", bundle: .kit)
                } actions: {
                    Button(String(localized: "清除筛选", bundle: .kit)) { clearAllFilters() }
                }
            }
        }
    }

    private func clearAllFilters() {
        filters.wrappedValue = DashboardFilters()
    }

    /// Count of filters that only live in the filter sheet (as opposed to the inline
    /// year/month row), so the toolbar button can show the filled icon and announce how many.
    private var sheetFilterCount: Int {
        let value = filters.wrappedValue
        return [value.franchise != nil, value.group != nil, value.eventType != nil,
                value.onlyFollowed, value.onlyWithPendingAction, value.dateRange != nil]
            .filter { $0 }.count
    }

    private var yearOptions: [Int] {
        Array(Set(store.availableYears(in: scope) + [filters.wrappedValue.year].compactMap { $0 })).sorted()
    }

    /// Groups in this scope's cached bundles, grouped by franchise so the filter sheet can
    /// narrow its group picker once a franchise is selected.
    private var groupsByFranchise: [Franchise: [String]] {
        Dictionary(grouping: store.bundles.filter { store.scope(of: $0) == scope }, by: { $0.event.franchise })
            .mapValues { bundles in Array(Set(bundles.flatMap { $0.event.groups })).sorted() }
    }

    private var yearMenuTitle: String {
        if let year = filters.wrappedValue.year {
            return String(localized: "\(String(year))年", bundle: .kit)
        }
        return String(localized: "全部年份", bundle: .kit)
    }

    /// "更新于 X 前" from the last successful refresh, or empty before the first one.
    /// `Text(date, style: .relative)` self-updates on a timer instead of formatting a fixed
    /// string in `body` with `RelativeDateTimeFormatter`.
    @ViewBuilder
    private var freshnessText: some View {
        if let date = store.lastRefreshedAt {
            Text("更新于\(Text(date, style: .relative))前", bundle: .kit)
        }
    }

    /// Year and month menus sharing one row.
    private var yearMonthRow: some View {
        HStack(spacing: 12) {
            calendarIcon
            yearMenu
            monthMenu
            Spacer()
        }
    }

    /// Year and month menus on their own rows, for accessibility sizes where two capsule
    /// menus no longer fit next to each other.
    private var yearMonthStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                calendarIcon
                yearMenu
            }
            monthMenu
        }
    }

    private func dashboardFilters(matchCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // At accessibility text sizes the two menus no longer fit on one line, so they
            // drop to their own rows directly instead of relying on `ViewThatFits`, which can
            // measure both branches at those sizes.
            if dynamicTypeSize.isAccessibilitySize {
                yearMonthStack
            } else {
                ViewThatFits(in: .horizontal) {
                    yearMonthRow
                    yearMonthStack
                }
            }

            freshnessText
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)

            if isAnyFilterActive {
                filterSummaryRow(matchCount: matchCount)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 8)
    }

    /// Whether any filter — sheet, year, month or search — is currently narrowing the list,
    /// so the summary/clear-all row only shows up when it has something to say.
    private var isAnyFilterActive: Bool {
        sheetFilterCount > 0 || filters.wrappedValue.year != nil || filters.wrappedValue.month != nil || !filters.wrappedValue.searchText.isEmpty
    }

    /// Count of every active filter, one per condition (sheet filters, year, month, search),
    /// for the "已应用 N 个条件" summary.
    private var activeFilterCount: Int {
        sheetFilterCount
            + (filters.wrappedValue.year != nil ? 1 : 0)
            + (filters.wrappedValue.month != nil ? 1 : 0)
            + (filters.wrappedValue.searchText.isEmpty ? 0 : 1)
    }

    private func filterSummaryRow(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("已应用 \(activeFilterCount) 个条件，显示 \(matchCount) 场公演", bundle: .kit)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(String(localized: "清除全部筛选", bundle: .kit)) { clearAllFilters() }
                .font(.caption)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .accessibilityIdentifier("clearAllFiltersButton")
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
    }

    private var calendarIcon: some View {
        Image(systemName: "calendar")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var yearMenu: some View {
        Menu {
            Picker(selection: filters.year) {
                Text("全部年份", bundle: .kit).tag(Int?.none)
                ForEach(yearOptions, id: \.self) { year in
                    Text("\(String(year))年", bundle: .kit).tag(Int?.some(year))
                }
            } label: {
                Text("年份", bundle: .kit)
            }
        } label: {
            filterMenuLabel(title: yearMenuTitle, isActive: filters.wrappedValue.year != nil)
        }
        .accessibilityIdentifier("eventYearPicker")
    }

    private var monthMenu: some View {
        Menu {
            Picker(selection: filters.month) {
                Text("全部月份", bundle: .kit).tag(Int?.none)
                ForEach(monthOptions, id: \.self) { month in
                    Text("\(month)月", bundle: .kit).tag(Int?.some(month))
                }
            } label: {
                Text("月份", bundle: .kit)
            }
        } label: {
            filterMenuLabel(title: monthMenuTitle, isActive: filters.wrappedValue.month != nil)
        }
        .accessibilityIdentifier("eventMonthPicker")
    }

    private var monthOptions: [Int] {
        Array(Set(store.availableMonths(in: scope) + [filters.wrappedValue.month].compactMap { $0 })).sorted()
    }

    private var monthMenuTitle: String {
        if let month = filters.wrappedValue.month {
            return String(localized: "\(month)月", bundle: .kit)
        }
        return String(localized: "全部月份", bundle: .kit)
    }

    /// Shared capsule styling for the year and month menus' labels, so both look identical.
    private func filterMenuLabel(title: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .font(.subheadline.weight(isActive ? .semibold : .regular))
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    /// Replaces the whole navigation stack so a reminder or notification lands on
    /// its event even when another event's detail is already open, per DESIGN.md 七.3.
    private func consumeDeepLink() {
        // The router always switches to the upcoming tab for a deep link, so only that
        // instance may consume it. Peek before consuming: a push tapped at cold launch
        // arrives while `store.load()` is still running, and consuming it here would
        // discard it before the bundle exists.
        guard scope == .upcoming, let target = router.pendingDeepLink,
              store.bundles.contains(where: { $0.event.id == target.eventID }) else { return }
        showsFilters = false
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

/// Puts the year/month filter row in the top safe area. iOS 26 gets the native `safeAreaBar`
/// chrome and material; earlier OSes fall back to `safeAreaInset` with an explicit `.bar`
/// background so the filter row never floats over content without a backdrop.
private struct FilterBarInset<FilterContent: View>: ViewModifier {
    let filterContent: FilterContent
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.safeAreaBar(edge: .top) { filterContent }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { filterContent.background(.bar) }
        }
    }
}

struct DashboardFiltersView: View {
    @Binding var filters: DashboardFilters
    let scope: DashboardScope
    let groupsByFranchise: [Franchise: [String]]
    @Environment(\.dismiss) private var dismiss

    /// Groups for the currently selected franchise, or the sorted union of every franchise's
    /// groups when none is selected.
    private var groupOptions: [String] {
        if let franchise = filters.franchise {
            return groupsByFranchise[franchise] ?? []
        }
        return Array(Set(groupsByFranchise.values.flatMap { $0 })).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $filters.franchise) {
                        Text("全部", bundle: .kit).tag(Franchise?.none)
                        Text(verbatim: "BanG Dream!").tag(Franchise?.some(.bangdream))
                        Text(verbatim: "Love Live!").tag(Franchise?.some(.lovelive))
                    } label: {
                        Text("企划", bundle: .kit)
                    }
                }
                Section {
                    Picker(selection: $filters.group) {
                        Text("全部", bundle: .kit).tag(String?.none)
                        ForEach(groupOptions, id: \.self) { group in
                            Text(verbatim: group).tag(String?.some(group))
                        }
                    } label: {
                        Text("团体", bundle: .kit)
                    }
                    Picker(selection: $filters.eventType) {
                        Text("全部", bundle: .kit).tag(EventType?.none)
                        Text(verbatim: "Live").tag(EventType?.some(.live))
                        Text(verbatim: "Fan Meeting").tag(EventType?.some(.fanMeeting))
                        Text("上映会", bundle: .kit).tag(EventType?.some(.screening))
                        Text("其他", bundle: .kit).tag(EventType?.some(.other))
                    } label: {
                        Text("活动类型", bundle: .kit)
                    }
                    Toggle(isOn: $filters.onlyFollowed) { Text("只看关注", bundle: .kit) }
                    Toggle(isOn: $filters.onlyWithPendingAction) { Text("只看有待办事项", bundle: .kit) }
                } header: {
                    Text("条件", bundle: .kit)
                }
                Section {
                    Toggle(isOn: Binding(get: { filters.dateRange != nil }, set: { enabled in
                        filters.dateRange = enabled ? defaultDateRange() : nil
                    })) {
                        Text("限制日期范围", bundle: .kit)
                    }
                    if let range = filters.dateRange {
                        DatePicker(selection: Binding(get: { range.lowerBound }, set: { value in
                            filters.dateRange = min(value, range.upperBound)...range.upperBound
                        }), in: ...range.upperBound, displayedComponents: .date) {
                            Text("开始", bundle: .kit)
                        }
                        DatePicker(selection: Binding(get: { range.upperBound }, set: { value in
                            filters.dateRange = range.lowerBound...max(value, range.lowerBound)
                        }), in: range.lowerBound..., displayedComponents: .date) {
                            Text("结束", bundle: .kit)
                        }
                    }
                } header: {
                    Text("日期", bundle: .kit)
                }
            }
            .navigationTitle(Text("筛选", bundle: .kit))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "重置", bundle: .kit)) { resetSheetFilters() }
                        .accessibilityHint(Text("只重置此处的条件，不影响年份、月份和搜索", bundle: .kit))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("完成", bundle: .kit) }
                }
            }
            .onChange(of: filters.franchise) { _, _ in
                if let group = filters.group, !groupOptions.contains(group) { filters.group = nil }
            }
        }
    }

    /// Upcoming defaults to today...+1 year; past defaults to -1 year...today. Falls back to
    /// `today` on either end if `Calendar.current.date(byAdding:)` fails, rather than force-unwrapping.
    private func defaultDateRange() -> ClosedRange<Date> {
        let today = Calendar.current.startOfDay(for: Date())
        switch scope {
        case .upcoming:
            let upper = Calendar.current.date(byAdding: .year, value: 1, to: today) ?? today
            return today...upper
        case .past:
            let lower = Calendar.current.date(byAdding: .year, value: -1, to: today) ?? today
            return lower...today
        }
    }

    /// Resets only the fields this sheet owns; year/month live in the dashboard's inline row
    /// and are left untouched.
    private func resetSheetFilters() {
        filters.franchise = nil
        filters.group = nil
        filters.eventType = nil
        filters.onlyFollowed = false
        filters.onlyWithPendingAction = false
        filters.dateRange = nil
    }
}
