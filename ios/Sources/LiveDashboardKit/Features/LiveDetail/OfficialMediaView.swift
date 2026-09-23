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
/// Preview decoding and zoom-viewer decoding both go through
/// `OfficialImagePipeline`, which caches original bytes and downsampled
/// images so switching performances doesn't re-download the same asset.
public struct OfficialMediaView: View {
    public let asset: MediaAsset
    public let compact: Bool

    @State private var previewImage: UIImage?
    /// The `previewTaskID` that `previewImage` was loaded for, so a stale load from a
    /// previous `previewTaskID` (e.g. a fast performance switch) is never shown or shared.
    @State private var loadedPreviewID: String?
    @State private var loadError: String?
    @State private var showsZoom = false
    @State private var copyFeedback = false

    public init(asset: MediaAsset, compact: Bool = false) {
        self.asset = asset
        self.compact = compact
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
        .fullScreenCover(isPresented: $showsZoom) {
            if let originalURL {
                ZoomableImageViewer(imageURL: originalURL, caption: asset.caption, sourceURL: distinctSourceURL)
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Button {
                    if displayedPreviewImage != nil { showsZoom = true }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.quaternary)
                        if let displayedPreviewImage {
                            Image(uiImage: displayedPreviewImage)
                                .resizable()
                                .scaledToFit()
                                .padding(4)
                                .transition(.opacity)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                                .accessibilityHidden(true)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        } else if loadError == nil {
                            PreviewLoadingIndicator()
                        }
                    }
                    .aspectRatio(displayedPreviewImage.map { $0.size.width / max($0.size.height, 1) } ?? (16.0 / 9.0), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: compact ? 160 : 340)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(displayedPreviewImage == nil)
                .accessibilityLabel(Text(verbatim: asset.caption ?? String(localized: "官方图片", bundle: .kit)))
                .accessibilityHint(Text("打开原图并缩放", bundle: .kit))
                .accessibilityIdentifier("mediaImage-\(asset.id)")

                if let loadError {
                    VStack(spacing: 6) {
                        Label {
                            Text(loadError).font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.statusWarning)
                        }
                        Button {
                            Task { await loadPreview() }
                        } label: {
                            Text("重试", bundle: .kit)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: compact ? 160 : 340)
                    .allowsHitTesting(true)
                }
            }
            .motionAnimation(previewImage != nil)

            if let caption = asset.caption, !caption.isEmpty {
                Text(verbatim: caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let originalURL {
                HStack(spacing: 12) {
                    if let displayedPreviewImage {
                        ShareLink(
                            item: OfficialImageTransfer(url: originalURL, caption: asset.caption),
                            preview: SharePreview(asset.caption ?? String(localized: "官方图片", bundle: .kit), image: Image(uiImage: displayedPreviewImage))
                        ) {
                            Label { Text("分享原图", bundle: .kit) } icon: { Image(systemName: "square.and.arrow.up") }
                        }
                        .accessibilityIdentifier("mediaShare-\(asset.id)")
                    }
                    Menu {
                        Link(destination: originalURL) {
                            Label { Text("在浏览器打开原图", bundle: .kit) } icon: { Image(systemName: "safari") }
                        }
                        Button {
                            UIPasteboard.general.string = originalURL.absoluteString
                            copyFeedback.toggle()
                        } label: {
                            Label { Text("复制链接", bundle: .kit) } icon: { Image(systemName: "doc.on.doc") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("更多操作", bundle: .kit))
                    .accessibilityIdentifier("mediaMoreActions-\(asset.id)")
                    if let host = originalURL.host {
                        Text(host).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .sensoryFeedback(.success, trigger: copyFeedback)
            }
        }
    }

    @ViewBuilder
    private var originalLink: some View {
        if let originalURL {
            Link(destination: originalURL) {
                VStack(alignment: .leading, spacing: 2) {
                    Label { Text("打开官方附件", bundle: .kit) } icon: { Image(systemName: "doc") }
                        .font(.caption)
                    if let host = originalURL.host {
                        Text(host).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = originalURL.absoluteString
                } label: {
                    Label { Text("复制链接", bundle: .kit) } icon: { Image(systemName: "doc.on.doc") }
                }
            }
            .accessibilityValue(Text(originalURL.absoluteString))
            .accessibilityIdentifier("mediaOriginalLink-\(asset.id)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("链接格式无效", bundle: .kit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(asset.originalURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityIdentifier("mediaOriginalLink-\(asset.id)")
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

    /// `previewImage`, but only once it has actually finished loading for the *current*
    /// `previewTaskID` — never an image left over from a previous performance/asset.
    private var displayedPreviewImage: UIImage? {
        loadedPreviewID == previewTaskID ? previewImage : nil
    }

    @MainActor
    private func loadPreview() async {
        // Intentionally does not reset `previewImage` to nil first: keeping the
        // last-decoded image on screen while a retry/refresh runs avoids the
        // card flashing to a spinner for an asset it can already display.
        let id = previewTaskID
        loadError = nil

        var urls: [URL] = []
        if let thumbnail = asset.thumbnailURL.flatMap(URL.init(string:)) { urls.append(thumbnail) }
        if let originalURL, !urls.contains(originalURL) { urls.append(originalURL) }

        for url in urls {
            do {
                let image = try await OfficialImagePipeline.shared.image(for: url, maxPixelSize: 1200)
                try Task.checkCancellation()
                guard previewTaskID == id else { return }
                previewImage = image
                loadedPreviewID = id
                loadError = nil
                return
            } catch {
                if Task.isCancelled || isCancellation(error) { return }
                guard previewTaskID == id else { return }
                // A same-id retry may keep showing the previously loaded image; a genuinely
                // new id that never succeeded must show the error state without any image.
                if loadedPreviewID != id { previewImage = nil }
                loadError = error.localizedDescription
            }
        }
    }
}

/// Shows the spinner immediately; the "loading" caption only appears once the
/// load has taken noticeably long, so quick loads never flash the label.
private struct PreviewLoadingIndicator: View {
    @State private var showsLabel = false

    var body: some View {
        VStack(spacing: 6) {
            ProgressView()
            if showsLabel {
                Text("正在载入…", bundle: .kit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            showsLabel = true
        }
    }
}

/// Full-screen zoomable viewer for an official image, backed by
/// `OfficialImagePipeline.viewerImage(for:)` (full-resolution, capped at
/// 4096px). Presented via `.fullScreenCover` so the image reads edge-to-edge.
public struct ZoomableImageViewer: View {
    let imageURL: URL
    let caption: String?
    let sourceURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loadError: String?
    @State private var copyFeedback = false

    public init(imageURL: URL, caption: String? = nil, sourceURL: URL? = nil) {
        self.imageURL = imageURL
        self.caption = caption
        self.sourceURL = sourceURL
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableUIImageView(image: image, caption: caption)
                } else if let loadError {
                    ContentUnavailableView {
                        Label { Text("无法显示图片", bundle: .kit) } icon: { Image(systemName: "photo") }
                    } description: {
                        Text(loadError)
                    } actions: {
                        VStack(spacing: 8) {
                            Button {
                                Task { await loadImage() }
                            } label: {
                                Text("重试", bundle: .kit)
                            }
                            .buttonStyle(.bordered)
                            Link(destination: imageURL) {
                                Text("在浏览器中打开", bundle: .kit)
                            }
                        }
                    }
                        .foregroundStyle(.white)
                } else {
                    ProgressView {
                        Text("正在载入原图…", bundle: .kit)
                    }
                        .tint(.white)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if let caption, !caption.isEmpty { Text(verbatim: caption).font(.footnote) }
                    if let host = imageURL.host() {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            sourceDetailRow(url: imageURL)
                            if let sourceURL, sourceURL != imageURL {
                                sourceDetailRow(url: sourceURL)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text("来源详情", bundle: .kit)
                            .font(.caption)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
                .sensoryFeedback(.success, trigger: copyFeedback)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("关闭", bundle: .kit)
                    }
                        .accessibilityIdentifier("zoomDoneButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    if let image {
                        ShareLink(
                            item: OfficialImageTransfer(url: imageURL, caption: caption),
                            preview: SharePreview(caption ?? String(localized: "官方图片", bundle: .kit), image: Image(uiImage: image))
                        ) {
                            Label { Text("分享", bundle: .kit) } icon: { Image(systemName: "square.and.arrow.up") }
                        }
                        .accessibilityIdentifier("zoomShareButton")
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task(id: imageURL) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        loadError = nil
        do {
            let loaded = try await OfficialImagePipeline.shared.viewerImage(for: imageURL)
            try Task.checkCancellation()
            image = loaded
        } catch {
            guard !Task.isCancelled, !isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func sourceDetailRow(url: URL) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(url.absoluteString)
                .font(.caption)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = url.absoluteString
                copyFeedback.toggle()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel(Text("复制", bundle: .kit))
        }
    }
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
    let caption: String?
    var fallbackAccessibilityLabel: String = String(localized: "官方图片", bundle: .kit)

    func makeUIView(context: Context) -> NativeImageZoomView {
        NativeImageZoomView(image: image, caption: caption, fallbackAccessibilityLabel: fallbackAccessibilityLabel)
    }

    func updateUIView(_ view: NativeImageZoomView, context: Context) {
        view.setImage(image, caption: caption, fallbackAccessibilityLabel: fallbackAccessibilityLabel)
    }
}

private final class NativeImageZoomView: UIScrollView, UIScrollViewDelegate {
    private let zoomedImageView = UIImageView()
    private var imageIdentity: ObjectIdentifier?
    private var lastBoundsSize: CGSize = .zero
    private var fallbackAccessibilityLabel: String
    private var caption: String?

    init(image: UIImage, caption: String?, fallbackAccessibilityLabel: String) {
        self.fallbackAccessibilityLabel = fallbackAccessibilityLabel
        self.caption = caption
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        zoomedImageView.contentMode = .scaleAspectFit
        addSubview(zoomedImageView)

        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "放大", bundle: .kit), target: self, selector: #selector(handleAccessibilityZoomIn)),
            UIAccessibilityCustomAction(name: String(localized: "缩小", bundle: .kit), target: self, selector: #selector(handleAccessibilityZoomOut)),
            UIAccessibilityCustomAction(name: String(localized: "重置", bundle: .kit), target: self, selector: #selector(handleAccessibilityResetZoom))
        ]

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        setImage(image, caption: caption, fallbackAccessibilityLabel: fallbackAccessibilityLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Zoom is reset only when the image identity or the view's bounds
        // size changes — not on every layout pass — so rotating back to the
        // same size or a benign re-layout doesn't discard the user's zoom.
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            layoutImage(resetZoom: true)
        } else {
            centerImage()
        }
    }

    func setImage(_ image: UIImage, caption: String?, fallbackAccessibilityLabel: String) {
        self.caption = caption
        self.fallbackAccessibilityLabel = fallbackAccessibilityLabel
        accessibilityLabel = (caption?.isEmpty == false) ? caption : fallbackAccessibilityLabel
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
        accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
    }

    // Reduce Motion turns off the animation for programmatic zoom changes
    // (double-tap and the VoiceOver custom actions); pinch-to-zoom is driven
    // by the system gesture and is left untouched.
    private var zoomAnimated: Bool { !UIAccessibility.isReduceMotionEnabled }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: zoomAnimated)
            return
        }
        zoomIn(at: recognizer.location(in: zoomedImageView))
    }

    private func zoomIn(at point: CGPoint) {
        let targetScale = min(maximumZoomScale, 3)
        let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
        zoom(to: CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        ), animated: zoomAnimated)
    }

    @objc private func handleAccessibilityZoomIn() -> Bool {
        zoomIn(at: CGPoint(x: zoomedImageView.bounds.midX, y: zoomedImageView.bounds.midY))
        return true
    }

    @objc private func handleAccessibilityZoomOut() -> Bool {
        setZoomScale(max(minimumZoomScale, zoomScale / 2), animated: zoomAnimated)
        return true
    }

    @objc private func handleAccessibilityResetZoom() -> Bool {
        setZoomScale(minimumZoomScale, animated: zoomAnimated)
        return true
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
