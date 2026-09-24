import XCTest
@testable import LiveDashboardKit

/// Index → detail → entity. Similar HTML is not an identity. A fragment on
/// the same path is.
final class OfficialDiscoveryTests: XCTestCase {
    override func tearDown() {
        DiscoveryURLProtocol.handler = nil
        super.tearDown()
    }

    func testSimilarBodiesOnDifferentPathsStaySeparateEvents() async throws {
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Taipei</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2026年5月1日(金)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>台北・Legacy</p>
          </div>
        </article>
        """
        let index = """
        <html><section class="p-live-event-list">
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/taipei-day1/">
            <div class="p-live-event-list__item-title">Taipei DAY1</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2026年5月1日(金)</p></div>
          </a></article>
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/taipei-day2/">
            <div class="p-live-event-list__item-title">Taipei DAY2</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2026年5月2日(土)</p></div>
          </a></article>
        </section></html>
        """
        DiscoveryURLProtocol.handler = { request in
            if request.url?.path == "/events/" || request.url?.path == "/events" { return Self.response(request, body: index) }
            return Self.response(request, body: detail)
        }
        let bundles = try await OfficialEventScraper(
            session: session(),
            indexURLs: [URL(string: "https://bang-dream.com/events/")!]
        ).collect(existing: [], cutoff: "2026-01-01", now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(bundles.count, 2)
        XCTAssertEqual(Set(bundles.map(\.event.id)).count, 2)
        XCTAssertEqual(Set(bundles.map(\.event.primarySourceURL)).count, 2)
    }

    func testFragmentOnTheSamePathIsOneEvent() async throws {
        let index = """
        <html><section class="p-live-event-list">
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/taipei/#day1">
            <div class="p-live-event-list__item-title">Taipei</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2026年5月1日(金)</p></div>
          </a></article>
          <article class="p-live-event-list__item"><a class="p-live-event-list__item-link" href="/events/taipei/#day2">
            <div class="p-live-event-list__item-title">Taipei</div>
            <div><h2 class="p-live-event-list__item-date">開催日</h2><p>2026年5月1日(金)</p></div>
          </a></article>
        </section></html>
        """
        let detail = """
        <article class="p-live-event-detail">
          <h1 class="p-live-event-detail__header-title">Taipei</h1>
          <div class="p-live-event-detail__content">
            <h2>日程</h2><p>2026年5月1日(金)　開場17:00／開演18:00</p>
            <h2>会場</h2><p>台北・Legacy</p>
          </div>
        </article>
        """
        var detailFetches = 0
        DiscoveryURLProtocol.handler = { request in
            if request.url?.path == "/events/" || request.url?.path == "/events" { return Self.response(request, body: index) }
            detailFetches += 1
            return Self.response(request, body: detail)
        }
        let bundles = try await OfficialEventScraper(
            session: session(),
            indexURLs: [URL(string: "https://bang-dream.com/events/")!]
        ).collect(existing: [], cutoff: "2026-01-01", now: Self.date("2026-09-22T12:00:00Z"))

        XCTAssertEqual(bundles.count, 1)
        XCTAssertEqual(detailFetches, 1)
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private static func response(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        return (response, Data(body.utf8))
    }
}

private final class DiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
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
