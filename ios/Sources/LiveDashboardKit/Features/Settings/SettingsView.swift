import SwiftUI
import UIKit
import UserNotifications
import LiveIngestionCore

public struct SettingsView: View {
    @Bindable var dashboardStore: DashboardStore
    let userDataStore: UserDataStore
    let assistant: AssistantCoordinator
    let externalStore: ExternalDataStore?
    let reminderService: ReminderScheduling
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("translation.targetLanguage") private var translationTargetRaw = TranslationTargetLanguage.followApp.rawValue
    @Environment(\.openURL) private var openURL

    @MainActor
    public init(dashboardStore: DashboardStore, userDataStore: UserDataStore, assistant: AssistantCoordinator, externalStore: ExternalDataStore? = nil, reminderService: ReminderScheduling = ReminderService()) {
        self.dashboardStore = dashboardStore
        self.userDataStore = userDataStore
        self.assistant = assistant
        self.externalStore = externalStore
        self.reminderService = reminderService
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { userDataStore.showsDeviceLocalTime }, set: { userDataStore.setDeviceLocalTimeEnabled($0) })) {
                        Text("同时显示设备本地时间", bundle: .kit)
                    }
                    NavigationLink {
                        CardSettingsView(userDataStore: userDataStore)
                    } label: {
                        Text("全局卡片设置", bundle: .kit)
                    }
                        .accessibilityIdentifier("globalCardSettingsLink")
                } header: {
                    Text("显示与卡片", bundle: .kit)
                }
                Section {
                    Picker(selection: $translationTargetRaw) {
                        ForEach(TranslationTargetLanguage.allCases, id: \.rawValue) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    } label: {
                        Text("目标语言", bundle: .kit)
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("translationTargetLanguagePicker")
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Text("在系统设置中更改 App 语言", bundle: .kit)
                    }
                } header: {
                    Text("语言与翻译", bundle: .kit)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("翻译在设备上完成，不上传官网内容；首次使用某个语言时系统会提示下载语言包。翻译需要手动点击，默认始终显示官网原文。", bundle: .kit)
                        Text("在系统设置中为本 App 选择简体中文、繁體中文、English 或 日本語。", bundle: .kit)
                    }
                }
                Section {
                    LabeledContent {
                        Text(notificationStatusText)
                    } label: {
                        Text("通知", bundle: .kit)
                    }
                    if notificationStatus == .denied {
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            Text("去设置开启", bundle: .kit)
                        }
                    }
                } header: {
                    Text("提醒", bundle: .kit)
                } footer: {
                    Text("截止提醒由本机通知发送。App 关闭时仍会按已保存的时间提醒，但无法自动发现官方之后修改的截止时间；再次打开 App 更新资料后请重新设置提醒。", bundle: .kit)
                }
                Section {
                    NavigationLink {
                        DataManagementView(dashboardStore: dashboardStore)
                    } label: {
                        LabeledContent {
                            if let lastRefreshedAt = dashboardStore.lastRefreshedAt {
                                Text(lastRefreshedAt.formatted(.relative(presentation: .named)))
                            } else {
                                Text("尚未完成", bundle: .kit)
                            }
                        } label: {
                            Text("资料管理", bundle: .kit)
                        }
                    }
                    .accessibilityIdentifier("dataManagementLink")
                } header: {
                    Text("资料管理", bundle: .kit)
                } footer: {
                    Text("公演资料下载后缓存在本机；关注、手动申请状态、提醒和卡片设置也保存在本机。", bundle: .kit)
                }
            }
            .navigationTitle(Text("设置", bundle: .kit))
            .task { notificationStatus = await reminderService.authorizationStatus() }
        }
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: String(localized: "已开启", bundle: .kit)
        case .denied: String(localized: "已关闭", bundle: .kit)
        case .notDetermined: String(localized: "未设置", bundle: .kit)
        @unknown default: String(localized: "未知", bundle: .kit)
        }
    }
}

/// Second-level settings page: on-demand official data refresh and manual history backfill.
private struct DataManagementView: View {
    @Bindable var dashboardStore: DashboardStore
    @State private var refreshMessage: String?
    @State private var refreshSucceeded = true
    @State private var historyStart: Date
    @State private var historyEnd: Date
    @State private var historyMessage: String?
    @State private var historySucceeded = true

