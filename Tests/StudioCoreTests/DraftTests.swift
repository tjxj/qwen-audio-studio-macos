import Foundation
import Testing
@testable import StudioCore

@MainActor
struct DraftTests {
    @Test func autosaveDebouncesRapidEditsAndEventuallySavesLatest() async throws {
        let controller = DraftController(store: InMemoryDraftStore())
        controller.change { $0.prompt = "初稿" }
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.draft == nil)
        controller.change { $0.prompt = "最后一版" }
        try await Task.sleep(for: .milliseconds(450))
        #expect(controller.draft == nil)
        try await Task.sleep(for: .milliseconds(550))
        #expect(controller.draft?.fields.prompt == "最后一版")
        #expect(controller.state == .saved)
    }

    @Test func handEditedPromptSurvivesEveryModeChange() {
        let controller = DraftController(store: InMemoryDraftStore())
        controller.change { $0.prompt = "手写稿\n保留空格  与标点！" }
        for mode in CreationMode.allCases {
            controller.change { $0.mode = mode }
            #expect(controller.fields.mode == mode)
            #expect(controller.fields.prompt == "手写稿\n保留空格  与标点！")
        }
    }

    @Test func sampleChangesOnlyUntilFirstManualEdit() {
        let controller = DraftController(store: InMemoryDraftStore())
        let original = controller.fields.prompt
        controller.change { $0.mode = .advertisement }
        #expect(controller.fields.prompt != original)
        let advertisement = controller.fields.prompt
        controller.change { $0.prompt += "\n我的句子" }
        controller.change { $0.prompt = advertisement }
        controller.change { $0.mode = .drama }
        #expect(controller.fields.prompt == advertisement)
    }

    @Test func commandSaveWaitsForInFlightSaveAndLatestEdits() async throws {
        let store = GatedDraftStore()
        let controller = DraftController(store: store)
        controller.change { $0.prompt = "第一版" }
        let first = Task { try await controller.saveNow() }
        await store.waitUntilSaving()
        controller.change { $0.prompt = "在保存期间继续编辑" }
        var commandFinished = false
        let command = Task {
            try await controller.saveNow()
            commandFinished = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!commandFinished)
        await store.release()
        try await first.value
        try await command.value
        #expect(commandFinished)
        #expect(controller.draft?.fields.prompt == "在保存期间继续编辑")
        #expect(controller.state == .saved)
    }

    @Test func revisionConflictKeepsLocalRecoveryText() async throws {
        let store = InMemoryDraftStore()
        let controller = DraftController(store: store)
        try await controller.saveNow()
        var external = try #require(controller.draft)
        external.fields.prompt = "另一窗口的版本"
        _ = try await store.save(external, expectedRevision: external.revision)
        controller.change { $0.prompt = "尚未保存的本地恢复文字" }
        await #expect(throws: DraftStoreError.conflict) { try await controller.saveNow() }
        #expect(controller.state == .conflict)
        #expect(controller.fields.prompt == "尚未保存的本地恢复文字")
        #expect(controller.localRecoveryText == "尚未保存的本地恢复文字")
        controller.change { $0.prompt += "，继续编辑" }
        #expect(controller.localRecoveryText == "尚未保存的本地恢复文字，继续编辑")
    }
}

/// Delays only the first storage write while preserving real revision semantics.
private actor GatedDraftStore: DraftStore {
    let storage = InMemoryDraftStore()
    var gate: CheckedContinuation<Void, Never>?
    var started = false
    func waitUntilSaving() async { while !started { await Task.yield() } }
    func release() { gate?.resume(); gate = nil }
    func create(_ fields: DraftFields) async throws -> ProjectDraft {
        if !started { await withCheckedContinuation { gate = $0; started = true } }
        return try await storage.create(fields)
    }
    func save(_ draft: ProjectDraft, expectedRevision: Int) async throws -> ProjectDraft {
        try await storage.save(draft, expectedRevision: expectedRevision)
    }
}
