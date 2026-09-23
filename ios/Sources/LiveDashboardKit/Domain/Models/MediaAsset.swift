import Foundation

public enum MediaAssetKind: String, Hashable, Sendable, LossyStringEnum {
    /// Artwork chosen by the official event listing, distinct from the detail poster.
    case eventCover
    case keyVisual
    case goodsList
    case venueGoodsNotice
    case goodsAreaMap
    case eventSeatingMap
    case venueGenericSeatingMap
    case product
    case standingArea
    case unknown
    public static let fallback: MediaAssetKind = .unknown
}

public enum MediaContentKind: String, Codable, Hashable, Sendable {
    case image, link
}

public struct MediaAsset: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let eventID: String
    public let kind: MediaAssetKind
    public let originalURL: String
    public let thumbnailURL: String?
    public let scope: Scope
    public let sourceURL: String
    public let version: Int
    public let caption: String?
    public let displayPolicy: MediaDisplayPolicy
    public let contentKind: MediaContentKind?

    public init(
        id: String,
        eventID: String,
        kind: MediaAssetKind,
        originalURL: String,
        thumbnailURL: String?,
        scope: Scope,
        sourceURL: String,
        version: Int,
        caption: String?,
        displayPolicy: MediaDisplayPolicy = .linkOnly,
        contentKind: MediaContentKind? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.kind = kind
        self.originalURL = originalURL
        self.thumbnailURL = thumbnailURL
        self.scope = scope
        self.sourceURL = sourceURL
        self.version = version
        self.caption = caption
        self.displayPolicy = displayPolicy
        self.contentKind = contentKind
    }

    private enum CodingKeys: String, CodingKey { case id, eventID, kind, originalURL, thumbnailURL, scope, sourceURL, version, caption, displayPolicy, contentKind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = try c.decode(String.self, forKey: .eventID)
        kind = try c.decode(MediaAssetKind.self, forKey: .kind)
        originalURL = try c.decode(String.self, forKey: .originalURL)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        scope = try c.decode(Scope.self, forKey: .scope)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        version = try c.decode(Int.self, forKey: .version)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        displayPolicy = try c.decodeIfPresent(MediaDisplayPolicy.self, forKey: .displayPolicy) ?? .linkOnly
        contentKind = try c.decodeIfPresent(MediaContentKind.self, forKey: .contentKind)
    }

    /// Explicit content type comes from an actual <img> or direct-image link.
    /// Legacy cache entries can still identify images by their URL extension.
    public var isImage: Bool {
        if let contentKind { return contentKind == .image }
        return Self.isImageURL(originalURL) || displayPolicy != .linkOnly
    }

    public static func isImageURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }

}

public enum MediaDisplayPolicy: String, Hashable, Sendable, LossyStringEnum {
    case linkOnly = "link_only"
    case remoteDisplay = "permitted_remote_display"
    case cacheAllowed = "permitted_cache"
    public static let fallback: MediaDisplayPolicy = .linkOnly
}
