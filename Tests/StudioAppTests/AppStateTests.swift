import Foundation
import Testing
@testable import QwenAudioStudioMacApp
@testable import StudioCore

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
}