    init(dashboardStore: DashboardStore) {
        self.dashboardStore = dashboardStore
        let today = Date()
        self._historyEnd = State(initialValue: today)
        self._historyStart = State(initialValue: Calendar.autoupdatingCurrent.date(byAdding: .month, value: -6, to: today) ?? today)
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await refreshOfficialData() }
                } label: {
                    if dashboardStore.isRefreshing && !dashboardStore.isFetchingHistory {
                        HStack {
                            ProgressView()
                            Text("正在同步资料，请稍候…", bundle: .kit)
                        }
                    } else {
                        Label { Text("立即同步资料", bundle: .kit) } icon: { Image(systemName: "arrow.clockwise") }
                    }
                }
                .disabled(dashboardStore.isRefreshing)
                .accessibilityIdentifier("officialRefreshButton")

                if let lastRefreshedAt = dashboardStore.lastRefreshedAt {
                    LabeledContent {
                        Text(lastRefreshedAt.formatted(.relative(presentation: .named)))
                    } label: {
                        Text("上次检查", bundle: .kit)
                    }
                    .accessibilityValue(Text(lastRefreshedAt, format: .dateTime))
                } else {
                    LabeledContent {
                        Text("尚未完成", bundle: .kit)
                    } label: {
                        Text("上次检查", bundle: .kit)
                    }
                }
                if let refreshMessage {
                    Label {
                        Text(verbatim: refreshMessage)
                    } icon: {
                        Image(systemName: refreshSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(refreshSucceeded ? Color.statusPositive : Color.statusCritical)
                }
            } header: {
                Text("资料更新", bundle: .kit)
            } footer: {
                Text("资料每小时由服务器统一更新。App 在前台每小时同步一次，回到前台时检查是否需要同步；也可随时手动同步。离线时保留上次保存的资料。", bundle: .kit)
            }
            Section {
                DatePicker(selection: $historyStart, in: ...Date(), displayedComponents: .date) {
                    Text("开始日期", bundle: .kit)
                }
                    .accessibilityIdentifier("historyStartPicker")
                    .onChange(of: historyStart) { _, newValue in
                        if historyEnd < newValue { historyEnd = newValue }
                    }
                DatePicker(selection: $historyEnd, in: historyStart...Date(), displayedComponents: .date) {
                    Text("结束日期", bundle: .kit)
                }
                    .accessibilityIdentifier("historyEndPicker")
                Button {
                    Task { await fetchHistory() }
                } label: {
                    if dashboardStore.isFetchingHistory {
                        HStack {
                            ProgressView()
                            Text("正在查找过往公演…", bundle: .kit)
                        }
                    } else {
                        Label { Text("查找该区间的公演", bundle: .kit) } icon: { Image(systemName: "clock.arrow.circlepath") }
                    }
                }
                .disabled(dashboardStore.isRefreshing || historyEnd < historyStart)
                .accessibilityIdentifier("historyFetchButton")

                if let historyMessage {
                    Label {
                        Text(verbatim: historyMessage)
                    } icon: {
                        Image(systemName: historySucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(historySucceeded ? Color.statusPositive : Color.statusCritical)
                }
            } header: {
                Text("历史资料", bundle: .kit)
            } footer: {
                Text("同步已发布的资料，并查找所选日期区间内的公演（含已结束的）。只能查找已发布目录中的公演。", bundle: .kit)
            }
        }
        .navigationTitle(Text("资料管理", bundle: .kit))
    }

    private func refreshOfficialData() async {
        await dashboardStore.refresh()
        if let error = dashboardStore.errorMessage {
            refreshSucceeded = false
            refreshMessage = error
        } else {
            refreshSucceeded = true
            refreshMessage = String(localized: "资料已同步", bundle: .kit)
        }
    }

    private func fetchHistory() async {
        let summary = await dashboardStore.fetchHistory(from: historyStart, to: historyEnd)
        if let error = dashboardStore.errorMessage {
            historySucceeded = false
            historyMessage = error
        } else if let summary, summary.fetchedCount > 0 {
            historySucceeded = true
            historyMessage = String(localized: "已找到 \(summary.fetchedCount) 场公演（\(summary.start) 至 \(summary.end)）", bundle: .kit)
        } else if summary != nil {
            historySucceeded = true
            historyMessage = String(localized: "未找到该区间的公演", bundle: .kit)
        }
    }
}
