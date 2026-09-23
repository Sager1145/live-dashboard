import SwiftUI

/// ChatGPT account and AI-summarisation settings. Credentials never live
/// here — only the masked account state and controls that call into
/// `AssistantCoordinator`, which keeps secrets in the Keychain.
public struct AssistantSettingsView: View {
    @Bindable var assistant: AssistantCoordinator

    @State private var apiKey = ""
    @State private var customModel = ""
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var isTestingConnection = false
    @State private var connectionResult: String?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false

    @AppStorage("assistant.oauthClientID") private var oauthClientID = ""
    @AppStorage("assistant.oauthRedirectURI") private var oauthRedirectURI = ""

    public init(assistant: AssistantCoordinator) {
        self.assistant = assistant
    }

    public var body: some View {
        Form {
            accountSection
            modelSection
            autoSummarizeSection
            advancedOAuthSection
            dataSection
        }
        .navigationTitle("ChatGPT 助手")
        .onAppear { customModel = assistant.model }
        .onChange(of: assistant.account) { _, _ in
            availableModels = []
            connectionResult = nil
        }
        .onChange(of: assistant.model) { _, newModel in
            customModel = newModel
            connectionResult = nil
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("账号") {
            accountStatusRow

            switch assistant.account {
            case .signedOut:
                if isSigningIn {
                    ProgressView()
                } else {
                    Button("使用 ChatGPT 账号登录") {
                        Task { await signInWithChatGPT() }
                    }
                    .accessibilityIdentifier("chatGPTSignInButton")
                }
                SecureField("OpenAI API Key", text: $apiKey)
                Button("使用 API Key 登录") {
                    Task { await signIn(apiKey: apiKey) }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSigningIn)
                if let signInError {
                    Text(signInError).font(.caption).foregroundStyle(.red)
                }
            case .apiKey, .chatGPT:
                Button("退出登录", role: .destructive) {
                    Task { await assistant.signOut() }
                }
            }
        }
    }

    @ViewBuilder
    private var accountStatusRow: some View {
        switch assistant.account {
        case .signedOut:
            LabeledContent("账号", value: "未登录")
        case .apiKey(let hint):
            LabeledContent("账号", value: "API Key \(hint)")
        case .chatGPT(let email, let accountID):
            LabeledContent("账号", value: "ChatGPT \(email ?? accountID ?? "已登录")")
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section("模型") {
            LabeledContent("当前模型", value: assistant.model)
            TextField("自定义模型名称", text: $customModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { applyCustomModel() }
                .accessibilityIdentifier("assistantCustomModelField")
            Button("切换到此模型") { applyCustomModel() }
                .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || customModel.trimmingCharacters(in: .whitespacesAndNewlines) == assistant.model)
                .accessibilityIdentifier("assistantApplyModelButton")
            Text("点选推荐模型可立即切换，也可输入模型名称后点击切换。选择会自动保存，下次 AI 整理生效；已有摘要可点「重新整理」更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(assistant.usesChatGPTBackend
                 ? "ChatGPT 登录默认使用 gpt-6-luna。推荐模型的可用性取决于账号权限，可修改模型后测试连接。"
                 : "API Key 默认使用 gpt-5-mini，可载入账号的可用模型列表。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await testConnection() }
            } label: {
                if isTestingConnection {
                    ProgressView()
                } else {
                    Text("测试连接")
                }
            }
            .disabled(isTestingConnection || !assistant.account.isSignedIn)
            if let connectionResult {
                Text(connectionResult).font(.caption).foregroundStyle(.secondary)
            }

            if assistant.usesChatGPTBackend {
                HorizontalSelectionStrip(
                    title: "Codex 推荐模型",
                    selection: $assistant.model,
                    options: Array(Set(AssistantCoordinator.suggestedChatGPTModels + [assistant.model])).sorted().map {
                        HorizontalSelectionOption(value: $0, title: $0)
                    }
                )
            } else {
                Button {
                    Task { await loadAvailableModels() }
                } label: {
                    if isLoadingModels {
                        ProgressView()
                    } else {
                        Text("载入可用模型列表")
                    }
                }
                .disabled(isLoadingModels || !assistant.account.isSignedIn)
                if !availableModels.isEmpty {
                    Picker("可用模型", selection: $assistant.model) {
                        ForEach(Array(Set(availableModels + [assistant.model])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var autoSummarizeSection: some View {
        Section("自动整理") {
            Toggle("官网资料更新后自动生成摘要", isOn: $assistant.autoSummarizeAfterRefresh)
            Text("开启后，每次官方资料刷新且内容有变化的公演会自动生成新摘要，会消耗 AI 用量或额度。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var advancedOAuthSection: some View {
        Section("高级（OAuth）") {
            TextField("Client ID", text: $oauthClientID, prompt: Text("app_EMoamEEZ73f0CkXaXp7hrann"))
            TextField("回调地址", text: $oauthRedirectURI, prompt: Text("http://localhost:1455/auth/callback"))
            Text("默认使用 OpenAI 官方的 ChatGPT 登录客户端（PKCE）。如需使用你自己注册的“Sign in with ChatGPT”应用，请填写 Client ID 与回调地址；自定义 scheme 请用 live-dashboard://oauth/openai。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var dataSection: some View {
        Section("数据") {
            Button("清除全部 AI 摘要", role: .destructive) {
                Task {
                    for eventID in assistant.summaries.keys {
                        await assistant.removeSummary(eventID: eventID)
                    }
                }
            }
        }
    }

    private func applyCustomModel() {
        let selected = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return }
        assistant.model = selected
        customModel = selected
    }

    private func signInWithChatGPT() async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            try await assistant.signInWithChatGPT()
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func signIn(apiKey: String) async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            try await assistant.signIn(apiKey: apiKey)
            self.apiKey = ""
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            connectionResult = try await assistant.testConnection()
        } catch {
            connectionResult = error.localizedDescription
        }
    }

    private func loadAvailableModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        availableModels = await assistant.availableModels()
    }
}
