import XCTest
import UniformTypeIdentifiers
@testable import LiveDashboardKit

final class MediaPresentationTests: XCTestCase {
    private func media(_ id: String = "image", url: String = "https://example.com/goods.jpg", kind: MediaContentKind? = nil) -> MediaAsset {
        MediaAsset(id: id, eventID: "event", kind: .goodsList, originalURL: url, thumbnailURL: nil,
            scope: .unconfirmed, sourceURL: "https://example.com/live", version: 1, caption: "Goods", contentKind: kind)
    }

    func testGoodsImagesFollowCitationOrderAndCollapseThumbnailTwins() {
        func asset(_ id: String, url: String, thumb: String? = nil, scope: Scope = .performances(performanceIDs: ["p"])) -> MediaAsset {
            MediaAsset(id: id, eventID: "event", kind: .goodsList, originalURL: url, thumbnailURL: thumb,
                scope: scope, sourceURL: "https://example.com/live", version: 1, caption: nil, displayPolicy: .remoteDisplay, contentKind: .image)
        }
        let full = asset("b", url: "https://example.com/full.jpg", thumb: "https://example.com/full-thumb.jpg")
        let twin = asset("a", url: "https://example.com/full-thumb.jpg", scope: .performances(performanceIDs: ["p"]))
        let later = asset("c", url: "https://example.com/second.jpg")
        let otherHall = asset("d", url: "https://example.com/kobe.jpg", scope: .performances(performanceIDs: ["other"]))
        let pending = asset("e", url: "https://example.com/unknown.jpg", scope: .unconfirmed)
        let shown = GoodsImageSequence.presentation(
            mediaAssetIDs: ["b", "a", "c", "d", "e"],
            mediaAssets: [later, twin, full, otherHall, pending],
            selectedPerformanceID: "p",
            selectedStopID: nil
        )
        XCTAssertEqual(shown.inline.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(shown.pending.map(\.id), ["e"])
    }

    func testTwelveDistinctAssetIDsStayTwelvePresentationItems() {
        let ids = (1...12).map { "asset-\($0)" }
        let assets = ids.map { id in
            MediaAsset(id: id, eventID: "event", kind: .goodsList, originalURL: "https://example.com/\(id).jpg",
                thumbnailURL: "https://example.com/\(id)-400.jpg", scope: .performances(performanceIDs: ["p"]),
                sourceURL: "https://example.com/live", version: 1, caption: nil, displayPolicy: .remoteDisplay, contentKind: .image)
        }
        let shown = GoodsImageSequence.presentation(
            mediaAssetIDs: ids + [ids[0]],
            mediaAssets: assets,
            selectedPerformanceID: "p",
            selectedStopID: nil
        )
        XCTAssertEqual(shown.inline.map(\.id), ids)
        XCTAssertEqual(shown.inline.count, 12)
        XCTAssertTrue(shown.pending.isEmpty)
    }

    func testDifferentAssetIDsAreNotCollapsedWhenSrcsetURLsOverlap() {
        func asset(_ id: String, url: String) -> MediaAsset {
            MediaAsset(id: id, eventID: "event", kind: .goodsList, originalURL: url, thumbnailURL: url,
                scope: .performances(performanceIDs: ["p"]), sourceURL: "https://example.com/live", version: 1,
                caption: nil, displayPolicy: .remoteDisplay, contentKind: .image)
        }
        let shown = GoodsImageSequence.presentation(
            mediaAssetIDs: ["wide", "narrow"],
            mediaAssets: [asset("wide", url: "https://example.com/same.jpg"), asset("narrow", url: "https://example.com/same.jpg")],
            selectedPerformanceID: "p",
            selectedStopID: nil
        )
        XCTAssertEqual(shown.inline.map(\.id), ["wide", "narrow"])
    }

    func testMediaCacheKeyUsesInstanceAssetHashAndVariantAndDropsMismatchedBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MediaStore(directory: directory)
        let bytes = Data("original-bytes".utf8)
        let hash = MediaStore.contentHash(of: bytes)
        let original = MediaCacheKey(serverInstanceID: "instance-a", assetID: "asset-1", contentHash: hash, variant: .original)
        let preview = MediaCacheKey(serverInstanceID: "instance-a", assetID: "asset-1", contentHash: hash, variant: .preview)
        let otherInstance = MediaCacheKey(serverInstanceID: "instance-b", assetID: "asset-1", contentHash: hash, variant: .original)
        let otherAsset = MediaCacheKey(serverInstanceID: "instance-a", assetID: "asset-2", contentHash: hash, variant: .original)
        let otherHash = MediaCacheKey(serverInstanceID: "instance-a", assetID: "asset-1", contentHash: String(repeating: "ab", count: 32), variant: .original)
        XCTAssertNotEqual(store.fileURL(for: original), store.fileURL(for: preview))
        XCTAssertNotEqual(store.fileURL(for: original), store.fileURL(for: otherInstance))
        XCTAssertNotEqual(store.fileURL(for: original), store.fileURL(for: otherAsset))
        XCTAssertNotEqual(store.fileURL(for: original), store.fileURL(for: otherHash))

        let official = URL(string: "https://official.example/original.jpg")!
        let server = URL(string: "https://server.example/media/asset-1")!
        XCTAssertNil(MediaStore.fetchPlan(serverContentURL: nil, officialOriginalURL: official).url)
        XCTAssertFalse(MediaStore.fetchPlan(serverContentURL: nil, officialOriginalURL: official).allowsOfficialOriginalFallback)
        XCTAssertEqual(MediaStore.fetchPlan(serverContentURL: server, officialOriginalURL: official).url, server)

        try store.writeVerified(bytes, key: original)
        XCTAssertThrowsError(try store.writeVerified(Data("other".utf8), key: original))
        let share = try store.shareFile(for: original)
        XCTAssertEqual(try Data(contentsOf: share), bytes)

        try Data("corrupt".utf8).write(to: store.fileURL(for: original), options: .atomic)
        XCTAssertThrowsError(try store.validatedData(for: original)) { error in
            XCTAssertEqual(error as? MediaStoreError, .hashMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: original).path))
        XCTAssertThrowsError(try store.shareFile(for: original))
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
