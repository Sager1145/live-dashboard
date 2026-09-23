import Foundation
import XCTest
@testable import LiveDashboardKit

final class AssistantBundleSchemaTests: XCTestCase {
    func testEveryObjectIsStrictAndRequiresEveryDeclaredProperty() throws {
        try assertStrictObjects(in: AssistantBundleSchema.schema(), path: "$" )
    }

    func testSchemaCoversEveryEncodedBundleFieldAndDeclaresOptionalFieldsNullable() throws {
        let bundle = Self.representativeBundle()
        let data = try LiveEventBundle.encoder.encode(bundle)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = AssistantBundleSchema.schema()

        try assertEncodedValue(encoded, isCoveredBy: schema, path: "$" )

        let expectedProperties: [String: Set<String>] = [
            "$": [
                "schemaVersion", "revision", "publishedAt", "event", "stops", "performances",
                "ticketTiers", "ticketRounds", "ticketOffers", "goodsCampaigns", "mediaAssets",
                "notices", "evidence", "editions", "streamOffers", "products", "goodsSessions",
                "ticketBenefits", "sourceHealth", "sourceText"
            ],
            "event": [
                "id", "franchise", "officialTitle", "groups", "eventType", "status",
                "primarySourceURL", "timeZone"
            ],
            "stops.items": ["id", "eventID", "name", "order"],
            "performances.items": [
                "id", "eventID", "stopID", "dayLabel", "subtitle", "localDate", "rawDate",
                "precision", "timeZone", "doorsAt", "startAt", "venueName", "venueCity",
                "performers", "order", "editionID"
            ],
            "ticketTiers.items": [
                "id", "eventID", "name", "priceJPY", "amount", "priceKind", "includes",
                "feeNote", "taxNote"
            ],
            "ticketRounds.items": [
                "id", "eventID", "officialName", "kind", "scope", "applyStartAt", "applyEndAt",
                "resultAt", "paymentDeadlineAt", "eligibility", "announcementURL", "applyURL",
                "overseasURL", "officialStatus", "status", "links", "applyWindowText", "resultText",
                "paymentStartAt", "paymentWindowText", "quantityLimit", "lotteryProducts",
                "applicationTarget", "notes"
            ],
            "ticketRounds.items.scope": ["kind", "stopID", "performanceIDs"],
            "ticketRounds.items.links.items": ["label", "url", "role", "productNames"],
            "ticketRounds.items.notes.items": ["kind", "text", "links"],
            "ticketOffers.items": ["id", "roundID", "tierID", "performanceIDs", "priceJPY", "amount"],
            "goodsCampaigns.items": [
                "id", "eventID", "officialName", "channel", "fulfillment", "phase", "scope",
                "salesStartAt", "salesEndAt", "pickupWindow", "shippingNote", "location",
                "requiresTicket", "purchaseLimit", "paymentMethods", "url", "mediaAssetIDs",
                "status", "links"
            ],
            "mediaAssets.items": [
                "id", "eventID", "kind", "originalURL", "thumbnailURL", "scope", "sourceURL",
                "version", "caption", "displayPolicy", "contentKind"
            ],
            "notices.items": ["id", "eventID", "kind", "title", "body", "publishedAt", "sourceURL", "scope"],
            "evidence.items": [
                "id", "recordID", "field", "sourceURL", "quote", "sourcePublishedAt",
                "verifiedAt", "verification"
            ],
            "editions.items": ["id", "eventID", "name", "order"],
            "streamOffers.items": [
                "id", "eventID", "platform", "officialName", "scope", "amount", "salesStartAt",
                "salesEndAt", "archiveAvailableUntil", "regionNote", "url", "status"
            ],
            "products.items": [
                "id", "eventID", "campaignID", "name", "amount", "url", "variants", "purchaseLimit"
            ],
            "products.items.variants.items": ["id", "name", "amount", "stockStatus"],
            "goodsSessions.items": ["id", "eventID", "campaignID", "scope", "startsAt", "endsAt", "location"],
            "ticketBenefits.items": [
                "id", "eventID", "officialName", "scope", "tierIDs", "detail", "notes",
                "redemptionLocation", "redemptionWindow", "redemptionNote", "mediaAssetIDs",
                "status", "links"
            ]
        ]

        for (path, expected) in expectedProperties {
            let node = try schemaNode(at: path, in: schema)
            let properties = try XCTUnwrap(node["properties"] as? [String: Any], "Missing properties at \(path)")
            XCTAssertEqual(Set(properties.keys), expected, "Schema fields differ at \(path)")
        }

        let nullablePaths = [
            "revision", "sourceText",
            "performances.items.stopID", "performances.items.subtitle", "performances.items.localDate",
            "performances.items.rawDate", "performances.items.precision", "performances.items.timeZone",
            "performances.items.doorsAt", "performances.items.startAt", "performances.items.editionID",
            "ticketTiers.items.priceJPY", "ticketTiers.items.amount", "ticketTiers.items.includes",
            "ticketTiers.items.feeNote", "ticketTiers.items.taxNote",
            "ticketRounds.items.scope.stopID", "ticketRounds.items.links.items.role",
            "ticketRounds.items.applyStartAt", "ticketRounds.items.applyEndAt", "ticketRounds.items.resultAt",
            "ticketRounds.items.paymentDeadlineAt", "ticketRounds.items.eligibility",
            "ticketRounds.items.announcementURL", "ticketRounds.items.applyURL",
            "ticketRounds.items.overseasURL", "ticketRounds.items.officialStatus",
            "ticketRounds.items.applyWindowText", "ticketRounds.items.resultText",
            "ticketRounds.items.paymentStartAt", "ticketRounds.items.paymentWindowText",
            "ticketRounds.items.quantityLimit", "ticketRounds.items.applicationTarget",
            "ticketOffers.items.priceJPY", "ticketOffers.items.amount",
            "goodsCampaigns.items.salesStartAt", "goodsCampaigns.items.salesEndAt",
            "goodsCampaigns.items.pickupWindow", "goodsCampaigns.items.shippingNote",
            "goodsCampaigns.items.location", "goodsCampaigns.items.requiresTicket",
            "goodsCampaigns.items.purchaseLimit", "goodsCampaigns.items.paymentMethods",
            "goodsCampaigns.items.url", "mediaAssets.items.thumbnailURL", "mediaAssets.items.caption",
            "mediaAssets.items.contentKind", "notices.items.publishedAt",
            "evidence.items.sourcePublishedAt", "streamOffers.items.amount",
            "streamOffers.items.salesStartAt", "streamOffers.items.salesEndAt",
            "streamOffers.items.archiveAvailableUntil", "streamOffers.items.regionNote",
            "streamOffers.items.url", "products.items.amount", "products.items.url",
            "products.items.purchaseLimit", "products.items.variants.items.amount",
            "products.items.variants.items.stockStatus", "goodsSessions.items.startsAt",
            "goodsSessions.items.endsAt", "ticketBenefits.items.detail", "ticketBenefits.items.notes",
            "ticketBenefits.items.redemptionLocation", "ticketBenefits.items.redemptionWindow",
            "ticketBenefits.items.redemptionNote"
        ]

        for path in nullablePaths {
            let node = try schemaNode(at: path, in: schema)
            XCTAssertTrue(supportsNull(node), "Expected nullable schema at \(path)")
        }
    }

