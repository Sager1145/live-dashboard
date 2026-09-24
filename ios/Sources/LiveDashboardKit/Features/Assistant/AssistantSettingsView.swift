import SwiftUI
import LiveIngestionCore

/// ChatGPT account and AI-summarisation settings. Credentials never live
/// here — only the masked account state and controls that call into
/// `AssistantCoordinator`, which keeps secrets in the Keychain.
public struct AssistantSettingsView: View {
    @Bindable var assistant: AssistantCoordinator

    @State private var apiKey = ""
    @State private var customModel = ""
    @State private var showsCustomModelField = false
    @State private var isSigningInWithChatGPT = false
    @State private var isSigningInWithAPIKey = false
    @State private var signInError: String?
    @State private var signInErrorWasFromAPIKey = false
    @State private var isAPIKeySectionExpanded = false
    @State private var isTestingConnection = false
    @State private var connectionResult: ConnectionResult?
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelListError: String?
    @State private var showsSignOutConfirmation = false
    @State private var showsClearSummariesConfirmation = false
    @State private var clearSummariesFeedback: String?
    @State private var isClearingSummaries = false
    @FocusState private var isAPIKeyFieldFocused: Bool
    @FocusState private var isCustomModelFieldFocused: Bool

    private var isSigningIn: Bool { isSigningInWithChatGPT || isSigningInWithAPIKey }

    private var apiKeySectionExpanded: Binding<Bool> {
        Binding(
            get: { isAPIKeySectionExpanded || signInErrorWasFromAPIKey },
            set: { isAPIKeySectionExpanded = $0 }
        )
    }

    @AppStorage("assistant.oauthClientID") private var oauthClientID = ""
    @AppStorage("assistant.oauthRedirectURI") private var oauthRedirectURI = ""

    /// Ids that never make sense as a chat/completions model, e.g.
    /// embeddings, TTS/whisper, dall-e or moderation models.
    private static let nonChatModelMarkers = ["embedding", "tts", "whisper", "dall-e", "moderation"]

    enum ConnectionResult {
        case ok(model: String)
        case failed(String)
    }

    public init(assistant: AssistantCoordinator) {
        self.assistant = assistant
    }

