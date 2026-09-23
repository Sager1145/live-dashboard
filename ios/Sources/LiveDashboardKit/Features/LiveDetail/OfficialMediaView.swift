import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct OfficialMediaResponse: Sendable {
    public let data: Data
    public let mimeType: String?
    public let suggestedFilename: String?

    public init(data: Data, mimeType: String?, suggestedFilename: String?) {
        self.data = data
        self.mimeType = mimeType
        self.suggestedFilename = suggestedFilename
    }
}

public protocol OfficialMediaLoading: Sendable {
    func load(_ url: URL) async throws -> OfficialMediaResponse
}

public actor URLSessionOfficialMediaLoader: OfficialMediaLoading {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func load(_ url: URL) async throws -> OfficialMediaResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let userAgent = OfficialWebsiteHeaders.compatibleUserAgent(for: url) {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw OfficialMediaError.invalidResponse
        }
        guard !data.isEmpty else { throw OfficialMediaError.invalidImage }
        return OfficialMediaResponse(
            data: data,
            mimeType: response.mimeType,
            suggestedFilename: response.suggestedFilename
        )
    }
}

public enum OfficialMediaError: Error, LocalizedError, Sendable {
    case invalidResponse
    case invalidImage

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "无法下载官方图片", bundle: .kit)
        case .invalidImage: String(localized: "官方链接未返回有效图片", bundle: .kit)
        }
    }
}

/// Displays official image assets inline regardless of the legacy display
/// policy. Non-image assets remain links and are never fetched automatically.
public struct OfficialMediaView: View {
    public let asset: MediaAsset
    public let compact: Bool
    private let loader: any OfficialMediaLoading

    @State private var previewImage: UIImage?
    @State private var isLoadingPreview = false
    @State private var isDownloading = false
    @State private var message: String?
    @State private var showsZoom = false
    @State private var shareFileURL: ShareFileURL?

    public init(
        asset: MediaAsset,
        compact: Bool = false,
        loader: any OfficialMediaLoading = URLSessionOfficialMediaLoader()
    ) {
        self.asset = asset
        self.compact = compact
        self.loader = loader
    }