    private func assertStrictObjects(in schema: [String: Any], path: String) throws {
        let types = schemaTypes(schema)
        if types.contains("object") {
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, "Object is not strict at \(path)")
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any], "Missing properties at \(path)")
            let required = try XCTUnwrap(schema["required"] as? [String], "Missing required at \(path)")
            XCTAssertEqual(Set(required), Set(properties.keys), "Required fields differ at \(path)")
            for (name, value) in properties {
                let child = try XCTUnwrap(value as? [String: Any], "Invalid schema node at \(path).\(name)")
                try assertStrictObjects(in: child, path: "\(path).\(name)")
            }
        }
        if types.contains("array"), let items = schema["items"] as? [String: Any] {
            try assertStrictObjects(in: items, path: "\(path).items")
        }
    }

    private func assertEncodedValue(_ value: Any, isCoveredBy schema: [String: Any], path: String) throws {
        if let object = value as? [String: Any] {
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any], "No object schema at \(path)")
            for (key, childValue) in object {
                let childSchema = try XCTUnwrap(properties[key] as? [String: Any], "Encoded field missing from schema: \(path).\(key)")
                try assertEncodedValue(childValue, isCoveredBy: childSchema, path: "\(path).\(key)")
            }
        } else if let array = value as? [Any] {
            let items = try XCTUnwrap(schema["items"] as? [String: Any], "No item schema at \(path)")
            for (index, childValue) in array.enumerated() {
                try assertEncodedValue(childValue, isCoveredBy: items, path: "\(path)[\(index)]")
            }
        }
    }

    private func schemaNode(at path: String, in schema: [String: Any]) throws -> [String: Any] {
        if path == "$" { return schema }
        var node = schema
        for component in path.split(separator: ".").map(String.init) {
            if component == "items" {
                node = try XCTUnwrap(node["items"] as? [String: Any], "Missing items in \(path)")
            } else {
                let properties = try XCTUnwrap(node["properties"] as? [String: Any], "Missing properties in \(path)")
                node = try XCTUnwrap(properties[component] as? [String: Any], "Missing \(component) in \(path)")
            }
        }
        return node
    }

    private func schemaTypes(_ schema: [String: Any]) -> Set<String> {
        if let type = schema["type"] as? String { return [type] }
        return Set(schema["type"] as? [String] ?? [])
    }

    private func supportsNull(_ schema: [String: Any]) -> Bool {
        guard schemaTypes(schema).contains("null") else { return false }
        guard let allowed = schema["enum"] as? [Any] else { return true }
        return allowed.contains { $0 is NSNull }
    }

    private static func representativeBundle() -> LiveEventBundle {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let eventID = "event-1"
        let scope = Scope.performances(performanceIDs: ["performance-1"])
        let amount = MoneyAmount(minorUnits: 12_000, currency: "JPY")
        let link = OfficialLink(
            label: "受付はこちら",
            url: "https://example.com/apply",
            role: .application,
            productNames: ["先行抽選券"]
        )

        return LiveEventBundle(
            schemaVersion: 1,
            revision: 2,
            publishedAt: date,
            event: LiveEvent(
                id: eventID,
                franchise: .bangdream,
                officialTitle: "Official Live",
                groups: ["Band"],
                eventType: .live,
                status: .scheduled,
                primarySourceURL: "https://example.com/event",
                timeZone: "Asia/Tokyo"
            ),
            stops: [LiveStop(id: "stop-1", eventID: eventID, name: "Tokyo", order: 0)],
            performances: [Performance(
                id: "performance-1",
                eventID: eventID,
                stopID: "stop-1",
                dayLabel: "Day 1",
                subtitle: "Evening",
                localDate: "2027-01-15",
                doorsAt: date,
                startAt: date,
                venueName: "Venue",
                venueCity: "Tokyo",
                performers: ["Band"],
                order: 0,
                editionID: "edition-1",
                rawDate: "2027年1月15日",
                precision: .minute,
                timeZone: "Asia/Tokyo"
            )],
            ticketTiers: [TicketTier(
                id: "tier-1",
                eventID: eventID,
                name: "一般席",
                priceJPY: 12_000,
                priceKind: .full,
                amount: amount,
                includes: "特典",
                feeNote: "手数料別",
                taxNote: "税込"
            )],
            ticketRounds: [TicketRound(
                id: "round-1",
                eventID: eventID,
                officialName: "最速先行",
                kind: .lottery,
                scope: scope,
                applyStartAt: date,
                applyEndAt: date,
                resultAt: date,
                paymentDeadlineAt: date,
                eligibility: "会員限定",
                announcementURL: "https://example.com/announcement",
                applyURL: link.url,
                overseasURL: "https://example.com/overseas",
                officialStatus: "受付中",
                status: .confirmed,
                links: [link],
                applyWindowText: "受付期間",
                resultText: "結果発表",
                paymentStartAt: date,
                paymentWindowText: "入金期間",
                quantityLimit: "2枚まで",
                lotteryProducts: ["先行抽選券"],
                applicationTarget: "全公演",
                notes: [TicketNote(kind: .membershipRequired, text: "会員登録が必要です", links: [link])]
            )],
            ticketOffers: [TicketOffer(
                id: "offer-1",
                roundID: "round-1",
                tierID: "tier-1",
                performanceIDs: ["performance-1"],
                priceJPY: 12_000,
                amount: amount
            )],
            goodsCampaigns: [GoodsCampaign(
                id: "campaign-1",
                eventID: eventID,
                officialName: "会場物販",
                channel: .venue,
                fulfillment: .venuePickup,
                phase: .during,
                scope: scope,
                salesStartAt: date,
                salesEndAt: date,
                pickupWindow: "10:00-18:00",
                shippingNote: "発送なし",
                location: "物販エリア",
                requiresTicket: true,
                purchaseLimit: "各2点",
                paymentMethods: "現金・カード",
                url: "https://example.com/goods",
                mediaAssetIDs: ["media-1"],
                status: .confirmed,
                links: [link]
            )],
            mediaAssets: [MediaAsset(
                id: "media-1",
                eventID: eventID,
                kind: .goodsList,
                originalURL: "https://example.com/goods.jpg",
                thumbnailURL: "https://example.com/goods-thumb.jpg",
                scope: scope,
                sourceURL: "https://example.com/event",
                version: 1,
                caption: "Goods",
                displayPolicy: .remoteDisplay,
                contentKind: .image
            )],
            notices: [Notice(
                id: "notice-1",
                eventID: eventID,
                kind: .change,
                title: "変更",
                body: "開場時間が変更されました",
                publishedAt: date,
                sourceURL: "https://example.com/notice",
                scope: scope
            )],
            evidence: [SourceEvidence(
                id: "evidence-1",
                recordID: "round-1",
                field: "applyStartAt",
                sourceURL: "https://example.com/event",
                quote: "受付期間",
                sourcePublishedAt: date,
                verifiedAt: date,
                verification: .confirmed
            )],
            editions: [Edition(id: "edition-1", eventID: eventID, name: "2027 Edition", order: 0)],
            streamOffers: [StreamOffer(
                id: "stream-1",
                eventID: eventID,
                platform: "Streaming",
                officialName: "配信チケット",
                scope: scope,
                amount: amount,
                salesStartAt: date,
                salesEndAt: date,
                archiveAvailableUntil: date,
                regionNote: "日本国内",
                url: "https://example.com/stream",
                status: .confirmed
            )],
            products: [Product(
                id: "product-1",
                eventID: eventID,
                campaignID: "campaign-1",
                name: "Tシャツ",
                amount: amount,
                url: "https://example.com/product",
                variants: [ProductVariant(id: "variant-1", name: "M", amount: amount, stockStatus: "在庫あり")],
                purchaseLimit: "2点"
            )],
            goodsSessions: [GoodsSession(
                id: "session-1",
                eventID: eventID,
                campaignID: "campaign-1",
                scope: scope,
                startsAt: date,
                endsAt: date,
                location: "物販エリア"
            )],
            ticketBenefits: [TicketBenefit(
                id: "benefit-1",
                eventID: eventID,
                officialName: "グッズ付きチケット特典",
                scope: scope,
                tierIDs: ["tier-1"],
                detail: "記念グッズ",
                notes: "当日引換",
                redemptionLocation: "会場",
                redemptionWindow: "開場後",
                redemptionNote: "チケット提示",
                mediaAssetIDs: ["media-1"],
                status: .confirmed,
                links: [link]
            )],
            sourceHealth: .healthy,
            sourceText: "Official page text"
        )
    }
}