    public var body: some View {
        Form {
            engineSection
            accountSection
            modelSection
            testConnectionSection
            autoSummarizeSection
            advancedOAuthLink
            dataSection
        }
        .navigationTitle(Text("ChatGPT 助手", bundle: .kit))
        .onAppear { customModel = assistant.model }
        .onChange(of: assistant.account) { _, _ in
            availableModels = []
            connectionResult = nil
        }
        .onChange(of: assistant.model) { _, newModel in
            customModel = newModel
            connectionResult = nil
        }
        .onChange(of: showsCustomModelField) { _, isShown in
            guard isShown else { return }
            // The custom-model field is revealed by a `.navigationLink`
            // picker popping back to this page; focusing immediately steals
            // focus mid-transition. Wait for the pop animation to settle.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                isCustomModelFieldFocused = true
            }
        }
    }

    @ViewBuilder
    private var engineSection: some View {
        Section {
            Picker(selection: $assistant.engine) {
                Text("规则解析", bundle: .kit).tag(AssistantEngine.rules)
                Text("Apple 本地整理", bundle: .kit).tag(AssistantEngine.appleOnDevice)
                Text("云端助手", bundle: .kit).tag(AssistantEngine.openAI)
            } label: {
                Text("整理方式", bundle: .kit)
            }
            LabeledContent {
                Text(verbatim: Self.appleIntelligenceStatusText(AppleIntelligenceStatus.current()))
            } label: {
                Text("Apple Intelligence", bundle: .kit)
            }
        } header: {
            Text("整理方式", bundle: .kit)
        } footer: {
            Text("Apple 本地整理不需要登录，只处理已经保存的官网文字。模型不可用时仍可使用规则解析。不会自动改用云端或私有云。", bundle: .kit)
        }
    }

    private static func appleIntelligenceStatusText(_ status: AppleIntelligenceAvailability) -> String {
        switch status {
        case .ready: "可用"
        case .unsupportedOS: "系统版本不支持"
        case .unsupportedDevice: "设备不支持"
        case .modelNotReady: "模型尚未就绪"
        case .systemDisabledOrUnavailable: "Apple Intelligence 未开启"
        case .unsupportedSourceLanguage: "不支持日文"
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            accountStatusRow

            switch assistant.account {
            case .signedOut:
                if assistant.signInPhase == .waitingForOAuth {
                    LabeledContent {
                        ProgressView()
                    } label: {
                        Text("正在等待 ChatGPT 登录…", bundle: .kit)
                    }
                }
                Button {
                    Task { await signInWithChatGPT() }
                } label: {
                    if isSigningInWithChatGPT {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("使用 ChatGPT 账号登录", bundle: .kit)
                        }
                    } else {
                        Text("使用 ChatGPT 账号登录", bundle: .kit)
                    }
                }
                .disabled(isSigningIn || assistant.signInPhase == .waitingForOAuth)
                .accessibilityIdentifier("chatGPTSignInButton")

                if !signInErrorWasFromAPIKey, let signInError {
                    Label {
                        Text(verbatim: signInError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup(isExpanded: apiKeySectionExpanded) {
                    SecureField(text: $apiKey, prompt: Text(verbatim: "sk-…")) {
                        Text("OpenAI API Key", bundle: .kit)
                    }
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .privacySensitive()
                    .focused($isAPIKeyFieldFocused)
                    .onSubmit { Task { await signIn(apiKey: apiKey) } }

                    Button {
                        Task { await signIn(apiKey: apiKey) }
                    } label: {
                        Text("使用 API Key 登录", bundle: .kit)
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSigningIn)

                    if signInErrorWasFromAPIKey, let signInError {
                        Label {
                            Text(verbatim: signInError)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.statusCritical)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Text("使用 API Key 连接", bundle: .kit)
                }
            case .apiKey, .chatGPT:
                Button(role: .destructive) {
                    showsSignOutConfirmation = true
                } label: {
                    Text("退出登录", bundle: .kit)
                }
            }
        } footer: {
            if case .signedOut = assistant.account {
                Text("登录后，官网页面文字与已解析的资料会发送至 OpenAI 生成摘要；生成会消耗账号额度。凭据仅保存在本机钥匙串。", bundle: .kit)
            }
        }
        .confirmationDialog(
            Text("退出登录后将无法继续生成新摘要，已生成的摘要仍会保留。", bundle: .kit),
            isPresented: $showsSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await assistant.signOut() }
            } label: {
                Text("退出登录", bundle: .kit)
            }
            Button(role: .cancel) {} label: {
                Text("取消", bundle: .kit)
            }
        }
    }

    @ViewBuilder
    private var accountStatusRow: some View {
        switch assistant.account {
        case .signedOut:
            LabeledContent {
                Text(verbatim: String(localized: "未登录", bundle: .kit))
            } label: {
                Text("账号", bundle: .kit)
            }
        case .apiKey(let hint):
            LabeledContent {
                Text(verbatim: "API Key \(hint)")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("账号", bundle: .kit)
            }
        case .chatGPT(let email, let accountID):
            LabeledContent {
                Text(verbatim: "ChatGPT \(email ?? accountID ?? String(localized: "已登录", bundle: .kit))")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Text("账号", bundle: .kit)
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            Picker(selection: modelPickerSelection) {
                ForEach(suggestedModels, id: \.self) { model in
                    Text(verbatim: model).tag(ModelPickerSelection.suggested(model))
                }
                Text("自定义…", bundle: .kit).tag(ModelPickerSelection.custom)
            } label: {
                Text("模型", bundle: .kit)
            }
            .pickerStyle(.navigationLink)

            if showsCustomModelField {
                TextField(text: $customModel) {
                    Text("自定义模型名称", bundle: .kit)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { applyCustomModel() }
                .focused($isCustomModelFieldFocused)
                .accessibilityIdentifier("assistantCustomModelField")
                Button {
                    applyCustomModel()
                } label: {
                    Text("使用此模型", bundle: .kit)
                }
                .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || customModel.trimmingCharacters(in: .whitespacesAndNewlines) == assistant.model)
                .accessibilityIdentifier("assistantApplyModelButton")
            }

            if !assistant.usesChatGPTBackend {
                Button {
                    Task { await loadAvailableModels() }
                } label: {
                    if isLoadingModels {
                        ProgressView()
                    } else {
                        Label {
                            Text("载入可用模型列表", bundle: .kit)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .disabled(isLoadingModels || !assistant.account.isSignedIn)
                if let modelListError {
                    Label {
                        Text(verbatim: modelListError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("模型", bundle: .kit)
        } footer: {
            Text("点选推荐模型可立即切换，或选择「自定义…」输入模型名称。选择会自动保存，下次 AI 整理生效；已有摘要可点「重新整理」更新。", bundle: .kit)
        }
    }

    private enum ModelPickerSelection: Hashable {
        case suggested(String)
        case custom
    }

    private var suggestedModels: [String] {
        let base = assistant.usesChatGPTBackend
            ? AssistantCoordinator.suggestedChatGPTModels
            : (availableModels.isEmpty ? [AssistantCoordinator.defaultAPIModel] : chatCapableModels(availableModels))
        return Array(Set(base + [assistant.model])).sorted()
    }

    private func chatCapableModels(_ ids: [String]) -> [String] {
        ids.filter { id in
            let lowered = id.lowercased()
            return !Self.nonChatModelMarkers.contains { lowered.contains($0) }
        }
    }

    private var modelPickerSelection: Binding<ModelPickerSelection> {
        Binding(
            get: { showsCustomModelField ? .custom : .suggested(assistant.model) },
            set: { newValue in
                switch newValue {
                case .suggested(let model):
                    showsCustomModelField = false
                    assistant.model = model
                    customModel = model
                case .custom:
                    showsCustomModelField = true
                }
            }
        )
    }

    @ViewBuilder
    private var testConnectionSection: some View {
        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack(spacing: 8) {
                    if isTestingConnection {
                        ProgressView()
                    }
                    Text("测试连接", bundle: .kit)
                }
            }
            .disabled(isTestingConnection || !assistant.account.isSignedIn)

            if let connectionResult {
                connectionResultLabel(connectionResult)
            }
        } header: {
            Text("连接", bundle: .kit)
        }
    }

    @ViewBuilder
    private func connectionResultLabel(_ result: ConnectionResult) -> some View {
        switch result {
        case .ok(let model):
            Label {
                Text("连接成功：\(model)", bundle: .kit)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(Color.statusPositive)
        case .failed(let message):
            Label {
                Text("连接失败：\(message)", bundle: .kit)
            } icon: {
                Image(systemName: "xmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(Color.statusCritical)
        }
    }

    @ViewBuilder
    private var autoSummarizeSection: some View {
        Section {
            Toggle(isOn: $assistant.autoSummarizeAfterRefresh) { Text("官网资料更新后自动整理 AI 字段", bundle: .kit) }
                .disabled(assistant.engine == .rules || !(assistant.engine == .appleOnDevice || assistant.account.isSignedIn))
        } footer: {
            switch assistant.engine {
            case .appleOnDevice:
                Text("开启后，刷新到有变化的公演时才会在本机整理未确定的日期。默认关闭。", bundle: .kit)
            case .rules:
                Text("规则解析在抓取时完成，不调用模型。", bundle: .kit)
            case .openAI:
                if !assistant.account.isSignedIn {
                    Text("登录后才能开启自动整理。", bundle: .kit)
                } else {
                    Text("开启后，每次官方资料刷新且内容有变化的公演会自动生成新摘要，会消耗 AI 用量或额度。", bundle: .kit)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedOAuthLink: some View {
        Section {
            NavigationLink {
                advancedOAuthForm
            } label: {
                Text("OAuth 客户端设置", bundle: .kit)
            }
        }
    }

    @ViewBuilder
    private var advancedOAuthForm: some View {
        Form {
            if assistant.account.isSignedIn {
                Section {
                    Text("请先退出登录再修改", bundle: .kit)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField(text: $oauthClientID, prompt: Text(verbatim: "app_EMoamEEZ73f0CkXaXp7hrann")) {
                    Text("Client ID", bundle: .kit)
                }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(assistant.account.isSignedIn)
                TextField(text: $oauthRedirectURI, prompt: Text(verbatim: "http://localhost:1455/auth/callback")) {
                    Text("回调地址", bundle: .kit)
                }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(assistant.account.isSignedIn)
            } footer: {
                Text("默认使用 OpenAI 官方的 ChatGPT 登录客户端（PKCE）。如需使用你自己注册的“Sign in with ChatGPT”应用，请填写 Client ID 与回调地址；自定义 scheme 请用 live-dashboard://oauth/openai。已登录时无法修改，请先退出登录。", bundle: .kit)
            }
        }
        .navigationTitle(Text("OAuth 客户端设置", bundle: .kit))
    }

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button(role: .destructive) {
                showsClearSummariesConfirmation = true
            } label: {
                if isClearingSummaries {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("清除全部 AI 摘要", bundle: .kit)
                    }
                } else {
                    Text("清除全部 AI 摘要", bundle: .kit)
                }
            }
            .disabled(assistant.summaries.isEmpty || isClearingSummaries)
            if let clearSummariesFeedback {
                Text(verbatim: clearSummariesFeedback).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("共 \(assistant.summaries.count) 份已保存的摘要。", bundle: .kit)
        }
        .confirmationDialog(
            Text("确定清除全部 \(assistant.summaries.count) 份 AI 摘要吗？此操作无法撤销。", bundle: .kit),
            isPresented: $showsClearSummariesConfirmation,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await clearAllSummaries() }
            } label: {
                Text("清除全部 AI 摘要", bundle: .kit)
            }
            Button(role: .cancel) {} label: {
                Text("取消", bundle: .kit)
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
        isSigningInWithChatGPT = true
        signInError = nil
        signInErrorWasFromAPIKey = false
        defer { isSigningInWithChatGPT = false }
        do {
            try await assistant.signInWithChatGPT()
        } catch ChatGPTOAuthError.cancelled {
            // User-cancelled OAuth is not an error worth surfacing.
        } catch {
            signInError = error.localizedDescription
            signInErrorWasFromAPIKey = false
        }
    }

    private func signIn(apiKey: String) async {
        isSigningInWithAPIKey = true
        signInError = nil
        signInErrorWasFromAPIKey = false
        defer { isSigningInWithAPIKey = false }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await assistant.signIn(apiKey: trimmed)
            self.apiKey = ""
        } catch {
            signInError = error.localizedDescription
            signInErrorWasFromAPIKey = true
            isAPIKeyFieldFocused = true
        }
    }

    private func clearAllSummaries() async {
        isClearingSummaries = true
        defer { isClearingSummaries = false }
        await assistant.removeAllSummaries()
        clearSummariesFeedback = String(localized: "已清除全部 AI 摘要", bundle: .kit)
        AccessibilityNotification.Announcement(String(localized: "已清除全部 AI 摘要", bundle: .kit)).post()
    }

    private func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }
        do {
            let model = try await assistant.testConnection()
            connectionResult = .ok(model: model)
            AccessibilityNotification.Announcement(String(localized: "连接成功", bundle: .kit)).post()
        } catch {
            let message = error.localizedDescription
            connectionResult = .failed(message)
            AccessibilityNotification.Announcement(String(localized: "连接失败：\(message)", bundle: .kit)).post()
        }
    }

    private func loadAvailableModels() async {
        isLoadingModels = true
        modelListError = nil
        defer { isLoadingModels = false }
        let models = await assistant.availableModels()
        if models.isEmpty {
            modelListError = String(localized: "载入模型列表失败", bundle: .kit)
        }
        availableModels = chatCapableModels(models)
    }
}
