import Foundation

public struct CatalogRemapRecord: Codable, Sendable, Equatable {
    public let entityKind: String
    public let legacyID: String
    public let currentID: String
}

/// Public catalog generations. `current.json` names the active generation; staging is invisible until then.
public actor CatalogGenerationStore {
    public let serverInstanceID: String
    private let root: URL
    private let fileManager: FileManager
    private var overlay: [String: CatalogEventDocumentV2] = [:]
    /// Test hook: the next event write throws and does not create a file.
    public var failNextWrite = false

    public init(directory: URL, serverInstanceID: String, fileManager: FileManager = .default) {
        self.root = directory
        self.serverInstanceID = serverInstanceID
        self.fileManager = fileManager
    }

    public func committedCursor() -> String? { loadActive()?.manifest.cursor }

    public func activeSnapshotID() -> String? { loadActive()?.manifest.snapshotID }

    public func documents() -> [CatalogEventDocumentV2] {
        var byID = Dictionary(uniqueKeysWithValues: (loadActive()?.documents ?? []).map { ($0.eventID, $0) })
        for (id, document) in overlay {
            if let current = byID[id], document.revision < current.revision { continue }
            byID[id] = document
        }
        return byID.values.sorted { $0.eventID < $1.eventID }
    }

    public func document(eventID: String) -> CatalogEventDocumentV2? {
        documents().first { $0.eventID == eventID }
    }

    public func beginGeneration(copyActive: Bool) throws -> UUID {
        let id = UUID()
        let directory = generationURL(id)
        try fileManager.createDirectory(at: directory.appendingPathComponent("events"), withIntermediateDirectories: true)
        if copyActive, let active = loadActive() {
            for document in active.documents {
                try writeFile(document, generation: id)
            }
            for document in overlay.values {
                if let current = active.documents.first(where: { $0.eventID == document.eventID }), document.revision < current.revision {
                    continue
                }
                try writeFile(document, generation: id)
            }
        }
        return id
    }

    public func write(generation: UUID, document: CatalogEventDocumentV2) throws {
        if failNextWrite {
            failNextWrite = false
            throw CatalogSyncError.notSaved
        }
        try writeFile(document, generation: generation)
    }

    public func delete(generation: UUID, eventID: String) throws {
        let url = eventURL(generation: generation, eventID: eventID)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    public func stagedEventIDs(generation: UUID) -> Set<String> {
        let directory = generationURL(generation).appendingPathComponent("events")
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    public func stagedRevision(generation: UUID, eventID: String) -> Int? {
        guard let data = try? Data(contentsOf: eventURL(generation: generation, eventID: eventID)),
              let document = try? CatalogEventDocumentV2(payload: data) else { return nil }
        return document.revision
    }

    public func canCommit(generation: UUID, windowEventIDs: [String]) -> Bool {
        CatalogCursorCommit.canCommit(savedEventIDs: stagedEventIDs(generation: generation), windowEventIDs: windowEventIDs)
    }

    public func discard(generation: UUID) {
        let url = generationURL(generation)
        if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
    }

    /// Points `current.json` at this generation only after the window's files are already in it.
    public func activate(
        generation: UUID,
        cursor: String,
        snapshotID: String,
        sourceHealth: [String: String],
        remaps: [CatalogRemapRecord]
    ) throws {
        try CatalogWire.validateDecimal(cursor)
        let manifest = GenerationManifest(cursor: cursor, snapshotID: snapshotID, sourceHealth: sourceHealth, remaps: remaps)
        let manifestURL = generationURL(generation).appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        let pointer = Pointer(generation: generation.uuidString)
        let pointerURL = root.appendingPathComponent("current.json")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent("current-\(UUID().uuidString).tmp")
        try JSONEncoder().encode(pointer).write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: pointerURL.path) {
            _ = try fileManager.replaceItemAt(pointerURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: pointerURL)
        }
        overlay = overlay.filter { id, document in
            guard let staged = stagedRevision(generation: generation, eventID: id) else { return true }
            return document.revision > staged
        }
    }

    /// A single-event read may store a newer revision without moving the committed cursor.
    public func keepNewerDetail(_ incoming: CatalogEventDocumentV2) {
        if let current = document(eventID: incoming.eventID), incoming.revision < current.revision { return }
        overlay[incoming.eventID] = incoming
    }

    public func isActiveGeneration(_ generation: UUID) -> Bool {
        loadPointer()?.generation == generation.uuidString
    }

    private struct Pointer: Codable { let generation: String }
    private struct GenerationManifest: Codable {
        var cursor: String
        var snapshotID: String
        var sourceHealth: [String: String]
        var remaps: [CatalogRemapRecord]
    }
    private struct ActiveGeneration {
        var manifest: GenerationManifest
        var documents: [CatalogEventDocumentV2]
    }

    private func loadPointer() -> Pointer? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("current.json")) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }

    private func loadActive() -> ActiveGeneration? {
        guard let id = loadPointer().flatMap({ UUID(uuidString: $0.generation) }) else { return nil }
        let manifestURL = generationURL(id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: data) else { return nil }
        let documents = stagedEventIDs(generation: id).compactMap { eventID -> CatalogEventDocumentV2? in
            guard let payload = try? Data(contentsOf: eventURL(generation: id, eventID: eventID)) else { return nil }
            return try? CatalogEventDocumentV2(payload: payload)
        }
        return ActiveGeneration(manifest: manifest, documents: documents)
    }

    private func writeFile(_ document: CatalogEventDocumentV2, generation: UUID) throws {
        let directory = generationURL(generation).appendingPathComponent("events")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try document.payload.write(to: eventURL(generation: generation, eventID: document.eventID), options: .atomic)
    }

    private func generationURL(_ id: UUID) -> URL {
        root.appendingPathComponent("generations", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func eventURL(generation: UUID, eventID: String) -> URL {
        generationURL(generation).appendingPathComponent("events", isDirectory: true).appendingPathComponent("\(eventID).json")
    }
}
