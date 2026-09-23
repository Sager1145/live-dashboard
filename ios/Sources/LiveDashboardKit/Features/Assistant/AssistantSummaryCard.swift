import SwiftUI

/// Overview singleton card: the assistant's organised reading of the whole
/// event, scoped down to the selected performance where relevant. Never a
/// substitute for the official page — every state routes back to it.
public struct AssistantSummaryCard: View {
    let bundle: LiveEventBundle
    let selectedPerformanceID: String
    let coordinator: AssistantCoordinator
    let userDataStore: UserDataStore
    @State private var showsSignInHint = false

    public init(bundle: LiveEventBundle, selectedPerformanceID: String, coordinator: AssistantCoordinator, userDataStore: UserDataStore) {
        self.bundle = bundle
        self.selectedPerformanceID = selectedPerformanceID
        self.coordinator = coordinator
        self.userDataStore = userDataStore
    }

    private var isGenerating: Bool { coordinator.generatingEventIDs.contains(bundle.event.id) }
    private var summary: AssistantEventSummary? { coordinator.summary(for: bundle.event.id) }

    public var body: some View {
        DetailCard(title: "AI 整理摘要", cardType: .assistantSummary, entityID: CardConfiguration.globalEntityID, userDataStore: userDataStore, eventID: bundle.event.id) {
            content
        }
        .accessibilityIdentifier("assistantSummaryCard")
    }

    @ViewBuilder
    private var content: some View {
        if !coordinator.account.isSignedIn {
            notSignedIn
        } else if isGenerating {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在整理官网内容…").foregroundStyle(.secondary)
            }
        } else if let summary {
            summaryContent(summary)
        } else {
            signedInNoSummary
        }
    }

    @ViewBuilder
    private var notSignedIn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("登录 ChatGPT 账号或填入 API Key 后，可自动整理并突出本公演重点。")
                .foregroundStyle(.secondary)
            Button("如何开启") { showsSignInHint.toggle() }
            if showsSignInHint {
                Text("设置 → ChatGPT 助手").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var signedInNoSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("用 AI 整理本公演", systemImage: "sparkles") {
                Task { await coordinator.generate(for: bundle, force: false) }
            }
            if let eventError = coordinator.error(for: bundle.event.id) {
                Text(eventError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func summaryContent(_ summary: AssistantEventSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(summary)

            AssistantRichTextView(text: summary.overview)

            if let performanceSummary = summary.performanceSummary(for: selectedPerformanceID) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本场（\(performanceSummary.dayLabel)）").font(.headline)
                    AssistantRichTextView(text: performanceSummary.summary)
                    ForEach(Array(performanceSummary.highlights.enumerated()), id: \.offset) { _, highlight in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                            AssistantRichTextView(text: highlight)
                        }
                    }
                }
            }

            keyPointsSection(summary)

            if !summary.warnings.isEmpty {
                DisclosureGroup("需要核对（\(summary.warnings.count)）") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.warnings, id: \.self) { warning in
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }

            actionsRow(summary)
        }
    }

    @ViewBuilder
    private func header(_ summary: AssistantEventSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("由 \(summary.model) 生成 · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened)) · 非官方资料，请以官网为准")
                .font(.caption)
                .foregroundStyle(.secondary)
            if coordinator.isStale(bundle) {
                Text("官网内容已更新，摘要可能过期")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func keyPointsSection(_ summary: AssistantEventSummary) -> some View {
        let points = summary.keyPoints(for: selectedPerformanceID)
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("重点").font(.headline)
                ForEach(points) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: AssistantCategoryLabel(point.category).systemImage)
                            .foregroundStyle(importanceColor(point.importance))
                        AssistantRichTextView(text: point.text)
                    }
                    .padding(point.importance == .high ? 6 : 0)
                    .background(
                        point.importance == .high
                            ? AnyShapeStyle(.red.opacity(0.08))
                            : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func actionsRow(_ summary: AssistantEventSummary) -> some View {
        HStack {
            Button("重新整理", systemImage: "sparkles") {
                Task { await coordinator.generate(for: bundle, force: true) }
            }
            .disabled(isGenerating)
            if let url = URL(string: bundle.event.primarySourceURL) {
                Link("查看官方页面", destination: url)
            }
        }
        .font(.footnote)
    }
}
