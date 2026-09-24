import Foundation
import Observation
import StudioCore

@MainActor @Observable
final class AppState {
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

    func submit(plan: GenerationPlan, hash: String, requestID: String) {
        guard !submitting, generationPlan?.confirmationHash == plan.confirmationHash else { return }
        generationPlan = nil
        submitting = true
        activeBatchID = nil
        jobStage = [:]
        activeRequestID = requestID
        Task { await monitorRequest(requestID) }
        Task {
            defer { submitting = false; activeRequestID = nil }
            do {
                let batch = try await generation.submit(plan, confirmedHash: hash, clientRequestID: requestID)
                activeBatchID = batch.id
                await refreshJobStages(batch.jobIDs)
            } catch {
                errorMessage = "生成未完成：\(error.localizedDescription)。请在作品库核查记录，勿直接重复提交。"
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
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
