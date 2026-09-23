import SwiftUI

/// Refresh work is owned by `LiveDetailView`, while the menu remains reusable
/// by every detail card. A missing action means this presentation does not
/// support a scoped official-source refresh.
public struct DetailCardRefreshAction: Sendable {
    public let isRefreshing: Bool
    public let refresh: @MainActor (CardType, String) async -> Void

    public init(
        isRefreshing: Bool,
        refresh: @escaping @MainActor (CardType, String) async -> Void
    ) {
        self.isRefreshing = isRefreshing
        self.refresh = refresh
    }
}

private struct DetailCardRefreshActionKey: EnvironmentKey {
    static let defaultValue: DetailCardRefreshAction? = nil
}

public extension EnvironmentValues {
    var detailCardRefreshAction: DetailCardRefreshAction? {
        get { self[DetailCardRefreshActionKey.self] }
        set { self[DetailCardRefreshActionKey.self] = newValue }
    }
}

/// Trailing per-card `Menu`: 隐藏, 置顶, 紧凑/详细, 提醒. Per DESIGN.md 五, this
/// writes a `CardConfiguration` keyed by (cardType, entityID) — never by
/// array index — so the change survives a republished bundle.
public struct DetailCardMenu: View {
    let cardType: CardType
    let entityID: String
    let userDataStore: UserDataStore
    let eventID: String?
    let onToggleReminder: (() -> Void)?
    @Environment(\.detailCardRefreshAction) private var refreshAction

    public init(
        cardType: CardType,
        entityID: String,
        userDataStore: UserDataStore,
        eventID: String? = nil,
        onToggleReminder: (() -> Void)? = nil
    ) {
        self.cardType = cardType
        self.entityID = entityID
        self.userDataStore = userDataStore
        self.eventID = eventID
        self.onToggleReminder = onToggleReminder
    }

    private var config: CardConfiguration {
        guard let eventID else {
            return userDataStore.configuration(cardType: cardType, entityID: entityID)
                ?? CardConfiguration(cardType: cardType, entityID: entityID)
        }
        return userDataStore.effectiveConfiguration(cardType: cardType, entityID: entityID, eventID: eventID)
    }

    public var body: some View {
        Menu {
            if let refreshAction, cardType != .assistantSummary {
                Button {
                    Task { await refreshAction.refresh(cardType, entityID) }
                } label: {
                    Label(refreshAction.isRefreshing ? "正在重新整理…" : "重新整理此卡片", systemImage: "arrow.clockwise")
                }
                .disabled(refreshAction.isRefreshing)
            }

            Button {
                var updated = config
                updated.entityID = entityID
                updated.eventID = eventID
                updated.isHidden = true
                userDataStore.setConfiguration(updated)
            } label: {
                Label("隐藏", systemImage: "eye.slash")
            }

            Button {
                var updated = config
                updated.entityID = entityID
                updated.eventID = eventID
                updated.isPinned.toggle()
                userDataStore.setConfiguration(updated)
            } label: {
                Label(config.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }

            Button {
                var updated = config
                updated.entityID = entityID
                updated.eventID = eventID
                updated.density = updated.density == .compact ? .detailed : .compact
                userDataStore.setConfiguration(updated)
            } label: {
                Label(config.density == .compact ? "详细" : "紧凑", systemImage: "text.alignleft")
            }

            if let onToggleReminder {
                Button(action: onToggleReminder) {
                    Label("提醒", systemImage: "bell")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
