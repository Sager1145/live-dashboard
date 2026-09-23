import Foundation
import Observation
import CryptoKit
#if canImport(Translation)
@preconcurrency import Translation
#endif

/// State machine for one in-flight (or just-finished) manual translation
/// batch. `translating(count:)` carries the number of segments still being
/// awaited so the toolbar/card UI can show progress.
public enum TranslationPhase: Sendable, Equatable {
    case idle
    case checking
    case downloading
    case translating(count: Int)
    case failed(String)
    case unsupported
}

/// Identifies what a translation request/failure belongs to: the whole page,
/// or one specific card. Lets a card's failure/progress be shown only on that
/// card, never leaking onto another event or the page toolbar.
public enum TranslationScope: Hashable, Sendable {
    case page(eventID: String)
    case card(eventID: String, cardKey: String)

    public var eventID: String {
        switch self {
        case .page(let id), .card(let id, _): id
        }
    }
}

/// A failed translation batch recorded against its scope, with enough state
/// (`items`, `target`) to retry exactly the original request.
public struct TranslationFailure: Equatable, Sendable {
    public let message: String
    public let items: [TranslationRequestItem]
    public let target: TranslationTargetLanguage
}

/// Manual, user-triggered translation of official (Japanese) text via
/// Apple's on-device `Translation` framework. Owns:
///  - a persistent cache of source-text-hash → translated text, so a
///    revisited event/card never re-translates unchanged text;
///  - per-event / per-card "show translated" UI toggles (memory-only);
///  - the pending-request queue and `TranslationSession.Configuration` that
///    drives the `.translationTask` attached by `LiveDetailView`.
///
/// `Translation` does not work in the iOS Simulator and this type must stay
/// usable in tests, so it never imports `Translation` itself — the actual
/// `session.translations(from:)` call lives in `LiveDetailView`, guarded by
/// `#if canImport(Translation)`, and results are handed back via `store(results:target:)`.
@MainActor
@Observable
public final class TranslationStore {
    public static let shared = TranslationStore()

    /// Maximum number of cached source→translation pairs kept on disk. Oldest
    /// entries (by insertion order) are dropped once this is exceeded.
    static let cacheEntryCap = 5000

    public private(set) var phase: TranslationPhase = .idle
    public private(set) var pendingRequests: [TranslationRequestItem] = []
    public private(set) var inFlightScopes: Set<TranslationScope> = []
    public private(set) var failures: [TranslationScope: TranslationFailure] = [:]
    @ObservationIgnored private var scopeRequests: [TranslationScope: [TranslationRequestItem]] = [:]

    #if canImport(Translation)
    /// Published so `.translationTask(store.configuration)` re-runs whenever
    /// a new batch is queued. `nil` means no translation is in flight.
    public var configuration: TranslationSession.Configuration?
    #endif

    public var translatedEventIDs: Set<String> = []
    public var translatedCardKeys: Set<String> = []

    /// The event whose `.translationTask` should currently be attached, so
    /// `LiveDetailView` can gate the modifier to the active detail page only.
    public private(set) var activeEventID: String?

