import CryptoKit
import Foundation

public enum MediaCacheVariant: String, Sendable, Equatable, Hashable {
    case preview
    case original
}

/// Cache identity is the server instance, the logical asset, the content hash, and the variant.
/// A new hash is a new object. The official `originalURL` is not part of the key.
public struct MediaCacheKey: Sendable, Equatable, Hashable {
    public var serverInstanceID: String
    public var assetID: String
    public var contentHash: String
    public var variant: MediaCacheVariant

    public init(serverInstanceID: String, assetID: String, contentHash: String, variant: MediaCacheVariant) {
        self.serverInstanceID = serverInstanceID
        self.assetID = assetID
        self.contentHash = contentHash
        self.variant = variant
    }

    public var filename: String {
        let raw = "\(serverInstanceID)\n\(assetID)\n\(contentHash.lowercased())\n\(variant.rawValue)"
        return MediaStore.sha256Hex(Data(raw.utf8))
    }
}

public struct MediaFetchPlan: Sendable, Equatable {
    public var url: URL?
    /// Always false. A miss must not download the official source URL.
    public var allowsOfficialOriginalFallback: Bool

    public init(url: URL?, allowsOfficialOriginalFallback: Bool) {
        self.url = url
        self.allowsOfficialOriginalFallback = allowsOfficialOriginalFallback
    }
}

public enum MediaStoreError: Error, Equatable {
    case hashMismatch
    case missingCache
    case notOriginalVariant
}

public struct MediaStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func contentHash(of data: Data) -> String {
        sha256Hex(data)
    }

    public func fileURL(for key: MediaCacheKey) -> URL {
        directory.appendingPathComponent(key.filename, isDirectory: false)
    }

    /// Writes only when `data` matches `key.contentHash`. A mismatch leaves no file.
    public func writeVerified(_ data: Data, key: MediaCacheKey) throws {
        guard Self.contentHash(of: data) == key.contentHash.lowercased() else {
            throw MediaStoreError.hashMismatch
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: key), options: .atomic)
    }

    /// Returns cached bytes. A hash mismatch deletes the file instead of serving it.
    public func validatedData(for key: MediaCacheKey) throws -> Data {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaStoreError.missingCache }
        let data = try Data(contentsOf: url)
        guard Self.contentHash(of: data) == key.contentHash.lowercased() else {
            try? FileManager.default.removeItem(at: url)
            throw MediaStoreError.hashMismatch
        }
        return data
    }

    /// Share file is the cached original bytes, copied out unchanged.
    public func shareFile(for key: MediaCacheKey) throws -> URL {
        guard key.variant == .original else { throw MediaStoreError.notOriginalVariant }
        let data = try validatedData(for: key)
        let shareDirectory = directory.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        let destination = shareDirectory.appendingPathComponent(key.filename + ".bin", isDirectory: false)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// `officialOriginalURL` is provenance for “open the official site”. It is never the fetch URL.
    public static func fetchPlan(serverContentURL: URL?, officialOriginalURL: URL?) -> MediaFetchPlan {
        if serverContentURL == nil, officialOriginalURL != nil {
            return MediaFetchPlan(url: nil, allowsOfficialOriginalFallback: false)
        }
        return MediaFetchPlan(url: serverContentURL, allowsOfficialOriginalFallback: false)
    }
}
