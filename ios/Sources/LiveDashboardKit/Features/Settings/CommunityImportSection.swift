import SwiftUI
import UniformTypeIdentifiers
import LiveIngestionCore

struct CommunityImportSection: View {
    let externalStore: ExternalDataStore
    let bundles: [LiveEventBundle]
    let userDataStore: UserDataStore
    @State private var importsSnapshot = false
    @State private var importsBackup = false
    @State private var preview: BackupImportPreview?
    @State private var acceptConflicts = false
    @State private var keyword = ""
    @State private var candidates: [EventernoteEventSummary] = []
    @State private var message: String?

    var body: some View {
        Section {
            TextField("出演者或演出", text: $keyword)
            Button("搜索 Eventernote") { Task { await searchEventernote() } }
            ForEach(candidates, id: \.id) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.name)
                    Text(verbatim: [item.date, item.startTime, item.place?.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("导入社区快照") { importsSnapshot = true }
            Button("导入参加记录备份") { importsBackup = true }
            if let preview {
                Text("已匹配 \(preview.matched.count) 条，未匹配 \(preview.unmatchedSourceIDs.count) 条，冲突 \(preview.conflicts.count) 条")
                    .font(.footnote)
                if !preview.conflicts.isEmpty {
                    Toggle("同时写入冲突记录", isOn: $acceptConflicts)
                }
                Button("写入个人参加记录") { apply(preview) }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("社区资料")
        } footer: {
            Text("快照只补充对照和歌单。参加记录备份不会删除官网活动，也不能当作账号同步。")
        }
        .fileImporter(isPresented: $importsSnapshot, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            Task { await importSnapshot(result) }
        }
        .fileImporter(isPresented: $importsBackup, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            Task { await importBackup(result) }
        }
    }

    private func searchEventernote() async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        do {
            let client = EventernoteClient(transport: URLSession.shared)
            let page = try await client.listEvents(EventernoteEventQuery(keyword: query))
            candidates = page.matched
            message = page.reachedBudget ? "搜索已达到请求上限。" : "找到 \(page.matched.count) 条候选，尚未写入官网资料。"
        } catch {
            candidates = []
            message = "Eventernote 搜索没有完成。"
        }
    }

    private func importSnapshot(_ result: Result<[URL], Error>) async {
        do {
            let files = try read(try result.get())
            let report = try await CommunityIngestor.ingest(files: files, revision: UpstreamSourceRegistry.llernoteRevision, locals: localSessions(), into: externalStore)
            switch report.admission {
            case .activate:
                message = "已接入 \(report.performanceCount) 场社区记录，建立 \(report.referenceCount) 条对照。"
            case .keepPrevious(let reason):
                message = "快照未替换当前资料（\(reason.rawValue)）。"
            }
        } catch {
            message = "社区快照没有导入。"
        }
    }

    private func importBackup(_ result: Result<[URL], Error>) async {
        do {
            let files = try read(try result.get())
            guard let data = files.values.first else { message = "没有读到备份。"; return }
            let references = try await externalStore.references()
            preview = try LLerNoteBackupImporter.preview(data: data) { sourceID in
                guard let localID = references.first(where: { $0.external.namespace == .llfans && $0.external.rawID == sourceID && $0.relation != .rejected })?.local.id,
                      let bundle = bundles.first(where: { $0.performances.contains { $0.id == localID } }) else { return nil }
                return BackupPerformanceLocator(eventID: bundle.event.id, performanceID: localID, explicitParticipation: explicit(bundle.event.id, localID))
            }
            acceptConflicts = false
            message = nil
        } catch BackupImportError.unsupportedVersion {
            preview = nil
            message = "不支持这个备份版本，没有写入。"
        } catch {
            preview = nil
            message = "备份没有导入。"
        }
    }

    private func apply(_ preview: BackupImportPreview) {
        let accepted = acceptConflicts ? Set(preview.conflicts.map(\.sourcePerformanceID)) : []
        for change in LLerNoteBackupImporter.changes(from: preview, acceptedConflictIDs: accepted) {
            let known = bundles.first { $0.event.id == change.eventID }?.performances.map(\.id) ?? [change.performanceID]
            userDataStore.setParticipation(eventID: change.eventID, performanceID: change.performanceID, participate: change.participate, knownPerformanceIDs: known)
        }
        message = "个人参加记录已写入。官网活动没有删除。"
        self.preview = nil
    }

    private func explicit(_ eventID: String, _ performanceID: String) -> Bool? {
        guard let state = userDataStore.eventStates[eventID] else { return nil }
        if state.participatingPerformanceIDs.isEmpty { return state.planningToAttend ? true : nil }
        return state.participatingPerformanceIDs.contains(performanceID)
    }

    private func localSessions() -> [LocalSession] {
        bundles.flatMap { bundle in
            bundle.performances.map { performance in
                LocalSession(
                    performanceID: performance.id, eventID: bundle.event.id, localDate: performance.localDate,
                    startTime: clock(performance.startAt, zone: bundle.event.resolvedTimeZone), dayLabel: performance.dayLabel,
                    venueName: performance.venueName, title: bundle.event.officialTitle, officialURL: bundle.event.primarySourceURL
                )
            }
        }
    }

    private func clock(_ date: Date?, zone: TimeZone) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func read(_ urls: [URL]) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            files[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return files
    }
}
