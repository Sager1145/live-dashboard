import CoreTransferable
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Shared image download / decode / cache pipeline for official-site media.
/// Both `OfficialMediaView` and `LiveEventCard` will route their downloads
/// through this actor in a later wave; it centralizes the request headers,
/// in-memory and on-disk byte caching, downsampled decoding, and staging of
/// files for sharing/export.
public actor OfficialImagePipeline {
    public static let shared = OfficialImagePipeline()

    private let session: URLSession

    /// Original, un-re-encoded bytes keyed by URL. Cost = byte count.
    private let dataCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Downsampled UIImages keyed by "url#maxPixelSize".
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        return cache
    }()

    /// In-flight original-byte downloads, deduplicated by URL.
    private var inFlightDownloads: [URL: Task<Data, Error>] = [:]

    private let diskCacheDirectory: URL

    private static func makeDiskCacheDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("LiveDashboard", isDirectory: true)
            .appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public init(session: URLSession = .shared) {
        self.session = session
        self.diskCacheDirectory = Self.makeDiskCacheDirectory()
    }

    /// Original bytes, cached in memory and on disk. Never re-encodes.
    public func originalData(for url: URL) async throws -> Data {
        if let cached = dataCache.object(forKey: url as NSURL) {
            return cached as Data
        }

        let diskURL = diskCacheFile(for: url)
        if let diskData = try? Data(contentsOf: diskURL) {
            dataCache.setObject(diskData as NSData, forKey: url as NSURL, cost: diskData.count)
            return diskData
        }

        if let existing = inFlightDownloads[url] {
            return try await existing.value
        }

        let task = Task<Data, Error> {
            let data = try await download(url)
            return data
        }
        inFlightDownloads[url] = task
        defer { inFlightDownloads[url] = nil }

        do {
            let data = try await task.value
            dataCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            try? data.write(to: diskURL, options: .atomic)
            return data
        } catch {
            throw error
        }
    }

    /// Downsampled UIImage whose longest side is at most `maxPixelSize`, decoded off the main actor with ImageIO.
    public func image(for url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let data = try await originalData(for: url)
        try Task.checkCancellation()
        let image = try Self.downsample(data: data, maxPixelSize: maxPixelSize)
        imageCache.setObject(image, forKey: key, cost: Self.approximateByteCost(of: image))
        return image
    }

    /// Full-resolution decode capped at 4096 px longest side (for the zoom viewer).
    public func viewerImage(for url: URL) async throws -> UIImage {
        try await image(for: url, maxPixelSize: 4096)
    }

    /// Writes the original bytes to a fresh temp folder with a file name derived from the URL and returns the file URL.
    public func stagedFile(for url: URL) async throws -> URL {
        let data = try await originalData(for: url)
        let directory = stagingRootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = Self.stagedFilename(for: url)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Removes temp folders created by `stagedFile` older than one hour.
    public func cleanupStagedFiles() async {
        let root = stagingRootDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-3600)
        for item in contents {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    // MARK: - Private

    private var stagingRootDirectory: URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfficialImagePipelineStaged", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let userAgent = OfficialWebsiteHeaders.compatibleUserAgent(for: url) {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw OfficialImagePipelineError.invalidResponse
        }
        guard !data.isEmpty else { throw OfficialImagePipelineError.invalidImage }
        return data
    }

    private func diskCacheFile(for url: URL) -> URL {
        diskCacheDirectory.appendingPathComponent(Self.sha256Hex(url.absoluteString))
    }

    private func cacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixelSize))" as NSString
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) throws -> UIImage {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            throw OfficialImagePipelineError.invalidImage
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw OfficialImagePipelineError.invalidImage
        }
        return UIImage(cgImage: cgImage)
    }

    private static func approximateByteCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func stagedFilename(for url: URL) -> String {
        let fallback = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        var name = fallback.isEmpty ? "official-image" : fallback
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let currentExtension = URL(fileURLWithPath: name).pathExtension
        if currentExtension.isEmpty {
            name += ".jpg"
        }
        return name
    }
}

public enum OfficialImagePipelineError: Error, LocalizedError, Sendable {
    case invalidResponse
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "无法下载官方图片", bundle: .kit)
        case .invalidImage: String(localized: "官方链接未返回有效图片", bundle: .kit)
        }
    }
}

public struct OfficialImageTransfer: Transferable, Sendable {
    public let url: URL
    public let caption: String?

    public init(url: URL, caption: String?) {
        self.url = url
        self.caption = caption
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(try await OfficialImagePipeline.shared.stagedFile(for: item.url))
        }
    }
}
