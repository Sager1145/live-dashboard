import SwiftUI
import UIKit

public struct SettingsView: View {
    @Bindable var dashboardStore: DashboardStore
    let userDataStore: UserDataStore
    let assistant: AssistantCoordinator
    @State private var refreshMessage: String?

    public init(dashboardStore: DashboardStore, userDataStore: UserDataStore, assistant: AssistantCoordinator) {
        self.dashboardStore = dashboardStore
        self.userDataStore = userDataStore
        self.assistant = assistant
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("资料更新") {
                    Button {
                        Task { await refreshOfficialData() }
                    } label: {
                        if dashboardStore.isRefreshing {
                            HStack {
                                ProgressView()
                                Text("正在检查官方资料…")
                            }
                        } else {
                            Label("立即检查官方资料", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(dashboardStore.isRefreshing)
                    .accessibilityIdentifier("officialRefreshButton")

                    if let lastRefreshedAt = dashboardStore.lastRefreshedAt {
                        LabeledContent("上次检查") {
                            Text(lastRefreshedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    } else {
                        LabeledContent("上次检查", value: "尚未完成")
                    }
                    if let refreshMessage {
                        Text(refreshMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("每天首次打开或跨天回到前台时自动整理官网资料，范围从手机当前日期往前一个自然月开始，包含所有未来公演。更早的已存公演会保留，但不再自动整理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("显示") {
                    Toggle("同时显示设备本地时间", isOn: Binding(get: { userDataStore.showsDeviceLocalTime }, set: { userDataStore.setDeviceLocalTimeEnabled($0) }))
                    NavigationLink("全局卡片设置") { CardSettingsView(userDataStore: userDataStore) }
                        .accessibilityIdentifier("globalCardSettingsLink")
                }
                Section("提醒") {
                    Button("打开系统通知设置") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    Text("截止提醒由本机通知发送。App 关闭时仍会按已保存的时间提醒，但无法自动发现官方之后修改的截止时间；再次打开 App 更新资料后请重新设置提醒。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("ChatGPT 助手") {
                    assistantAccountRow
                    NavigationLink("ChatGPT 账号与 AI 整理") {
                        AssistantSettingsView(assistant: assistant)
                    }
                    .accessibilityIdentifier("assistantSettingsLink")
                    Text("登录后可自动整理多日公演重点、识别售票与通贩链接。摘要为 AI 生成，非官方资料。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("隐私") {
                    Text("公演资料、关注、手动申请状态、提醒和卡片设置都保存在本机。检查官方资料不需要账号或服务器安装身份。若登录 ChatGPT 助手，会将官网页面文字发送到 OpenAI 生成摘要；凭据保存在本机钥匙串。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
    @ViewBuilder
    private var assistantAccountRow: some View {
        switch assistant.account {
        case .signedOut:
            LabeledContent("账号", value: "未登录")
        case .apiKey(let hint):
            LabeledContent("账号", value: "API Key \(hint)")
        case .chatGPT(let email, let accountID):
            LabeledContent("账号", value: "ChatGPT \(email ?? accountID ?? "已登录")")
        }
    }

    private func refreshOfficialData() async {
        await dashboardStore.refresh()
        refreshMessage = dashboardStore.errorMessage ?? String(localized: "官方资料已更新")
    }
}
