import Foundation

/// The read-only snapshot shared by GitHub Pages and the app.
public struct PagesCatalogSnapshot: Codable, Sendable {
    public struct SourceFailure: Codable, Sendable {
        public let url: String
        public let kind: String
        public let message: String

        public init(url: String, kind: String, message: String) {
            self.url = url
            self.kind = kind
            self.message = message
        }
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let lastSuccessfulRefreshAt: Date?
    public let refreshIntervalSeconds: Int
    public let sourceFailures: [SourceFailure]
    public let events: [LiveEventBundle]

    public init(schemaVersion: Int = 1, generatedAt: Date, lastSuccessfulRefreshAt: Date?,
                refreshIntervalSeconds: Int = 3600, sourceFailures: [SourceFailure], events: [LiveEventBundle]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.sourceFailures = sourceFailures
        self.events = events
    }
}
