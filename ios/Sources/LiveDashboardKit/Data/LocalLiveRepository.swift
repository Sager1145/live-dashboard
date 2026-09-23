import Foundation

/// An inclusive calendar month based on the date currently shown by the phone.
public enum LocalRefreshPolicy {
    public static func cutoff(now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .month, value: -1, to: day)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func phoneDay(now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    public static func isArchived(_ bundle: LiveEventBundle, cutoff: String) -> Bool {
        hasEnded(bundle, before: cutoff)
    }

    /// True when every performance has a known local date and the last one is before `day` (yyyy-MM-dd).
    /// An unknown date or any later tour stop keeps the event current.
    public static func hasEnded(_ bundle: LiveEventBundle, before day: String) -> Bool {
        guard !bundle.performances.isEmpty,
              bundle.performances.allSatisfy({ $0.localDate != nil }),
              let last = bundle.performances.compactMap(\.localDate).max() else { return false }
        return last < day
    }
}

public actor LocalLiveRepository: LiveRepository {
    private struct Catalog: Codable {
        var events: [LiveEventBundle] = []
        var lastRefresh: Date?
        var lastRefreshDay: String?
        var lastAttemptDay: String?
    }
    private let scraper: any OfficialEventScraping
    private let fileURL: URL
    private let legacyCacheURL: URL?
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var catalog: Catalog?
    private var refreshTask: Task<[LiveEventBundle], Error>?
    private var eventTasks: [String: Task<LiveEventBundle, Error>] = [:]
    private var historyTask: Task<[LiveEventBundle], Error>?

    public init(scraper: any OfficialEventScraping = OfficialEventScraper(), directory: URL? = nil,
                calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }) {
        if directory == nil {
            let raw = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://127.0.0.1:3000/"
            let baseURL = URL(string: raw) ?? URL(string: "http://127.0.0.1:3000/")!
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in baseURL.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            legacyCacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("LiveDashboard/PublicCatalog/\(String(hash, radix: 16))/catalog.json")
        } else { legacyCacheURL = nil }
        self.scraper = scraper
        self.calendar = calendar
        self.now = now
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveDashboard/OfficialCatalog", isDirectory: true)
        self.fileURL = root.appendingPathComponent("catalog.json")
    }

    public func allBundles() async throws -> [LiveEventBundle] { try load().events }
    public func bundle(eventID: String) async throws -> LiveEventBundle? { try load().events.first { $0.event.id == eventID } }
    public func changes(eventID: String) async throws -> [EventChangeHistory] { [] }
    public func lastRefreshDate() async -> Date? { try? load().lastRefresh }

    public func refreshIfNeeded() async throws -> [LiveEventBundle] {
        if let refreshTask { return try await refreshTask.value }
        let saved = try load()
        let today = LocalRefreshPolicy.phoneDay(now: now(), timeZone: calendar.timeZone)
        if saved.lastRefreshDay == today || saved.lastAttemptDay == today { return saved.events }
        return try await refresh()
    }

    public func refresh() async throws -> [LiveEventBundle] {
        if let refreshTask { return try await refreshTask.value }
        while !eventTasks.isEmpty || historyTask != nil {
            for task in eventTasks.values { _ = try? await task.value }
            if let historyTask { _ = try? await historyTask.value }
        }
        if let refreshTask { return try await refreshTask.value }
        var previous = try load()
        let timestamp = now()
        previous.lastAttemptDay = LocalRefreshPolicy.phoneDay(now: timestamp, timeZone: calendar.timeZone)
        try persist(previous)
        catalog = previous
        let cutoff = LocalRefreshPolicy.cutoff(now: timestamp, timeZone: calendar.timeZone)
        let task = Task { [scraper] in
            defer { self.refreshTask = nil }
            do {
                let collected = try await scraper.collect(existing: previous.events, cutoff: cutoff, now: timestamp)
                try Task.checkCancellation()
                return try self.save(collected: collected, previous: previous, cutoff: cutoff, timestamp: timestamp)
            } catch OfficialEventScraperError.partialFailure(let bundles, let failures) {
                _ = try self.save(collected: bundles, previous: previous, cutoff: cutoff, timestamp: previous.lastRefresh, completed: false)
                throw OfficialEventScraperError.partialFailure(partialBundles: bundles, failures: failures)
            }
        }
        refreshTask = task
        return try await task.value
    }

    /// Explicit per-event refresh also permits rechecking an archived event.
    public func refresh(eventID: String) async throws -> LiveEventBundle? {
        try await refreshEvent(eventID: eventID, card: nil)
    }

    public func refresh(eventID: String, cardType: CardType, entityID: String) async throws -> LiveEventBundle? {
        try await refreshEvent(eventID: eventID, card: (cardType, entityID))
    }

