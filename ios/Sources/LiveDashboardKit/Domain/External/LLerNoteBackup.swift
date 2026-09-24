import Foundation
import LiveIngestionCore

public struct BackupAttendanceChange: Equatable, Sendable {
    public var sourcePerformanceID: String
    public var eventID: String
    public var performanceID: String
    public var participate: Bool
    public var tombstone: Bool
}

public struct BackupImportPreview: Equatable, Sendable {
    public var version: Int
    public var matched: [BackupAttendanceChange]
    public var unmatchedSourceIDs: [String]
    public var conflicts: [BackupAttendanceChange]
}

public enum BackupImportError: Error, Equatable {
    case malformed
    case unsupportedVersion(Int)
}

public struct BackupPerformanceLocator: Equatable, Sendable {
    public var eventID: String
    public var performanceID: String
    /// Nil when the user has no personal participation fact for this performance.
    public var explicitParticipation: Bool?
}

public enum LLerNoteBackupImporter {
    /// Reads a v1 or v2 local backup. A tombstone changes only that personal
    /// record. Unknown versions are rejected before any change is returned.
    public static func preview(data: Data, locate: (String) -> BackupPerformanceLocator?) throws -> BackupImportPreview {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any], let version = root["version"] as? Int else { throw BackupImportError.malformed }
        guard version == 1 || version == 2 else { throw BackupImportError.unsupportedVersion(version) }
        guard let attendance = root["attendance"] as? [String: Any] else { throw BackupImportError.malformed }
        var matched: [BackupAttendanceChange] = []
        var unmatched: [String] = []
        var conflicts: [BackupAttendanceChange] = []
        for key in attendance.keys.sorted() {
            guard let record = attendance[key] as? [String: Any] else { throw BackupImportError.malformed }
            let sourceID = (record["performanceId"] as? String) ?? key
            guard let status = record["status"] as? String, status == "attended" || status == "interested" else { throw BackupImportError.malformed }
            let deleted = record["deleted"] as? Bool
            guard let local = locate(sourceID) else {
                unmatched.append(sourceID)
                continue
            }
            let participate = deleted != true
            let change = BackupAttendanceChange(sourcePerformanceID: sourceID, eventID: local.eventID, performanceID: local.performanceID, participate: participate, tombstone: deleted == true)
            if let explicit = local.explicitParticipation, explicit != participate {
                conflicts.append(change)
            } else {
                matched.append(change)
            }
        }
        return BackupImportPreview(version: version, matched: matched, unmatchedSourceIDs: unmatched, conflicts: conflicts)
    }

    /// Confirmed changes only. Conflicts stay out unless their source id is included.
    public static func changes(from preview: BackupImportPreview, acceptedConflictIDs: Set<String> = []) -> [BackupAttendanceChange] {
        preview.matched + preview.conflicts.filter { acceptedConflictIDs.contains($0.sourcePerformanceID) }
    }
}
