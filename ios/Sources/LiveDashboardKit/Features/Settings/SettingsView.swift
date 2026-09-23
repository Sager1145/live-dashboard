import SwiftUI
import UIKit
import UserNotifications

public struct SettingsView: View {
    @Bindable var dashboardStore: DashboardStore
    let userDataStore: UserDataStore
    let assistant: AssistantCoordinator
    let reminderService: ReminderScheduling
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("translation.targetLanguage") private var translationTargetRaw = TranslationTargetLanguage.followApp.rawValue
    @Environment(\.openURL) private var openURL

    public init(dashboardStore: DashboardStore, userDataStore: UserDataStore, assistant: AssistantCoordinator, reminderService: ReminderScheduling = ReminderService()) {
        self.dashboardStore = dashboardStore
        self.userDataStore = userDataStore
        self.assistant = assistant
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
                        AssistantSettingsView(assistant: assistant)
                    } label: {
                        LabeledContent {
                            Text(assistantStatusText)
                        } label: {
                            Text("ChatGPT 助手", bundle: .kit)
                        }
                    }
                    .accessibilityIdentifier("assistantSettingsLink")
                } header: {
                    Text("ChatGPT 助手", bundle: .kit)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI 会重新分析官网，填写公演、票务、座位与周边字段，并独立保存结果。", bundle: .kit)
                        Text("若登录 ChatGPT 助手，会将官网页面文字发送到 OpenAI 生成摘要；凭据保存在本机钥匙串。", bundle: .kit)
                    }
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
                    Text("公演资料、关注、手动申请状态、提醒和卡片设置都保存在本机。检查官方资料不需要账号或服务器安装身份。", bundle: .kit)
                }
            }
            .navigationTitle(Text("设置", bundle: .kit))
            .task { notificationStatus = await reminderService.authorizationStatus() }
        }
    }

    private var assistantStatusText: String {
        switch assistant.account {
        case .signedOut: String(localized: "未登录", bundle: .kit)
        case .apiKey(let hint): String(localized: "API Key \(hint)", bundle: .kit)
        case .chatGPT(let email, let accountID): String(localized: "ChatGPT \(email ?? accountID ?? String(localized: "已登录", bundle: .kit))", bundle: .kit)
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
                            Text("正在检查官方资料…", bundle: .kit)
                        }
                    } else {
                        Label { Text("立即检查官方资料", bundle: .kit) } icon: { Image(systemName: "arrow.clockwise") }
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
                Text("每天首次打开或跨天回到前台时自动整理官网资料，范围从手机当前日期往前一个自然月开始，包含所有未来公演。更早的已存公演会保留，但不再自动整理。", bundle: .kit)
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
                            Text("正在抓取过往公演…", bundle: .kit)
                        }
                    } else {
                        Label { Text("抓取该区间的公演", bundle: .kit) } icon: { Image(systemName: "clock.arrow.circlepath") }
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
                Text("手动抓取官网在所选日期区间内举办过的公演（含已结束的），并保存到本机。区间越长抓取时间越久。抓取结果不会影响每日自动整理。", bundle: .kit)
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
            refreshMessage = String(localized: "官方资料已更新", bundle: .kit)
        }
    }

    private func fetchHistory() async {
        let summary = await dashboardStore.fetchHistory(from: historyStart, to: historyEnd)
        if let error = dashboardStore.errorMessage {
            historySucceeded = false
            historyMessage = error
        } else if let summary, summary.fetchedCount > 0 {
            historySucceeded = true
            historyMessage = String(localized: "已抓取 \(summary.fetchedCount) 场公演（\(summary.start) 至 \(summary.end)）", bundle: .kit)
        } else if summary != nil {
            historySucceeded = true
            historyMessage = String(localized: "未找到该区间的公演", bundle: .kit)
        }
    }
}