    private func refreshEvent(eventID: String, card: (CardType, String)?) async throws -> LiveEventBundle? {
        if let refreshTask { _ = try? await refreshTask.value }
        if let historyTask { _ = try? await historyTask.value }
        if let task = eventTasks[eventID] {
            _ = try? await task.value
            // Each selected card is a distinct operation; queue it after the current one.
            return try await refreshEvent(eventID: eventID, card: card)
        }
        guard let existing = try load().events.first(where: { $0.event.id == eventID }) else { return nil }
        let timestamp = now()
        let task = Task { [scraper] in
            defer { self.eventTasks[eventID] = nil }
            let fresh = try await scraper.collect(event: existing, now: timestamp)
            let updated = try card.map { try CardRefreshMerge.apply(fresh, to: existing, cardType: $0.0, entityID: $0.1) } ?? fresh
            try Task.checkCancellation()
            var current = try self.load()
            current.events.removeAll { $0.event.id == eventID }
            current.events.append(updated)
            current.events.sort { $0.event.id < $1.event.id }
            // A single card does not count as the day's complete catalog refresh.
            try self.persist(current)
            self.catalog = current
            return updated
        }
        eventTasks[eventID] = task
        return try await task.value
    }

    public func clearPublicCache() async throws {
        // Wait for an active write before removing it, so a completed clear stays cleared.
        if let refreshTask { _ = try? await refreshTask.value }
        for task in eventTasks.values { _ = try? await task.value }
        if let historyTask { _ = try? await historyTask.value }
        let empty = Catalog()
        try persist(empty)
        catalog = empty
    }

    public func fetchHistory(start: String, end: String) async throws -> [LiveEventBundle] {
        if let historyTask { return try await historyTask.value }
        // Wait until no catalog write is in flight, then re-check: another caller
        // may have started one while this actor was suspended.
        while refreshTask != nil || !eventTasks.isEmpty {
            if let refreshTask { _ = try? await refreshTask.value }
            for task in eventTasks.values { _ = try? await task.value }
        }
        if let historyTask { return try await historyTask.value }
        let previous = try load()
        let timestamp = now()
        let window = OfficialDateWindow(start: start, end: end)
        let task = Task { [scraper] in
            defer { self.historyTask = nil }
            do {
                let collected = try await scraper.collect(existing: previous.events, window: window, now: timestamp)
                try Task.checkCancellation()
                try self.saveHistory(collected: collected)
                return collected
            } catch OfficialEventScraperError.partialFailure(let bundles, let failures) {
                try self.saveHistory(collected: bundles)
                throw OfficialEventScraperError.partialFailure(partialBundles: bundles, failures: failures)
            }
        }
        historyTask = task
        return try await task.value
    }

    private func load() throws -> Catalog {
        if let catalog { return catalog }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Keep previously organized API data on upgrade, including archived events and IDs.
            if let legacyCacheURL, FileManager.default.fileExists(atPath: legacyCacheURL.path) {
                struct LegacyCatalog: Decodable { let events: [LiveEventBundle] }
                let legacy = try LiveEventBundle.decoder.decode(LegacyCatalog.self, from: Data(contentsOf: legacyCacheURL))
                let migrated = Catalog(events: legacy.events)
                try persist(migrated)
                catalog = migrated
                return migrated
            }
            let empty = Catalog(); catalog = empty; return empty
        }
        let saved = try LiveEventBundle.decoder.decode(Catalog.self, from: Data(contentsOf: fileURL))
        catalog = saved
        return saved
    }

    private func persist(_ value: Catalog) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LiveEventBundle.encoder.encode(value).write(to: fileURL, options: .atomic)
    }

    private func save(collected: [LiveEventBundle], previous: Catalog, cutoff: String, timestamp: Date?, completed: Bool = true) throws -> [LiveEventBundle] {
        var merged = Dictionary(previous.events.map { ($0.event.id, $0) }, uniquingKeysWith: { _, last in last })
        for bundle in collected {
            if let saved = merged[bundle.event.id], LocalRefreshPolicy.isArchived(saved, cutoff: cutoff) { continue }
            guard !LocalRefreshPolicy.isArchived(bundle, cutoff: cutoff) else { continue }
            merged[bundle.event.id] = bundle
        }
        let saved = Catalog(events: merged.values.sorted { $0.event.id < $1.event.id }, lastRefresh: timestamp,
            lastRefreshDay: completed ? timestamp.map { LocalRefreshPolicy.phoneDay(now: $0, timeZone: calendar.timeZone) } : previous.lastRefreshDay,
            lastAttemptDay: previous.lastAttemptDay)
        try persist(saved)
        catalog = saved
        return saved.events
    }

    /// A manual history fetch is not the day's catalog refresh: unlike `save`,
    /// this overwrites every collected bundle unconditionally (no archived
    /// checks) and never touches `lastRefresh`/`lastRefreshDay`/`lastAttemptDay`.
    private func saveHistory(collected: [LiveEventBundle]) throws {
        var current = try load()
        for bundle in collected {
            current.events.removeAll { $0.event.id == bundle.event.id }
            current.events.append(bundle)
        }
        current.events.sort { $0.event.id < $1.event.id }
        try persist(current)
        catalog = current
    }
}
