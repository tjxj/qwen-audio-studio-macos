import Foundation
import Testing
@testable import StudioCore

struct LibraryTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func metadataAndFiltersSurviveRestart() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let directory = DirectorySnapshot(id: "folder", version: 1, bookmark: Data("synthetic".utf8))
        try await store.saveDirectory(directory)
        let project = try await store.createProject(fields: DraftFields(name: "雨声播客", mode: .podcast, prompt: "合成台词", outputDirectoryID: directory.id))
        let compiled = try PromptCompiler.compile(mode: .podcast, prompt: project.fields.prompt, bindings: [])
        let request = BatchSubmission(clientRequestID: "first", project: project, compiledPrompt: compiled.text, candidateSeeds: [1,2], directory: directory, references: [], consent: UploadConsent(clientRequestID: "first", references: [], confirmed: true))
        let batch = try await store.createBatch(request)
        _ = try await store.claimJob(id: batch.jobIDs[0])
        _ = try await store.transitionJob(id: batch.jobIDs[0], from: .preparing, to: .requesting)
        _ = try await store.recordProviderResponse(id: batch.jobIDs[0], response: ProviderResponseSnapshot(providerRequestID: "synthetic", audioURL: URL(string: "https://example.com/audio.wav")!))
        _ = try await store.transitionJob(id: batch.jobIDs[0], from: .downloading, to: .validating)
        _ = try await store.transitionJob(id: batch.jobIDs[0], from: .validating, to: .success)
        try await store.updateJobMetadata(id: batch.jobIDs[0], name: "夜读版本", favorite: true, note: "最终采用")
        try await store.setFinalJob(batchID: batch.id, jobID: batch.jobIDs[0])
        #expect(try await store.libraryPage(.init(search: "夜读", favoriteOnly: true, limit: 1)).items.map(\.job.id) == [batch.jobIDs[0]])
        #expect(try await store.getJobMetadata(id: batch.jobIDs[0])?.note == "最终采用")
        #expect(try await store.finalJobID(batchID: batch.id) == batch.jobIDs[0])
        #expect(try await store.libraryPage(.init()).items.first(where: { $0.job.id == batch.jobIDs[0] })?.isFinal == true)
        #expect(try await store.libraryPage(.init()).items.first(where: { $0.job.id == batch.jobIDs[1] })?.isFinal == false)
        let firstPage = try await store.libraryPage(.init(mode: .podcast, limit: 1))
        #expect(firstPage.items.count == 1)
        let secondPage = try await store.libraryPage(.init(mode: .podcast, beforeID: firstPage.nextBeforeID, limit: 1))
        #expect(secondPage.items.count == 1)
        #expect(firstPage.items[0].job.id != secondPage.items[0].job.id)
        #expect(try await store.libraryPage(.init(state: .success)).items.map(\.job.id) == [batch.jobIDs[0]])
        #expect(try await store.libraryPage(.init(since: Date().addingTimeInterval(3600))).items.isEmpty)
        try await store.close()
        let reopened = try StudioStore(dataRoot: url)
        #expect(try await reopened.getJobMetadata(id: batch.jobIDs[0])?.name == "夜读版本")
        #expect(try await reopened.finalJobID(batchID: batch.id) == batch.jobIDs[0])
        try await reopened.close()
    }
    @Test func historicalLibraryRowsUseSubmittedProjectSnapshot() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let directory = DirectorySnapshot(id: "folder", version: 1, bookmark: Data("synthetic".utf8))
        try await store.saveDirectory(directory)
        let initial = DraftFields(name: "旧版夜读", mode: .podcast, prompt: "原始脚本", outputDirectoryID: directory.id)
        let project = try await store.createProject(fields: initial)
        let compiled = try PromptCompiler.compile(mode: initial.mode, prompt: initial.prompt, bindings: [])
        let submission = BatchSubmission(clientRequestID: "historical", project: project,
            compiledPrompt: compiled.text, candidateSeeds: [42], directory: directory, references: [],
            consent: UploadConsent(clientRequestID: "historical", references: [], confirmed: true))
        let batch = try await store.createBatch(submission)
        var changed = initial
        changed.name = "新版广告"; changed.mode = .advertisement; changed.prompt = "新写文案"
        _ = try await store.saveProject(id: project.id, expectedRevision: 1, changes: changed)
        let historical = try await store.libraryPage(.init(search: "原始脚本", mode: .podcast))
        #expect(historical.items.map(\.job.id) == batch.jobIDs)
        let row = try #require(historical.items.first)
        #expect(row.project.fields.name == "旧版夜读")
        #expect(row.project.fields.prompt == "原始脚本")
        #expect(try await store.libraryPage(.init(search: "新写文案")).items.isEmpty)
        #expect(try await store.libraryPage(.init(mode: .advertisement)).items.isEmpty)
        try await store.close()
    }
    @Test func retryEligibilityRequiresKnownUnexpiredGetReceipt() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let directory = DirectorySnapshot(id: "folder", version: 1, bookmark: Data("synthetic".utf8))
        try await store.saveDirectory(directory)
        let fields = DraftFields(prompt: "合成", outputDirectoryID: directory.id)
        let project = try await store.createProject(fields: fields)
        let compiled = try PromptCompiler.compile(mode: fields.mode, prompt: fields.prompt, bindings: [])
        let batch = try await store.createBatch(BatchSubmission(clientRequestID: "retry", project: project,
            compiledPrompt: compiled.text, candidateSeeds: [1,2], directory: directory, references: [],
            consent: UploadConsent(clientRequestID: "retry", references: [], confirmed: true)))
        #expect(try await store.canRetryDownload(id: batch.jobIDs[0]) == false)
        _ = try await store.claimJob(id: batch.jobIDs[0])
        _ = try await store.transitionJob(id: batch.jobIDs[0], from: .preparing, to: .requesting)
        _ = try await store.recordProviderResponse(id: batch.jobIDs[0], response: ProviderResponseSnapshot(
            providerRequestID: "receipt", audioURL: URL(string: "https://example.invalid/audio.wav")!,
            expiresAt: Date().addingTimeInterval(3600)))
        _ = try await store.transitionJob(id: batch.jobIDs[0], from: .downloading, to: .failed)
        #expect(try await store.canRetryDownload(id: batch.jobIDs[0]))
        #expect(try await store.canRetryDownload(id: batch.jobIDs[1]) == false)
        try await store.close()
    }
    @Test func storageUsageCountsApplicationOwnedReferenceBytes() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let before = try await store.localStorageBytes()
        let referenceRoot = url.appendingPathComponent("ReferenceAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceRoot, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1_048_576).write(to: referenceRoot.appendingPathComponent("synthetic.bin"))
        let after = try await store.localStorageBytes()
        #expect(after >= before + 1_048_576)
        try await store.close()
    }
}
