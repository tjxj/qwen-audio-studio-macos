import Foundation
import AVFoundation
import Observation
import StudioCore

enum StudioPage: String, CaseIterable, Identifiable, Sendable {
    case chat = "AI 编剧"
    case creation = "创作台"
    case library = "作品库"
    case templates = "灵感模板"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .creation: "waveform"
        case .library: "square.stack"
        case .templates: "lightbulb"
        }
    }
}

@MainActor @Observable
final class AppState {
    var selectedPage: StudioPage = ProcessInfo.processInfo.arguments.contains("--capture-page=chat") ? .chat :
        (ProcessInfo.processInfo.arguments.contains("--capture-page=templates") ? .templates :
        (ProcessInfo.processInfo.arguments.contains("--capture-page=library") ? .library : .creation))
    let dataRoot: URL
    let store: StudioStore
    let directories: OutputDirectoryStore
    let assets: GeneratedAssetStore
    let references: ReferenceAudioService
    let generation: GenerationService
    let outputFolders: OutputFolderController
    let templates: TemplateLibraryController
    let draft: DraftController
    let playback = AudioPlaybackController.shared
    var errorMessage: String?
    var generationPlan: GenerationPlan?
    var preparing = false
    var submitting = false
    var candidateCount = 1
    var activeBatchID: String?
    var activeRequestID: String?
    var jobStage: [String: JobState] = [:]

    init(dataRoot: URL, synthesizer: any SynthesizerClient = NextClient(),
         batchCommitterFactory: ((StudioStore) -> any BatchCommitting)? = nil) throws {
        self.dataRoot = dataRoot
        store = try StudioStore(dataRoot: dataRoot)
        directories = OutputDirectoryStore(store: store)
        assets = GeneratedAssetStore(store: store, directories: directories)
        references = try ReferenceAudioService(root: dataRoot.appendingPathComponent("ReferenceAudio"), store: store)
        generation = GenerationService(store: store, directories: directories, assets: assets, synthesizer: synthesizer,
                                       batchCommitter: batchCommitterFactory?(store),
                                       maxConcurrentJobs: StudioPreferences().defaultConcurrency)
        outputFolders = OutputFolderController(directories: directories, referenceAudio: references)
        templates = TemplateLibraryController(store: SQLiteTemplateStore(store: store))
        draft = DraftController(store: SQLiteDraftStore(store: store))
        playback.configure(assets: assets)
    }

    static func live() throws -> AppState {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try AppState(dataRoot: support.appendingPathComponent("QwenAudioStudioNative", isDirectory: true))
    }

    func restore() async {
        do {
            let preferred = try await store.currentProjectID()
            if let preferred, let project = try await store.getProject(id: preferred) { draft.load(project) }
            else if let latest = try await store.listProjects().first { draft.load(latest) }
        } catch { errorMessage = "恢复本地工作区失败，请检查作品库和输出目录。" }
        await outputFolders.loadDefault()
        do { try await LegacyImporter(dataRoot: dataRoot, store: store).recoverAbandonedStages() }
        catch { errorMessage = "旧版导入暂存清理失败，请检查应用数据目录。" }
        do { try await assets.reconcilePendingOperations() }
        catch { errorMessage = "部分生成文件待恢复；请重新授权输出目录后刷新作品库。" }
        await templates.reload()
    }

    func openProject(_ project: ProjectDraft) async {
        do {
            try await draft.saveNow()
            draft.load(project)
            try await store.setCurrentProject(id: project.id)
        } catch { errorMessage = "当前草稿尚未保存，无法切换项目。" }
    }
    func openProjectID(_ id: String) async {
        do {
            guard let current = try await store.getProject(id: id) else { throw StudioStoreError.missing }
            await openProject(current)
        } catch { errorMessage = "项目已不可用，请刷新作品库。" }
    }

    func newBlankDraft() async {
        do {
            try await draft.saveNow()
            draft.beginNew(fields: DraftFields(params: StudioPreferences().defaultParams))
            try await store.setCurrentProject(id: nil)
        } catch { errorMessage = "当前草稿尚未保存，无法新建草稿。" }
    }

