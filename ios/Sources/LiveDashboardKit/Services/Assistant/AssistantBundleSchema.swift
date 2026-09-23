import Foundation

/// Strict structured-output schema for reconstructing a `LiveEventBundle`
/// from an official event page. Optional Swift properties remain required in
/// the JSON object and use `null` when the page does not establish a value.
internal enum AssistantBundleSchema {
    static func schema() -> [String: Any] {
        let link = object([
            "label": string(description: "Official anchor text, preserved verbatim."),
            "url": string(description: "Absolute URL present on the official page."),
            "role": nullableEnum(["application", "overseasApplication", "support", "product", "other"]),
            "productNames": array(string())
        ])

        let scope = object([
            "kind": enumeration(["wholeEvent", "stop", "performances", "unconfirmed"]),
            "stopID": nullableString(),
            "performanceIDs": array(string(), description: "Use the app-provided performance IDs. Empty only when scope is unconfirmed.")
        ], description: "Applicability of the record. Prefer performances with explicit IDs; use unconfirmed rather than guessing.")

        let nullableMoney = nullableObject([
            "minorUnits": integer(description: "Amount in the currency's minor units."),
            "currency": string(description: "ISO 4217 currency code, for example JPY.")
        ])

        let event = object([
            "id": string(),
            "franchise": enumeration(["bangdream", "lovelive", "unknown"]),
            "officialTitle": string(description: "Official event title, preserved verbatim."),
            "groups": array(string()),
            "eventType": enumeration(["live", "fanMeeting", "screening", "other"]),
            "status": enumeration(["scheduled", "postponed", "cancelled", "finished", "unknown"]),
            "primarySourceURL": string(description: "Canonical official page URL."),
            "timeZone": string(description: "IANA time-zone identifier, for example Asia/Tokyo.")
        ])

        let stop = object([
            "id": string(),
            "eventID": string(),
            "name": string(),
            "order": integer()
        ])

        let performance = object([
            "id": string(),
            "eventID": string(),
            "stopID": nullableString(),
            "dayLabel": string(),
            "subtitle": nullableString(),
            "localDate": nullableString(description: "Organizer-local calendar date in YYYY-MM-DD form when known."),
            "rawDate": nullableString(description: "Date text as printed when it cannot be represented precisely."),
            "precision": nullableEnum(["minute", "date", "month", "range", "unknown"]),
            "timeZone": nullableString(description: "IANA time-zone identifier."),
            "doorsAt": nullableDate(),
            "startAt": nullableDate(),
            "venueName": string(),
            "venueCity": string(),
            "performers": array(string()),
            "order": integer(),
            "editionID": nullableString()
        ])

        let ticketTier = object([
            "id": string(),
            "eventID": string(),
            "name": string(),
            "priceJPY": nullableInteger(),
            "amount": nullableMoney,
            "priceKind": enumeration(["full", "upgradeDifference", "streaming", "under20", "other"]),
            "includes": nullableString(),
            "feeNote": nullableString(),
            "taxNote": nullableString()
        ])

        let ticketNote = object([
            "kind": enumeration([
                "faceRecognition", "companionRegistration", "identityCheck", "smartTicketOnly",
                "creditCardOnly", "membershipRequired", "other"
            ]),
            "text": string(description: "Important notice sentence preserved verbatim."),
            "links": array(link)
        ])

        let ticketRound = object([
            "id": string(),
            "eventID": string(),
            "officialName": string(),
            "kind": enumeration(["lottery", "firstComeFirstServed", "resale", "upgrade", "other"]),
            "scope": scope,
            "applyStartAt": nullableDate(),
            "applyEndAt": nullableDate(),
            "resultAt": nullableDate(),
            "paymentDeadlineAt": nullableDate(),
            "eligibility": nullableString(),
            "announcementURL": nullableString(),
            "applyURL": nullableString(),
            "overseasURL": nullableString(),
            "officialStatus": nullableString(),
            "status": dataStatus(),
            "links": array(link),
            "applyWindowText": nullableString(),
            "resultText": nullableString(),
            "paymentStartAt": nullableDate(),
            "paymentWindowText": nullableString(),
            "quantityLimit": nullableString(),
            "lotteryProducts": array(string()),
            "applicationTarget": nullableString(),
            "notes": array(ticketNote)
        ])

        let ticketOffer = object([
            "id": string(),
            "roundID": string(),
            "tierID": string(),
            "performanceIDs": array(string()),
            "priceJPY": nullableInteger(),
            "amount": nullableMoney
        ])

        let goodsCampaign = object([
            "id": string(),
            "eventID": string(),
            "officialName": string(),
            "channel": enumeration(["online", "venue", "unknown"]),
            "fulfillment": enumeration(["shipping", "venuePickup", "unknown"]),
            "phase": enumeration(["pre", "during", "post", "unknown"]),
            "scope": scope,
            "salesStartAt": nullableDate(),
            "salesEndAt": nullableDate(),
            "pickupWindow": nullableString(),
            "shippingNote": nullableString(),
            "location": nullableString(),
            "requiresTicket": nullableBoolean(),
            "purchaseLimit": nullableString(),
            "paymentMethods": nullableString(),
            "url": nullableString(),
            "mediaAssetIDs": array(string()),
            "status": dataStatus(),
            "links": array(link)
        ])

        let mediaAsset = object([
            "id": string(),
            "eventID": string(),
            "kind": enumeration([
                "eventCover", "keyVisual", "goodsList", "venueGoodsNotice", "goodsAreaMap",
                "eventSeatingMap", "venueGenericSeatingMap", "product", "standingArea", "unknown"
            ]),
            "originalURL": string(),
            "thumbnailURL": nullableString(),
            "scope": scope,
            "sourceURL": string(),
            "version": integer(),
            "caption": nullableString(),
            "displayPolicy": enumeration(["link_only", "permitted_remote_display", "permitted_cache"]),
            "contentKind": nullableEnum(["image", "link"])
        ])

        let notice = object([
            "id": string(),
            "eventID": string(),
            "kind": enumeration(["change", "cancellation", "postponement", "refund", "other"]),
            "title": string(),
            "body": string(),
            "publishedAt": nullableDate(),
            "sourceURL": string(),
            "scope": scope
        ])

        let evidence = object([
            "id": string(),
            "recordID": string(),
            "field": string(),
            "sourceURL": string(),
            "quote": string(description: "Short verbatim quote that supports the field."),
            "sourcePublishedAt": nullableDate(),
            "verifiedAt": date(),
            "verification": enumeration(["confirmed", "needsReview", "conflict"])
        ])

        let edition = object([
            "id": string(),
            "eventID": string(),
            "name": string(),
            "order": integer()
        ])

        let streamOffer = object([
            "id": string(),
            "eventID": string(),
            "platform": string(),
            "officialName": string(),
            "scope": scope,
            "amount": nullableMoney,
            "salesStartAt": nullableDate(),
            "salesEndAt": nullableDate(),
            "archiveAvailableUntil": nullableDate(),
            "regionNote": nullableString(),
            "url": nullableString(),
            "status": dataStatus()
        ])

        let productVariant = object([
            "id": string(),
            "name": string(),
            "amount": nullableMoney,
            "stockStatus": nullableString()
        ])

        let product = object([
            "id": string(),
            "eventID": string(),
            "campaignID": string(),
            "name": string(),
            "amount": nullableMoney,
            "url": nullableString(),
            "variants": array(productVariant),
            "purchaseLimit": nullableString()
        ])

        let goodsSession = object([
            "id": string(),
            "eventID": string(),
            "campaignID": string(),
            "scope": scope,
            "startsAt": nullableDate(),
            "endsAt": nullableDate(),
            "location": string()
        ])

        let ticketBenefit = object([
            "id": string(),
            "eventID": string(),
            "officialName": string(),
            "scope": scope,
            "tierIDs": array(string()),
            "detail": nullableString(),
            "notes": nullableString(),
            "redemptionLocation": nullableString(),
            "redemptionWindow": nullableString(),
            "redemptionNote": nullableString(),
            "mediaAssetIDs": array(string()),
            "status": dataStatus(),
            "links": array(link)
        ])

        return object([
            "schemaVersion": integer(),
            "revision": nullableInteger(),
            "publishedAt": date(),
            "event": event,
            "stops": array(stop),
            "performances": array(performance),
            "ticketTiers": array(ticketTier),
            "ticketRounds": array(ticketRound),
            "ticketOffers": array(ticketOffer),
            "goodsCampaigns": array(goodsCampaign),
            "mediaAssets": array(mediaAsset),
            "notices": array(notice),
            "evidence": array(evidence),
            "editions": array(edition),
            "streamOffers": array(streamOffer),
            "products": array(product),
            "goodsSessions": array(goodsSession),
            "ticketBenefits": array(ticketBenefit),
            "sourceHealth": enumeration(["healthy", "stale", "blocked", "fetch_failed", "parse_failed"]),
            "sourceText": nullableString(description: "Official page text used for reconstruction, or null when the caller supplies it.")
        ], description: "Complete LiveEventBundle reconstructed only from the official page.")
    }

