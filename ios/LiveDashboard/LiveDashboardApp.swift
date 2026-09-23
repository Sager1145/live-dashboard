import SwiftUI
import LiveDashboardKit
import UserNotifications

@main
struct LiveDashboardApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            AppShell(dependencies: dependencies)
                .onOpenURL { dependencies.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await dependencies.dashboardStore.refreshIfNeeded() }
                }
        }
    }
}

@MainActor @Observable
final class AppDependencies {
    let repository: LocalLiveRepository
    let userDataStore: UserDataStore
    let reminderService: ReminderService
    let installationService: InstallationService
    let dashboardStore: DashboardStore
    let assistant = AssistantCoordinator()
    let router = AppRouter()

    init() {
        repository = LocalLiveRepository()
        userDataStore = UserDataStore()
        reminderService = ReminderService()
        installationService = InstallationService()
        PushAppDelegate.router = router
        dashboardStore = DashboardStore(repository: repository, userDataStore: userDataStore)
        dashboardStore.assistant = assistant
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func argument(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let eventID = argument(after: "-detailEventID") {
            router.navigate(to: DeepLinkTarget(eventID: eventID, performanceID: argument(after: "-detailPerformanceID"), tab: DetailTab(rawValue: argument(after: "-detailTab") ?? "overview") ?? .overview))
        }
        #endif
    }

    func handle(url: URL) {
        guard url.scheme == "live-dashboard" else { return }
        let pieces = url.pathComponents.filter { $0 != "/" }
        let eventID = url.host == "event" ? pieces.first : (pieces.first == "event" ? pieces.dropFirst().first : nil)
        guard let eventID else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        router.navigate(to: DeepLinkTarget(eventID: eventID, performanceID: value("performanceID"), tab: DetailTab(rawValue: value("tab") ?? "overview") ?? .overview, cardType: value("cardType").flatMap(CardType.init(rawValue:)), entityID: value("entityID")))
    }
}

@MainActor
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var router: AppRouter?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let eventID = info["eventID"] as? String else { return }
        let performanceID = info["performanceID"] as? String
        let tab = DetailTab(rawValue: info["tab"] as? String ?? "overview") ?? .overview
        var cardType = (info["cardType"] as? String).flatMap(CardType.init(rawValue:))
        var entityID = info["entityID"] as? String
        if let cardKey = info["cardKey"] as? String {
            let parts = cardKey.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                entityID = parts[1]
                switch parts[0] {
                case "ticket-round": cardType = .ticketRound
                case "goods-campaign": cardType = .goodsCampaign
                case "event-seating": cardType = .eventSeatingMap
                default: break
                }
            }
        }
        let target = DeepLinkTarget(eventID: eventID, performanceID: performanceID, tab: tab, cardType: cardType, entityID: entityID)
        await MainActor.run { Self.router?.navigate(to: target) }
    }
}

struct AppShell: View {
    @Bindable var dependencies: AppDependencies

    var body: some View {
        @Bindable var router = dependencies.router
        TabView(selection: $router.selectedRootTab) {
            Tab(value: RootTab.dashboard) {
                DashboardView(store: dependencies.dashboardStore, userDataStore: dependencies.userDataStore, reminderService: dependencies.reminderService, repository: dependencies.repository, router: dependencies.router, installationService: dependencies.installationService, assistant: dependencies.assistant)
            } label: {
                Label { Text("演出", bundle: .kit) } icon: { Image(systemName: "calendar") }
            }
            Tab(value: RootTab.pastLives) {
                DashboardView(store: dependencies.dashboardStore, userDataStore: dependencies.userDataStore, reminderService: dependencies.reminderService, repository: dependencies.repository, router: dependencies.router, installationService: dependencies.installationService, assistant: dependencies.assistant, scope: .past)
            } label: {
                Label { Text("往期", bundle: .kit) } icon: { Image(systemName: "clock.arrow.circlepath") }
            }
            Tab(value: RootTab.myLives) {
                MyLivesView(dashboardStore: dependencies.dashboardStore, userDataStore: dependencies.userDataStore, reminderService: dependencies.reminderService, repository: dependencies.repository, installationService: dependencies.installationService, assistant: dependencies.assistant, router: dependencies.router)
            } label: {
                Label { Text("我的", bundle: .kit) } icon: { Image(systemName: "star") }
            }
            Tab(value: RootTab.settings) {
                SettingsView(dashboardStore: dependencies.dashboardStore, userDataStore: dependencies.userDataStore, assistant: dependencies.assistant)
            } label: {
                Label { Text("设置", bundle: .kit) } icon: { Image(systemName: "gearshape") }
            }
        }
        .task { await dependencies.assistant.load() }
    }
}