    private let provider: TranslationProviding
    @ObservationIgnored private var cache: [String: String] = [:]
    /// Insertion order of `cache` keys, oldest first, used to trim the cache
    /// once it exceeds `Self.cacheEntryCap`.
    @ObservationIgnored private var cacheOrder: [String] = []
    private let cacheURL: URL
    @ObservationIgnored private var currentTarget: TranslationTargetLanguage?
    @ObservationIgnored private var pendingByID: [String: TranslationRequestItem] = [:]
    /// Incremented on every `request(items:target:)` call. `perform(with:)`
    /// captures the generation it started with so a batch that finishes (or
    /// fails, or is cancelled) after a newer request was made never clobbers
    /// the newer request's `phase`/`pendingRequests`.
    @ObservationIgnored private var generation = 0
    /// Set from the most recent `availability(target:)` call; consumed once
    /// by the next `perform(with:)` to decide whether to call
    /// `session.prepareTranslation()` (and show `.downloading`) before
    /// translating.
    @ObservationIgnored private var pendingNeedsDownload = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(provider: TranslationProviding = AppleTranslationProvider(), directory: URL? = nil) {
        self.provider = provider
        let baseDirectory = directory ?? {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return support.appendingPathComponent("LiveDashboard/Translations", isDirectory: true)
        }()
        self.cacheURL = baseDirectory.appendingPathComponent("cache.json")
        // Reading a small JSON cache file synchronously in `init` is
        // acceptable; it must not happen lazily inside `cached()`, which is
        // called from view bodies.
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.cache = decoded
            self.cacheOrder = Array(decoded.keys)
        }
    }

    // MARK: - Cache

    private func scheduleSave() {
        let snapshot = cache
        let url = cacheURL
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Test-only: waits for the most recently scheduled debounced cache save
    /// to finish writing to disk.
    func flushPendingSave() async {
        await saveTask?.value
    }

    private func remember(key: String, text: String) {
        if cache.updateValue(text, forKey: key) == nil {
            cacheOrder.append(key)
        }
        trimCacheIfNeeded()
    }

    private func trimCacheIfNeeded() {
        guard cacheOrder.count > Self.cacheEntryCap else { return }
        let overflow = cacheOrder.count - Self.cacheEntryCap
        for key in cacheOrder.prefix(overflow) { cache.removeValue(forKey: key) }
        cacheOrder.removeFirst(overflow)
    }

    private static func cacheKey(text: String, target: TranslationTargetLanguage) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(target.rawValue)|\(hex)"
    }

    public func cached(_ text: String, target: TranslationTargetLanguage) -> String? {
        cache[Self.cacheKey(text: text, target: target)]
    }

    // MARK: - Per-event / per-card UI toggles

    public func isShowingTranslation(eventID: String, cardKey: String?) -> Bool {
        if translatedEventIDs.contains(eventID) { return true }
        if let cardKey { return translatedCardKeys.contains(cardKey) }
        return false
    }

    public func togglePage(eventID: String) {
        if translatedEventIDs.contains(eventID) {
            translatedEventIDs.remove(eventID)
        } else {
            translatedEventIDs.insert(eventID)
        }
    }

    public func toggleCard(cardKey: String) {
        if translatedCardKeys.contains(cardKey) {
            translatedCardKeys.remove(cardKey)
        } else {
            translatedCardKeys.insert(cardKey)
        }
    }

    public static func cardKey(eventID: String, cardType: CardType, entityID: String) -> String {
        "\(eventID)|\(cardType.rawValue)|\(entityID)"
    }

    // MARK: - Availability + request lifecycle

    public func availability(target: TranslationTargetLanguage) async -> TranslationAvailability {
        phase = .checking
        guard let targetLanguage = target.localeLanguage else {
            phase = .idle
            return .unsupported
        }
        let result = await provider.availability(from: TranslationTargetLanguage.sourceLanguage, to: targetLanguage)
        pendingNeedsDownload = (result == .needsDownload)
        phase = .idle
        return result
    }

    /// Filters out already-cached items, then (if anything remains) sets up
    /// the `TranslationSession.Configuration` so the view's
    /// `.translationTask` fires and calls back into `perform`/`store`.
    ///
    /// If a batch is already translating for the same `target`, new uncached
    /// items are merged into `pendingRequests` and the existing
    /// `configuration` is invalidated in place (never replaced) so
    /// `.translationTask` reruns with a session covering the merged set.
    public func request(items: [TranslationRequestItem], target: TranslationTargetLanguage, eventID: String? = nil, scope: TranslationScope? = nil) {
        if let eventID { activeEventID = eventID }
        if let scope { activeEventID = scope.eventID; failures[scope] = nil }
        var seen = Set<String>()
        let uncached = items.filter { item in
            guard seen.insert(item.text).inserted else { return false }
            return cached(item.text, target: target) == nil
        }
        guard !uncached.isEmpty else {
            if pendingRequests.isEmpty { phase = .idle }
            return
        }

        // Only bump the generation once a batch is actually queued or
        // invalidated — an all-cached request (e.g. a card whose segments
        // were already translated) must never make an in-flight batch's
        // generation stale, or that batch's eventual failure/cancel would
        // silently drop its scopes instead of clearing them.
        generation += 1

        let previousTarget = currentTarget
        if target != previousTarget {
            // Language pair changed: any old pending items belonged to a
            // different target and are no longer relevant.
            pendingRequests = []
            pendingByID = [:]
            inFlightScopes = []
            scopeRequests = [:]
        }
        currentTarget = target

        for item in uncached where pendingByID[item.id] == nil {
            pendingRequests.append(item)
            pendingByID[item.id] = item
        }
        if let scope {
            inFlightScopes.insert(scope)
            scopeRequests[scope, default: []] += items
        }
        phase = .translating(count: pendingRequests.count)

        #if canImport(Translation)
        guard let targetLanguage = target.localeLanguage else {
            phase = .unsupported
            inFlightScopes = []
            scopeRequests = [:]
            return
        }
        if configuration != nil, previousTarget == target {
            configuration?.invalidate()
        } else {
            configuration?.invalidate()
            configuration = TranslationSession.Configuration(source: TranslationTargetLanguage.sourceLanguage, target: targetLanguage)
        }
        #endif
    }

    public func store(results: [TranslationResultItem], target: TranslationTargetLanguage) {
        store(results: results, target: target, generation: generation)
    }

    /// Test-only window into the request generation counter (see `generation`).
    var currentGeneration: Int { generation }

    /// `batchGeneration` is the generation `perform(with:)` captured when it
    /// started. Cached results are always written (they're correct
    /// regardless of how stale the batch is), but `phase` is only updated
    /// when this is still the current generation — an older batch finishing
    /// must never clobber a newer request's pending items or phase.
    func store(results: [TranslationResultItem], target: TranslationTargetLanguage, generation batchGeneration: Int) {
        var storedIDs = Set<String>()
        for result in results {
            guard let source = pendingByID[result.id] else { continue }
            remember(key: Self.cacheKey(text: source.text, target: target), text: result.text)
            storedIDs.insert(result.id)
        }
        scheduleSave()

        pendingRequests.removeAll { storedIDs.contains($0.id) }
        for id in storedIDs { pendingByID.removeValue(forKey: id) }

        if pendingRequests.isEmpty { inFlightScopes = []; scopeRequests = [:] }

        guard batchGeneration == generation else { return }
        phase = pendingRequests.isEmpty ? .idle : .translating(count: pendingRequests.count)
    }

    public func fail(_ message: String) {
        fail(message, generation: generation)
    }

    func fail(_ message: String, generation batchGeneration: Int) {
        guard batchGeneration == generation else { return }
        for scope in inFlightScopes {
            failures[scope] = TranslationFailure(message: message, items: scopeRequests[scope] ?? [], target: currentTarget ?? .followApp)
        }
        inFlightScopes = []
        scopeRequests = [:]
        pendingRequests = []
        pendingByID = [:]
        phase = .failed(message)
    }

    public func cancel() {
        generation += 1
        pendingRequests = []
        pendingByID = [:]
        inFlightScopes = []
        scopeRequests = [:]
        phase = .idle
    }

    public func failure(for scope: TranslationScope) -> TranslationFailure? {
        failures[scope]
    }

    public func clearFailure(_ scope: TranslationScope) {
        failures[scope] = nil
    }

    /// Retries a failed batch with exactly the items it originally requested.
    /// Never toggles the page/card "show translated" flag — the caller is
    /// already showing (or wants to show) the translation.
    public func retry(_ scope: TranslationScope) {
        guard let failure = failures[scope] else { return }
        request(items: failure.items, target: failure.target, scope: scope)
    }

    public func isTranslating(_ scope: TranslationScope) -> Bool {
        inFlightScopes.contains(scope)
    }

    public func isTranslating(eventID: String) -> Bool {
        inFlightScopes.contains { $0.eventID == eventID }
    }

    public func hasUntranslated(_ items: [TranslationRequestItem], target: TranslationTargetLanguage) -> Bool {
        items.contains { Self.isTranslatable($0.text) && cached($0.text, target: target) == nil }
    }

    // MARK: - Segment collection

    /// Free-form official text worth translating for the given bundle and
    /// (optionally) a specific performance. Skips empty, numeric-only, URL,
    /// and ASCII-only (no CJK) strings, and deduplicates by text.
    public func sourceSegments(for bundle: LiveEventBundle, performanceID: String?) -> [TranslationRequestItem] {
        var seenTexts = Set<String>()
        var items: [TranslationRequestItem] = []

        func add(_ id: String, _ text: String?) {
            guard let text, Self.isTranslatable(text) else { return }
            guard seenTexts.insert(text).inserted else { return }
            items.append(TranslationRequestItem(id: id, text: text))
        }

        add("event|title", bundle.event.officialTitle)

        let performances = performanceID.flatMap { pid in bundle.performances.filter { $0.id == pid } } ?? bundle.performances
        for performance in performances {
            add("performance|\(performance.id)|venueName", performance.venueName)
            add("performance|\(performance.id)|venueCity", performance.venueCity)
            add("performance|\(performance.id)|rawDate", performance.rawDate)
            for (index, performer) in performance.performers.enumerated() {
                add("performance|\(performance.id)|performer|\(index)", performer)
            }
        }

        for notice in bundle.notices {
            add("notice|\(notice.id)|title", notice.title)
            add("notice|\(notice.id)|body", notice.body)
        }

        for tier in bundle.ticketTiers {
            add("tier|\(tier.id)|name", tier.name)
        }

        for round in bundle.ticketRounds {
            add("round|\(round.id)|name", round.officialName)
            for (index, note) in round.notes.enumerated() {
                add("round|\(round.id)|note|\(index)", note.text)
            }
        }

        for campaign in bundle.goodsCampaigns {
            add("campaign|\(campaign.id)|name", campaign.officialName)
        }
        for product in bundle.products {
            add("product|\(product.id)|name", product.name)
            for variant in product.variants {
                add("product|\(product.id)|variant|\(variant.id)|name", variant.name)
            }
        }

        for round in bundle.ticketRounds {
            for link in round.links { add("link|\(link.id)|label", link.label) }
        }
        for campaign in bundle.goodsCampaigns {
            for link in campaign.links { add("link|\(link.id)|label", link.label) }
        }

        return items
    }

    #if canImport(Translation)
    /// Called from `.translationTask(store.configuration) { session in await store.perform(with: session) }`
    /// on `LiveDetailView`. Translates `pendingRequests` in one batch and
    /// stores the results, or moves `phase` to `.failed`/`.idle` on error.
    public func perform(with session: TranslationSession) async {
        guard let target = currentTarget, !pendingRequests.isEmpty else { return }
        let requests = pendingRequests
        let batchGeneration = generation
        do {
            if pendingNeedsDownload {
                pendingNeedsDownload = false
                if batchGeneration == generation { phase = .downloading }
                try await session.prepareTranslation()
                if batchGeneration == generation { phase = .translating(count: requests.count) }
            }
            let results = try await Self.translate(requests, with: session)
            store(results: results, target: target, generation: batchGeneration)
        } catch is CancellationError {
            // A newer request likely invalidated this session (merge-by-
            // reinvalidate); if so it already owns `phase`/`pendingRequests`
            // and this batch must not touch them.
            guard batchGeneration == generation else { return }
            phase = .idle
            pendingRequests = []
            pendingByID = [:]
            inFlightScopes = []
            scopeRequests = [:]
        } catch {
            fail(error.localizedDescription, generation: batchGeneration)
        }
    }

    /// Runs off the main actor so the `TranslationSession.Request`/`Response`
    /// values built here never have to "send" across an isolation boundary
    /// from `perform(with:)`'s main-actor context.
    private nonisolated static func translate(_ requests: [TranslationRequestItem], with session: TranslationSession) async throws -> [TranslationResultItem] {
        let sessionRequests = requests.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        let responses = try await session.translations(from: sessionRequests)
        return responses.compactMap { response in
            guard let id = response.clientIdentifier else { return nil }
            return TranslationResultItem(id: id, text: response.targetText)
        }
    }
    #endif

    static func isTranslatable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^https?://"#, options: .regularExpression) != nil { return false }
        if trimmed.range(of: #"^[0-9\p{P}\s]+$"#, options: .regularExpression) != nil { return false }
        // Skip strings with no CJK content — nothing meaningful to translate.
        let hasCJK = trimmed.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)   // Hiragana/Katakana
                || (0x4E00...0x9FFF).contains(scalar.value) // CJK unified ideographs
                || (0x3400...0x4DBF).contains(scalar.value) // CJK extension A
        }
        return hasCJK
    }
}