    public var body: some View {
        Group {
            if asset.isImage {
                imageContent
            } else {
                originalLink
            }
        }
        .task(id: previewTaskID) {
            guard asset.isImage else { return }
            await loadPreview()
        }
        .sheet(isPresented: $showsZoom) {
            ZoomableImageSheet(
                imageURL: originalURL,
                caption: asset.caption,
                sourceURL: distinctSourceURL,
                loader: loader
            )
        }
        .sheet(item: $shareFileURL) { wrapper in
            OfficialImageShareSheet(fileURL: wrapper.url) {
                try? FileManager.default.removeItem(at: wrapper.url.deletingLastPathComponent())
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if previewImage != nil { showsZoom = true }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else if isLoadingPreview {
                        ProgressView()
                    } else {
                        ContentUnavailableView("无法显示图片", systemImage: "photo")
                    }
                }
                .aspectRatio(previewImage.map { $0.size.width / max($0.size.height, 1) } ?? (16.0 / 9.0), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: compact ? 160 : 340)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(previewImage == nil)
            .accessibilityLabel("打开原图并缩放")
            .accessibilityIdentifier("mediaImage-\(asset.id)")
            .contextMenu {
                Button {
                    Task { await prepareShare() }
                } label: {
                    Label("分享图片", systemImage: "square.and.arrow.up")
                }
            }

            if let caption = asset.caption, !caption.isEmpty {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // The original image URL and its official source page are shown in
            // the zoom sheet after the image is opened, not on the card itself.
            Button {
                Task { await prepareShare() }
            } label: {
                if isDownloading {
                    HStack {
                        ProgressView()
                        Text("正在准备原图…")
                    }
                } else {
                    Label("分享原图", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isDownloading || originalURL == nil)
            .accessibilityIdentifier("mediaShare-\(asset.id)")

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var originalLink: some View {
        if let originalURL {
            Link(destination: originalURL) {
                Label {
                    Text(originalURL.absoluteString)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: asset.isImage ? "photo" : "link")
                }
            }
            .textSelection(.enabled)
            .accessibilityIdentifier("mediaOriginalLink-\(asset.id)")
        } else {
            Text(asset.originalURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var originalURL: URL? { URL(string: asset.originalURL) }

    private var distinctSourceURL: URL? {
        guard let sourceURL = URL(string: asset.sourceURL), sourceURL != originalURL else { return nil }
        return sourceURL
    }

    private var previewTaskID: String {
        "\(asset.id)::v\(asset.version)::\(asset.thumbnailURL ?? "")::\(asset.originalURL)"
    }

    @MainActor
    private func loadPreview() async {
        previewImage = nil
        message = nil
        isLoadingPreview = true
        defer { isLoadingPreview = false }

        var urls: [URL] = []
        if let thumbnail = asset.thumbnailURL.flatMap(URL.init(string:)) { urls.append(thumbnail) }
        if let originalURL, !urls.contains(originalURL) { urls.append(originalURL) }

        for url in urls {
            do {
                let response = try await loader.load(url)
                try Task.checkCancellation()
                guard let image = UIImage(data: response.data) else { throw OfficialMediaError.invalidImage }
                previewImage = image
                message = nil
                return
            } catch {
                if Task.isCancelled || isCancellation(error) { return }
                message = error.localizedDescription
            }
        }
    }

    @MainActor
    private func prepareShare() async {
        guard let originalURL else { return }
        isDownloading = true
        message = nil
        defer { isDownloading = false }
        do {
            let response = try await loader.load(originalURL)
            try Task.checkCancellation()
            guard UIImage(data: response.data) != nil else { throw OfficialMediaError.invalidImage }
            let fileURL = try prepareShareFile(response: response, url: originalURL)
            shareFileURL = ShareFileURL(url: fileURL)
        } catch {
            guard !Task.isCancelled, !isCancellation(error) else { return }
            message = error.localizedDescription
        }
    }
}

/// Compatible replacement for the former SwiftUI scale-effect sheet.
public struct ZoomableImageSheet: View {
    let imageURL: URL?
    let caption: String?
    let sourceURL: URL?
    private let loader: any OfficialMediaLoading

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var isDownloading = false
    @State private var message: String?
    @State private var shareFileURL: ShareFileURL?

    public init(
        imageURL: URL?,
        caption: String? = nil,
        sourceURL: URL? = nil,
        loader: any OfficialMediaLoading = URLSessionOfficialMediaLoader()
    ) {
        self.imageURL = imageURL
        self.caption = caption
        self.sourceURL = sourceURL
        self.loader = loader
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableUIImageView(image: image)
                        .background(Color.black)
                } else if isLoading {
                    ProgressView("正在载入原图…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("无法显示图片", systemImage: "photo", description: message.map { Text($0) })
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if let caption, !caption.isEmpty { Text(caption).font(.footnote) }
                    if let imageURL {
                        Link(imageURL.absoluteString, destination: imageURL)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    if let sourceURL, sourceURL != imageURL {
                        Link(sourceURL.absoluteString, destination: sourceURL)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("zoomDoneButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await prepareShare() }
                    } label: {
                        if isDownloading { ProgressView() }
                        else { Label("分享", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(isDownloading || imageURL == nil)
                    .accessibilityIdentifier("zoomShareButton")
                }
            }
            .task(id: imageURL) { await loadImage() }
            .sheet(item: $shareFileURL) { wrapper in
                OfficialImageShareSheet(fileURL: wrapper.url) {
                    try? FileManager.default.removeItem(at: wrapper.url.deletingLastPathComponent())
                }
            }
        }
    }

    @MainActor
    private func loadImage() async {
        guard let imageURL else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let response = try await loader.load(imageURL)
            try Task.checkCancellation()
            guard let loaded = UIImage(data: response.data) else { throw OfficialMediaError.invalidImage }
            image = loaded
        } catch {
            guard !Task.isCancelled, !isCancellation(error) else { return }
            message = error.localizedDescription
        }
    }

    @MainActor
    private func prepareShare() async {
        guard let imageURL else { return }
        isDownloading = true
        message = nil
        defer { isDownloading = false }
        do {
            let response = try await loader.load(imageURL)
            try Task.checkCancellation()
            guard UIImage(data: response.data) != nil else { throw OfficialMediaError.invalidImage }
            let fileURL = try prepareShareFile(response: response, url: imageURL)
            shareFileURL = ShareFileURL(url: fileURL)
        } catch {
            guard !Task.isCancelled, !isCancellation(error) else { return }
            message = error.localizedDescription
        }
    }
}

/// Presents the system share sheet for a locally staged image file. The share
/// sheet itself offers "Save Image"/"Save to Files", so downloading remains
/// possible through it.
public struct OfficialImageShareSheet: UIViewControllerRepresentable {
    public let fileURL: URL
    public let onComplete: () -> Void

    public init(fileURL: URL, onComplete: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onComplete = onComplete
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        controller.excludedActivityTypes = nil
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper so a staged share file URL can drive `.sheet(item:)`.
struct ShareFileURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Writes the downloaded image bytes to a temporary file, keeping the nice
/// suggested filename intact for the share sheet, without re-encoding. Each
/// call gets its own `OfficialImages/<UUID>/<filename>` subdirectory so
/// concurrent or repeated shares of assets with the same filename never
/// collide; the caller removes that subdirectory (not just the file) once
/// the share sheet completes.
func prepareShareFile(response: OfficialMediaResponse, url: URL) throws -> URL {
    let contentType = imageType(for: response, url: url)
    let filename = exportFilename(suggested: response.suggestedFilename, url: url, contentType: contentType)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OfficialImages", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent(filename)
    try response.data.write(to: fileURL, options: .atomic)
    return fileURL
}

private struct ZoomableUIImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> NativeImageZoomView {
        NativeImageZoomView(image: image)
    }

    func updateUIView(_ view: NativeImageZoomView, context: Context) {
        view.setImage(image)
    }
}

private final class NativeImageZoomView: UIScrollView, UIScrollViewDelegate {
    private let zoomedImageView = UIImageView()
    private var imageIdentity: ObjectIdentifier?
    private var lastBoundsSize: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black
        zoomedImageView.contentMode = .scaleAspectFit
        addSubview(zoomedImageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        setImage(image)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            layoutImage(resetZoom: true)
        } else {
            centerImage()
        }
    }

    func setImage(_ image: UIImage) {
        let identity = ObjectIdentifier(image)
        guard identity != imageIdentity else { return }
        imageIdentity = identity
        zoomedImageView.image = image
        layoutImage(resetZoom: true)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomedImageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func layoutImage(resetZoom: Bool) {
        guard let image = zoomedImageView.image,
              bounds.width > 0,
              bounds.height > 0,
              image.size.width > 0,
              image.size.height > 0 else { return }
        if resetZoom { setZoomScale(minimumZoomScale, animated: false) }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        zoomedImageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerImage()
    }

    private func centerImage() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let targetScale = min(maximumZoomScale, 3)
        let point = recognizer.location(in: zoomedImageView)
        let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
        zoom(to: CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        ), animated: true)
    }
}

func imageType(for response: OfficialMediaResponse, url: URL) -> UTType {
    if let source = CGImageSourceCreateWithData(response.data as CFData, nil),
       let identifier = CGImageSourceGetType(source) {
        if let type = UTType(identifier as String), type.conforms(to: .image) { return type }
    }
    if let mimeType = response.mimeType,
       let type = UTType(mimeType: mimeType),
       type.conforms(to: .image) {
        return type
    }
    if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
        return type
    }
    return .png
}

func exportFilename(suggested: String?, url: URL, contentType: UTType) -> String {
    let fallback = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    var name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    if name.isEmpty { name = "official-image" }
    name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    if let fileExtension = contentType.preferredFilenameExtension {
        let currentExtension = URL(fileURLWithPath: name).pathExtension
        let currentType = UTType(filenameExtension: currentExtension)
        if currentExtension.isEmpty {
            name += ".\(fileExtension)"
        } else if currentType != contentType {
            name = (name as NSString).deletingPathExtension + ".\(fileExtension)"
        }
    }
    return name
}

private func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
