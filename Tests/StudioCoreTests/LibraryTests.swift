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
}
