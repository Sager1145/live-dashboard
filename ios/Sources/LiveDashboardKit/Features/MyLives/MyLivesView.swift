import SwiftUI
import LiveIngestionCore

public struct MyLivesView: View {
    @Bindable var dashboardStore: DashboardStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let repository: LiveRepository
    let installationService: InstallationService
    let assistant: AssistantCoordinator
    let externalStore: ExternalDataStore?
    /// Optional so this view keeps working wherever it isn't wired to the shared router yet;
    /// when present, the empty state offers a way back to the dashboard to follow something.
    let router: AppRouter?
    @State private var path: [DetailRoute] = []

    public init(dashboardStore: DashboardStore, userDataStore: UserDataStore, reminderService: ReminderScheduling, repository: LiveRepository, installationService: InstallationService, assistant: AssistantCoordinator, externalStore: ExternalDataStore? = nil, router: AppRouter? = nil) {
        self.dashboardStore = dashboardStore
        self.userDataStore = userDataStore
        self.reminderService = reminderService
        self.repository = repository
        self.installationService = installationService
        self.assistant = assistant
        self.externalStore = externalStore
        self.router = router
    }

    /// Every followed event's scope, looked up once per body pass instead of once per summary
    /// (`scope(ofEventID:)` is a linear scan over `bundles`, so calling it per-summary is O(n²)).
    private func scopesByEventID() -> [String: DashboardScope] {
        Dictionary(uniqueKeysWithValues: dashboardStore.bundles.map { ($0.event.id, dashboardStore.scope(of: $0)) })
    }

    /// `followed` split into upcoming/past sections in one pass; order within each is preserved.
    private func splitFollowed(_ followed: [DashboardEventSummary]) -> (upcoming: [DashboardEventSummary], past: [DashboardEventSummary]) {
        let scopes = scopesByEventID()
        var upcoming: [DashboardEventSummary] = []
        var past: [DashboardEventSummary] = []
        for summary in followed {
            if scopes[summary.id] == .past { past.append(summary) } else { upcoming.append(summary) }
        }
        return (upcoming, past)
    }

    public var body: some View {
        // Computed once per body pass: `followedSummaries()` and the scope split each walk
        // `bundles`, so both are done exactly once here rather than once per section/overlay.
        let followed = dashboardStore.followedSummaries()
        let split = splitFollowed(followed)
        NavigationStack(path: $path) {
            List {
                if !split.upcoming.isEmpty {
                    Section {
                        ForEach(split.upcoming) { summary in
                            NavigationLink(value: DetailRoute(eventID: summary.id)) {
                                row(for: summary)
                            }
                        }
                    } header: {
                        Text("即将到来", bundle: .kit)
                    }
                }
                if !split.past.isEmpty {
                    Section {
                        ForEach(split.past) { summary in
                            NavigationLink(value: DetailRoute(eventID: summary.id)) {
                                row(for: summary)
                            }
                        }
                    } header: {
                        Text("已结束", bundle: .kit)
                    }
                }
            }
            .overlay {
                emptyStateOverlay(followed: followed)
            }
            .safeAreaInset(edge: .bottom) {
                if dashboardStore.errorMessage != nil, !dashboardStore.bundles.isEmpty {
                    refreshFailureBar
                }
            }
            .navigationTitle(Text("我的", bundle: .kit))
            .navigationDestination(for: DetailRoute.self) { route in
                if let bundle = dashboardStore.bundles.first(where: { $0.event.id == route.eventID }) {
                    LiveDetailView(bundle: bundle, initialPerformanceID: route.performanceID ?? userDataStore.selectedPerformanceID(eventID: bundle.event.id), initialTab: route.tab, userDataStore: userDataStore, reminderService: reminderService, repository: repository, installationService: installationService, assistant: assistant, externalStore: externalStore, onBundleRefresh: dashboardStore.acceptRefreshedBundle)
                        .id(route)
                } else if dashboardStore.isLoading || dashboardStore.isRefreshing {
                    ProgressView { Text("正在载入资料…", bundle: .kit) }
                } else {
                    ContentUnavailableView {
                        Label { Text("公演资料已不在本机缓存中", bundle: .kit) } icon: { Image(systemName: "calendar.badge.exclamationmark") }
                    } description: {
                        Text("资料可能已被移除，或尚未载入。", bundle: .kit)
                    } actions: {
                        Button(String(localized: "重新检查资料", bundle: .kit)) { Task { await dashboardStore.refresh() } }
                    }
                }
            }
            .task { if dashboardStore.bundles.isEmpty { await dashboardStore.load() } }
            .refreshable { await dashboardStore.refresh() }
        }
    }

    @ViewBuilder
    private func emptyStateOverlay(followed: [DashboardEventSummary]) -> some View {
        if dashboardStore.bundles.isEmpty && dashboardStore.errorMessage == nil {
            // Data has never loaded yet (regardless of `isLoading`/`isRefreshing` timing), so
            // this is still "loading", never "no follows".
            ProgressView { Text("正在载入资料…", bundle: .kit) }
        } else if dashboardStore.bundles.isEmpty, let error = dashboardStore.errorMessage {
            ContentUnavailableView {
                Label { Text("无法更新公演资料", bundle: .kit) } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: error)
            } actions: {
                Button(String(localized: "重试", bundle: .kit)) { Task { await dashboardStore.refresh() } }
            }
        } else if followed.isEmpty {
            ContentUnavailableView {
                Label { Text("还没有关注的公演", bundle: .kit) } icon: { Image(systemName: "star") }
            } description: {
                Text("打开演出详情并点击关注，就会出现在这里。", bundle: .kit)
            } actions: {
                if let router {
                    Button(String(localized: "浏览演出", bundle: .kit)) { router.selectedRootTab = .dashboard }
                }
            }
        }
    }

    private var refreshFailureBar: some View {
        HStack(spacing: 12) {
            Label {
                Text("更新失败，显示的是已保存的资料", bundle: .kit)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                Task { await dashboardStore.refresh() }
            } label: {
                Text("重试", bundle: .kit)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .font(.footnote)
            .disabled(dashboardStore.isRefreshing)
            Button {
                dashboardStore.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel(Text("关闭", bundle: .kit))
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func row(for summary: DashboardEventSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: summary.officialTitle)
                .font(.headline)
            Text(verbatim: dateText(for: summary))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let deadline = summary.nextDeadline {
                let zone = EventFormatting.timeZone(identifier: summary.timeZoneIdentifier, fallback: .current)
                let label = summary.currentRoundLabel.map { $0 + "：" } ?? ""
                Text("下一事项：\(label)\(EventFormatting.dateTime(deadline, in: zone))截止", bundle: .kit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "date range · venue", the date including its year when it isn't the current year.
    private func dateText(for summary: DashboardEventSummary) -> String {
        let zone = EventFormatting.timeZone(identifier: summary.timeZoneIdentifier, fallback: .current)
        var parts: [String] = []
        if let first = summary.firstLocalDate, let firstDate = EventFormatting.parseISODate(first, in: zone) {
            if let last = summary.lastLocalDate, last != first, let lastDate = EventFormatting.parseISODate(last, in: zone) {
                parts.append(EventFormatting.dateRange(firstDate, lastDate, in: zone))
            } else {
                let includesYear = Calendar.current.component(.year, from: firstDate) != Calendar.current.component(.year, from: Date())
                parts.append(EventFormatting.date(firstDate, in: zone, includesYear: includesYear))
            }
        }
        if !summary.venueSummary.isEmpty { parts.append(summary.venueSummary) }
        return parts.joined(separator: " · ")
    }
}
