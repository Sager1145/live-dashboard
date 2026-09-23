import Foundation

/// A labelled hyperlink captured verbatim from an official page section, such
/// as a ticket vendor entry or a mail-order (通販) store page. `label` is the
/// anchor text as published; `url` is the resolved absolute URL. Links are
/// never synthesized: every value here was present in the source HTML.
public struct OfficialLink: Codable, Hashable, Identifiable, Sendable {
    public let label: String
    public let url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }

    public var id: String { "\(url)::\(label)" }

    /// Host-based vendor hint for display, e.g. "eplus.jp". `nil` when the
    /// URL cannot be parsed.
    public var host: String? { URL(string: url)?.host?.lowercased() }
}
