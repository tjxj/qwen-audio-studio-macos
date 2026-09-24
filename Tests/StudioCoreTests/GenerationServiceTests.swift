import Foundation
import Testing
@testable import StudioCore

private actor FakeSynthesizer: SynthesizerClient {
    private(set) var seeds: [Int] = []
    var shouldFail = false
    var onCall: (@Sendable () -> Void)?
    func synthesize(_ request: CompiledRequest) async throws -> ProviderOutput {
        seeds.append(request.seed)
        onCall?()
        if shouldFail { throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://signed.invalid/audio?private=signature")!]) }
        return ProviderOutput(receipt: ProviderResponseSnapshot(providerRequestID: "synthetic-id", audioURL: URL(string: "https://audio.example.invalid/a.wav")!, expiresAt: Date().addingTimeInterval(3600)))
    }
    func setFailing(_ value: Bool) { shouldFail = value }
    func setOnCall(_ callback: @escaping @Sendable () -> Void) { onCall = callback }
    func calls() -> [Int] { seeds }
}

struct GenerationServiceTests {
    private func fixture() throws -> (URL, StudioStore, OutputDirectoryStore, GeneratedAssetStore, FakeSynthesizer, GenerationService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("generation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try StudioStore(dataRoot: root.appendingPathComponent("db"))
        let dirs = OutputDirectoryStore(store: store, bookmarks: FixtureBookmarks())
        let assets = GeneratedAssetStore(store: store, directories: dirs)
        let fake = FakeSynthesizer()
        return (root, store, dirs, assets, fake, GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake, downloader: FakeAudioDownloader()))
    }

    private func input(_ root: URL, _ store: StudioStore, _ dirs: OutputDirectoryStore, params: GenerationParams = .init(), prompt: String = "合成测试", candidates: Int = 1, requestID: String = "stable") async throws -> GenerationInput {
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let dirID = try await dirs.register(selectedURL: output)
        let dir = try #require(try await store.getDirectory(id: dirID))
        let project = try await store.createProject(fields: DraftFields(prompt: prompt, params: params, outputDirectoryID: dirID))
        return GenerationInput(clientRequestID: requestID, project: project, directory: dir, candidateCount: candidates, references: [], preparedReferences: [])
    }

    @Test func invalidParamsStopPaidCallsBeforePersistence() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bad = try await input(root, store, dirs, params: GenerationParams(format: "mp3", sampleRate: 8000, enableCBR: true, bitRate: 320))
        await #expect(throws: (any Error).self) { try await service.preflight(bad) }
        #expect(await fake.calls().isEmpty)
        #expect(try await store.listLibrary().isEmpty)
        try await store.close()
    }

    @Test func changedReferenceBytesFailPreflightBeforePaidPost() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await input(root, store, dirs)
        let reference = ReferenceSnapshot(id: "voice", contentHash: String(repeating: "a", count: 64), fileName: "sample.wav", duration: 1)
        let project = try await store.saveProject(id: base.project.id, expectedRevision: 1,
            changes: DraftFields(prompt: "@voice1 测试", referenceBindings: [ReferenceBinding(referenceID: "voice", alias: "讲述者", slot: 1)], outputDirectoryID: base.directory.id))
        let request = GenerationInput(clientRequestID: "voice-request", project: project, directory: base.directory,
                                      candidateCount: 1, references: [reference],
                                      preparedReferences: [PreparedReference(snapshot: reference, mimeType: "audio/wav", data: Data("different".utf8))])
        await #expect(throws: GenerationError.referenceUnavailable) { try await service.preflight(request) }
        #expect(await fake.calls().isEmpty)
        try await store.close()
    }

    @Test func twoCandidatesTwoDistinctSeedsAndDuplicateNonceNoExtraPost() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs, candidates: 2)
        let plan = try await service.preflight(request)
        let batch = try await service.submit(plan, confirmedHash: plan.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 2)
        #expect(Set(await fake.calls()).count == 2)
        for id in batch.jobIDs {
            #expect(try await store.getJob(id: id)?.state == .success)
            let assets = try await store.listAssets(jobID: id)
            #expect(Set(assets.map(\.kind)) == ["audio", "prompt", "report"])
            for asset in assets { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").appendingPathComponent(asset.relativePath).path)) }
        }
        #expect(try await service.submit(plan, confirmedHash: plan.confirmationHash, clientRequestID: request.clientRequestID).id == batch.id)
        #expect(await fake.calls().count == 2)
        var changed = request; changed.candidateCount = 1
        let changedPlan = try await service.preflight(changed)
        await #expect(throws: StudioStoreError.requestConflict) { try await service.submit(changedPlan, confirmedHash: changedPlan.confirmationHash, clientRequestID: request.clientRequestID) }
        try await store.close()
    }

    @Test func uncertainPostNeverAutomaticallyResubmitsAndOnlyQueuedCancelSucceeds() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await fake.setFailing(true)
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let batch = try await service.submit(plan, confirmedHash: plan.confirmationHash, clientRequestID: request.clientRequestID)
        let job = try #require(try await store.getJob(id: batch.jobIDs[0]))
        #expect(job.resultUncertain)
        #expect(job.state == .interrupted)
        #expect(!String(describing: job).contains("signature"))
        #expect(try await service.cancelQueued(job.id) == false)
        _ = try await service.submit(plan, confirmedHash: plan.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 1)
        try await store.close()
    }

    @Test func corruptDownloadFailsWithoutSuccessAndExplicitRetryUsesOnlyGet() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bad = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                    downloader: FakeAudioDownloader(corrupt: true))
        let request = try await input(root, store, dirs)
        let plan = try await bad.preflight(request)
        let batch = try await bad.submit(plan, confirmedHash: plan.confirmationHash, clientRequestID: request.clientRequestID)
        let id = batch.jobIDs[0]
        #expect(try await store.getJob(id: id)?.state == .failed)
        #expect(try await store.providerResponse(id: id) != nil)
        let good = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                     downloader: FakeAudioDownloader())
        try await good.resumeDownload(jobID: id)
        #expect(try await store.getJob(id: id)?.state == .success)
        #expect(await fake.calls().count == 1)
        try await store.close()
    }

    @Test func retryFinishesRegisteredAudioAndPromptWithoutAnotherPostOrOverwrite() async throws {
        let (root, store, dirs, assets, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let batch = try await store.createBatch(plan.submission)
        let id = batch.jobIDs[0]
        _ = try await store.claimJob(id: id)
        let lease = try await dirs.resolveForJob(id, directoryID: request.directory.id)
        #expect(try await store.transitionJob(id: id, from: .preparing, to: .requesting))
        let receipt = ProviderResponseSnapshot(providerRequestID: "synthetic-id", audioURL: URL(string: "https://audio.example.invalid/a.wav")!, expiresAt: Date().addingTimeInterval(3600))
        #expect(try await store.recordProviderResponse(id: id, response: receipt))
        let wav = try await FakeAudioDownloader().download(receipt)
        let audio = try await assets.write(data: wav, fileName: "audio.wav", kind: "audio", job: id, lease: lease)
        let originalIdentity = audio.fileIdentity
        _ = try await assets.write(data: Data(plan.prompt.utf8), fileName: "prompt.txt", kind: "prompt", job: id, lease: lease)
        let collision = lease.url.appendingPathComponent("report.txt")
        try Data("user-owned sentinel".utf8).write(to: collision)
        #expect(try await store.transitionJob(id: id, from: .downloading, to: .failed, message: "synthetic interrupted write"))
        lease.close()
        try await service.resumeDownload(jobID: id)
        #expect(try await store.getJob(id: id)?.state == .failed)
        #expect(try String(contentsOf: collision, encoding: .utf8) == "user-owned sentinel")
        try FileManager.default.removeItem(at: collision)
        try await service.resumeDownload(jobID: id)
        #expect(try await store.getJob(id: id)?.state == .success)
        let completed = try await store.listAssets(jobID: id)
        #expect(Set(completed.map(\.kind)) == ["audio", "prompt", "report"])
        #expect(completed.first(where: { $0.kind == "audio" })?.fileIdentity == originalIdentity)
        #expect(await fake.calls().isEmpty)
        try await store.close()
    }

    @Test func queuedSecondCandidateCannotUploadAfterConsentExpires() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        await fake.setOnCall { clock.advance(by: 601) }
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), now: { clock.date })
        let request = try await input(root, store, dirs, candidates: 2)
        let plan = try await service.preflight(request)
        let batch = try await service.submit(plan, confirmedHash: plan.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 1)
        #expect(try await store.getJob(id: batch.jobIDs[0])?.state == .success)
        #expect(try await store.getJob(id: batch.jobIDs[1])?.state == .failed)
        try await store.close()
    }

    @Test func storedJobMessageRedactsURLSessionURLsAndBearerTokens() async throws {
        let (root, store, dirs, _, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let batch = try await store.createBatch(plan.submission)
        let id = batch.jobIDs[0]
        _ = try await store.claimJob(id: id)
        #expect(try await store.transitionJob(id: id, from: .preparing, to: .requesting))
        #expect(try await store.markResultUncertain(id: id, message: "URLSession https://signed.invalid/file?token=secret Bearer synthetic-token"))
        let message = try #require(try await store.getJob(id: id)?.message)
        #expect(!message.contains("signed.invalid"))
        #expect(!message.contains("synthetic-token"))
        try await store.close()
    }

    @Test func queuedJobCancelsWithoutAnyPaidPost() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let batch = try await store.createBatch(plan.submission)
        let id = batch.jobIDs[0]
        #expect(try await service.cancelQueued(id))
        #expect(try await store.getJob(id: id)?.state == .cancelled)
        _ = try await service.submit(plan, confirmedHash: plan.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().isEmpty)
        try await store.close()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var date: Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
    func advance(by seconds: TimeInterval) { lock.lock(); offset += seconds; lock.unlock() }
}

private struct FakeAudioDownloader: AudioDownloading {
    var corrupt = false
    func download(_ receipt: ProviderResponseSnapshot) async throws -> Data {
        guard !corrupt else { return Data("invalid".utf8) }
        let frames = 4_800, channels = 2, sampleRate = 48_000
        let bytes = frames * channels * 2
        var result = Data()
        func word<T: FixedWidthInteger>(_ number: T) { var little = number.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        result.append(contentsOf: "RIFF".utf8); word(UInt32(36 + bytes))
        result.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1))
        word(UInt16(channels)); word(UInt32(sampleRate)); word(UInt32(sampleRate * channels * 2))
        word(UInt16(channels * 2)); word(UInt16(16)); result.append(contentsOf: "data".utf8); word(UInt32(bytes))
        result.append(Data(repeating: 0, count: bytes))
        return result
    }
}
