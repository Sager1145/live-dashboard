import SwiftUI
import LiveIngestionCore

/// Refresh work is owned by `LiveDetailView`, while the menu remains reusable
/// by every detail card. A missing action means this presentation does not
/// support a scoped official-source refresh.
public struct DetailCardRefreshAction: Sendable {
    public let isRefreshing: Bool
    /// The card currently being refreshed, so individual cards can show
    /// their own progress indicator instead of a tab-wide banner.
    public let activeCardKey: CardConfiguration.Key?
    public let refresh: @MainActor (CardType, String) async -> Void

    public init(
        isRefreshing: Bool,
        activeCardKey: CardConfiguration.Key? = nil,
        refresh: @escaping @MainActor (CardType, String) async -> Void
    ) {
        self.isRefreshing = isRefreshing
        self.activeCardKey = activeCardKey
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

/// Fired after a card is hidden from `DetailCardMenu`, so the enclosing tab
/// can show a transient "已隐藏 · 撤销" row without needing to inspect every
/// card's configuration itself.
public struct DetailCardHideNotification: Sendable {
    public let notify: @MainActor (CardType, String, String) -> Void
    public init(notify: @escaping @MainActor (CardType, String, String) -> Void) {
        self.notify = notify
    }
}

private struct DetailCardHideNotificationKey: EnvironmentKey {
    static let defaultValue: DetailCardHideNotification? = nil
}

public extension EnvironmentValues {
    var detailCardHideNotification: DetailCardHideNotification? {
        get { self[DetailCardHideNotificationKey.self] }
        set { self[DetailCardHideNotificationKey.self] = newValue }
    }
}

/// Fired when a per-card translation toggle finds the current language pair
/// unsupported, so `LiveDetailView` can surface the same alert the page-level
/// toolbar button uses instead of silently toggling a card on with no result.
public struct DetailCardTranslationUnsupportedAction: Sendable {
    public let notify: @MainActor (String) -> Void
    public init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }
}

private struct DetailCardTranslationUnsupportedKey: EnvironmentKey {
    static let defaultValue: DetailCardTranslationUnsupportedAction? = nil
}

public extension EnvironmentValues {
    var detailCardTranslationUnsupported: DetailCardTranslationUnsupportedAction? {
        get { self[DetailCardTranslationUnsupportedKey.self] }
        set { self[DetailCardTranslationUnsupportedKey.self] = newValue }
    }
}

/// Trailing per-card `Menu`: 重新整理, 隐藏, 置顶, 显示密度. Per DESIGN.md 五, this
/// writes a `CardConfiguration` keyed by (cardType, entityID) — never by
/// array index — so the change survives a republished bundle.
public struct DetailCardMenu: View {
    let title: String
    let cardType: CardType
    let entityID: String
    /// The entity ID passed to `refreshAction.refresh(cardType:entityID:)`.
    /// Defaults to `entityID`, but overview cards keyed by
    /// `CardConfiguration.globalEntityID` (e.g. 时间与会场/出演) need their
    /// refresh scoped to the current performance instead.
    let refreshEntityID: String
    let userDataStore: UserDataStore
    let eventID: String?
    /// Segments this card would submit for translation. `nil` hides the
    /// "翻译此卡片" menu item entirely.
    let translationSegments: (() -> [TranslationRequestItem])?
    /// When true, `title` is a `Localizable.xcstrings` key (app copy) rather
    /// than already-official verbatim text, so the menu label and hide
    /// notification localize it instead of showing the raw key/official text
    /// mismatch.
    let titleIsLocalizationKey: Bool
    @Environment(\.detailCardRefreshAction) private var refreshAction
    @Environment(\.detailCardHideNotification) private var hideNotification
    @Environment(\.detailCardTranslationUnsupported) private var translationUnsupported
    @AppStorage("translation.targetLanguage") private var translationTargetRaw = TranslationTargetLanguage.followApp.rawValue
    private var translationStore: TranslationStore { TranslationStore.shared }

    public init(
        title: String,
        cardType: CardType,
        entityID: String,
        refreshEntityID: String? = nil,
        userDataStore: UserDataStore,
        eventID: String? = nil,
        translationSegments: (() -> [TranslationRequestItem])? = nil,
        titleIsLocalizationKey: Bool = false
    ) {
        self.title = title
        self.cardType = cardType
        self.entityID = entityID
        self.refreshEntityID = refreshEntityID ?? entityID
        self.userDataStore = userDataStore
        self.eventID = eventID
        self.translationSegments = translationSegments
        self.titleIsLocalizationKey = titleIsLocalizationKey
    }

    private var displayTitle: String {
        titleIsLocalizationKey ? String(localized: String.LocalizationValue(title), bundle: .kit) : title
    }

