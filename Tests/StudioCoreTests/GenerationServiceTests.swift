import Foundation
import Testing
import CryptoKit
@testable import StudioCore

private actor FakeSynthesizer: SynthesizerClient {
    private(set) var seeds: [Int] = []
    var shouldFail = false
    var onCall: (@Sendable () async -> Void)?
    func synthesize(_ request: CompiledRequest) async throws -> ProviderOutput {
        seeds.append(request.seed)
        await onCall?()
        if shouldFail { throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://signed.invalid/audio?private=signature")!]) }
        return ProviderOutput(receipt: ProviderResponseSnapshot(providerRequestID: "synthetic-id", audioURL: URL(string: "https://audio.example.invalid/a.wav")!, expiresAt: Date().addingTimeInterval(3600)))
    }
    func setFailing(_ value: Bool) { shouldFail = value }
    func setOnCall(_ callback: @escaping @Sendable () async -> Void) { onCall = callback }
    func calls() -> [Int] { seeds }
}

private actor HoldingSynthesizer: SynthesizerClient {
    private var seeds: [Int] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    let failSeed: Int?
    init(failSeed: Int? = nil) { self.failSeed = failSeed }
    func synthesize(_ request: CompiledRequest) async throws -> ProviderOutput {
        seeds.append(request.seed)
        if !released { await withCheckedContinuation { waiters.append($0) } }
        if request.seed == failSeed { throw URLError(.timedOut) }
        return ProviderOutput(receipt: ProviderResponseSnapshot(providerRequestID: "synthetic-id-\(request.seed)",
            audioURL: URL(string: "https://audio.example.invalid/a.wav")!, expiresAt: Date().addingTimeInterval(3600)))
    }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func calls() -> [Int] { seeds }
}

private actor PausedBatchCommitter: BatchCommitting {
    private let store: StudioStore
    private var entered = 0
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    init(store: StudioStore) { self.store = store }
    func createBatch(_ submission: BatchSubmission) async throws -> StoredBatch {
        entered += 1
        let attempt = entered
        let ready = entryWaiters.filter { $0.0 <= entered }
        entryWaiters.removeAll { $0.0 <= entered }
        ready.forEach { $0.1.resume() }
        let succeeds = await withCheckedContinuation { releaseWaiters[attempt] = $0 }
        guard succeeds else { throw CommitFailure.synthetic }
        return try await store.createBatch(submission)
    }
    func waitForEntries(_ count: Int) async {
        if entered >= count { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }
    func releaseAll() {
        let waiting = releaseWaiters
        releaseWaiters = [:]
        waiting.values.forEach { $0.resume(returning: true) }
    }
    func release(_ attempt: Int, succeeds: Bool) { releaseWaiters.removeValue(forKey: attempt)?.resume(returning: succeeds) }
    func attempts() -> Int { entered }
}

private enum CommitFailure: Error { case synthetic }

private extension GenerationService {
    func submitReportingSuspension(_ plan: GenerationPlan, authorization: GenerationAuthorization,
                                   signal: @escaping @Sendable () -> Void) async throws -> StoredBatch {
        // This actor-inheriting task can report only once submit below yields.
        // submit is actor-isolated too: it reaches its first persistence/shared
        // result wait before this queued actor work can run.
        Task { self.reportSuspension(signal) }
        return try await submit(plan, confirmedHash: authorization.confirmationHash,
                                clientRequestID: authorization.clientRequestID)
    }
    func reportSuspension(_ signal: @Sendable () -> Void) { signal() }
}

struct GenerationServiceTests {
    private func waitForCalls(_ expected: Int, fake: HoldingSynthesizer) async -> Bool {
        for _ in 0..<40 {
            if await fake.calls().count >= expected { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test(arguments: [2, 3]) func configuredConcurrentCandidatesEnterRequestingOnce(limit: Int) async throws {
        let (root, store, dirs, assets, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = HoldingSynthesizer()
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), maxConcurrentJobs: limit)
        let request = try await input(root, store, dirs, candidates: 3)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let first = Task { try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID) }
        let reached = await waitForCalls(limit, fake: fake)
        let duplicate = Task { try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID) }
        let states = try await store.listLibrary().map(\.state)
        await fake.release()
        #expect(reached)
        #expect(states.filter { $0 == .requesting }.count == limit)
        let batch = try await first.value
        #expect(try await duplicate.value.id == batch.id)
        #expect(Set(await fake.calls()).count == 3)
        #expect(await fake.calls().count == 3)
        for id in batch.jobIDs { #expect(try await store.getJob(id: id)?.state == .success) }
        try await store.close()
    }

    @Test func parallelCancellationOnlyRemovesUnclaimedCandidate() async throws {
        let (root, store, dirs, assets, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = HoldingSynthesizer()
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), maxConcurrentJobs: 2)
        let request = try await input(root, store, dirs, candidates: 3)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let task = Task { try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID) }
        let reached = await waitForCalls(2, fake: fake)
        let batchID = try #require(try await store.listLibrary().first?.batchID)
        let cancelled = try await service.cancelBatch(batchID: batchID)
        await fake.release()
        #expect(reached)
        #expect(cancelled == 1)
        let batch = try await task.value
        #expect(await fake.calls().count == 2)
        #expect(try await store.getJob(id: batch.jobIDs[2])?.state == .cancelled)
        try await store.close()
    }

    @Test func parallelUncertainResponseNeverPostsAgain() async throws {
        let (root, store, dirs, assets, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = HoldingSynthesizer(failSeed: 43)
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), maxConcurrentJobs: 2)
        let request = try await input(root, store, dirs, candidates: 2)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let task = Task { try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID) }
        let reached = await waitForCalls(2, fake: fake)
        await fake.release()
        #expect(reached)
        let batch = try await task.value
        #expect(try await store.getJob(id: batch.jobIDs[1])?.state == .interrupted)
        #expect(try await store.getJob(id: batch.jobIDs[1])?.resultUncertain == true)
        _ = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 2)
        try await store.close()
    }
    @Test func sharedReferenceLeaseSurvivesBothParallelPaidCalls() async throws {
        let (root, store, dirs, assets, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = HoldingSynthesizer()
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), maxConcurrentJobs: 2)
        let base = try await input(root, store, dirs, candidates: 2)
        let bytes = FakeAudioDownloader.wav(frames: 2 * 48_000)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let reference = ReferenceSnapshot(id: "shared-voice", contentHash: hash, fileName: "synthetic.wav", duration: 2)
        try await store.saveReference(reference)
        let fields = DraftFields(prompt: "@voice1 合成测试", referenceBindings: [ReferenceBinding(referenceID: reference.id, alias: "合成", slot: 1)], outputDirectoryID: base.directory.id)
        let project = try await store.saveProject(id: base.project.id, expectedRevision: 1, changes: fields)
        let request = GenerationInput(clientRequestID: "parallel-voice", project: project, directory: base.directory,
            candidateCount: 2, references: [reference], preparedReferences: [PreparedReference(snapshot: reference, mimeType: "audio/wav", data: bytes)])
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let task = Task { try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID) }
        let reached = await waitForCalls(2, fake: fake)
        let leased = try await store.activeLeaseCount(referenceID: reference.id)
        await fake.release()
        #expect(reached)
        #expect(leased == 2)
        let batch = try await task.value
        for id in batch.jobIDs { #expect(try await store.getJob(id: id)?.state == .success) }
        #expect(try await store.activeLeaseCount(referenceID: reference.id) == 0)
        try await store.close()
    }
    private func startSuspendedSubmit(_ service: GenerationService, _ plan: GenerationPlan,
                                      _ authorization: GenerationAuthorization) async -> Task<StoredBatch, Error> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await service.submitReportingSuspension(plan, authorization: authorization) {
                continuation.yield(())
                continuation.finish()
            }
        }
        for await _ in stream { break }
        return task
    }

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

    @Test func preflightHashAloneCannotAuthorizePaidSubmit() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs)
        let preview = try await service.preflight(request)
        await #expect(throws: GenerationError.confirmationMismatch) {
            try await service.submit(preview, confirmedHash: preview.confirmationHash, clientRequestID: request.clientRequestID)
        }
        #expect(await fake.calls().isEmpty)
        #expect(try await store.listLibrary().isEmpty)
        try await store.close()
    }

    @Test func revokedUnconsumedConfirmationCannotSubmit() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        await service.revokeAuthorization(authorization)
        await #expect(throws: GenerationError.confirmationMismatch) {
            try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        }
        #expect(await fake.calls().isEmpty)
        #expect(try await store.listLibrary().isEmpty)
        try await store.close()
    }

    @Test func revokingWhileBatchCommitAwaitsCancelsAllQueuedBeforeAnyPost() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PausedBatchCommitter(store: store)
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), batchCommitter: gate)
        let request = try await input(root, store, dirs, candidates: 2)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let submitting = Task {
            try await service.submit(plan, confirmedHash: authorization.confirmationHash,
                                     clientRequestID: request.clientRequestID)
        }
        await gate.waitForEntries(1)
        await service.revokeAuthorization(authorization)
        await #expect(throws: GenerationError.confirmationMismatch) { try await service.confirm(plan) }
        await gate.releaseAll()
        let batch = try await submitting.value
        #expect(await fake.calls().isEmpty)
        for id in batch.jobIDs { #expect(try await store.getJob(id: id)?.state == .cancelled) }
        await #expect(throws: GenerationError.confirmationMismatch) {
            try await service.submit(plan, confirmedHash: authorization.confirmationHash,
                                     clientRequestID: request.clientRequestID)
        }
        await #expect(throws: GenerationError.confirmationMismatch) { try await service.confirm(plan) }
        try await store.close()
    }

    @Test func concurrentDuplicateSubmitWhileCommitAwaitsPostsOnce() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PausedBatchCommitter(store: store)
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), batchCommitter: gate)
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let first = await startSuspendedSubmit(service, plan, authorization)
        await gate.waitForEntries(1)
        let second = await startSuspendedSubmit(service, plan, authorization)
        #expect(await gate.attempts() == 1)
        await gate.releaseAll()
        let a = try await first.value, b = try await second.value
        #expect(a.id == b.id)
        #expect(await fake.calls().count == 1)
        try await store.close()
    }

    // The second persistence attempt is deliberately configured to succeed if a
    // regression lets it enter. Failure of the first must reach both callers;
    // no second durable batch or paid POST may escape that shared result.
    @Test(arguments: ["none", "revoke", "ownerCancel", "duplicateCancel"], [false, true])
    func concurrentCommitSharesOneOutcome(cancellation: String, succeeds: Bool) async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PausedBatchCommitter(store: store)
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), batchCommitter: gate)
        let request = try await input(root, store, dirs, candidates: 2)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let first = await startSuspendedSubmit(service, plan, authorization)
        await gate.waitForEntries(1)
        let second = await startSuspendedSubmit(service, plan, authorization)
        #expect(await gate.attempts() == 1)
        switch cancellation {
        case "revoke": await service.revokeAuthorization(authorization)
        case "ownerCancel": first.cancel()
        case "duplicateCancel": second.cancel()
        default: break
        }
        await gate.release(1, succeeds: succeeds)
        let a = await first.result
        await gate.releaseAll()
        let b = await second.result
        #expect(await gate.attempts() == 1)
        if succeeds {
            let firstBatch = try a.get(), secondBatch = try b.get()
            #expect(firstBatch.id == secondBatch.id)
            for id in firstBatch.jobIDs {
                #expect(try await store.getJob(id: id)?.state == (cancellation == "none" ? .success : .cancelled))
            }
            #expect(await fake.calls().count == (cancellation == "none" ? 2 : 0))
        } else {
            for result in [a, b] {
                switch result {
                case .success: Issue.record("A failed commit must fail every concurrent caller")
                case .failure(let error): #expect(error is CommitFailure)
                }
            }
            #expect(try await store.listLibrary().isEmpty)
            #expect(await fake.calls().isEmpty)
        }
        if cancellation != "none", await gate.attempts() == 1 {
            await #expect(throws: GenerationError.confirmationMismatch) {
                try await service.submit(plan, confirmedHash: authorization.confirmationHash,
                                         clientRequestID: request.clientRequestID)
            }
        } else if !succeeds, await gate.attempts() == 1 {
            // A new explicit attempt after the shared failure may succeed;
            // joining that failed attempt never performs this retry implicitly.
            let retry = await startSuspendedSubmit(service, plan, authorization)
            await gate.waitForEntries(2)
            await gate.releaseAll()
            let batch = try await retry.value
            #expect(await gate.attempts() == 2)
            #expect(await fake.calls().count == 2)
            for id in batch.jobIDs { #expect(try await store.getJob(id: id)?.state == .success) }
        }
        try await store.close()
    }

    @Test func uploadConsentStartsAtExplicitConfirmationAfterLongPreview() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(initialOffset: -601)
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), now: { clock.date })
        let request = try await input(root, store, dirs)
        let preview = try await service.preflight(request)
        clock.advance(by: 601)
        let authorization = try await service.confirm(preview)
        #expect(authorization.submission.consent.confirmed)
        #expect(authorization.submission.consent.confirmedAt > preview.submission.consent.confirmedAt)
        let batch = try await service.submit(preview, confirmedHash: authorization.confirmationHash,
                                             clientRequestID: request.clientRequestID)
        #expect(try await store.getJob(id: batch.jobIDs[0])?.state == .success)
        #expect(await fake.calls().count == 1)
        try await store.close()
    }

    @Test func expiredUnconsumedConfirmationGetsFreshTokenButConsumedNonceStaysIdempotent() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(initialOffset: -601)
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader(), now: { clock.date })
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let stale = try await service.confirm(plan)
        clock.advance(by: 601)
        let fresh = try await service.confirm(plan)
        #expect(fresh.confirmationHash != stale.confirmationHash)
        #expect(fresh.submission.consent.confirmedAt > stale.submission.consent.confirmedAt)
        await #expect(throws: GenerationError.confirmationMismatch) {
            try await service.submit(plan, confirmedHash: stale.confirmationHash, clientRequestID: request.clientRequestID)
        }
        let batch = try await service.submit(plan, confirmedHash: fresh.confirmationHash, clientRequestID: request.clientRequestID)
        clock.advance(by: 601)
        let consumed = try await service.confirm(plan)
        #expect(consumed.confirmationHash == fresh.confirmationHash)
        #expect(try await service.submit(plan, confirmedHash: consumed.confirmationHash,
            clientRequestID: request.clientRequestID).id == batch.id)
        #expect(await fake.calls().count == 1)
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

    @Test func forgedTwoSecondSnapshotCannotUploadThirtyOneSecondWAV() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await input(root, store, dirs)
        let bytes = FakeAudioDownloader.wav(frames: 31 * 48_000)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let reference = ReferenceSnapshot(id: "voice", contentHash: hash, fileName: "synthetic-long.wav", duration: 2)
        let project = try await store.saveProject(id: base.project.id, expectedRevision: 1,
            changes: DraftFields(prompt: "@voice1 测试", referenceBindings: [ReferenceBinding(referenceID: "voice", alias: "讲述者", slot: 1)], outputDirectoryID: base.directory.id))
        let request = GenerationInput(clientRequestID: "long-reference", project: project, directory: base.directory,
                                      candidateCount: 1, references: [reference],
                                      preparedReferences: [PreparedReference(snapshot: reference, mimeType: "audio/wav", data: bytes)])
        await #expect(throws: GenerationError.referenceUnavailable) { try await service.preflight(request) }
        #expect(await fake.calls().isEmpty)
        try await store.close()
    }

    @Test func verifiedTwoSecondMonoPCM16WAVCanReachFakeProvider() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await input(root, store, dirs)
        let bytes = FakeAudioDownloader.wav(frames: 2 * 48_000)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let reference = ReferenceSnapshot(id: "voice", contentHash: hash, fileName: "synthetic-two-seconds.wav", duration: 2)
        try await store.saveReference(reference)
        let project = try await store.saveProject(id: base.project.id, expectedRevision: 1,
            changes: DraftFields(prompt: "@voice1 测试", referenceBindings: [ReferenceBinding(referenceID: "voice", alias: "讲述者", slot: 1)], outputDirectoryID: base.directory.id))
        let request = GenerationInput(clientRequestID: "valid-reference", project: project, directory: base.directory,
                                      candidateCount: 1, references: [reference],
                                      preparedReferences: [PreparedReference(snapshot: reference, mimeType: "audio/wav", data: bytes)])
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let batch = try await service.submit(plan, confirmedHash: authorization.confirmationHash,
                                             clientRequestID: request.clientRequestID)
        #expect(try await store.getJob(id: batch.jobIDs[0])?.state == .success)
        #expect(await fake.calls().count == 1)
        try await store.close()
    }

    @Test func twoCandidatesTwoDistinctSeedsAndDuplicateNonceNoExtraPost() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs, candidates: 2)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let batch = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 2)
        #expect(Set(await fake.calls()).count == 2)
        for id in batch.jobIDs {
            #expect(try await store.getJob(id: id)?.state == .success)
            let assets = try await store.listAssets(jobID: id)
            #expect(Set(assets.map(\.kind)) == ["audio", "prompt", "report"])
            for asset in assets { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").appendingPathComponent(asset.relativePath).path)) }
        }
        await service.revokeAuthorization(authorization)
        #expect(try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID).id == batch.id)
        #expect(await fake.calls().count == 2)
        var changed = request; changed.candidateCount = 1
        let changedPlan = try await service.preflight(changed)
        await #expect(throws: StudioStoreError.requestConflict) { try await service.confirm(changedPlan) }
        try await store.close()
    }

    @Test func uncertainPostNeverAutomaticallyResubmitsAndOnlyQueuedCancelSucceeds() async throws {
        let (root, store, dirs, _, fake, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await fake.setFailing(true)
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let batch = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        let job = try #require(try await store.getJob(id: batch.jobIDs[0]))
        #expect(job.resultUncertain)
        #expect(job.state == .interrupted)
        #expect(!String(describing: job).contains("signature"))
        #expect(try await service.cancelQueued(job.id) == false)
        _ = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 1)
        try await store.close()
    }

    @Test func corruptDownloadFailsWithoutSuccessAndExplicitRetryUsesOnlyGet() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bad = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                    downloader: FakeAudioDownloader(corrupt: true))
        let request = try await input(root, store, dirs)
        let plan = try await bad.preflight(request)
        let authorization = try await bad.confirm(plan)
        let batch = try await bad.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
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
        let authorization = try await service.confirm(plan)
        let batch = try await store.createBatch(authorization.submission)
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
        let authorization = try await service.confirm(plan)
        let batch = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 1)
        #expect(try await store.getJob(id: batch.jobIDs[0])?.state == .success)
        #expect(try await store.getJob(id: batch.jobIDs[1])?.state == .failed)
        try await store.close()
    }

    @Test func cancellingBatchDuringFirstPaidCallPreventsLaterPosts() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader())
        await fake.setOnCall {
            if let batchID = try? await store.listLibrary().first?.batchID {
                _ = try? await service.cancelBatch(batchID: batchID)
            }
        }
        let request = try await input(root, store, dirs, candidates: 3)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let batch = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 1)
        #expect(try await store.getJob(id: batch.jobIDs[0])?.state == .success)
        #expect(try await store.getJob(id: batch.jobIDs[1])?.state == .cancelled)
        #expect(try await store.getJob(id: batch.jobIDs[2])?.state == .cancelled)
        try await store.close()
    }

    @Test func cancellingSubmitTaskDuringFirstCallStopsQueuedCandidates() async throws {
        let (root, store, dirs, assets, fake, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = GenerationService(store: store, directories: dirs, assets: assets, synthesizer: fake,
                                        downloader: FakeAudioDownloader())
        await fake.setOnCall { withUnsafeCurrentTask { $0?.cancel() } }
        let request = try await input(root, store, dirs, candidates: 3)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let batch = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().count == 1)
        #expect(try await store.getJob(id: batch.jobIDs[0])?.state == .success)
        #expect(try await store.getJob(id: batch.jobIDs[1])?.state == .cancelled)
        #expect(try await store.getJob(id: batch.jobIDs[2])?.state == .cancelled)
        try await store.close()
    }

    @Test func storedJobMessageRedactsURLSessionURLsAndBearerTokens() async throws {
        let (root, store, dirs, _, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let request = try await input(root, store, dirs)
        let plan = try await service.preflight(request)
        let authorization = try await service.confirm(plan)
        let batch = try await store.createBatch(authorization.submission)
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
        let authorization = try await service.confirm(plan)
        let batch = try await store.createBatch(authorization.submission)
        let id = batch.jobIDs[0]
        #expect(try await service.cancelQueued(id))
        #expect(try await store.getJob(id: id)?.state == .cancelled)
        _ = try await service.submit(plan, confirmedHash: authorization.confirmationHash, clientRequestID: request.clientRequestID)
        #expect(await fake.calls().isEmpty)
        try await store.close()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval
    init(initialOffset: TimeInterval = 0) { offset = initialOffset }
    var date: Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
    func advance(by seconds: TimeInterval) { lock.lock(); offset += seconds; lock.unlock() }
}

private struct FakeAudioDownloader: AudioDownloading {
    var corrupt = false
    func download(_ receipt: ProviderResponseSnapshot) async throws -> Data {
        guard !corrupt else { return Data("invalid".utf8) }
        return Self.wav(frames: 4_800, channels: 2)
    }
    static func wav(frames: Int, channels: Int = 1) -> Data {
        let sampleRate = 48_000
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
