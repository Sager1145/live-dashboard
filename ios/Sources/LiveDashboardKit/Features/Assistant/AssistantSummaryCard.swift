import SwiftUI

/// Overview singleton card: the assistant's organised reading of the whole
/// event, scoped down to the selected performance where relevant. Never a
/// substitute for the official page — every state routes back to it.
public struct AssistantSummaryCard: View {
    let bundle: LiveEventBundle
    let selectedPerformanceID: String
    let coordinator: AssistantCoordinator
    let userDataStore: UserDataStore
    @State private var showsAllPoints = false
    @State private var showsDeleteConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(bundle: LiveEventBundle, selectedPerformanceID: String, coordinator: AssistantCoordinator, userDataStore: UserDataStore) {
        self.bundle = bundle
        self.selectedPerformanceID = selectedPerformanceID
        self.coordinator = coordinator
        self.userDataStore = userDataStore
    }

    /// The single state machine every render derives from: which UI a given
    /// combination of (signed in?, generating?, cached summary, last error)
    /// should show.
    enum CardPhase {
        case notSignedIn
        case empty
        case generating(previous: AssistantEventSummary?)
        case ready(AssistantEventSummary)
        case failed(previous: AssistantEventSummary?, message: String)
    }

    private var isGenerating: Bool { coordinator.generatingEventIDs.contains(bundle.event.id) }
    private var summary: AssistantEventSummary? { coordinator.summary(for: bundle.event.id) }

    private var phase: CardPhase {
        if isGenerating { return .generating(previous: summary) }
        if let message = coordinator.error(for: bundle.event.id) { return .failed(previous: summary, message: message) }
        if let summary { return .ready(summary) }
        return coordinator.account.isSignedIn ? .empty : .notSignedIn
    }

    /// Cheap `Equatable` identity for `phase`, used to drive `.motionAnimation`
    /// without needing `CardPhase` itself to be `Equatable`.
    private var phaseIdentity: String {
        switch phase {
        case .notSignedIn: "notSignedIn"
        case .empty: "empty"
        case .generating: "generating"
        case .ready(let summary): "ready-\(summary.generatedAt.timeIntervalSince1970)"
        case .failed(_, let message): "failed-\(message)"
        }
    }

