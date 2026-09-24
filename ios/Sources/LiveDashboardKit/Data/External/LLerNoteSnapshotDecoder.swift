import Foundation
import LiveIngestionCore

public enum LLerNoteSnapshotError: Error, Equatable {
    case missingCatalog
    case malformed(String)
}

public enum LLerNoteSnapshotDecoder {
    /// Joins files from one revision. A missing extra record keeps the base performance.
    public static func decode(files: [String: Data], revision: String) throws -> LLerNoteCatalog {
        guard let performanceData = files["performance-info.json"] else { throw LLerNoteSnapshotError.missingCatalog }
        let bases = try jsonArray(performanceData, file: "performance-info.json")
        let extras = try files["event-extra.json"].map { try jsonObject($0, file: "event-extra.json") } ?? [:]
        let venues = try files["venue-info.json"].map { try jsonArray($0, file: "venue-info.json") } ?? []
        let map = try files["eventernote-map.json"].map { try jsonObject($0, file: "eventernote-map.json") } ?? [:]
        let setlistObject = try files["performance-setlists.json"].map { try jsonObject($0, file: "performance-setlists.json") } ?? [:]
        let songs = try files["song-info.json"].map { try jsonArray($0, file: "song-info.json") } ?? []

        var performances: [LLerPerformance] = []
        var seen = Set<String>()
        for base in bases {
            let id = try requiredString(base, "id", file: "performance-info.json")
            if !seen.insert(id).inserted { throw LLerNoteSnapshotError.malformed("duplicate performance \(id)") }
            let extra = extras[id] as? [String: Any] ?? [:]
            performances.append(LLerPerformance(
                id: id,
                eventID: flexString(base["eventId"]),
                concertID: flexString(base["concertId"]),
                tourName: flexString(base["tourName"]) ?? "",
                date: flexString(base["date"]),
                venueName: flexString(extra["venue"]) ?? flexString(base["venue"]),
                venueID: flexString(extra["venueId"]) ?? flexString(base["venueId"]),
                seriesIDs: flexStringArray(base["seriesIds"]),
                status: flexString(base["status"]),
                hasSetlist: base["hasSetlist"] as? Bool ?? false,
                performanceName: flexString(extra["performanceName"]),
                concertName: flexString(extra["concertName"]),
                openTime: flexString(extra["openTime"]),
                startTime: flexString(extra["startTime"]),
                tourType: flexString(extra["tourType"]),
                canceled: extra["canceled"] as? Bool,
                note: flexString(extra["note"]),
                category: normalizedCategory(flexString(extra["tourType"]) ?? flexString(base["category"]))
            ))
        }

        var forward: [String: String] = [:]
        var reverse: [String: [String]] = [:]
        for (performanceID, raw) in map {
            guard let eventernoteID = flexString(raw) else { continue }
            forward[performanceID] = eventernoteID
            reverse[eventernoteID, default: []].append(performanceID)
        }
        for key in reverse.keys { reverse[key]?.sort() }

        let decodedVenues = venues.compactMap { raw -> LLerVenue? in
            guard let id = flexString(raw["id"]) ?? flexString(raw["venueId"]) else { return nil }
            return LLerVenue(
                id: id, name: flexString(raw["name"]) ?? "", source: flexString(raw["source"]),
                sourceID: flexString(raw["sourceId"]), confidence: raw["confidence"] as? Double,
                reviewRequired: raw["reviewRequired"] as? Bool, address: flexString(raw["address"]),
                latitude: raw["lat"] as? Double ?? raw["latitude"] as? Double,
                longitude: raw["lng"] as? Double ?? raw["longitude"] as? Double,
                country: flexString(raw["country"]), region: flexString(raw["region"]),
                locality: flexString(raw["locality"]), website: flexString(raw["website"])
            )
        }
        let decodedSetlists = setlistObject.compactMap { performanceID, raw -> LLerSetlist? in
            guard let object = raw as? [String: Any] else { return nil }
            let items = (object["items"] as? [[String: Any]] ?? []).enumerated().map { index, item in
                LLerSetlistItem(
                    id: flexString(item["id"]) ?? "\(performanceID)-\(index)",
                    type: flexString(item["type"]) ?? "unknown",
                    position: item["position"] as? Int ?? index,
                    songID: flexString(item["songId"]),
                    customSongName: flexString(item["customSongName"]),
                    isCustomSong: item["isCustomSong"] as? Bool,
                    title: flexString(item["title"]),
                    remarks: flexString(item["remarks"])
                )
            }
            let sections = (object["sections"] as? [[String: Any]] ?? []).map { section in
                LLerSetlistSection(
                    name: flexString(section["name"]) ?? "",
                    startIndex: section["startIndex"] as? Int ?? 0,
                    endIndex: section["endIndex"] as? Int ?? 0,
                    type: flexString(section["type"]) ?? "unknown"
                )
            }
            return LLerSetlist(
                id: flexString(object["id"]) ?? performanceID,
                performanceID: flexString(object["performanceId"]) ?? performanceID,
                items: items, sections: sections, isActual: object["isActual"] as? Bool ?? false
            )
        }
        let decodedSongs = songs.compactMap { raw -> LLerSong? in
            guard let id = flexString(raw["id"]), let name = flexString(raw["name"]) else { return nil }
            return LLerSong(id: id, name: name, seriesIDs: flexStringArray(raw["seriesIds"]))
        }
        return LLerNoteCatalog(
            revision: revision, performances: performances, venues: decodedVenues,
            eventernoteByPerformance: forward, eventernoteTargets: reverse,
            setlists: decodedSetlists, songs: decodedSongs
        )
    }

    /// Unknown and missing categories stay unset. A shared tour name does not fill them in.
    private static func normalizedCategory(_ raw: String?) -> String? {
        switch raw {
        case "live", "online", "tv": return raw
        case nil, "": return nil
        default: return raw
        }
    }

    private static func jsonArray(_ data: Data, file: String) throws -> [[String: Any]] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLerNoteSnapshotError.malformed(file)
        }
        return rows
    }

    private static func jsonObject(_ data: Data, file: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLerNoteSnapshotError.malformed(file)
        }
        return object
    }

    private static func requiredString(_ object: [String: Any], _ key: String, file: String) throws -> String {
        guard let value = flexString(object[key]) else { throw LLerNoteSnapshotError.malformed(file) }
        return value
    }

    private static func flexString(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func flexStringArray(_ value: Any?) -> [String] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap(flexString)
    }
}