    func preflight() async {
        guard !preparing, !submitting, generationPlan == nil else { return }
        preparing = true; defer { preparing = false }
        errorMessage = nil
        do {
            try await draft.saveNow()
            if let id = draft.draft?.id { try await store.setCurrentProject(id: id) }
            guard let project = draft.draft,
                  let directoryID = draft.fields.outputDirectoryID ?? outputFolders.defaultID,
                  let snapshot = try await store.getDirectory(id: directoryID) else {
                throw GenerationError.invalidSelection
            }
            if draft.fields.outputDirectoryID != directoryID {
                draft.change { $0.outputDirectoryID = directoryID }
                try await draft.saveNow()
            }
            let savedProject = try await store.getProject(id: project.id) ?? project
            let bindings = savedProject.fields.referenceBindings.sorted { $0.slot < $1.slot }
            let prepared = try await withThrowingTaskGroup(of: (Int, PreparedReference).self) { group in
                for binding in bindings {
                    group.addTask { [references] in (binding.slot, try await references.prepared(referenceID: binding.referenceID)) }
                }
                var values: [(Int, PreparedReference)] = []
                for try await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let input = GenerationInput(clientRequestID: UUID().uuidString, project: savedProject,
                                        directory: snapshot, candidateCount: candidateCount,
                                        references: prepared.map(\.snapshot), preparedReferences: prepared)
            generationPlan = try await generation.preflight(input)
        } catch {
            errorMessage = "预检未通过：\(error.localizedDescription)"
        }
    }

    var isShowingGenerationOverlay = false
    var activeGenerationStage = "准备生成音频…"
    var generationResults: [GeneratedAudioResult] = []
    var generationFailedMessage: String?
    var generationFinished = false

    func submit(plan: GenerationPlan, hash: String, requestID: String) {
        guard !submitting else { return }
        submitting = true
        generationFinished = false
        generationResults = []
        generationFailedMessage = nil
        activeGenerationStage = "正在向阿里云百炼提交通义全景声模型请求…"
        activeBatchID = nil
        jobStage = [:]
        activeRequestID = requestID
        isShowingGenerationOverlay = true

        Task { await monitorRequest(requestID) }
        Task {
            defer {
                submitting = false
                activeRequestID = nil
                generationFinished = true
            }
            do {
                let batch = try await generation.submit(plan, confirmedHash: hash, clientRequestID: requestID)
                activeBatchID = batch.id
                await refreshJobStages(batch.jobIDs)

                // Query generated audio files
                var collected: [GeneratedAudioResult] = []
                for jobID in batch.jobIDs {
                    if let job = try? await store.getJob(id: jobID), job.state == .success {
                        let assetsList = (try? await store.listAssets(jobID: jobID)) ?? []
                        if let audioAsset = assetsList.first(where: { $0.kind == "audio" }) {
                            if let (lease, url) = try? await assets.resolveRegisteredAsset(audioAsset.id) {
                                defer { lease.close() }
                                let duration: Double
                                if let player = try? AVAudioPlayer(contentsOf: url) {
                                    duration = player.duration
                                } else {
                                    duration = (try? await assets.decodeRegisteredAudio(audioAsset.id).duration) ?? 0
                                }
                                collected.append(GeneratedAudioResult(
                                    id: audioAsset.id,
                                    jobID: jobID,
                                    batchID: batch.id,
                                    fileURL: url,
                                    assetID: audioAsset.id,
                                    duration: duration,
                                    format: plan.submission.project.fields.params.format,
                                    sampleRate: plan.submission.project.fields.params.sampleRate
                                ))
                            }
                        }
                    }
                }

                generationResults = collected
                if collected.isEmpty {
                    var failMsg = ""
                    for jobID in batch.jobIDs {
                        if let job = try? await store.getJob(id: jobID), let msg = job.message, !msg.isEmpty {
                            failMsg = msg
                            break
                        }
                    }
                    generationFailedMessage = failMsg.isEmpty ? "模型请求未成功生成音频文件，请在设置中检查 API Key 或 Workspace ID。" : failMsg
                } else {
                    activeGenerationStage = "音频生成完成！"
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                generationFailedMessage = "生成未完成：\(msg)"
                errorMessage = generationFailedMessage
            }
        }
    }

    func refreshJobStages(_ ids: [String]) async {
        for id in ids { if let job = try? await store.getJob(id: id) { jobStage[id] = job.state } }
    }
    func cancelRemaining() async {
        guard let activeBatchID else { return }
        do { _ = try await generation.cancelBatch(batchID: activeBatchID) }
        catch { errorMessage = "仅尚未开始的候选可以取消；当前请求会继续记录真实结果。" }
    }
    private func monitorRequest(_ requestID: String) async {
        while submitting, activeRequestID == requestID {
            if let jobs = try? await store.listLibrary() {
                for job in jobs {
                    guard let batch = try? await store.getBatch(id: job.batchID),
                          batch.submission.clientRequestID == requestID else { continue }
                    activeBatchID = batch.id
                    jobStage[job.id] = job.state
                    switch job.state {
                    case .queued:
                        activeGenerationStage = "任务已排队，等待模型处理…"
                    case .preparing:
                        activeGenerationStage = "正在编译剧本与准备参考音频…"
                    case .requesting:
                        activeGenerationStage = "阿里云百炼正在生成全景声音频 (qwen-audio-3.1-tts-next)…"
                    case .downloading:
                        activeGenerationStage = "音频已生成，正在高速下载至本地输出目录…"
                    case .validating:
                        activeGenerationStage = "正在校验音频采样率与完整性…"
                    case .success:
                        activeGenerationStage = "音频已成功写入本地作品库！"
                    case .failed, .interrupted:
                        if let msg = job.message { activeGenerationStage = msg }
                    case .cancelled:
                        activeGenerationStage = "任务已取消"
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}

public struct GeneratedAudioResult: Identifiable, Sendable {
    public let id: String
    public let jobID: String
    public let batchID: String
    public let fileURL: URL
    public let assetID: String
    public let duration: Double
    public let format: String
    public let sampleRate: Int

    public init(id: String, jobID: String, batchID: String, fileURL: URL, assetID: String, duration: Double, format: String, sampleRate: Int) {
        self.id = id; self.jobID = jobID; self.batchID = batchID; self.fileURL = fileURL
        self.assetID = assetID; self.duration = duration; self.format = format; self.sampleRate = sampleRate
    }
}
