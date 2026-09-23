import Foundation
import Observation

/// The single entry point the UI talks to for the assistant feature: sign
/// in/out, generating summaries, and reading cached results.
/// Phase of an interactive ChatGPT sign-in, surfaced so the UI can disable
/// (not replace) its buttons and show progress while OAuth is in flight.
public enum AssistantSignInPhase: Equatable, Sendable {
    case idle
    case waitingForOAuth
}

@MainActor
@Observable
public final class AssistantCoordinator {
    public private(set) var account: AssistantAccountState = .signedOut
    /// Set when a 401 forced an automatic sign-out (credential invalid or
    /// expired beyond recovery); cleared as soon as sign-in succeeds again.
    public private(set) var lastSignOutReason: String?
    public private(set) var signInPhase: AssistantSignInPhase = .idle
    public var autoSummarizeAfterRefresh: Bool {
        didSet {
            defaults.set(autoSummarizeAfterRefresh, forKey: Self.autoSummarizeDefaultsKey)
        }
    }
    public var model: String {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model, forKey: modelDefaultsKey)
            resetFailures()
        }
    }
    public private(set) var summaries: [String: AssistantEventSummary] = [:]
    public private(set) var generatingEventIDs: Set<String> = []
    public private(set) var lastError: String?
    /// Per-event failure messages (eventID → message), so a card can show why
    /// its own summary failed without every other card reporting the same
    /// global error.
    public private(set) var errors: [String: String] = [:]
    public private(set) var isLoaded = false

    private let defaults: UserDefaults
    private let accountStore: AssistantAccountStore
    private let summaryStore: AssistantSummaryStore
    private let client: OpenAIResponsesClient
    private let officialPageSession: URLSession?
    private let urlSession: URLSession
    private var signInFlowBox: ChatGPTSignInFlow?

    private var deletingEventIDs: Set<String> = []
    private var isRemovingAllSummaries = false
    private static let deletedEventsDefaultsKey = "assistant.deletedEventIDs"
    private var deletedEventIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.deletedEventsDefaultsKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Self.deletedEventsDefaultsKey) }
    }

    private static let autoSummarizeDefaultsKey = "assistant.autoSummarize"
    public static let defaultAPIModel = "gpt-5-mini"
    public static let defaultChatGPTModel = "gpt-6-luna"
    public static let suggestedChatGPTModels = ["gpt-6-luna", "gpt-6-sol", "gpt-5.6-luna"]
    private static let legacyModelDefaultsKey = "assistant.model"
    private var modelDefaultsKey: String {
        usesChatGPTBackend ? "assistant.model.chatGPT" : "assistant.model.api"
    }

    public var usesChatGPTBackend: Bool {
        if case .chatGPT(let session) = credential { return session.apiKey == nil }
        return false
    }

    private var configurationRevision = 0

    private var credential: AssistantCredential?
    private var inFlightGenerations: [String: Task<AssistantEventSummary?, Never>] = [:]
    /// Shared in-flight ChatGPT token refresh so concurrent callers (a stale
    /// access token plus a 401 retry, for instance) never race two refreshes.
    private var refreshTask: Task<ChatGPTSession, Error>?
    /// Fingerprints of bundles that already failed generation this process,
    /// so `generateStale` does not retry the same failure on every refresh.
    private var failedFingerprints: Set<String> = []
    private var isGeneratingStale = false

    public init(
        officialPageSession: URLSession? = .shared,
        accountStore: AssistantAccountStore = AssistantAccountStore(),
        summaryStore: AssistantSummaryStore = AssistantSummaryStore(),
        client: OpenAIResponsesClient = OpenAIResponsesClient(),
        urlSession: URLSession = .shared,
        signInFlow: ChatGPTSignInFlow? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.officialPageSession = officialPageSession
        self.defaults = defaults
        self.accountStore = accountStore
        self.summaryStore = summaryStore
        self.client = client
        self.urlSession = urlSession
        self.signInFlowBox = signInFlow
        self.autoSummarizeAfterRefresh = defaults.bool(forKey: Self.autoSummarizeDefaultsKey)
        self.model = Self.defaultAPIModel
    }

    private var signInFlow: ChatGPTSignInFlow {
        if let signInFlowBox { return signInFlowBox }
        let flow = ChatGPTSignInFlow()
        signInFlowBox = flow
        return flow
    }

    public func load() async {
        guard !isLoaded else { return }
        let loadedCredential = await accountStore.load()
        summaries = (try? await summaryStore.all()) ?? [:]
        credential = loadedCredential
        account = loadedCredential?.accountState ?? .signedOut
        if loadedCredential != nil { restoreModel() }
        isLoaded = true
    }

    public func summary(for eventID: String) -> AssistantEventSummary? {
        summaries[eventID]
    }

    public func error(for eventID: String) -> String? {
        errors[eventID]
    }

    /// Cached per (event, summary generation, bundle content) so repeated
    /// `body` evaluations for an unchanged bundle never re-hash the source
    /// text. Keyed on `bundle.hashValue` — Swift's synthesized `Hashable`
    /// conformance covers every field (including `sourceText`), so it is a
    /// cheap stand-in for the bundle's content that never goes stale itself;
    /// only recomputing the actual SHA-256 fingerprint when either the
    /// summary or the bundle content has changed.
    private var staleCache: [String: (summaryStamp: Date, bundleToken: Int, isStale: Bool)] = [:]

    public func isStale(_ bundle: LiveEventBundle) -> Bool {
        guard let summary = summaries[bundle.event.id] else { return true }
        let token = bundle.hashValue
        if let cached = staleCache[bundle.event.id],
           cached.summaryStamp == summary.generatedAt,
           cached.bundleToken == token {
            return cached.isStale
        }
        let stale = summary.sourceFingerprint != AssistantSummarizer.fingerprint(of: bundle)
        staleCache[bundle.event.id] = (summary.generatedAt, token, stale)
        return stale
    }

    @discardableResult
    public func generate(for bundle: LiveEventBundle, force: Bool = false) async -> AssistantEventSummary? {
        let eventID = bundle.event.id
        guard !isRemovingAllSummaries, !deletingEventIDs.contains(eventID) else { return nil }
        if !force, !isStale(bundle), let cached = summaries[eventID] {
            return cached
        }
        if let existing = inFlightGenerations[eventID] {
            return await existing.value
        }

        let task = Task { [weak self] () -> AssistantEventSummary? in
            guard let self else { return nil }
            do {
                let summary = try await self.runSummarize(bundle: bundle)
                // `cancelGeneration`/`removeAllSummaries` only mark the task
                // cancelled — the underlying request may still finish. Never
                // let a cancelled generation resurrect a summary the user
                // already asked to remove.
                guard !Task.isCancelled else { return nil }
                do {
                    try await self.summaryStore.save(summary)
                } catch {
                    throw AssistantError.provider(String(localized: "AI 整理结果保存失败，请重试。", bundle: .kit))
                }
                // The task may have been cancelled while the save was in
                // flight (e.g. `removeAllSummaries`); never leave a summary
                // on disk that the user already asked to remove.
                guard !Task.isCancelled else {
                    try? await self.summaryStore.remove(eventID: eventID, ifGeneratedAt: summary.generatedAt)
                    return nil
                }
                let applied = await MainActor.run { () -> Bool in
                    guard !Task.isCancelled else { return false }
                    self.summaries[eventID] = summary
                    self.deletedEventIDs.remove(eventID)
                    self.lastError = nil
                    self.errors.removeValue(forKey: eventID)
                    return true
                }
                guard applied else {
                    try? await self.summaryStore.remove(eventID: eventID, ifGeneratedAt: summary.generatedAt)
                    return nil
                }
                return summary
            } catch {
                guard !Task.isCancelled else { return nil }
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.lastError = message
                    self.errors[eventID] = message
                }
                return nil
            }
        }
        generatingEventIDs.insert(eventID)
        inFlightGenerations[eventID] = task
        let result = await task.value
        // Only clear bookkeeping if this is still the task we registered —
        // a cancel-then-regenerate may have already replaced it with a
        // newer task, which must be left running/registered.
        if inFlightGenerations[eventID] == task {
            inFlightGenerations.removeValue(forKey: eventID)
            generatingEventIDs.remove(eventID)
        }
        return result
    }

    /// Cancels an in-flight generation for `eventID`, if any, and clears its
    /// generating/error state.
    public func cancelGeneration(for eventID: String) {
        inFlightGenerations[eventID]?.cancel()
        inFlightGenerations.removeValue(forKey: eventID)
        generatingEventIDs.remove(eventID)
    }

    /// Resolves a transport and runs the summarizer. A 401 from the ChatGPT
    /// backend transport forces one shared token refresh (see
    /// `refreshChatGPTSession`) and retries once. A 401 from an API-key
    /// transport — or a retry that still 401s — signs the credential out (if
    /// it was a plain API key) and surfaces a re-login message.
    private func runSummarize(bundle: LiveEventBundle) async throws -> AssistantEventSummary {
        let requestModel = model
        let transport = try await currentTransport()
        let summarizer = AssistantSummarizer(client: client, officialPageSession: officialPageSession)
        do {
            return try await summarizer.summarize(bundle: bundle, model: requestModel, transport: transport)
        } catch AssistantError.http(401, _) {
            guard case .chatGPTBackend = transport else {
                lastSignOutReason = Self.invalidCredentialMessage
                await signOut()
                throw AssistantCredentialInvalidError()
            }
            let refreshedTransport = try await forceRefreshChatGPTTransport()
            do {
                return try await summarizer.summarize(bundle: bundle, model: requestModel, transport: refreshedTransport)
            } catch AssistantError.http(401, _) {
                lastSignOutReason = Self.invalidCredentialMessage
                await signOut()
                throw AssistantCredentialInvalidError()
            }
        }
    }

    private static let invalidCredentialMessage = String(localized: "凭据无效，已退出登录", bundle: .kit)

    /// Best-effort detection of an OpenAI "model not found"/"does not exist"
    /// error, as distinct from an invalid-key rejection — used so `signIn`
    /// only falls back to the default model for a model problem, never for
    /// a credential problem.
    private static func looksLikeModelNotFound(status: Int, body: String) -> Bool {
        if status == 404 { return true }
        let lowered = body.lowercased()
        guard lowered.contains("model") else { return false }
        return lowered.contains("not found")
            || lowered.contains("does not exist")
            || lowered.contains("invalid model")
            || lowered.contains("model_not_found")
    }

    public func generateStale(in bundles: [LiveEventBundle]) async {
        guard autoSummarizeAfterRefresh, account.isSignedIn else { return }
        guard !isGeneratingStale else { return }
        isGeneratingStale = true
        defer { isGeneratingStale = false }

        let stale = bundles
            .filter { bundle in
                guard !deletedEventIDs.contains(bundle.event.id) else { return false }
                if officialPageSession == nil {
                    guard let sourceText = bundle.sourceText,
                          !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                }
                guard isStale(bundle) else { return false }
                return !failedFingerprints.contains(AssistantSummarizer.fingerprint(of: bundle))
            }
            .sorted { lhs, rhs in
                let lhsMax = lhs.performances.compactMap(\.localDate).max() ?? ""
                let rhsMax = rhs.performances.compactMap(\.localDate).max() ?? ""
                return lhsMax > rhsMax
            }
            .prefix(20)

        let batchRevision = configurationRevision
        for bundle in stale {
            guard !isRemovingAllSummaries, batchRevision == configurationRevision else { break }
            guard !deletedEventIDs.contains(bundle.event.id) else { continue }
            let fingerprint = AssistantSummarizer.fingerprint(of: bundle)
            let revision = configurationRevision
            let result = await generate(for: bundle)
            if result == nil, revision == configurationRevision {
                failedFingerprints.insert(fingerprint)
            }
        }
    }

    /// Tests the candidate API key against the API backend before persisting
    /// anything: a bad key never reaches the Keychain or replaces a working
    /// credential.
    public func signIn(apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AssistantError.invalidOutput(String(localized: "API key 不能为空", bundle: .kit))
        }
        let testModel = defaults.string(forKey: "assistant.model.api") ?? Self.defaultAPIModel
        do {
            _ = try await performConnectionTest(transport: .openAIAPI(apiKey: trimmed), model: testModel)
        } catch AssistantError.http(let status, let body)
            where status != 401 && testModel != Self.defaultAPIModel && Self.looksLikeModelNotFound(status: status, body: body) {
            // The saved API model may no longer exist (renamed/retired) —
            // that says nothing about whether the key itself is valid, so
            // retry the connection test against the default model before
            // rejecting the key.
            _ = try await performConnectionTest(transport: .openAIAPI(apiKey: trimmed), model: Self.defaultAPIModel)
        }

        let credential = AssistantCredential.apiKey(trimmed)
        try await accountStore.save(credential)
        self.credential = credential
        self.account = credential.accountState
        self.lastSignOutReason = nil
        restoreModel()
        resetFailures()
    }

    public func signInWithChatGPT() async throws {
        signInPhase = .waitingForOAuth
        defer { signInPhase = .idle }
        let configuration = ChatGPTOAuthConfiguration.stored()
        let session = try await signInFlow.signIn(configuration: configuration, urlSession: urlSession)
        let credential = AssistantCredential.chatGPT(session)
        try await accountStore.save(credential)
        self.credential = credential
        self.account = credential.accountState
        self.lastSignOutReason = nil
        restoreModel()
        resetFailures()
    }

    public func signOut() async {
        try? await accountStore.clear()
        credential = nil
        account = .signedOut
        resetFailures()
    }

    public func testConnection() async throws -> String {
        let requestModel = model
        let transport = try await currentTransport()
        return try await performConnectionTest(transport: transport, model: requestModel)
    }

    /// Shared ping used by `testConnection()` and `signIn(apiKey:)` (which
    /// tests a candidate credential that has not been persisted yet).
    private func performConnectionTest(transport: AssistantTransport, model requestModel: String) async throws -> String {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["ok": ["type": "string"]],
            "required": ["ok"],
            "additionalProperties": false
        ]
        _ = try await client.generateStructured(
            model: requestModel,
            instructions: "Reply with a JSON object containing an \"ok\" field set to \"ok\".",
            input: "ping",
            schemaName: "assistant_ping",
            schema: schema,
            transport: transport
        )
        return requestModel
    }

    public func availableModels() async -> [String] {
        guard let transport = try? await currentTransport() else { return [] }
        return (try? await client.listModels(transport: transport)) ?? []
    }

    public func removeSummary(eventID: String) async {
        guard !deletingEventIDs.contains(eventID) else { return }
        deletingEventIDs.insert(eventID)
        defer { deletingEventIDs.remove(eventID) }
        let generation = inFlightGenerations[eventID]
        cancelGeneration(for: eventID)
        // Wait for a cancelled save to finish before removing its on-disk result.
        _ = await generation?.value
        do {
            try await summaryStore.remove(eventID: eventID)
            summaries.removeValue(forKey: eventID)
            errors.removeValue(forKey: eventID)
            staleCache.removeValue(forKey: eventID)
            deletedEventIDs.insert(eventID)
        } catch {
            let message = String(localized: "无法删除本公演的 AI 整理结果，请重试。", bundle: .kit)
            errors[eventID] = message
            lastError = message
        }
    }

    /// Cancels every in-flight generation first, then clears every stored
    /// summary — so a generation that finishes mid-clear cannot resurrect a
    /// summary the user just asked to remove.
    public func removeAllSummaries() async {
        guard !isRemovingAllSummaries else { return }
        isRemovingAllSummaries = true
        configurationRevision += 1
        defer { isRemovingAllSummaries = false }
        let generations = inFlightGenerations
        for eventID in generations.keys { cancelGeneration(for: eventID) }
        for task in generations.values { _ = await task.value }
        do {
            let persisted = try await summaryStore.all()
            let deleted = Set(persisted.keys).union(summaries.keys).union(generations.keys)
            try await summaryStore.removeAll()
            summaries.removeAll()
            errors.removeAll()
            staleCache.removeAll()
            deletedEventIDs.formUnion(deleted)
            lastError = nil
        } catch {
            lastError = String(localized: "无法删除 AI 整理结果，请重试。", bundle: .kit)
        }
    }

    private func restoreModel() {
        let fallback = usesChatGPTBackend ? Self.defaultChatGPTModel : Self.defaultAPIModel
        let saved = defaults.string(forKey: modelDefaultsKey)
            ?? defaults.string(forKey: Self.legacyModelDefaultsKey)
        let candidate = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The old shared default is an API model rejected by the Codex backend.
        model = candidate.isEmpty || (usesChatGPTBackend && candidate == Self.defaultAPIModel)
            ? fallback : candidate
        defaults.set(model, forKey: modelDefaultsKey)
        // Migrate the shared preference once; later login methods get their own default.
        defaults.removeObject(forKey: Self.legacyModelDefaultsKey)
    }

    private func resetFailures() {
        configurationRevision += 1
        failedFingerprints.removeAll()
        errors.removeAll()
        lastError = nil
    }

    // MARK: - Transport resolution

    private func currentTransport() async throws -> AssistantTransport {
        guard let credential else { throw AssistantError.notSignedIn }
        switch credential {
        case .apiKey(let key):
            return .openAIAPI(apiKey: key)
        case .chatGPT(let session):
            if let apiKey = session.apiKey {
                return .openAIAPI(apiKey: apiKey)
            }
            if let expiresAt = session.expiresAt, expiresAt <= Date(), session.refreshToken != nil {
                let refreshed = try await refreshChatGPTSession(from: session)
                if let apiKey = refreshed.apiKey {
                    return .openAIAPI(apiKey: apiKey)
                }
                return .chatGPTBackend(accessToken: refreshed.accessToken, accountID: refreshed.accountID)
            }
            return .chatGPTBackend(accessToken: session.accessToken, accountID: session.accountID)
        }
    }

    /// Forces a refresh of the current ChatGPT session regardless of its
    /// expiry, used to recover from a 401 against the ChatGPT backend.
    private func forceRefreshChatGPTTransport() async throws -> AssistantTransport {
        guard case .chatGPT(let session) = credential else { throw AssistantError.notSignedIn }
        let refreshed = try await refreshChatGPTSession(from: session)
        if let apiKey = refreshed.apiKey {
            return .openAIAPI(apiKey: apiKey)
        }
        return .chatGPTBackend(accessToken: refreshed.accessToken, accountID: refreshed.accountID)
    }

    /// Runs the shared token refresh, or awaits the one already in flight so
    /// concurrent callers never issue two refreshes for the same session.
    /// Only signed out on `ChatGPTOAuthError.invalidGrant`; any other
    /// refresh failure surfaces `lastError` and rethrows without signing out.
    /// The refreshed session is only saved/applied if `credential` is still
    /// the same ChatGPT session this refresh started from — if the user
    /// signed out (or signed back in) meanwhile, the result is discarded.
    private func refreshChatGPTSession(from session: ChatGPTSession) async throws -> ChatGPTSession {
        if let refreshTask {
            return try await refreshTask.value
        }
        let startingRefreshToken = session.refreshToken
        let startingAccessToken = session.accessToken
        let configuration = ChatGPTOAuthConfiguration.stored()
        let oauthClient = ChatGPTOAuthClient(configuration: configuration)
        let urlSession = self.urlSession
        let task = Task<ChatGPTSession, Error> {
            try await oauthClient.refresh(session, session: urlSession)
        }
        refreshTask = task
        do {
            let refreshed = try await task.value
            refreshTask = nil
            if case .chatGPT(let current) = credential,
               current.refreshToken == startingRefreshToken,
               current.accessToken == startingAccessToken {
                let refreshedCredential = AssistantCredential.chatGPT(refreshed)
                try? await accountStore.save(refreshedCredential)
                self.credential = refreshedCredential
                self.account = refreshedCredential.accountState
            }
            return refreshed
        } catch {
            refreshTask = nil
            if case ChatGPTOAuthError.invalidGrant = error {
                lastSignOutReason = Self.invalidCredentialMessage
                await signOut()
            }
            self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw error
        }
    }
}

/// Thrown when a credential is invalid or expired and could not be
/// recovered by a refresh/retry; surfaces a re-login message to the UI.
private struct AssistantCredentialInvalidError: Error, LocalizedError {
    var errorDescription: String? { String(localized: "凭据无效或已过期，请重新登录", bundle: .kit) }
}