    private var translationTarget: TranslationTargetLanguage {
        TranslationTargetLanguage(rawValue: translationTargetRaw) ?? .followApp
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
                    Task { await refreshAction.refresh(cardType, refreshEntityID) }
                } label: {
                    Label {
                        Text(refreshAction.isRefreshing ? "正在刷新…" : "刷新此卡片", bundle: .kit)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(refreshAction.isRefreshing)
            }

            Toggle(isOn: Binding(
                get: { config.isPinned },
                set: { newValue in
                    var updated = config
                    updated.entityID = entityID
                    updated.eventID = eventID
                    updated.isPinned = newValue
                    userDataStore.setConfiguration(updated)
                }
            )) {
                Label { Text("置顶", bundle: .kit) } icon: { Image(systemName: "pin") }
            }

            Picker(selection: Binding(
                get: { config.density },
                set: { newValue in
                    var updated = config
                    updated.entityID = entityID
                    updated.eventID = eventID
                    updated.density = newValue
                    userDataStore.setConfiguration(updated)
                }
            )) {
                Text("精简", bundle: .kit).tag(CardDensity.compact)
                Text("完整", bundle: .kit).tag(CardDensity.detailed)
            } label: {
                Text("显示密度", bundle: .kit)
            }

            if let translationSegments, let eventID,
               translationTarget != .off, !translationTarget.resolvesToJapanese {
                let cardKey = TranslationStore.cardKey(eventID: eventID, cardType: cardType, entityID: entityID)
                let pageOn = translationStore.translatedEventIDs.contains(eventID)
                if !pageOn {
                    let isShowing = translationStore.translatedCardKeys.contains(cardKey)
                    Button {
                        if isShowing {
                            translationStore.toggleCard(cardKey: cardKey)
                            translationStore.clearFailure(.card(eventID: eventID, cardKey: cardKey))
                        } else {
                            let segments = translationSegments()
                            Task {
                                // Same availability check as LiveDetailView's
                                // page-level `startPageTranslation()`: never
                                // toggle the card on for an unsupported
                                // language pair.
                                let availability = await translationStore.availability(target: translationTarget)
                                switch availability {
                                case .unsupported:
                                    translationUnsupported?.notify(String(localized: "当前语言对不受支持", bundle: .kit))
                                case .installed, .needsDownload:
                                    translationStore.toggleCard(cardKey: cardKey)
                                    translationStore.request(items: segments, target: translationTarget, eventID: eventID, scope: .card(eventID: eventID, cardKey: cardKey))
                                }
                            }
                        }
                    } label: {
                        Label(isShowing ? String(localized: "显示原文", bundle: .kit) : String(localized: "翻译此卡片", bundle: .kit), systemImage: "translate")
                    }
                }
            }

            Divider()

            Button {
                var updated = config
                updated.entityID = entityID
                updated.eventID = eventID
                updated.isHidden = true
                userDataStore.setConfiguration(updated)
                hideNotification?.notify(cardType, entityID, displayTitle)
            } label: {
                Label { Text("隐藏", bundle: .kit) } icon: { Image(systemName: "eye.slash") }
            }
        } label: {
            Label {
                Text("\(displayTitle) 选项", bundle: .kit)
            } icon: {
                Image(systemName: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
    }
}

/// Footer shown on tabs where some cards are hidden: lets the user restore
/// them in bulk without hunting for the individual card's menu.
public struct HiddenCardsFooter: View {
    let count: Int
    let action: () -> Void

    public init(count: Int, action: @escaping () -> Void) {
        self.count = count
        self.action = action
    }

    public var body: some View {
        if count > 0 {
            ViewThatFits {
                HStack {
                    text
                    Spacer()
                    button
                }
                VStack(alignment: .leading, spacing: 4) {
                    text
                    button
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var text: some View {
        Text("已隐藏 \(count) 张卡片", bundle: .kit)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var button: some View {
        Button(action: action) {
            Text("恢复显示", bundle: .kit)
        }
        .font(.footnote)
    }
}

/// Transient row shown right after a card is hidden from its menu, letting
/// the user immediately undo the action. Dismisses itself after ~5 seconds.
public struct UndoHiddenCardRow: View {
    let id: String
    let title: String
    let onUndo: () -> Void
    let onExpire: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// `id` identifies the card that was just hidden (e.g. `"\(cardType)|\(entityID)"`).
    /// Using it as the `.task(id:)` key restarts the 5-second auto-expire
    /// timer whenever a *different* card is hidden while this row is still
    /// showing, instead of letting the earlier timer fire early for the new card.
    public init(id: String, title: String, onUndo: @escaping () -> Void, onExpire: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.onUndo = onUndo
        self.onExpire = onExpire
    }

    public var body: some View {
        HStack {
            Text("已隐藏「\(title)」", bundle: .kit)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onUndo) {
                Text("撤销", bundle: .kit)
            }
            .font(.footnote)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .task(id: id) {
            guard !voiceOverEnabled else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            onExpire()
        }
        .onAppear {
            AccessibilityNotification.Announcement(String(localized: "已隐藏「\(title)」", bundle: .kit)).post()
        }
    }
}

/// Renders one field of official text, swapped for its cached on-device
/// translation when the enclosing page or card has translation toggled on.
/// Always `Text(verbatim:)` — never routed through localized string tables.
public struct OfficialText: View {
    let text: String
    let cardKey: String
    let eventID: String
    @AppStorage("translation.targetLanguage") private var translationTargetRaw = TranslationTargetLanguage.followApp.rawValue
    private var store: TranslationStore { TranslationStore.shared }

    public init(_ text: String, cardKey: String, eventID: String) {
        self.text = text
        self.cardKey = cardKey
        self.eventID = eventID
    }

    private var target: TranslationTargetLanguage {
        TranslationTargetLanguage(rawValue: translationTargetRaw) ?? .followApp
    }

    public var body: some View {
        let showsTranslation = store.isShowingTranslation(eventID: eventID, cardKey: cardKey)
        Text(verbatim: showsTranslation ? (store.cached(text, target: target) ?? text) : text)
            .contentTransition(.opacity)
            .motionAnimation(showsTranslation)
    }
}

/// Joins several official text values into a single wrapping line, swapping
/// each value for its cached translation independently (so a partial cache
/// hit still shows translated text where available).
public struct OfficialTextList: View {
    let values: [String]
    let separator: String
    let cardKey: String
    let eventID: String
    @AppStorage("translation.targetLanguage") private var translationTargetRaw = TranslationTargetLanguage.followApp.rawValue
    private var store: TranslationStore { TranslationStore.shared }

    public init(_ values: [String], separator: String, cardKey: String, eventID: String) {
        self.values = values
        self.separator = separator
        self.cardKey = cardKey
        self.eventID = eventID
    }

    private var target: TranslationTargetLanguage {
        TranslationTargetLanguage(rawValue: translationTargetRaw) ?? .followApp
    }

    public var body: some View {
        let showsTranslation = store.isShowingTranslation(eventID: eventID, cardKey: cardKey)
        let joined = values.map { showsTranslation ? (store.cached($0, target: target) ?? $0) : $0 }.joined(separator: separator)
        Text(verbatim: joined)
            .contentTransition(.opacity)
            .motionAnimation(showsTranslation)
    }
}

/// Footer shown under a page/card whose text is currently displayed
/// translated, attributing the translation to Apple's on-device framework.
public struct TranslationAttributionFooter: View {
    let isPartial: Bool

    public init(isPartial: Bool = false) {
        self.isPartial = isPartial
    }

    public var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple 本机翻译，非官方资料，请以官网为准", bundle: .kit)
                if isPartial {
                    Text("部分内容仍显示原文", bundle: .kit)
                }
            }
        } icon: {
            Image(systemName: "character.bubble")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Inline error state for a failed translation batch, with a retry action.
/// `.unsupported` availability hides the retry button since retrying cannot
/// help.
public struct TranslationFailureRow: View {
    let message: String
    let isUnsupported: Bool
    let onRetry: () -> Void

    public init(message: String, isUnsupported: Bool = false, onRetry: @escaping () -> Void) {
        self.message = message
        self.isUnsupported = isUnsupported
        self.onRetry = onRetry
    }

    public var body: some View {
        if isUnsupported {
            label
        } else {
            ViewThatFits {
                HStack {
                    label
                    Spacer()
                    retryButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    label
                    retryButton
                }
            }
        }
    }

    private var label: some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.caption)
        .foregroundStyle(.statusCritical)
    }

    private var retryButton: some View {
        Button {
            onRetry()
        } label: {
            Text("重试", bundle: .kit)
        }
        .font(.caption)
        .buttonStyle(.bordered)
    }
}

/// Card-scoped translation state for the bottom of a `DetailCard`: progress,
/// failure + retry of this card's own request, or a short attribution.
/// Renders nothing when the card is not translated.
public struct DetailCardTranslationStatus: View {
    let eventID: String
    let cardType: CardType
    let entityID: String
    let segments: () -> [TranslationRequestItem]
    @AppStorage("translation.targetLanguage") private var translationTargetRaw = TranslationTargetLanguage.followApp.rawValue
    private var store: TranslationStore { TranslationStore.shared }

    public init(eventID: String, cardType: CardType, entityID: String, segments: @escaping () -> [TranslationRequestItem]) {
        self.eventID = eventID
        self.cardType = cardType
        self.entityID = entityID
        self.segments = segments
    }

    private var target: TranslationTargetLanguage {
        TranslationTargetLanguage(rawValue: translationTargetRaw) ?? .followApp
    }

    private var cardKey: String {
        TranslationStore.cardKey(eventID: eventID, cardType: cardType, entityID: entityID)
    }

    private var scope: TranslationScope {
        .card(eventID: eventID, cardKey: cardKey)
    }

    public var body: some View {
        let pageOn = store.translatedEventIDs.contains(eventID)
        let isShowingTranslation = pageOn || store.translatedCardKeys.contains(cardKey)
        if isShowingTranslation, store.isTranslating(scope) {
            Label {
                Text("正在翻译", bundle: .kit)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let failure = store.failure(for: scope) {
            TranslationFailureRow(message: failure.message) { store.retry(scope) }
        } else if !pageOn, store.translatedCardKeys.contains(cardKey) {
            TranslationAttributionFooter(isPartial: store.hasUntranslated(segments(), target: target))
        }
    }
}
