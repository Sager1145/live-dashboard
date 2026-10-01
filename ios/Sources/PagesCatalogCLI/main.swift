import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LiveIngestionCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct PagesCatalogCLI {
    static func main() async {
        do { try await publish() }
        catch {
            FileHandle.standardError.write(Data("Catalog publication failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func publish() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            throw CLIError.usage
        }
        let input = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[2])
        let previous: PagesCatalogSnapshot?
        if FileManager.default.fileExists(atPath: input.path) {
            previous = try LiveEventBundle.decoder.decode(PagesCatalogSnapshot.self, from: Data(contentsOf: input))
            guard previous?.schemaVersion == 1 else { throw CLIError.invalidSnapshot }
        } else {
            previous = nil
        }
        let now = Date()
        let japan = TimeZone(identifier: "Asia/Tokyo")!
        let cutoff = LocalRefreshPolicy.cutoff(now: now, timeZone: japan)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let scraper = OfficialEventScraper(session: URLSession(configuration: configuration))
        var collected: [LiveEventBundle]
        var failures: [PagesCatalogSnapshot.SourceFailure] = []
        do {
            collected = try await scraper.collect(existing: previous?.events ?? [], cutoff: cutoff, now: now)
        } catch OfficialEventScraperError.partialFailure(let bundles, let sourceFailures) {
            collected = bundles
            failures = sourceFailures.map {
                .init(url: $0.url.absoluteString, kind: $0.kind.rawValue, message: $0.message)
            }
        }
        // Never discard archived records or last-known data during partial outages.
        var merged = Dictionary((previous?.events ?? []).map { ($0.event.id, $0) }, uniquingKeysWith: { _, last in last })
        for bundle in collected { merged[bundle.event.id] = bundle }
        guard !merged.isEmpty else { throw CLIError.noData }
        let snapshot = PagesCatalogSnapshot(
            generatedAt: now,
            lastSuccessfulRefreshAt: failures.isEmpty ? now : previous?.lastSuccessfulRefreshAt,
            sourceFailures: failures,
            events: merged.values.sorted { $0.event.id < $1.event.id }
        )
        let encoder = LiveEventBundle.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: output, options: .atomic)
        print("Published \(snapshot.events.count) events; \(failures.count) source failures.")
        for failure in failures { print("Source warning: \(failure.kind) \(failure.url)") }
    }

    enum CLIError: Error, LocalizedError {
        case usage, invalidSnapshot, noData
        var errorDescription: String? {
            switch self {
            case .usage: "Usage: PagesCatalogCLI previous-catalog.json output-catalog.json"
            case .invalidSnapshot: "Unsupported previous catalog schema."
            case .noData: "No official data available; refusing to publish an empty catalog."
            }
        }
    }
}