    private static func object(
        _ properties: [String: Any],
        description: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": properties.keys.sorted(),
            "additionalProperties": false
        ]
        if let description { result["description"] = description }
        return result
    }

    private static func nullableObject(_ properties: [String: Any]) -> [String: Any] {
        var result = object(properties)
        result["type"] = ["object", "null"]
        return result
    }

    private static func array(_ items: [String: Any], description: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": "array", "items": items]
        if let description { result["description"] = description }
        return result
    }

    private static func string(description: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": "string"]
        if let description { result["description"] = description }
        return result
    }

    private static func nullableString(description: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": ["string", "null"]]
        if let description { result["description"] = description }
        return result
    }

    private static func integer(description: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": "integer"]
        if let description { result["description"] = description }
        return result
    }

    private static func nullableInteger() -> [String: Any] {
        ["type": ["integer", "null"]]
    }

    private static func nullableBoolean() -> [String: Any] {
        ["type": ["boolean", "null"]]
    }

    private static func enumeration(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    private static func nullableEnum(_ values: [String]) -> [String: Any] {
        var allowed: [Any] = values
        allowed.append(NSNull())
        return ["type": ["string", "null"], "enum": allowed]
    }

    private static func date() -> [String: Any] {
        [
            "type": "string",
            "description": "ISO-8601 date-time with an explicit timezone offset."
        ]
    }

    private static func nullableDate() -> [String: Any] {
        [
            "type": ["string", "null"],
            "description": "ISO-8601 date-time with an explicit timezone offset, or null when not stated."
        ]
    }

    private static func dataStatus() -> [String: Any] {
        enumeration(["confirmed", "officiallyTBA", "notFetched", "needsReview", "parseFailed", "notApplicable"])
    }
}
