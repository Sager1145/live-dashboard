import XCTest
import UniformTypeIdentifiers
@testable import LiveDashboardKit

final class MediaPresentationTests: XCTestCase {
    private func media(_ id: String = "image", url: String = "https://example.com/goods.jpg", kind: MediaContentKind? = nil) -> MediaAsset {
        MediaAsset(id: id, eventID: "event", kind: .goodsList, originalURL: url, thumbnailURL: nil,
            scope: .unconfirmed, sourceURL: "https://example.com/live", version: 1, caption: "Goods", contentKind: kind)
    }

    func testLegacyImageAndExplicitOpaqueImageDisplayWhilePageLinksDoNot() {
        XCTAssertTrue(media().isImage) // old link_only records with actual image URLs
        XCTAssertTrue(media(url: "https://example.com/image?id=1", kind: .image).isImage)
        XCTAssertFalse(media(url: "https://example.com/shop", kind: .link).isImage)
        XCTAssertFalse(media(url: "https://example.com/shop").isImage)
        XCTAssertFalse(media(url: "https://example.com/fake.jpg", kind: .link).isImage)
    }

    func testMediaContentKindRoundTripsWithoutBreakingLegacyRecords() throws {
        let original = media(url: "https://example.com/image?id=1", kind: .image)
        let data = try LiveEventBundle.encoder.encode(original)
        XCTAssertEqual(try LiveEventBundle.decoder.decode(MediaAsset.self, from: data), original)
        let legacy = media()
        XCTAssertTrue(try LiveEventBundle.decoder.decode(MediaAsset.self, from: LiveEventBundle.encoder.encode(legacy)).isImage)
    }

    func testShareFileUsesActualImageFormatAndUsefulFilename() {
        let response = OfficialMediaResponse(data: MediaDownloadProtocol.png, mimeType: "image/jpeg", suggestedFilename: "image.php")
        let url = URL(string: "https://example.com/image?id=1")!
        XCTAssertEqual(imageType(for: response, url: url), .png)
        XCTAssertEqual(exportFilename(suggested: "image.php", url: url, contentType: .png), "image.png")
        XCTAssertEqual(exportFilename(suggested: nil, url: url, contentType: .png), "image.png")
    }

    func testPrepareShareFileWritesOriginalBytesWithTypedFilename() throws {
        let response = OfficialMediaResponse(data: MediaDownloadProtocol.png, mimeType: "text/html", suggestedFilename: "image.php")
        let url = URL(string: "https://example.com/image?id=1")!
        let fileURL = try prepareShareFile(response: response, url: url)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        XCTAssertEqual(fileURL.lastPathComponent, "image.png")
        XCTAssertEqual(try Data(contentsOf: fileURL), MediaDownloadProtocol.png)
    }

    func testLoaderPreservesOriginalBytesAndRejectsFailedHTTPResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaDownloadProtocol.self]
        let loader = URLSessionOfficialMediaLoader(session: URLSession(configuration: configuration))
        let image = try await loader.load(URL(string: "https://example.com/original")!)
        XCTAssertEqual(image.data, MediaDownloadProtocol.png)
        do {
            _ = try await loader.load(URL(string: "https://example.com/missing")!)
            XCTFail("A failed HTTP response must not become a downloaded image")
        } catch let error as OfficialMediaError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error") }
        }
    }

    func testLoveLiveImageUsesCompatibleRequestAndDecodesMislabeledImage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaDownloadProtocol.self]
        let loader = URLSessionOfficialMediaLoader(session: URLSession(configuration: configuration))
        let url = URL(string: "https://www.lovelive-anime.jp/special/live/image.php?img_path=/goods.jpeg")!
        let response = try await loader.load(url)
        XCTAssertEqual(response.data, MediaDownloadProtocol.png)
        // The real image.php endpoint reports text/html even for valid images.
        XCTAssertEqual(response.mimeType, "text/html")
        XCTAssertEqual(imageType(for: response, url: url), .png)
        XCTAssertNil(OfficialWebsiteHeaders.compatibleUserAgent(for: URL(string: "https://bang-dream.com/image.jpg")!))
    }

    private func campaign(_ id: String = "goods", assets: [String]) -> GoodsCampaign {
        GoodsCampaign(id: id, eventID: "event", officialName: "グッズ", channel: .unknown, fulfillment: .unknown,
            phase: .unknown, scope: .unconfirmed, salesStartAt: nil, salesEndAt: nil, pickupWindow: nil,
            shippingNote: nil, location: nil, requiresTicket: nil, purchaseLimit: nil, paymentMethods: nil,
            url: "https://example.com/shop", mediaAssetIDs: assets, status: .confirmed)
    }

    func testImageOnlyCampaignWithUnknownChannelRemainsVisible() {
        let goods = campaign(assets: ["image"])
        let sections = ImportantInformationPolicy.goodsTabSections(applicableCampaigns: [goods])
        XCTAssertEqual(sections.other.map(\.id), ["goods"])
    }

    func testRefreshingGoodsCardBringsItsImagesAndPreservesUnrelatedMedia() throws {
        let now = Date()
        let event = LiveEvent(id: "event", franchise: .bangdream, officialTitle: "Live", groups: [], eventType: .live,
            status: .scheduled, primarySourceURL: "https://example.com/live", timeZone: "Asia/Tokyo")
        func bundle(campaigns: [GoodsCampaign], media: [MediaAsset], evidence: [SourceEvidence]) -> LiveEventBundle {
            LiveEventBundle(schemaVersion: 1, publishedAt: now, event: event, stops: [], performances: [],
                ticketTiers: [], ticketRounds: [], ticketOffers: [], goodsCampaigns: campaigns,
                mediaAssets: media, notices: [], evidence: evidence)
        }
        let unrelated = media("unrelated", url: "https://example.com/unrelated.png")
        let saved = bundle(campaigns: [campaign(assets: [])], media: [unrelated], evidence: [])
        let image = media(kind: .image)
        let evidence = [
            SourceEvidence(id: "goods-proof", recordID: "goods", field: "goods.campaign", sourceURL: event.primarySourceURL,
                quote: "グッズ", sourcePublishedAt: nil, verifiedAt: now, verification: .confirmed),
            SourceEvidence(id: "image-proof", recordID: "image", field: "media.asset", sourceURL: event.primarySourceURL,
                quote: image.originalURL, sourcePublishedAt: nil, verifiedAt: now, verification: .confirmed)
        ]
        let fresh = bundle(campaigns: [campaign(assets: [image.id])], media: [image], evidence: evidence)
        let result = try CardRefreshMerge.apply(fresh, to: saved, cardType: .goodsCampaign, entityID: "goods")
        XCTAssertEqual(Set(result.mediaAssets.map(\.id)), ["image", "unrelated"])
        XCTAssertEqual(result.mediaAssets.first { $0.id == "unrelated" }, unrelated)
        XCTAssertEqual(result.goodsCampaigns.first?.mediaAssetIDs, ["image"])
        XCTAssertTrue(result.evidence.contains { $0.recordID == "image" })
    }
}

private final class MediaDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isLoveLive = request.url!.host == "www.lovelive-anime.jp"
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        let compatible = agent.contains("Safari/") && agent.contains("Mobile/") && agent.contains("LiveDashboard/")
        let status = isLoveLive && !compatible ? 403 : (request.url!.lastPathComponent == "missing" ? 404 : 200)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": isLoveLive ? "text/html" : "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
