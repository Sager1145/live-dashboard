import XCTest
@testable import LiveDashboardKit

final class AssistantServiceTests: XCTestCase {

    func testLocalOAuthCallbackServerStartsOnLoopbackAndReportsRedirect() async throws {
        let port: UInt16 = 14_555
        let server = LocalOAuthCallbackServer(port: port)
        let received = expectation(description: "callback")
        let box = CallbackBox()
        server.onCallback = { url in box.set(url); received.fulfill() }
        server.onFailure = { error in XCTFail("server failed: \(error)") }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let url = URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=xyz")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("登录成功"))
        await fulfillment(of: [received], timeout: 5)
        let callback = try XCTUnwrap(box.get())
        XCTAssertEqual(callback.path, "/auth/callback")
        XCTAssertEqual(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value, "abc")
    }

    private final class CallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        func set(_ value: URL) { lock.lock(); url = value; lock.unlock() }
        func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
    }
    override func tearDown() {
        AssistantStubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - PKCE

    func testPKCEMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEGeneratesNonEmptyValues() {
        let pkce = PKCE()
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertFalse(pkce.challenge.isEmpty)
        XCTAssertFalse(pkce.state.isEmpty)
    }

    // MARK: - OAuth callback parsing

    func testParseCallbackAcceptsMatchingState() throws {
        let url = URL(string: "http://localhost:1455/auth/callback?code=abc123&state=xyz")!
        let code = try ChatGPTOAuthClient.parseCallback(url, expectedState: "xyz")
        XCTAssertEqual(code, "abc123")
    }

    func testParseCallbackRejectsStateMismatch() {
        let url = URL(string: "http://localhost:1455/auth/callback?code=abc123&state=other")!
        XCTAssertThrowsError(try ChatGPTOAuthClient.parseCallback(url, expectedState: "xyz")) { error in
            XCTAssertEqual(error as? ChatGPTOAuthError, .stateMismatch)
        }
    }

    func testParseCallbackRejectsMissingCode() {
        let url = URL(string: "http://localhost:1455/auth/callback?state=xyz")!
        XCTAssertThrowsError(try ChatGPTOAuthClient.parseCallback(url, expectedState: "xyz")) { error in
            XCTAssertEqual(error as? ChatGPTOAuthError, .missingCode)
        }
    }

    func testParseCallbackSurfacesProviderError() {
        let url = URL(string: "http://localhost:1455/auth/callback?error=access_denied&state=xyz")!
        XCTAssertThrowsError(try ChatGPTOAuthClient.parseCallback(url, expectedState: "xyz")) { error in
            XCTAssertEqual(error as? ChatGPTOAuthError, .providerError("access_denied"))
        }
    }

    // MARK: - JWT decoding

    func testDecodeJWTPayloadReturnsNestedClaims() {
        let header = Self.base64URLEncode(#"{"alg":"none"}"#)
        let payload: [String: Any] = [
            "email": "fan@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-123"]
        ]
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let payloadSegment = Self.base64URLEncode(payloadData)
        let token = "\(header).\(payloadSegment).sig"

        let claims = ChatGPTOAuthClient.decodeJWTPayload(token)
        XCTAssertEqual(claims?["email"] as? String, "fan@example.com")
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        XCTAssertEqual(auth?["chatgpt_account_id"] as? String, "acct-123")
    }

    // MARK: - Fingerprint

    func testFingerprintChangesWithSourceTextAndIsStableOtherwise() {
        let bundleA = Self.fixtureBundle(sourceText: "官网原文 A")
        let bundleB = Self.fixtureBundle(sourceText: "官网原文 B")
        XCTAssertNotEqual(AssistantSummarizer.fingerprint(of: bundleA), AssistantSummarizer.fingerprint(of: bundleB))

        let repeatA = Self.fixtureBundle(sourceText: "官网原文 A")
        XCTAssertEqual(AssistantSummarizer.fingerprint(of: bundleA), AssistantSummarizer.fingerprint(of: repeatA))
    }

    // MARK: - buildInput

    func testBuildInputIncludesPerformanceIDsLinksAndSourceText() {
        let bundle = Self.fixtureBundle(sourceText: "官网原文全文测试")
        let input = AssistantSummarizer.buildInput(bundle: bundle)
        XCTAssertTrue(input.contains("perf-1"))
        XCTAssertTrue(input.contains("perf-2"))
        XCTAssertTrue(input.contains("eplus（https://eplus.jp/round1）"))
        XCTAssertTrue(input.contains("官网原文全文测试"))
    }

    // MARK: - Summarizer end-to-end

    func testSummarizerDecodesDropsUnknownLinkAndFillsMissingPerformance() async throws {
        let bundle = Self.fixtureBundle(sourceText: "官网原文全文测试 https://eplus.jp/round1")
        let modelJSON: [String: Any] = [
            "overview": ["segments": [["text": "总览", "style": "normal", "url": NSNull()]]],
            "keyPoints": [
                [
                    "id": "",
                    "category": "ticket",
                    "importance": "high",
                    "text": ["segments": [["text": "注意截止时间", "style": "important", "url": NSNull()]]],
                    "performanceIDs": []
                ]
            ],
            "performances": [
                [
                    "performanceID": "perf-1",
                    "dayLabel": "Day1",
                    "summary": ["segments": [["text": "第一天", "style": "normal", "url": NSNull()]]],
                    "highlights": []
                ]
            ],
            "ticketLinks": [
                [
                    "label": "eplus", "url": "https://eplus.jp/round1", "kind": "ticketSales",
                    "note": NSNull(), "performanceIDs": [], "relatedRecordID": NSNull()
                ],
                [
                    "label": "未知渠道", "url": "https://unknown.example.com/x", "kind": "ticketSales",
                    "note": NSNull(), "performanceIDs": [], "relatedRecordID": NSNull()
                ]
            ],
            "goodsLinks": [],
            "warnings": []
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: modelJSON)
        let jsonText = String(data: jsonData, encoding: .utf8)!
        let sseBody = Self.sseCompletedEvent(outputText: jsonText)

        AssistantStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data(sseBody.utf8))
        }

        let client = OpenAIResponsesClient(session: Self.stubbedSession())
        let summarizer = AssistantSummarizer(client: client)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = try await summarizer.summarize(bundle: bundle, model: "gpt-5-mini", transport: .openAIAPI(apiKey: "sk-test"), now: now)

        XCTAssertEqual(summary.eventID, bundle.event.id)
        XCTAssertEqual(summary.performances.count, 2)
        let day1 = try XCTUnwrap(summary.performances.first { $0.performanceID == "perf-1" })
        XCTAssertEqual(day1.summary.plainText, "第一天")
        let day2 = try XCTUnwrap(summary.performances.first { $0.performanceID == "perf-2" })
        XCTAssertEqual(day2.summary.plainText, "官网未单独说明本场差异")

        XCTAssertEqual(summary.ticketLinks.count, 1)
        XCTAssertEqual(summary.ticketLinks.first?.url, "https://eplus.jp/round1")
        XCTAssertTrue(summary.warnings.contains { $0.contains("未知渠道") })
        XCTAssertEqual(summary.keyPoints.first?.id, "kp-0")
        XCTAssertEqual(summary.sourceFingerprint, AssistantSummarizer.fingerprint(of: bundle))
    }

    func testSummarizerDowngradesLinkSegmentNotOnPageAndWarns() async throws {
        let bundle = Self.fixtureBundle(sourceText: "官网原文全文测试 https://eplus.jp/round1")
        let modelJSON: [String: Any] = [
            "overview": [
                "segments": [
                    ["text": "点击购票", "style": "link", "url": "https://unknown.example.com/not-on-page"]
                ]
            ],
            "keyPoints": [],
            "performances": [],
            "ticketLinks": [],
            "goodsLinks": [],
            "warnings": []
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: modelJSON)
        let jsonText = String(data: jsonData, encoding: .utf8)!
        let sseBody = Self.sseCompletedEvent(outputText: jsonText)

        AssistantStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data(sseBody.utf8))
        }

        let client = OpenAIResponsesClient(session: Self.stubbedSession())
        let summarizer = AssistantSummarizer(client: client)
        let summary = try await summarizer.summarize(bundle: bundle, model: "gpt-5-mini", transport: .openAIAPI(apiKey: "sk-test"))

        let segment = try XCTUnwrap(summary.overview.segments.first)
        XCTAssertEqual(segment.style, .bold)
        XCTAssertNil(segment.url)
        XCTAssertEqual(segment.text, "点击购票")
        XCTAssertTrue(summary.warnings.contains { $0.contains("已忽略摘要正文中 1 个未在官网出现的链接") })
    }

    func testAllowedURLsTrimsTrailingPunctuation() {
        let bundle = Self.fixtureBundle(sourceText: nil)
        let sourceText = "详情见 https://example.com/info。 另见 [列表] https://example.com/list] 更多信息"
        let allowed = AssistantSummarizer.allowedURLs(bundle: bundle, sourceText: sourceText)
        XCTAssertTrue(allowed.contains("https://example.com/info"))
        XCTAssertTrue(allowed.contains("https://example.com/list"))
    }

    func testSummarizerDedupesDuplicatePerformancesAndKeepsBundleOrder() async throws {
        let bundle = Self.fixtureBundle(sourceText: "官网原文全文测试 https://eplus.jp/round1")
        let modelJSON: [String: Any] = [
            "overview": ["segments": [["text": "总览", "style": "normal", "url": NSNull()]]],
            "keyPoints": [],
            "performances": [
                ["performanceID": "perf-2", "dayLabel": "Day2", "summary": ["segments": [["text": "第二天", "style": "normal", "url": NSNull()]]], "highlights": []],
                ["performanceID": "perf-1", "dayLabel": "Day1", "summary": ["segments": [["text": "第一天A", "style": "normal", "url": NSNull()]]], "highlights": []],
                ["performanceID": "perf-1", "dayLabel": "Day1", "summary": ["segments": [["text": "第一天B（重复）", "style": "normal", "url": NSNull()]]], "highlights": []]
            ],
            "ticketLinks": [],
            "goodsLinks": [],
            "warnings": []
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: modelJSON)
        let jsonText = String(data: jsonData, encoding: .utf8)!
        let sseBody = Self.sseCompletedEvent(outputText: jsonText)

        AssistantStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data(sseBody.utf8))
        }

        let client = OpenAIResponsesClient(session: Self.stubbedSession())
        let summarizer = AssistantSummarizer(client: client)
        let summary = try await summarizer.summarize(bundle: bundle, model: "gpt-5-mini", transport: .openAIAPI(apiKey: "sk-test"))

        XCTAssertEqual(summary.performances.count, 2)
        XCTAssertEqual(summary.performances.map(\.performanceID), ["perf-1", "perf-2"])
        XCTAssertEqual(summary.performances[0].summary.plainText, "第一天A")
    }

    @MainActor
    func testCallbackPortParsesValidPortAndFallsBackOtherwise() {
        XCTAssertEqual(ChatGPTSignInFlow.callbackPort(for: "http://localhost:70000/auth/callback"), 1455)
        XCTAssertEqual(ChatGPTSignInFlow.callbackPort(for: "http://localhost:8080/auth/callback"), 8080)
        XCTAssertEqual(ChatGPTSignInFlow.callbackPort(for: "http://localhost/auth/callback"), 1455)
    }

    func testSSEParserHandlesResponseFailed() async {
        AssistantStubURLProtocol.handler = { request in
            let body = "data: {\"type\":\"response.failed\",\"error\":{\"message\":\"boom\"}}\n\n"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data(body.utf8))
        }
        let client = OpenAIResponsesClient(session: Self.stubbedSession())
        do {
            _ = try await client.generateStructured(
                model: "gpt-5-mini", instructions: "x", input: "y", schemaName: "s",
                schema: ["type": "object"], transport: .openAIAPI(apiKey: "sk-test")
            )
            XCTFail("expected error")
        } catch let AssistantError.provider(message) {
            XCTAssertEqual(message, "boom")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - AssistantSummaryStore

    func testSummaryStoreRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AssistantSummaryStore(directory: directory)
        let summary = Self.fixtureSummary(eventID: "event-1")
        try await store.save(summary)

        let loaded = try await store.summary(for: "event-1")
        XCTAssertEqual(loaded, summary)

        let all = try await store.all()
        XCTAssertEqual(all.count, 1)

        try await store.remove(eventID: "event-1")
        let afterRemove = try await store.summary(for: "event-1")
        XCTAssertNil(afterRemove)
    }

    // MARK: - AssistantAccountStore

    func testAccountStoreRoundTripsAPIKeyAndChatGPTCredentialsWithMaskedHints() async throws {
        let store = AssistantAccountStore(secrets: InMemorySecretStore())

        try await store.save(.apiKey("sk-abcdef1234"))
        let loadedKey = await store.load()
        XCTAssertEqual(loadedKey, .apiKey("sk-abcdef1234"))
        if case .apiKey(let hint) = loadedKey?.accountState {
            XCTAssertTrue(hint.hasSuffix("1234"))
            XCTAssertFalse(hint.contains("abcdef1234"))
        } else {
            XCTFail("expected apiKey account state")
        }

        let session = ChatGPTSession(accessToken: "at", refreshToken: "rt", idToken: nil, expiresAt: nil, accountID: "acct-1", email: "fan@example.com", apiKey: nil)
        try await store.save(.chatGPT(session))
        let loadedSession = await store.load()
        XCTAssertEqual(loadedSession, .chatGPT(session))
        if case .chatGPT(let email, let accountID) = loadedSession?.accountState {
            XCTAssertEqual(email, "fan@example.com")
            XCTAssertEqual(accountID, "acct-1")
        } else {
            XCTFail("expected chatGPT account state")
        }

        try await store.clear()
        let cleared = await store.load()
        XCTAssertNil(cleared)
    }

    // MARK: - AssistantCoordinator

    @MainActor
    func testCoordinatorIsStaleBeforeAndAfterGenerate() async throws {
        let bundle = Self.fixtureBundle(sourceText: "官网原文全文测试 https://eplus.jp/round1")
        let modelJSON: [String: Any] = [
            "overview": ["segments": [["text": "总览", "style": "normal", "url": NSNull()]]],
            "keyPoints": [],
            "performances": [
                ["performanceID": "perf-1", "dayLabel": "Day1", "summary": ["segments": [["text": "第一天", "style": "normal", "url": NSNull()]]], "highlights": []],
                ["performanceID": "perf-2", "dayLabel": "Day2", "summary": ["segments": [["text": "第二天", "style": "normal", "url": NSNull()]]], "highlights": []]
            ],
            "ticketLinks": [],
            "goodsLinks": [],
            "warnings": []
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: modelJSON)
        let jsonText = String(data: jsonData, encoding: .utf8)!
        let sseBody = Self.sseCompletedEvent(outputText: jsonText)

        AssistantStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data(sseBody.utf8))
        }

        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())
        try await accountStore.save(.apiKey("sk-test"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let summaryStore = AssistantSummaryStore(directory: directory)
        let client = OpenAIResponsesClient(session: Self.stubbedSession())

        let coordinator = AssistantCoordinator(accountStore: accountStore, summaryStore: summaryStore, client: client)
        await coordinator.load()

        XCTAssertTrue(coordinator.isStale(bundle))

        let summary = await coordinator.generate(for: bundle)
        XCTAssertNotNil(summary)
        XCTAssertFalse(coordinator.isStale(bundle))
    }

    @MainActor
    func testCoordinatorMigratesLegacyDefaultToChatGPTBackendDefault() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gpt-5-mini", forKey: "assistant.model")

        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())
        try await accountStore.save(.chatGPT(Self.chatGPTSession()))
        let coordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            defaults: defaults
        )

        await coordinator.load()

        XCTAssertTrue(coordinator.usesChatGPTBackend)
        XCTAssertEqual(coordinator.model, AssistantCoordinator.defaultChatGPTModel)
        XCTAssertEqual(defaults.string(forKey: "assistant.model.chatGPT"), AssistantCoordinator.defaultChatGPTModel)
    }

    @MainActor
    func testCoordinatorPreservesCustomLegacyModelForChatGPTBackend() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("custom-chat-model", forKey: "assistant.model")

        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())
        try await accountStore.save(.chatGPT(Self.chatGPTSession()))
        let coordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            defaults: defaults
        )

        await coordinator.load()

        XCTAssertTrue(coordinator.usesChatGPTBackend)
        XCTAssertEqual(coordinator.model, "custom-chat-model")
        XCTAssertEqual(defaults.string(forKey: "assistant.model.chatGPT"), "custom-chat-model")
    }

    @MainActor
    func testCoordinatorTreatsExchangedChatGPTCredentialAsAPITransportDuringMigration() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gpt-5-mini", forKey: "assistant.model")

        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())
        try await accountStore.save(.chatGPT(Self.chatGPTSession(apiKey: "sk-exchanged")))
        let coordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            defaults: defaults
        )

        await coordinator.load()

        XCTAssertFalse(coordinator.usesChatGPTBackend)
        XCTAssertEqual(coordinator.model, AssistantCoordinator.defaultAPIModel)
        XCTAssertEqual(defaults.string(forKey: "assistant.model.api"), AssistantCoordinator.defaultAPIModel)
        XCTAssertNil(defaults.string(forKey: "assistant.model.chatGPT"))
    }

    @MainActor
    func testCoordinatorPersistsModelsIndependentlyWhenSwitchingAccountTransports() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())

        try await accountStore.save(.apiKey("sk-first"))
        let apiCoordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            defaults: defaults
        )
        await apiCoordinator.load()
        XCTAssertEqual(apiCoordinator.model, AssistantCoordinator.defaultAPIModel)
        apiCoordinator.model = "api-custom-model"

        try await accountStore.save(.chatGPT(Self.chatGPTSession()))
        let chatGPTCoordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            defaults: defaults
        )
        await chatGPTCoordinator.load()
        XCTAssertTrue(chatGPTCoordinator.usesChatGPTBackend)
        XCTAssertEqual(chatGPTCoordinator.model, AssistantCoordinator.defaultChatGPTModel)
        chatGPTCoordinator.model = "chat-custom-model"

        try await chatGPTCoordinator.signIn(apiKey: "sk-second")
        XCTAssertFalse(chatGPTCoordinator.usesChatGPTBackend)
        XCTAssertEqual(chatGPTCoordinator.model, "api-custom-model")

        try await accountStore.save(.chatGPT(Self.chatGPTSession()))
        let reloadedChatGPTCoordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            defaults: defaults
        )
        await reloadedChatGPTCoordinator.load()
        XCTAssertEqual(reloadedChatGPTCoordinator.model, "chat-custom-model")
    }

    @MainActor
    func testCoordinatorTestConnectionUsesSelectedChatGPTModelAndBackendHeaders() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gpt-5-mini", forKey: "assistant.model")

        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())
        try await accountStore.save(.chatGPT(Self.chatGPTSession()))
        let requestBox = RequestBox()
        AssistantStubURLProtocol.handler = { request in
            requestBox.set(request, body: try Self.requestBodyData(from: request))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(Self.sseCompletedEvent(outputText: #"{"ok":"ok"}"#).utf8))
        }
        let coordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            client: OpenAIResponsesClient(session: Self.stubbedSession()),
            defaults: defaults
        )
        await coordinator.load()

        let selectedModel = try await coordinator.testConnection()

        XCTAssertEqual(selectedModel, AssistantCoordinator.defaultChatGPTModel)
        let captured = try XCTUnwrap(requestBox.get())
        let request = captured.request
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "responses=experimental")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: captured.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, AssistantCoordinator.defaultChatGPTModel)
    }

    @MainActor
    func testGenerateStaleRetriesFailedFingerprintAfterModelChanges() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "assistant.autoSummarize")

        let counter = LockedCounter()
        AssistantStubURLProtocol.handler = { request in
            counter.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("failed".utf8)
            )
        }
        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())
        try await accountStore.save(.apiKey("sk-test"))
        let coordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            client: OpenAIResponsesClient(session: Self.stubbedSession()),
            defaults: defaults
        )
        await coordinator.load()
        let bundle = Self.fixtureBundle(sourceText: "官网原文")

        await coordinator.generateStale(in: [bundle])
        await coordinator.generateStale(in: [bundle])
        XCTAssertEqual(counter.get(), 1, "unchanged failed input should remain suppressed")

        coordinator.model = "another-api-model"
        await coordinator.generateStale(in: [bundle])
        XCTAssertEqual(counter.get(), 2, "changing models should allow the failed input to retry")
    }

    @MainActor
    func testInFlightFailureFromOldModelDoesNotSuppressRetryForNewModel() async throws {
        let (defaults, suiteName) = Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "assistant.autoSummarize")

        let firstRequestStarted = expectation(description: "first request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let counter = LockedCounter()
        AssistantStubURLProtocol.handler = { request in
            if counter.increment() == 1 {
                firstRequestStarted.fulfill()
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("failed".utf8)
            )
        }
        let accountStore = AssistantAccountStore(secrets: InMemorySecretStore())
        try await accountStore.save(.apiKey("sk-test"))
        let coordinator = AssistantCoordinator(
            accountStore: accountStore,
            summaryStore: Self.temporarySummaryStore(),
            client: OpenAIResponsesClient(session: Self.stubbedSession()),
            defaults: defaults
        )
        await coordinator.load()
        let bundle = Self.fixtureBundle(sourceText: "官网原文")

        let oldGeneration = Task { await coordinator.generateStale(in: [bundle]) }
        await fulfillment(of: [firstRequestStarted], timeout: 5)
        coordinator.model = "new-api-model"
        releaseFirstRequest.signal()
        await oldGeneration.value

        await coordinator.generateStale(in: [bundle])
        XCTAssertEqual(counter.get(), 2, "an old-model failure must not suppress the new-model request")
    }

    // MARK: - Fixtures

    private static func base64URLEncode(_ string: String) -> String {
        base64URLEncode(Data(string.utf8))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sseCompletedEvent(outputText: String) -> String {
        let responseObject: [String: Any] = [
            "output": [
                [
                    "type": "message",
                    "content": [
                        ["type": "output_text", "text": outputText]
                    ]
                ]
            ]
        ]
        let event: [String: Any] = ["type": "response.completed", "response": responseObject]
        let data = try! JSONSerialization.data(withJSONObject: event)
        let text = String(data: data, encoding: .utf8)!
        return "data: \(text)\n\n"
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AssistantServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func temporarySummaryStore() -> AssistantSummaryStore {
        AssistantSummaryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private static func chatGPTSession(apiKey: String? = nil) -> ChatGPTSession {
        ChatGPTSession(
            accessToken: "at-test",
            refreshToken: nil,
            idToken: nil,
            expiresAt: nil,
            accountID: "acct-test",
            email: "fan@example.com",
            apiKey: apiKey
        )
    }

    private static func fixtureSummary(eventID: String) -> AssistantEventSummary {
        AssistantEventSummary(
            eventID: eventID,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "gpt-5-mini",
            sourceFingerprint: "abc123",
            overview: AssistantRichText("总览"),
            keyPoints: [],
            performances: [],
            ticketLinks: [],
            goodsLinks: [],
            warnings: []
        )
    }

    private static func fixtureBundle(sourceText: String?) -> LiveEventBundle {
        let event = LiveEvent(
            id: "event-1",
            franchise: .bangdream,
            officialTitle: "Test LIVE",
            groups: ["Roselia"],
            eventType: .live,
            status: .scheduled,
            primarySourceURL: "https://bang-dream.com/events/test-live/",
            timeZone: "Asia/Tokyo"
        )
        let start1 = ISO8601DateFormatter().date(from: "2027-03-01T11:00:00Z")!
        let start2 = ISO8601DateFormatter().date(from: "2027-03-02T11:00:00Z")!
        let performances = [
            Performance(id: "perf-1", eventID: "event-1", stopID: nil, dayLabel: "Day1", subtitle: nil,
                localDate: "2027-03-01", doorsAt: nil, startAt: start1, venueName: "Test Hall", venueCity: "Tokyo",
                performers: ["Roselia"], order: 0),
            Performance(id: "perf-2", eventID: "event-1", stopID: nil, dayLabel: "Day2", subtitle: nil,
                localDate: "2027-03-02", doorsAt: nil, startAt: start2, venueName: "Test Hall", venueCity: "Tokyo",
                performers: ["Roselia"], order: 1)
        ]
        let round = TicketRound(
            id: "round-1", eventID: "event-1", officialName: "一般先行", kind: .lottery, scope: .wholeEvent,
            applyStartAt: nil, applyEndAt: nil, resultAt: nil, paymentDeadlineAt: nil, eligibility: nil,
            announcementURL: nil, applyURL: "https://eplus.jp/round1", overseasURL: nil, officialStatus: nil,
            status: .confirmed, links: [OfficialLink(label: "eplus", url: "https://eplus.jp/round1")]
        )
        return LiveEventBundle(
            schemaVersion: 1, publishedAt: .distantPast, event: event, stops: [], performances: performances,
            ticketTiers: [], ticketRounds: [round], ticketOffers: [], goodsCampaigns: [], mediaAssets: [],
            notices: [], evidence: [], sourceText: sourceText
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return current
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: (request: URLRequest, body: Data)?

    func set(_ request: URLRequest, body: Data) {
        lock.lock()
        captured = (request, body)
        lock.unlock()
    }

    func get() -> (request: URLRequest, body: Data)? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

private final class AssistantStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
