import Foundation
import Testing
@testable import QwenAudioStudioMacApp
@testable import StudioCore

private actor AppCommitGate: BatchCommitting {
    let store: StudioStore
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(store: StudioStore) { self.store = store }
    func createBatch(_ submission: BatchSubmission) async throws -> StoredBatch {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return try await store.createBatch(submission)
    }
    func waitEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor struct AppStateTests {
    @Test func currentDraftRestoresAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AppState(dataRoot: root)
        first.draft.change { $0.name = "重启保留"; $0.prompt = "持续写作" }
        try await first.draft.saveNow()
        let id = try #require(first.draft.draft?.id)
        try await first.store.close()
        let second = try AppState(dataRoot: root)
        await second.restore()
        #expect(second.draft.draft?.id == id)
        #expect(second.draft.fields.prompt == "持续写作")
        try await second.store.close()
    }
    @Test func preflightKeepsOneConfirmationAndUsesCandidateCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-preflight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try AppState(dataRoot: root)
        let snapshot = DirectorySnapshot(id: "output", version: 1, bookmark: Data("synthetic".utf8))
        try await state.store.saveDirectory(snapshot)
        state.draft.change { $0.name = "短句"; $0.prompt = "【对白：讲述者】你好。"; $0.outputDirectoryID = snapshot.id }
        state.candidateCount = 3
        await state.preflight()
        let first = try #require(state.generationPlan)
        #expect(first.callCount == 3)
        #expect(Set(first.seeds).count == 3)
        await state.preflight()
        #expect(state.generationPlan?.confirmationHash == first.confirmationHash)
        state.generationPlan = nil
        state.candidateCount = 1
        await state.preflight()
        #expect(state.generationPlan?.callCount == 1)
        try await state.store.close()
    }
    @Test func selectedOlderProjectRestoresInsteadOfLatest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-project-choice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AppState(dataRoot: root)
        let older = try await first.store.createProject(fields: DraftFields(name: "较早项目", prompt: "保留"))
        _ = try await first.store.createProject(fields: DraftFields(name: "较新项目", prompt: "较新"))
        await first.openProject(older)
        try await first.store.close()
        let second = try AppState(dataRoot: root)
        await second.restore()
        #expect(second.draft.draft?.id == older.id)
        try await second.store.close()
    }
    @Test func continuingHistoricalVersionLoadsCurrentProjectRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-current-revision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try AppState(dataRoot: root)
        let old = try await state.store.createProject(fields: DraftFields(name: "旧名", prompt: "旧稿"))
        _ = try await state.store.saveProject(id: old.id, expectedRevision: 1,
            changes: DraftFields(name: "新名", prompt: "新稿"))
        await state.openProjectID(old.id)
        #expect(state.draft.fields.name == "新名")
        #expect(state.draft.draft?.revision == 2)
        try await state.store.close()
    }
    @Test func customTemplateAndFavoriteRestoreAcrossAppRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-templates-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try AppState(dataRoot: root)
        await first.templates.reload()
        #expect(first.templates.templates.count == 42)
        let custom = StudioTemplate(name: "自建试验", mode: .podcast, promptPattern: "【对白：讲述者】自建内容")
        #expect(await first.templates.save(custom))
        await first.templates.favorite(custom)
        #expect(first.templates.favorites.contains(custom.id))
        await first.templates.remove(custom)
        #expect(!first.templates.templates.contains(where: { $0.id == custom.id }))
        await first.templates.undoLastRemoval()
        #expect(first.templates.templates.contains(where: { $0.id == custom.id }))
        try await first.store.close()
        let second = try AppState(dataRoot: root)
        await second.restore()
        #expect(second.templates.templates.count == 43)
        #expect(second.templates.favorites.contains(custom.id))
        try await second.store.close()
    }
    @Test func startingNewSubmitCannotCancelPreviousBatchWhileCommitWaits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-batch-switch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var gate: AppCommitGate?
        let state = try AppState(dataRoot: root, batchCommitterFactory: { store in
            let created = AppCommitGate(store: store); gate = created; return created
        })
        let snapshot = DirectorySnapshot(id: "output", version: 1, bookmark: Data("synthetic".utf8))
        try await state.store.saveDirectory(snapshot)
        state.draft.change { $0.name = "短句"; $0.prompt = "【对白：讲述者】你好。"; $0.outputDirectoryID = snapshot.id }
        try await state.draft.saveNow()
        let project = try #require(state.draft.draft)
        let compiled = try PromptCompiler.compile(mode: project.fields.mode, prompt: project.fields.prompt, bindings: [])
        let old = try await state.store.createBatch(BatchSubmission(clientRequestID: "old", project: project,
            compiledPrompt: compiled.text, candidateSeeds: [11], directory: snapshot, references: [],
            consent: UploadConsent(clientRequestID: "old", references: [], confirmed: true)))
        state.activeBatchID = old.id
        state.jobStage[old.jobIDs[0]] = .queued
        await state.preflight()
        let plan = try #require(state.generationPlan)
        let authorization = try await state.generation.confirm(plan)
        state.submit(plan: plan, hash: authorization.confirmationHash, requestID: authorization.clientRequestID)
        let held = try #require(gate)
        await held.waitEntered()
        #expect(state.activeBatchID == nil)
        #expect(state.jobStage.isEmpty)
        await state.cancelRemaining()
        #expect(try await state.store.getJob(id: old.jobIDs[0])?.state == .queued)
        await held.release()
        for _ in 0..<40 where state.submitting { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(!state.submitting)
        try await state.store.close()
    }
}
