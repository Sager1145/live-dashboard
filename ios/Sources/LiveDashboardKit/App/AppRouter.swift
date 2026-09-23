import Foundation
import Observation

public enum DetailTab: String, CaseIterable, Hashable, Sendable {
    case overview
    case tickets
    case seating
    case goods

    public var titleZH: String {
        switch self {
        case .overview: return "概要"
        case .tickets: return "售票"
        case .seating: return "座位"
        case .goods: return "周边"
        }
    }
}

public enum RootTab: String, CaseIterable, Hashable, Sendable {
    case dashboard
    case pastLives
    case myLives
    case settings

    public var titleZH: String {
        switch self {
        case .dashboard: return "演出"
        case .pastLives: return "往期"
        case .myLives: return "我的"
        case .settings: return "设置"
        }
    }
}

/// A fully-qualified deep link target, per DESIGN.md 七.3: reminders and
/// notifications must resolve to the correct event, performance, tab, and
/// card.
public struct DeepLinkTarget: Hashable, Sendable {
    public let eventID: String
    public let performanceID: String?
    public let tab: DetailTab
    public let cardType: CardType?
    public let entityID: String?

    public init(
        eventID: String,
        performanceID: String? = nil,
        tab: DetailTab = .overview,
        cardType: CardType? = nil,
        entityID: String? = nil
    ) {
        self.eventID = eventID
        self.performanceID = performanceID
        self.tab = tab
        self.cardType = cardType
        self.entityID = entityID
    }
}

/// Centralized navigation state: which root tab is active, and a pending
/// deep link (from a reminder or notification) waiting to be consumed by the
/// detail screen.
@Observable
@MainActor
public final class AppRouter {
    public var selectedRootTab: RootTab = .dashboard
    public var pendingDeepLink: DeepLinkTarget?
    /// Incremented on every navigate so that tapping the same notification twice still
    /// re-triggers observers; `pendingDeepLink` alone is Equatable and would look unchanged.
    public private(set) var deepLinkRequestCount = 0

    public init() {}

    public func navigate(to target: DeepLinkTarget) {
        selectedRootTab = .dashboard
        pendingDeepLink = target
        deepLinkRequestCount &+= 1
    }

    public func consumePendingDeepLink() -> DeepLinkTarget? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }
}
