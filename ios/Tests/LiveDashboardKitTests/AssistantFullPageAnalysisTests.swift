import XCTest
@testable import LiveDashboardKit

final class AssistantFullPageAnalysisTests: XCTestCase {
    override func tearDown() {
        FullPageURLProtocol.handler = nil
        FullPageURLProtocol.requests = []
        FullPageURLProtocol.requestBodies = []
        super.tearDown()
    }

    func testLivePageBuildsIndependentBundleAndPreservesMatchingPerformanceIdentity() async throws {
        let original = Self.bundle(
            eventID: "event-stable",
            performanceID: "performance-stable",
            sourceText: "STALE SCRAPER VALUE"
        )
        let generated = Self.bundle(
            eventID: "model-invented-event",
            performanceID: "model-invented-performance",
            sourceText: nil,
            evidence: [
                SourceEvidence(
                    id: "admission-evidence",
                    recordID: "model-invented-event",
                    field: "event.admission",
                    sourceURL: original.event.primarySourceURL,
                    quote: "Fresh admission: photo ID required",
                    sourcePublishedAt: nil,
                    verifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    verification: .confirmed
                )
            ]
        )
        let modelJSON = try Self.modelOutput(bundle: generated)
        let session = Self.session()

        FullPageURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                let html = "<html><body><h1>Fresh official title</h1><p>Fresh admission: photo ID required</p><a href='/tickets'>Tickets</a></body></html>"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
            }
            let event = try Self.completedSSE(outputText: modelJSON)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(event.utf8))
        }

        let summarizer = AssistantSummarizer(
            client: OpenAIResponsesClient(session: session),
            officialPageSession: session
        )
        let summary = try await summarizer.summarize(
            bundle: original,
            model: "test-model",
            transport: .openAIAPI(apiKey: "test-key"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let organized = try XCTUnwrap(summary.organizedBundle)
        XCTAssertEqual(organized.event.id, original.event.id)
        XCTAssertEqual(organized.event.primarySourceURL, original.event.primarySourceURL)
        XCTAssertEqual(organized.performances.map(\.id), ["performance-stable"])
        XCTAssertTrue(organized.sourceText?.contains("Fresh official title") == true)
        XCTAssertFalse(organized.sourceText?.contains("STALE SCRAPER VALUE") == true)
        XCTAssertEqual(organized.evidence.first?.recordID, original.event.id)
        XCTAssertEqual(organized.evidence.first?.field, "event.admission")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AssistantSummaryStore(directory: directory)
        try await store.save(summary)
        let reloaded = try await store.summary(for: original.event.id)
        XCTAssertEqual(reloaded?.organizedBundle, organized)

        let dateField = try XCTUnwrap(summary.organizedFields?.first { $0.section == "时间" && $0.label == "日期" })
        XCTAssertEqual(dateField.performanceIDs, ["performance-stable"])
        XCTAssertTrue(summary.organizedFields?.contains { $0.section == "座位" && $0.label == "座位图" && $0.value == "官网未说明" } == true)

        let requests = FullPageURLProtocol.requests
        XCTAssertEqual(requests.first?.cachePolicy, .reloadIgnoringLocalCacheData)
        let postBody = FullPageURLProtocol.requestBodies.map { String(decoding: $0, as: UTF8.self) }
            .first { $0.contains("Fresh official title") } ?? ""
        XCTAssertTrue(postBody.contains("Fresh official title"))
        XCTAssertFalse(postBody.contains("STALE SCRAPER VALUE"))
    }

    func testFreshFetchFailureDoesNotFallBackToCapturedSourceOrCallModel() async {
        let original = Self.bundle(eventID: "event", performanceID: "performance", sourceText: "stale")
        let session = Self.session()
        FullPageURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let summarizer = AssistantSummarizer(
            client: OpenAIResponsesClient(session: session),
            officialPageSession: session
        )

        do {
            _ = try await summarizer.summarize(
                bundle: original,
                model: "test-model",
                transport: .openAIAPI(apiKey: "test-key")
            )
            XCTFail("Expected live-page fetch failure")
        } catch let AssistantError.provider(message) {
            XCTAssertTrue(message.contains("500"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(FullPageURLProtocol.requests.count, 1)
    }

    func testLiveGenerationRejectsMissingOrganizedBundle() async throws {
        let original = Self.bundle(eventID: "event", performanceID: "performance", sourceText: "stale")
        let legacyOutput = try Self.modelOutput(bundle: nil)
        let session = Self.session()
        FullPageURLProtocol.handler = Self.successHandler(modelJSON: legacyOutput)
        let summarizer = AssistantSummarizer(
            client: OpenAIResponsesClient(session: session),
            officialPageSession: session
        )

        do {
            _ = try await summarizer.summarize(
                bundle: original,
                model: "test-model",
                transport: .openAIAPI(apiKey: "test-key")
            )
            XCTFail("Expected missing organizedBundle to be rejected")
        } catch let AssistantError.invalidOutput(message) {
            XCTAssertTrue(message.contains("organizedBundle"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLiveGenerationRejectsBrokenPerformanceScope() async throws {
        let original = Self.bundle(eventID: "event", performanceID: "performance", sourceText: "stale")
        let brokenRound = TicketRound(
            id: "round",
            eventID: "generated-event",
            officialName: "Broken round",
            kind: .lottery,
            scope: .performances(performanceIDs: ["missing-performance"]),
            applyStartAt: nil,
            applyEndAt: nil,
            resultAt: nil,
            paymentDeadlineAt: nil,
            eligibility: nil,
            announcementURL: nil,
            applyURL: nil,
            overseasURL: nil,
            officialStatus: nil,
            status: .needsReview
        )
        let generated = Self.bundle(
            eventID: "generated-event",
            performanceID: "generated-performance",
            sourceText: nil,
            ticketRounds: [brokenRound]
        )
        let session = Self.session()
        FullPageURLProtocol.handler = Self.successHandler(modelJSON: try Self.modelOutput(bundle: generated))
        let summarizer = AssistantSummarizer(
            client: OpenAIResponsesClient(session: session),
            officialPageSession: session
        )

        do {
            _ = try await summarizer.summarize(
                bundle: original,
                model: "test-model",
                transport: .openAIAPI(apiKey: "test-key")
            )
            XCTFail("Expected broken scope to be rejected")
        } catch let AssistantError.invalidOutput(message) {
            XCTAssertTrue(message.contains("performanceID"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOfficialPageTextResolvesRelativeLinksAndRemovesExecutablePageContent() {
        let html = """
        <html><script>IGNORE-ME</script><body><p>Official facts</p>
        <a href="../tickets/apply">Apply</a>
        <a href="/map"><img alt="Seating map" src="/assets/map.png"></a>
        <a href="#tickets">Ticket details</a></body></html>
        """
        let baseURL = URL(string: "https://official.example/events/one/")!
        let text = AssistantSummarizer.officialPageText(from: html, baseURL: baseURL)

        XCTAssertTrue(text.contains("Official facts"))
        XCTAssertFalse(text.contains("IGNORE-ME"))
        XCTAssertTrue(text.contains("https://official.example/events/tickets/apply"))
        XCTAssertTrue(text.contains("https://official.example/assets/map.png"))
        XCTAssertTrue(text.contains("Seating map（https://official.example/assets/map.png）"))
        XCTAssertTrue(AssistantSummarizer.allowedURLs(sourceText: html, baseURL: baseURL).contains("https://official.example/events/one/#tickets"))
    }

    private static func bundle(
        eventID: String,
        performanceID: String,
        sourceText: String?,
        evidence: [SourceEvidence] = [],
        ticketRounds: [TicketRound] = []
    ) -> LiveEventBundle {
        let event = LiveEvent(
            id: eventID,
            franchise: .bangdream,
            officialTitle: "Fixture Event",
            groups: [],
            eventType: .live,
            status: .scheduled,
            primarySourceURL: "https://official.example/events/one/",
            timeZone: "Asia/Tokyo"
        )
        let performance = Performance(
            id: performanceID,
            eventID: eventID,
            stopID: nil,
            dayLabel: "Day 1",
            subtitle: nil,
            localDate: "2027-01-02",
            doorsAt: nil,
            startAt: nil,
            venueName: "Official Hall",
            venueCity: "Tokyo",
            performers: [],
            order: 0
        )
        return LiveEventBundle(
            schemaVersion: 1,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            event: event,
            stops: [],
            performances: [performance],
            ticketTiers: [],
            ticketRounds: ticketRounds,
            ticketOffers: [],
            goodsCampaigns: [],
            mediaAssets: [],
            notices: [],
            evidence: evidence,
            sourceText: sourceText
        )
    }

    private static func modelOutput(bundle: LiveEventBundle?) throws -> String {
        var output: [String: Any] = [
            "overview": ["segments": [["text": "Fresh overview", "style": "normal", "url": NSNull()]]],
            "keyPoints": [],
            "performances": [[
                "performanceID": "model-invented-performance",
                "dayLabel": "Day 1",
                "summary": ["segments": [["text": "Fresh performance", "style": "normal", "url": NSNull()]]],
                "highlights": []
            ]],
            "ticketLinks": [],
            "goodsLinks": [],
            "organizedFields": [[
                "id": "date-field",
                "section": "时间",
                "label": "日期",
                "value": "2027-01-02",
                "performanceIDs": ["model-invented-performance"]
            ]],
            "warnings": []
        ]
        if let bundle {
            let bundleData = try LiveEventBundle.encoder.encode(bundle)
            output["organizedBundle"] = try JSONSerialization.jsonObject(with: bundleData)
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
    }

    private static func successHandler(modelJSON: String) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            if request.httpMethod == "GET" {
                let html = "<html><body>Fresh official page</body></html>"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(html.utf8))
            }
            let event = try completedSSE(outputText: modelJSON)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(event.utf8))
        }
    }

    private static func completedSSE(outputText: String) throws -> String {
        let payload: [String: Any] = [
            "type": "response.completed",
            "response": [
                "output": [[
                    "type": "message",
                    "content": [["type": "output_text", "text": outputText]]
                ]]
            ]
        ]
        return "data: \(String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))\n\n"
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FullPageURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class FullPageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            Self.requestBodies.append(try Self.bodyData(from: request))
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

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
