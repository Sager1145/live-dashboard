import Foundation

/// The role a link plays on an official page: the real application entry
/// point, a vendor service/contact/guide page, a linked product page, an
/// overseas application entry point, or something else.
public enum OfficialLinkRole: String, Codable, Hashable, Sendable, CaseIterable {
    case application
    case overseasApplication
    case support
    case product
    case other
}

/// A labelled hyperlink captured verbatim from an official page section, such
/// as a ticket vendor entry or a mail-order (通販) store page. `label` is the
/// anchor text as published; `url` is the resolved absolute URL. Links are
/// never synthesized: every value here was present in the source HTML.
public struct OfficialLink: Codable, Hashable, Identifiable, Sendable {
    public let label: String
    public let url: String
    public let role: OfficialLinkRole?

    public init(label: String, url: String, role: OfficialLinkRole? = nil) {
        self.label = label
        self.url = url
        self.role = role
    }

    public var id: String { "\(url)::\(label)" }

    /// Host-based vendor hint for display, e.g. "eplus.jp". `nil` when the
    /// URL cannot be parsed.
    public var host: String? { URL(string: url)?.host?.lowercased() }

    private enum CodingKeys: String, CodingKey {
        case label, url, role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        url = try c.decode(String.self, forKey: .url)
        role = try c.decodeIfPresent(OfficialLinkRole.self, forKey: .role)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(role, forKey: .role)
    }

    /// Vendor hosts that host the real application flow (受付 button).
    private static let applicationHosts: Set<String> = [
        "eplus.jp", "pia.jp", "t.pia.jp", "w.pia.jp", "l-tike.com", "tixplus.jp",
        "ticket.bushiroad-music.com", "ticket.rakuten.co.jp", "ticketport.jp", "lawson-ticket",
    ]

    private static let productHosts: Set<String> = [
        "bushiroad-music.com", "bushiroad-store.com", "amazon.co.jp", "amazon.com",
        "tower.jp", "hmv.co.jp", "cdjapan.co.jp",
    ]

    private static let applicationLabels: Set<String> = [
        "受付はこちら", "お申込みはこちら", "お申し込みはこちら", "ご購入はこちら", "購入はこちら",
        "申込はこちら", "buy tickets", "受付url", "申込url",
    ]

    private static let supportPathFragments: [String] = [
        "/qa", "/faq", "/help", "/guide", "/sf/", "/support", "/update-",
        "faceticket", "userguide", "/inquiry", "/contact", "/terms", "/policy",
    ]

    private static let supportLabelFragments: [String] = [
        "問い合わせ", "問合せ", "とは", "ガイド", "注意事項", "手続き", "会員登録", "アプリ", "利用について", "詳しくは",
    ]

    private static let productPathFragments: [String] = [
        "/discographies/", "/discography/", "/products/", "/news/",
    ]

    /// Classifies a link by its label and resolved URL. Evaluated in a fixed
    /// priority order (support > overseasApplication > application by vendor
    /// host > product > application by label > other); the first matching
    /// rule wins. Vendor hosts win over product rules so an e+ serial
    /// application page (`eplus.jp/serial/…`) or `ticket.bushiroad-music.com`
    /// stays an application link.
    public static func classify(label: String, url: String) -> OfficialLinkRole {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedLabel = trimmedLabel.lowercased()
        let components = URLComponents(string: url)
        let host = (components?.host ?? URL(string: url)?.host)?.lowercased() ?? ""
        let path = (components?.path ?? URL(string: url)?.path ?? "").lowercased()

        func hostMatches(_ candidates: Set<String>) -> Bool {
            candidates.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        if supportPathFragments.contains(where: { path.contains($0) })
            || host.hasPrefix("support") || host.hasPrefix("member.") || host.hasPrefix("help.")
            || supportLabelFragments.contains(where: { trimmedLabel.contains($0) }) {
            return .support
        }

        let isPiaOrEplusHost = host == "pia.jp" || host.hasSuffix(".pia.jp") || host == "eplus.jp" || host.hasSuffix(".eplus.jp")
        let isKKTIXEvent = (host.hasSuffix("kktix.cc") || host.hasSuffix("kktix.com")) && path.contains("/events/")
        let englishPath = path.range(of: #"(?:^|[/_-])(?:en|eng)(?:[/_-]|$)|engpls"#, options: .regularExpression) != nil
        if host.hasPrefix("ib.") || isKKTIXEvent || host.contains("cityline")
            || (isPiaOrEplusHost && englishPath) {
            return .overseasApplication
        }

        if hostMatches(applicationHosts) {
            return .application
        }

        if hostMatches(productHosts)
            || productPathFragments.contains(where: { path.contains($0) }) {
            return .product
        }

        if applicationLabels.contains(lowercasedLabel) {
            return .application
        }

        return .other
    }
}