    public var body: some View {
        DetailCard(title: "AI 整理结果", cardType: .assistantSummary, entityID: CardConfiguration.globalEntityID, userDataStore: userDataStore, eventID: bundle.event.id) {
            content
        }
        .accessibilityIdentifier("assistantSummaryCard")
        .confirmationDialog(Text("删除本公演的 AI 整理结果？", bundle: .kit), isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button(role: .destructive) {
                Task {
                    await coordinator.removeSummary(eventID: bundle.event.id)
                    AccessibilityNotification.Announcement(String(localized: "已删除 AI 整理结果", bundle: .kit)).post()
                }
            } label: { Text("删除 AI 整理结果", bundle: .kit) }
            Button(role: .cancel) {} label: { Text("取消", bundle: .kit) }
        } message: {
            Text("仅删除此 Live 的 AI 结果，保留官网资料。之后可手动重新整理。", bundle: .kit)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let signOutMessage = coordinator.lastSignOutReason {
                Label {
                    Text(verbatim: signOutMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(Color.statusCritical)
            }

            switch phase {
            case .notSignedIn:
                notSignedInView
            case .empty:
                emptyView
            case .generating(let previous):
                generatingView(previous: previous)
            case .ready(let summary):
                summaryContent(summary)
            case .failed(let previous, let message):
                failedView(previous: previous, message: message)
            }
        }
        .motionAnimation(phaseIdentity)
        .transition(.opacity)
    }

    @ViewBuilder
    private var notSignedInView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("登录后，AI 会重新分析官网并填写公演字段。", bundle: .kit)
                .foregroundStyle(.secondary)
            NavigationLink {
                AssistantSettingsView(assistant: coordinator)
            } label: {
                Label {
                    Text("前往设置登录", bundle: .kit)
                } icon: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("整理官网资料并保存到本机，结果不是官方资料。", bundle: .kit)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await coordinator.generate(for: bundle, force: false) }
            } label: {
                Label {
                    Text("用 AI 整理本公演", bundle: .kit)
                } icon: {
                    Image(systemName: "sparkles")
                }
            }
        }
    }

    @ViewBuilder
    private func generatingView(previous: AssistantEventSummary?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label {
                    Text("正在重新整理…", bundle: .kit)
                } icon: {
                    if reduceMotion {
                        Image(systemName: "sparkles")
                    } else {
                        Image(systemName: "sparkles")
                            .symbolEffect(.pulse)
                    }
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    coordinator.cancelGeneration(for: bundle.event.id)
                } label: {
                    Text("取消", bundle: .kit)
                        .contentShape(.rect)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
            }
            generationLog
            if let previous {
                summaryContent(previous)
                    .opacity(0.5)
                    .disabled(true)
            }
        }
    }

    @ViewBuilder
    private var generationLog: some View {
        let entries = coordinator.generationLog(for: bundle.event.id)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("处理日志", bundle: .kit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: index == entries.indices.last ? "circle.dotted" : "checkmark.circle.fill")
                            .foregroundStyle(index == entries.indices.last ? Color.secondary : Color.statusPositive)
                            .accessibilityHidden(true)
                        Text(verbatim: entry)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("处理日志", bundle: .kit))
        }
    }

    @ViewBuilder
    private func failedView(previous: AssistantEventSummary?, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            errorBanner(message)
            if let previous {
                Text("上次结果", bundle: .kit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                summaryContent(previous)
                    .opacity(0.5)
            } else {
                officialLink
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(Color.statusCritical)
            Spacer()
            Button {
                Task { await coordinator.generate(for: bundle, force: true) }
            } label: {
                Text("重试", bundle: .kit)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private func summaryContent(_ summary: AssistantEventSummary) -> some View {
        let density = userDataStore.effectiveConfiguration(cardType: .assistantSummary, entityID: CardConfiguration.globalEntityID, eventID: bundle.event.id).density
        VStack(alignment: .leading, spacing: 10) {
            header(summary)

            if coordinator.isStale(bundle) {
                staleRow
            }

            if !summary.warnings.isEmpty {
                warningsSection(summary.warnings)
            }

            if let performanceSummary = summary.performanceSummary(for: selectedPerformanceID) {
                performanceSummarySection(performanceSummary)
            }

            highKeyPointsSection(summary)

            AssistantRichTextView(text: summary.overview)

            remainingKeyPointsSection(summary, compact: density == .compact)

            organizedFieldsSection(summary)
            actionsRow
        }
    }

    @ViewBuilder
    private func performanceSummarySection(_ performanceSummary: AssistantPerformanceSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本场（\(performanceSummary.dayLabel)）", bundle: .kit).font(.headline)
            AssistantRichTextView(text: performanceSummary.summary)
            let shown = Array(performanceSummary.highlights.prefix(3))
            let rest = Array(performanceSummary.highlights.dropFirst(3))
            ForEach(Array(shown.enumerated()), id: \.offset) { _, highlight in
                highlightRow(highlight)
            }
            if !rest.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(rest.enumerated()), id: \.offset) { _, highlight in
                            highlightRow(highlight)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("显示全部 \(performanceSummary.highlights.count) 条", bundle: .kit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func highlightRow(_ highlight: AssistantRichText) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•").accessibilityHidden(true)
            AssistantRichTextView(text: highlight)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var staleRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Label {
                Text("官网内容已更新，摘要可能过期", bundle: .kit)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.statusWarning)
            Spacer()
            regenerateButton(prominent: true)
        }
    }

    @ViewBuilder
    private func organizedFieldsSection(_ summary: AssistantEventSummary) -> some View {
        let fields = (summary.organizedFields ?? []).filter {
            $0.performanceIDs.isEmpty || $0.performanceIDs.contains(selectedPerformanceID)
        }
        let sections = fields.reduce(into: [String]()) { sections, field in
            if !sections.contains(field.section) { sections.append(field.section) }
        }
        if !fields.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text("独立保存的官网分析，可与官方抓取字段不同。未公布的信息保留为空缺。", bundle: .kit)
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: section).font(.subheadline.weight(.semibold))
                            ForEach(fields.filter { $0.section == section }) { field in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: field.label).font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: field.value).font(.subheadline).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("AI 整理字段", bundle: .kit).font(.headline)
            }
            .accessibilityIdentifier("assistantOrganizedFields")
        }
    }

    @ViewBuilder
    private func warningsSection(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Label {
                    Text(verbatim: warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(Color.statusWarning)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func header(_ summary: AssistantEventSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已保存到本机", bundle: .kit)
                .font(.caption).foregroundStyle(.secondary)
            Text("由 \(summary.model) 生成 · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened)) · 非官方资料，请以官网为准", bundle: .kit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func highKeyPointsSection(_ summary: AssistantEventSummary) -> some View {
        let highPoints = summary.keyPoints(for: selectedPerformanceID).filter { $0.importance == .high }
        if !highPoints.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("重点", bundle: .kit).font(.headline)
                ForEach(highPoints) { point in
                    keyPointRow(point)
                }
            }
        }
    }

    @ViewBuilder
    private func remainingKeyPointsSection(_ summary: AssistantEventSummary, compact: Bool) -> some View {
        let allPoints = summary.keyPoints(for: selectedPerformanceID)
        let hasHigh = allPoints.contains { $0.importance == .high }
        let remaining = allPoints.filter { $0.importance != .high }
        if !remaining.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !hasHigh {
                    Text("重点", bundle: .kit).font(.headline)
                }
                if compact && !showsAllPoints {
                    Button {
                        showsAllPoints = true
                    } label: {
                        Text("展开全部", bundle: .kit)
                            .contentShape(.rect)
                    }
                    .font(.caption)
                    .frame(minHeight: 44)
                } else {
                    ForEach(remaining) { point in
                        keyPointRow(point)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyPointRow(_ point: AssistantKeyPoint) -> some View {
        let category = AssistantCategoryLabel(point.category)
        HStack(alignment: .top, spacing: 8) {
            if point.importance == .high {
                Image(systemName: category.systemImage)
                    .foregroundStyle(importanceColor(point.importance))
            } else {
                Image(systemName: importanceSymbol(point.importance))
                    .foregroundStyle(importanceColor(point.importance))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if point.importance == .high {
                        Text("重要", bundle: .kit)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.importanceHighBackground, in: Capsule())
                    }
                    Text(verbatim: category.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                AssistantRichTextView(text: point.text)
                    .fontWeight(point.importance == .high ? .semibold : .regular)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(importanceText(point.importance))，\(category.text)：\(point.text.plainText)"))
    }

    @ViewBuilder
    private var actionsRow: some View {
        ViewThatFits {
            HStack {
                regenerateButton(prominent: false)
                officialLink
                if self.summary != nil {
                    deleteMenu
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                regenerateButton(prominent: false)
                officialLink
                if self.summary != nil {
                    deleteMenu
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote)
    }

    @ViewBuilder
    private var deleteMenu: some View {
        Menu {
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label { Text("删除本公演 AI 结果", bundle: .kit) } icon: { Image(systemName: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .contentShape(.rect)
        }
        .accessibilityLabel(Text("更多操作", bundle: .kit))
        .accessibilityIdentifier("deleteAssistantSummaryButton")
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func regenerateButton(prominent: Bool) -> some View {
        if prominent {
            Button {
                Task { await coordinator.generate(for: bundle, force: true) }
            } label: {
                Label {
                    Text(summary == nil ? "用 AI 整理本公演" : "重新整理", bundle: .kit)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .contentShape(.rect)
            }
            .disabled(isGenerating || !coordinator.account.isSignedIn)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(minHeight: 44)
        } else {
            Button {
                Task { await coordinator.generate(for: bundle, force: true) }
            } label: {
                Label {
                    Text(summary == nil ? "用 AI 整理本公演" : "重新整理", bundle: .kit)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .contentShape(.rect)
            }
            .disabled(isGenerating || !coordinator.account.isSignedIn)
            .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private var officialLink: some View {
        if let url = URL(string: bundle.event.primarySourceURL) {
            Link(destination: url) {
                Label {
                    Text("查看官方页面", bundle: .kit)
                } icon: {
                    Image(systemName: "arrow.up.right")
                }
            }
        }
    }
}
