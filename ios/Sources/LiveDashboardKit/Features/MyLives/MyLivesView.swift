import SwiftUI

public struct MyLivesView: View {
    @Bindable var dashboardStore: DashboardStore
    let userDataStore: UserDataStore
    let reminderService: ReminderScheduling
    let repository: LiveRepository
    let installationService: InstallationService
    let assistant: AssistantCoordinator
    @State private var selectedBundle: LiveEventBundle?

    public init(dashboardStore: DashboardStore, userDataStore: UserDataStore, reminderService: ReminderScheduling, repository: LiveRepository, installationService: InstallationService, assistant: AssistantCoordinator) {
        self.dashboardStore = dashboardStore; self.userDataStore = userDataStore; self.reminderService = reminderService; self.repository = repository; self.installationService = installationService; self.assistant = assistant
    }

    public var body: some View {
        NavigationStack {
            List {
                let followed = dashboardStore.bundles.filter { userDataStore.state(for: $0.event.id).isFollowed }
                ForEach(followed, id: \.event.id) { bundle in
                    Button { selectedBundle = bundle } label: {
                        VStack(alignment: .leading) {
                            Text(bundle.event.officialTitle).font(.headline)
                            let state = userDataStore.state(for: bundle.event.id)
                            Text(state.planningToAttend ? "计划参加" : "已关注").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if followed.isEmpty { ContentUnavailableView("还没有关注的公演", systemImage: "star") }
            }
            .navigationTitle("我的")
            .navigationDestination(item: $selectedBundle) { bundle in
                LiveDetailView(bundle: bundle, initialPerformanceID: userDataStore.selectedPerformanceID(eventID: bundle.event.id), userDataStore: userDataStore, reminderService: reminderService, repository: repository, installationService: installationService, assistant: assistant, onBundleRefresh: dashboardStore.acceptRefreshedBundle)
            }
            .task { if dashboardStore.bundles.isEmpty { await dashboardStore.load() } }
        }
    }
}
