import SwiftUI
import StudioCore
import AppKit

struct LibraryScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    var state: AppState? = nil
    var onContinue: (ProjectDraft) -> Void = { _ in }
    @State private var tab = 0
    @State private var search = ""
    @State private var mode: CreationMode?
    @State private var status: JobState?
    @State private var favoriteOnly = false
    @State private var recentDays = 0
    @State private var archivedOnly = false
    @State private var jobs: [StudioCore.LibraryItem] = []
    @State private var projects: [ProjectDraft] = []
    @State private var removed: [StoredJob] = []
    @State private var selectedJobID: String?
    @State private var selectedProjectID: String?
    @State private var nextBeforeID: String?
    @State private var name = ""
    @State private var note = ""
    @State private var feedback: String?
    @State private var result: ResultScreenController?
    @State private var loading = false
    @State private var audioReady = false
    @State private var audioChecking = false
    @State private var selectedAudioAsset: StoredAsset?

    private var selected: StudioCore.LibraryItem? { jobs.first { $0.job.id == selectedJobID } }
    private var selectedProject: ProjectDraft? { projects.first { $0.id == selectedProjectID } }
    private var accent: Color { colorScheme == .dark ? Color(red: 0.50, green: 0.79, blue: 0.69) : StudioPalette.green }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("作品库").font(StudioTypography.serif(29))
                    Text("生成记录、项目与可恢复回收站").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { Task { await reload() } }.buttonStyle(.borderless)
            }
            Picker("作品视图", selection: $tab) {
                Text("全部生成").tag(0); Text("项目").tag(1); Text("回收站").tag(2)
            }.pickerStyle(.segmented).frame(width: 310)
            if tab == 0 {
                HStack(spacing: 8) {
                    TextField("搜索作品、项目或文案", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("library-search")
                    Picker("类型", selection: $mode) {
                        Text("全部类型").tag(nil as CreationMode?)
                        ForEach(CreationMode.allCases) { Text($0.title).tag(Optional($0)) }
                    }.frame(width: 132)
                    Picker("状态", selection: $status) {
                        Text("全部状态").tag(nil as JobState?)
                        ForEach([JobState.queued, .preparing, .requesting, .downloading, .validating, .success, .failed, .cancelled, .interrupted], id: \.self) {
                            Text(stage($0)).tag(Optional($0))
                        }
                    }.frame(width: 130)
                    Picker("时间", selection: $recentDays) {
                        Text("全部时间").tag(0); Text("近 7 天").tag(7); Text("近 30 天").tag(30)
                    }.frame(width: 116)
                    Toggle("收藏", isOn: $favoriteOnly).toggleStyle(.checkbox)
                }.font(.system(size: 12))
            } else if tab == 1 {
                Toggle("显示已归档项目", isOn: $archivedOnly).toggleStyle(.checkbox).font(.caption)
            }
            HStack(alignment: .top, spacing: 12) {
                listPane.frame(maxWidth: .infinity)
                detailPane.frame(maxWidth: .infinity)
            }.frame(maxHeight: .infinity)
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(20).background(StudioPalette.background).navigationTitle("作品库")
        .task { await reload() }
        .onChange(of: tab) { _, _ in Task { await reload() } }
        .onChange(of: search) { _, _ in Task { await reload() } }
        .onChange(of: mode) { _, _ in Task { await reload() } }
        .onChange(of: status) { _, _ in Task { await reload() } }
        .onChange(of: favoriteOnly) { _, _ in Task { await reload() } }
        .onChange(of: recentDays) { _, _ in Task { await reload() } }
        .onChange(of: archivedOnly) { _, _ in Task { await reload() } }
        .task(id: selectedJobID) { await inspectSelectedAudio() }
        .sheet(isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            if let result { ResultScreen(controller: result).frame(minWidth: 980, minHeight: 650) }
        }
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                if tab == 0 {
                    ForEach(jobs, id: \.job.id) { item in
                        Button {
                            selectedJobID = item.job.id; name = item.metadata.name; note = item.metadata.note
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.metadata.favorite ? "star.fill" : "waveform")
                                    .foregroundStyle(accent).frame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.metadata.name.isEmpty ? item.project.fields.name : item.metadata.name)
                                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text("\(item.project.fields.mode.title) · \(stage(item.job.state)) · 版本 \(item.job.candidateIndex + 1)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedJobID == item.job.id ? StudioPalette.green.opacity(0.13) : StudioPalette.background,
                                            in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityIdentifier("library-job-\(item.job.id)")
                    }
                    if nextBeforeID != nil { Button(loading ? "载入中…" : "显示更多") { Task { await loadMore() } }.disabled(loading).padding(12) }
                } else if tab == 1 {
                    ForEach(projects) { project in
                        Button { selectedProjectID = project.id } label: {
                            HStack { Image(systemName: "doc.text").foregroundStyle(accent)
                                VStack(alignment: .leading) { Text(project.fields.name).fontWeight(.medium)
                                    Text("\(project.fields.mode.title) · 修订 \(project.revision)").font(.caption).foregroundStyle(.secondary) }
                                Spacer() }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedProjectID == project.id ? StudioPalette.green.opacity(0.13) : StudioPalette.background,
                                                in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                } else {
                    ForEach(removed) { job in
                        Button { selectedJobID = job.id } label: {
                            HStack { Image(systemName: "trash"); Text("版本 \(job.candidateIndex + 1) · \(stage(job.state))"); Spacer() }
                                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedJobID == job.id ? StudioPalette.green.opacity(0.13) : StudioPalette.background,
                                            in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(9)
        }.background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.stroke))
    }

    @ViewBuilder private var detailPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tab == 0, let item = selected {
                Text(item.project.fields.name).font(StudioTypography.serif(22)).lineLimit(1)
                HStack { Label(stage(item.job.state), systemImage: item.job.state == .success ? "checkmark.circle" : "clock")
                    Spacer(); Text("Seed \(item.job.seed)") }.font(.caption).foregroundStyle(.secondary)
                TextField("版本名称", text: $name).textFieldStyle(.roundedBorder)
                TextField("备注", text: $note, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder)
                HStack {
                    Button("保存名称与备注") { Task { await updateMetadata(item) } }
                    Button(item.metadata.favorite ? "取消收藏" : "收藏", systemImage: item.metadata.favorite ? "star.slash" : "star") {
                        Task { await favorite(item) }
                    }
                }.buttonStyle(.borderless)
                Divider()
                HStack {
                    Button("试听 / A-B") { Task { await showResult(item.job.batchID) } }.disabled(!audioReady)
                    Button("下载") { Task { await download(item.job.id) } }.disabled(!audioReady)
                    Button("Finder") { Task { await reveal(item.job.id) } }.disabled(!audioReady)
                }.buttonStyle(.bordered)
                if item.job.state == .success && !audioReady {
                    HStack {
                        Text(audioChecking ? "正在核验生成音频…" : "音频文件缺失、已更换或无法解码。")
                            .font(.caption).foregroundStyle(.orange)
                        if let selectedAudioAsset {
                            Button("重新授权目录") { Task {
                                if await state?.outputFolders.reauthorize(selectedAudioAsset.directoryID) == true { await inspectSelectedAudio() }
                            } }.font(.caption)
                        }
                    }
                }
                HStack {
                    Button("复制 Prompt") { Task { await copyPrompt(item.job.batchID) } }
                    Button("继续创作") { onContinue(item.project) }
                    Button("设为最终版本") { Task { await makeFinal(item) } }.disabled(item.job.state != .success)
                }.buttonStyle(.bordered)
                HStack {
                    Button("导出报告") { Task { await exportReport(item) } }
                    if item.job.state == .queued { Button("取消排队") { Task { await cancel(item.job.id) } } }
                    if item.job.state.isTerminal {
                        Menu("移入回收站") {
                            Button("仅移除记录") { Task { await trash(item.job.id, scope: .recordOnly) } }
                            Button("记录与生成文件一起移除") { Task { await trash(item.job.id, scope: .generatedFiles) } }
                        }
                    }
                }.buttonStyle(.borderless)
                if item.job.resultUncertain { Text("云端结果不确定；请勿重试付费请求。") .foregroundStyle(.orange).font(.caption) }
                if let message = item.job.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Divider()
                HStack {
                    Text("创作快照").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(item.project.fields.mode.title) · \(item.project.fields.params.format.uppercased()) · \(item.project.fields.params.sampleRate / 1000) kHz")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(item.project.fields.prompt)
                        .font(StudioTypography.serif(14)).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxHeight: .infinity)
                .background(StudioPalette.background, in: RoundedRectangle(cornerRadius: 9))
            } else if tab == 1, let project = selectedProject {
                Text(project.fields.name).font(StudioTypography.serif(23))
                Text("\(project.fields.mode.title) · \(project.fields.prompt.unicodeScalars.count) 字 · 修订 \(project.revision)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("继续创作") { onContinue(project) }.buttonStyle(.borderedProminent)
                Button(archivedOnly ? "恢复项目" : "归档项目") { Task { await archive(project, archived: !archivedOnly) } }.buttonStyle(.borderless)
                Spacer()
            } else if tab == 2, let id = selectedJobID, removed.contains(where: { $0.id == id }) {
                Text("可恢复的生成记录").font(StudioTypography.serif(23))
                Text("恢复时不会覆盖已有同名文件；发生冲突会另存安全名称。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复记录与文件") { Task { await restore(id) } }.buttonStyle(.borderedProminent)
                Spacer()
            } else {
                ContentUnavailableView(tab == 0 ? "选择一个生成版本" : tab == 1 ? "选择一个项目" : "选择一条回收记录",
                                       systemImage: tab == 2 ? "trash" : "square.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(17).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioPalette.stroke))
    }

    private func stage(_ value: JobState) -> String {
        switch value {
        case .queued: "排队中"; case .preparing: "准备中"; case .requesting: "请求中"
        case .downloading: "下载中"; case .validating: "校验中"; case .success: "已完成"
        case .failed: "失败"; case .cancelled: "已取消"; case .interrupted: "已中断"
        }
    }
    private func reload() async {
        guard let state else { return }
        loading = true; defer { loading = false }
        do {
            switch tab {
            case 0:
                let page = try await state.store.libraryPage(.init(search: search, mode: mode, state: status, favoriteOnly: favoriteOnly,
                    since: recentDays == 0 ? nil : Date().addingTimeInterval(-Double(recentDays) * 86400)))
                jobs = page.items; nextBeforeID = page.nextBeforeID
                if !jobs.contains(where: { $0.job.id == selectedJobID }) {
                    selectedJobID = jobs.first(where: { $0.job.state == .success })?.job.id ?? jobs.first?.job.id
                }
                if let selected { name = selected.metadata.name; note = selected.metadata.note }
                await inspectSelectedAudio()
            case 1:
                let all = try await state.store.listProjects()
                var active: [ProjectDraft] = []
                for project in all where (try await state.store.projectArchived(id: project.id)) == archivedOnly { active.append(project) }
                projects = active
                if !projects.contains(where: { $0.id == selectedProjectID }) { selectedProjectID = projects.first?.id }
            default:
                removed = try await state.store.listRemovedJobs()
                if !removed.contains(where: { $0.id == selectedJobID }) { selectedJobID = removed.first?.id }
            }
            feedback = nil
        } catch { feedback = "作品库读取失败：\(error.localizedDescription)" }
    }
    private func loadMore() async {
        guard let state, let nextBeforeID, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = try await state.store.libraryPage(.init(search: search, mode: mode, state: status,
                                                               favoriteOnly: favoriteOnly,
                                                               since: recentDays == 0 ? nil : Date().addingTimeInterval(-Double(recentDays) * 86400),
                                                               beforeID: nextBeforeID))
            jobs += page.items; self.nextBeforeID = page.nextBeforeID
        } catch { feedback = "载入更多记录失败。" }
    }
    private func updateMetadata(_ item: StudioCore.LibraryItem) async {
        guard let state else { return }
        do { try await state.store.updateJobMetadata(id: item.job.id, name: name, favorite: item.metadata.favorite, note: note); await reload() }
        catch { feedback = "保存版本信息失败。" }
    }
    private func favorite(_ item: StudioCore.LibraryItem) async {
        guard let state else { return }
        do { try await state.store.updateJobMetadata(id: item.job.id, name: name, favorite: !item.metadata.favorite, note: note); await reload() }
        catch { feedback = "收藏操作失败。" }
    }
    private func makeFinal(_ item: StudioCore.LibraryItem) async {
        guard let state else { return }
        do { try await state.store.setFinalJob(batchID: item.job.batchID, jobID: item.job.id); feedback = "已设为最终版本。" }
        catch { feedback = "仅成功生成的同批次版本可设为最终版本。" }
    }
    private func archive(_ project: ProjectDraft, archived: Bool) async {
        guard let state else { return }
        do { try await state.store.setProjectArchived(id: project.id, archived: archived); await reload() }
        catch { feedback = "归档失败。" }
    }
    private func cancel(_ id: String) async {
        guard let state else { return }
        do { _ = try await state.generation.cancelQueued(id); await reload() }
        catch { feedback = "任务已经开始，无法取消云端请求。" }
    }
    private func trash(_ id: String, scope: AssetRemovalScope) async {
        guard let state else { return }
        do { try await state.assets.trash(job: id, scope: scope); await reload() }
        catch { feedback = "移入回收站失败，请检查目录授权和文件状态。" }
    }
    private func restore(_ id: String) async {
        guard let state else { return }
        do { try await state.assets.restore(job: id); await reload() }
        catch { feedback = "恢复失败，请重新授权原输出文件夹。" }
    }
    private func audioAsset(_ id: String) async throws -> StoredAsset {
        guard let state, let asset = try await state.store.listAssets(jobID: id).first(where: { $0.kind == "audio" }) else {
            throw StudioStoreError.missing
        }
        return asset
    }
    private func inspectSelectedAudio() async {
        audioReady = false; selectedAudioAsset = nil
        guard let state, let selected, selected.job.state == .success else { return }
        audioChecking = true; defer { audioChecking = false }
        do {
            let asset = try await audioAsset(selected.job.id)
            _ = try await state.assets.decodeRegisteredAudio(asset.id)
            guard selectedJobID == selected.job.id else { return }
            selectedAudioAsset = asset
            audioReady = true
        } catch {
            if selectedJobID == selected.job.id {
                selectedAudioAsset = try? await audioAsset(selected.job.id)
                audioReady = false
            }
        }
    }
    private func showResult(_ batchID: String) async {
        guard let state else { return }
        do {
            guard let batch = try await state.store.getBatch(id: batchID) else { throw StudioStoreError.missing }
            var candidates: [ResultCandidate] = []
            for id in batch.jobIDs {
                guard let job = try await state.store.getJob(id: id) else { continue }
                let assetID = try await state.store.listAssets(jobID: id).first(where: { $0.kind == "audio" })?.id
                candidates.append(ResultCandidate(id: id, number: job.candidateIndex + 1, state: job.state, assetID: assetID))
            }
            result = ResultScreenController(candidates: candidates, assets: state.assets)
        } catch { feedback = "版本详情无法打开，请检查本地记录。" }
    }
    private func reveal(_ id: String) async {
        guard let state else { return }
        do { let asset = try await audioAsset(id); await state.outputFolders.revealAsset(asset.id, assets: state.assets) }
        catch { feedback = "音频文件尚不可用。" }
    }
    private func download(_ id: String) async {
        guard let state else { return }
        do {
            let asset = try await audioAsset(id)
            let bytes = try await state.assets.readRegisteredAudio(asset.id)
            let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: asset.relativePath).lastPathComponent
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try bytes.write(to: url, options: .atomic)
            feedback = "音频已导出到所选位置。"
        } catch { feedback = "音频导出失败，请检查文件和输出权限。" }
    }
    private func copyPrompt(_ batchID: String) async {
        guard let state, let batch = try? await state.store.getBatch(id: batchID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(batch.submission.compiledPrompt, forType: .string)
    }
    private func exportReport(_ item: StudioCore.LibraryItem) async {
        guard let state else { return }
        do {
            guard let batch = try await state.store.getBatch(id: item.job.batchID) else { throw StudioStoreError.missing }
            let report = ["model": "qwen-audio-3.1-tts-next", "project": item.project.fields.name,
                          "job_id": item.job.id, "state": item.job.state.rawValue,
                          "prompt": batch.submission.compiledPrompt, "note": note]
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let panel = NSSavePanel(); panel.nameFieldStringValue = "qwen-result-\(item.job.candidateIndex + 1).json"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try bytes.write(to: url, options: .atomic)
            feedback = "报告已导出。"
        } catch { feedback = "导出报告失败。" }
    }
}
