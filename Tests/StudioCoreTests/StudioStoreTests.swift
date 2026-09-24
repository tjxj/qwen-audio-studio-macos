import Foundation
import Testing
import SQLite3
import Darwin
@testable import StudioCore

struct StudioStoreTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("studio-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func submission(_ store: StudioStore, requestID: String = UUID().uuidString,
                            seeds: [Int] = [10, 20, 30]) async throws -> BatchSubmission {
        let directory = DirectorySnapshot(id: "folder", version: 1, bookmark: Data("synthetic-bookmark".utf8))
        try await store.saveDirectory(directory)
        let reference = ReferenceSnapshot(id: "voice", contentHash: "synthetic-hash", fileName: "synthetic.wav", duration: 2)
        try await store.saveReference(reference)
        let draft = try await store.createProject(fields: DraftFields(prompt: "合成测试 @voice1", referenceBindings: [ReferenceBinding(referenceID: reference.id, alias: "讲述", slot: 1)], outputDirectoryID: directory.id))
        let compiled = try PromptCompiler.compile(mode: draft.fields.mode, prompt: draft.fields.prompt, bindings: draft.fields.referenceBindings)
        return BatchSubmission(clientRequestID: requestID, project: draft, compiledPrompt: compiled.text,
                               candidateSeeds: seeds, directory: directory, references: [reference],
                               consent: UploadConsent(clientRequestID: requestID, references: [reference], confirmed: true))
    }

    @Test func revisionConflictAndLegacyStringIDSurviveCloseAndReopen() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let draft = try await store.createProject(id: "proj_legacy-测试", fields: DraftFields(prompt: "原文"))
        var fields = draft.fields; fields.prompt = "保留空格  标点！' SQL --"
        let saved = try await store.saveProject(id: draft.id, expectedRevision: 1, changes: fields)
        #expect(saved.revision == 2)
        await #expect(throws: DraftStoreError.conflict) { try await store.saveProject(id: draft.id, expectedRevision: 1, changes: draft.fields) }
        try await store.close()
        let reopened = try StudioStore(dataRoot: url)
        #expect(try await reopened.getProject(id: draft.id) == saved)
        #expect(try await reopened.listProjects() == [saved])
        let adapter: any DraftStore = SQLiteDraftStore(store: reopened)
        var updated = saved; updated.fields.name = "再次保存"
        #expect(try await adapter.save(updated, expectedRevision: 2).revision == 3)
        try await reopened.close()
    }

    @Test func duplicateRequestsAreIdempotentAndChangedBodiesConflict() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, requestID: "request-stable")
        let batch = try await store.createBatch(input)
        #expect(try await store.createBatch(input) == batch)
        let changed = BatchSubmission(clientRequestID: input.clientRequestID, project: input.project,
                                     compiledPrompt: input.compiledPrompt, candidateSeeds: [99], directory: input.directory,
                                     references: input.references, consent: input.consent)
        await #expect(throws: StudioStoreError.requestConflict) { try await store.createBatch(changed) }
        #expect(try await store.listLibrary().count == 3)
        #expect(try await store.activeLeaseCount(referenceID: "voice") == 3)
        try await store.close()
        let reopened = try StudioStore(dataRoot: url)
        #expect(try await reopened.createBatch(input) == batch)
        #expect(try await reopened.listLibrary().count == 3)
        try await reopened.close()
    }

    @Test func failingThirdInsertRollsBackBatchJobsConsentsAndLeases() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store)
        // A real SQLite trigger fails after earlier candidate rows and leases have been inserted.
        let raw = try SQLiteConnection(url: url.appendingPathComponent("studio.sqlite"))
        try raw.execute("CREATE TRIGGER reject_third BEFORE INSERT ON jobs WHEN NEW.candidate_index = 2 BEGIN SELECT RAISE(ABORT, 'synthetic disk failure'); END")
        await #expect(throws: (any Error).self) { try await store.createBatch(input) }
        for table in ["batches", "jobs", "upload_consents", "reference_leases"] {
            #expect(try raw.rows("SELECT COUNT(*) FROM \(table)").first?.first?.int == 0)
        }
        try raw.execute("DROP TRIGGER reject_third")
        #expect(try await store.createBatch(input).jobIDs.count == 3)
        try await store.close()
    }

    @Test func submissionRechecksRevisionDirectoryReferenceAndConsent() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store)
        try await store.saveDirectory(DirectorySnapshot(id: "folder", version: 2, bookmark: Data("changed".utf8)))
        await #expect(throws: StudioStoreError.staleDirectory) { try await store.createBatch(input) }
        try await store.saveDirectory(input.directory)
        try await store.saveReference(ReferenceSnapshot(id: "voice", contentHash: "changed", fileName: "synthetic.wav", duration: 2))
        await #expect(throws: StudioStoreError.staleReference) { try await store.createBatch(input) }
        try await store.saveReference(input.references[0])
        let unconfirmed = BatchSubmission(clientRequestID: "other", project: input.project, compiledPrompt: input.compiledPrompt,
                                         candidateSeeds: [10], directory: input.directory, references: input.references, consent: input.consent)
        await #expect(throws: StudioStoreError.missingConsent) { try await store.createBatch(unconfirmed) }
        _ = try await store.saveProject(id: input.project.id, expectedRevision: 1, changes: input.project.fields)
        await #expect(throws: DraftStoreError.conflict) { try await store.createBatch(input) }
        #expect(try await store.listLibrary().isEmpty)
        try await store.close()
    }

    @Test func candidateValidationDoesNotPersistPartialData() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        for seeds in [[], [1, 1], [1, 2, 3, 4]] {
            let input = try await submission(store, seeds: seeds)
            await #expect(throws: StudioStoreError.invalidSubmission) { try await store.createBatch(input) }
        }
        #expect(try await store.listLibrary().isEmpty)
        try await store.close()
    }

    @Test func uploadConsentExpiresAfterTenMinutesAndRejectsFutureConfirmation() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        // Decode test fixtures so the first RED remains executable against the old model,
        // which silently ignores these missing consent timestamps.
        func withConfirmation(_ secondsFromNow: Double, lifetime: Double = 600) throws -> BatchSubmission {
            var json = try #require(JSONSerialization.jsonObject(with: storeEncode(input)) as? [String: Any])
            var consent = try #require(json["consent"] as? [String: Any])
            let confirmed = Date().addingTimeInterval(secondsFromNow)
            consent["confirmedAt"] = confirmed.timeIntervalSinceReferenceDate
            consent["expiresAt"] = confirmed.addingTimeInterval(lifetime).timeIntervalSinceReferenceDate
            json["consent"] = consent
            return try JSONDecoder().decode(BatchSubmission.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let expired = try withConfirmation(-601)
        await #expect(throws: StudioStoreError.expiredConsent) { try await store.createBatch(expired) }
        let future = try withConfirmation(60)
        await #expect(throws: StudioStoreError.expiredConsent) { try await store.createBatch(future) }
        let overlong = try withConfirmation(-1, lifetime: 3600)
        await #expect(throws: StudioStoreError.expiredConsent) { try await store.createBatch(overlong) }
        #expect(try await store.listLibrary().isEmpty)
        #expect(try await store.activeLeaseCount(referenceID: "voice") == 0)
        #expect(input.consent.expiresAt.timeIntervalSince(input.consent.confirmedAt) == 600)
        _ = try await store.createBatch(input)
        let raw = try SQLiteConnection(url: url.appendingPathComponent("studio.sqlite"))
        #expect(try raw.rows("SELECT expires_at_ms-confirmed_at_ms FROM upload_consents").first?.first?.int == 600000)
        try await store.close()
    }

    @Test func claimAndCancelRaceHasExactlyOneWinner() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        for _ in 0..<30 {
            let input = try await submission(store, seeds: [10])
            let batch = try await store.createBatch(input)
            let id = try #require(batch.jobIDs.first)
            async let claimed = store.claimJob(id: id)
            async let cancelled = store.cancelQueued(id: id)
            let (claim, cancel) = try await (claimed, cancelled)
            #expect((claim != nil) != cancel)
            #expect(try await store.getJob(id: id)?.state == (cancel ? .cancelled : .preparing))
            #expect(try await store.cancelQueued(id: id) == false)
            #expect(try await store.claimJob(id: id) == nil)
        }
        try await store.close()
    }

    @Test func restartInterruptsWithoutRetryAndDistinguishesUnknownOutcome() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store)
        let batch = try await store.createBatch(input)
        _ = try await store.claimJob(id: batch.jobIDs[0])
        #expect(try await store.transitionJob(id: batch.jobIDs[0], from: .preparing, to: .requesting))
        _ = try await store.claimJob(id: batch.jobIDs[1])
        #expect(try await store.transitionJob(id: batch.jobIDs[1], from: .preparing, to: .failed, message: "synthetic preflight failure"))
        #expect(throws: InstanceOwnershipError.alreadyOwned) { try StudioStore(dataRoot: url) }
        #expect(try await store.getJob(id: batch.jobIDs[0])?.state == .requesting)
        try await store.close()
        let reopened = try StudioStore(dataRoot: url)
        #expect(try await reopened.getJob(id: batch.jobIDs[0])?.state == .interrupted)
        #expect(try await reopened.getJob(id: batch.jobIDs[0])?.resultUncertain == true)
        #expect(try await reopened.getJob(id: batch.jobIDs[1])?.state == .failed)
        #expect(try await reopened.getJob(id: batch.jobIDs[1])?.resultUncertain == false)
        #expect(try await reopened.getJob(id: batch.jobIDs[2])?.state == .interrupted)
        #expect(try await reopened.activeLeaseCount(referenceID: "voice") == 0)
        #expect(try await reopened.claimJob(id: batch.jobIDs[0]) == nil)
        #expect(try await reopened.getBatch(id: batch.id)?.submission == input)
        try await reopened.close()
    }

    @Test func uncertainResultCannotBeClaimedOrCancelled() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let id = try #require(try await store.createBatch(input).jobIDs.first)
        _ = try await store.claimJob(id: id)
        #expect(try await store.transitionJob(id: id, from: .preparing, to: .requesting))
        #expect(try await store.markResultUncertain(id: id, message: "synthetic timeout"))
        #expect(try await store.getJob(id: id)?.resultUncertain == true)
        #expect(try await store.claimJob(id: id) == nil)
        #expect(try await store.cancelQueued(id: id) == false)
        #expect(try await store.activeLeaseCount(referenceID: "voice") == 0)
        try await store.close()
    }

    @Test func downloadingRequiresDurablyRecordedProviderResponse() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let id = try #require(try await store.createBatch(input).jobIDs.first)
        _ = try await store.claimJob(id: id)
        #expect(try await store.transitionJob(id: id, from: .preparing, to: .requesting))
        await #expect(throws: StudioStoreError.invalidTransition) {
            try await store.transitionJob(id: id, from: .requesting, to: .downloading)
        }
        #expect(try await store.getJob(id: id)?.state == .requesting)
        try await store.close()
    }

    @Test func providerResponseAndDownloadStageCommitTogetherAndSurviveRestart() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let id = try #require(try await store.createBatch(input).jobIDs.first)
        let response = ProviderResponseSnapshot(providerRequestID: "synthetic-request", audioURL: URL(string: "https://example.invalid/audio.wav?synthetic_signature=private")!)
        #expect(try await store.recordProviderResponse(id: id, response: response) == false)
        _ = try await store.claimJob(id: id)
        #expect(try await store.transitionJob(id: id, from: .preparing, to: .requesting))
        let raw = try SQLiteConnection(url: url.appendingPathComponent("studio.sqlite"))
        try raw.execute("CREATE TRIGGER reject_receipt BEFORE UPDATE ON jobs WHEN NEW.state='downloading' BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END")
        await #expect(throws: (any Error).self) { try await store.recordProviderResponse(id: id, response: response) }
        #expect(try await store.getJob(id: id)?.state == .requesting)
        #expect(try await store.providerResponse(id: id) == nil)
        try raw.execute("DROP TRIGGER reject_receipt")
        #expect(try await store.recordProviderResponse(id: id, response: response))
        #expect(try await store.getJob(id: id)?.state == .downloading)
        #expect(try await store.providerResponse(id: id) == response)
        #expect(!String(describing: response).contains("private"))
        #expect(!String(reflecting: response).contains("example.invalid"))
        #expect(!String(reflecting: try await store.listLibrary()).contains("example.invalid"))
        try await store.close()
        let reopened = try StudioStore(dataRoot: url)
        #expect(try await reopened.getJob(id: id)?.state == .interrupted)
        #expect(try await reopened.getJob(id: id)?.resultUncertain == false)
        #expect(try await reopened.providerResponse(id: id) == response)
        #expect(try await reopened.claimJob(id: id) == nil)
        async let first = reopened.claimDownloadRetry(id: id)
        async let second = reopened.claimDownloadRetry(id: id)
        let retries = try await [first, second]
        #expect(retries.compactMap { $0 }.count == 1)
        #expect(retries.compactMap { $0 }.first == response)
        #expect(try await reopened.getJob(id: id)?.state == .downloading)
        #expect(try await reopened.activeLeaseCount(referenceID: "voice") == 0)
        #expect(try await reopened.transitionJob(id: id, from: .downloading, to: .failed, message: "synthetic GET failure"))
        #expect(try await reopened.claimDownloadRetry(id: id) == response)
        #expect(try await reopened.transitionJob(id: id, from: .downloading, to: .validating))
        #expect(try await reopened.transitionJob(id: id, from: .validating, to: .success))
        #expect(try await reopened.claimDownloadRetry(id: id) == nil)
        try await reopened.close()
    }

    @Test func uncertainRequestHasNoDownloadRetryAndResponseRejectsNonHTTPS() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let id = try #require(try await store.createBatch(input).jobIDs.first)
        _ = try await store.claimJob(id: id)
        #expect(try await store.transitionJob(id: id, from: .preparing, to: .requesting))
        let invalid = ProviderResponseSnapshot(providerRequestID: "synthetic", audioURL: URL(string: "file:///synthetic.wav")!)
        await #expect(throws: StudioStoreError.invalidSubmission) { try await store.recordProviderResponse(id: id, response: invalid) }
        #expect(try await store.markResultUncertain(id: id, message: "synthetic disconnect"))
        #expect(try await store.claimDownloadRetry(id: id) == nil)
        #expect(try await store.providerResponse(id: id) == nil)
        try await store.close()
    }

    @Test func templateCRUDAndFavoritesPersist() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let templates = SQLiteTemplateStore(store: store)
        let builtin = try #require(try await templates.list().first)
        var user = StudioTemplate(id: "user-test", name: "测试模板", mode: .auto, promptPattern: "合成测试")
        try await templates.save(user)
        user.name = "更新模板"; try await templates.save(user)
        try await templates.setFavorite(id: builtin.id, favorite: true)
        try await templates.setFavorite(id: user.id, favorite: true)
        await #expect(throws: TemplateError.readOnly) { try await templates.save(builtin) }
        try await store.close()
        let reopened = try StudioStore(dataRoot: url)
        let persisted = SQLiteTemplateStore(store: reopened)
        #expect(try await persisted.list().count == 43)
        #expect(try await persisted.list().contains(user))
        #expect(try await persisted.favorites() == [builtin.id, user.id])
        try await persisted.remove(id: user.id)
        #expect(try await persisted.favorites() == [builtin.id])
        await #expect(throws: TemplateError.readOnly) { try await persisted.remove(id: builtin.id) }
        try await reopened.close()
    }

    @Test func assetsAndPendingFileJournalPersistWithoutMovingFiles() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let id = try #require(try await store.createBatch(input).jobIDs.first)
        let asset = StoredAsset(id: "asset", jobID: id, directoryID: "folder", relativePath: "job/audio.wav", kind: "audio", appOwned: true)
        try await store.registerAsset(asset)
        let operation = FileOperation(id: "move", assetID: asset.id, sourceRelativePath: asset.relativePath, destinationRelativePath: ".trash/unique/audio.wav", kind: .trash)
        try await store.journalFileOperation(operation)
        try await store.close()
        let reopened = try StudioStore(dataRoot: url)
        #expect(try await reopened.listAssets(jobID: id) == [asset])
        #expect(try await reopened.pendingFileOperations() == [operation])
        try await reopened.finishFileOperation(id: operation.id)
        #expect(try await reopened.pendingFileOperations().isEmpty)
        #expect(try await reopened.listAssets(jobID: id).first?.relativePath == operation.destinationRelativePath)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(asset.relativePath).path))
        try await reopened.close()
    }

    @Test func fileJournalRejectsExternalAssetsTraversalAndConcurrentMoves() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let jobID = try #require(try await store.createBatch(input).jobIDs.first)
        let external = StoredAsset(id: "external", jobID: jobID, directoryID: "folder", relativePath: "external.wav", kind: "audio", appOwned: false)
        try await store.registerAsset(external)
        await #expect(throws: StudioStoreError.invalidPath) {
            try await store.journalFileOperation(FileOperation(id: "external-move", assetID: external.id, sourceRelativePath: external.relativePath, destinationRelativePath: ".trash/external.wav", kind: .trash))
        }
        for path in ["../escape.wav", "/absolute.wav", "dir/../escape.wav", "dir//audio.wav"] {
            await #expect(throws: StudioStoreError.invalidPath) {
                try await store.registerAsset(StoredAsset(id: "invalid", jobID: jobID, directoryID: "folder", relativePath: path, kind: "audio", appOwned: true))
            }
        }
        let asset = StoredAsset(id: "owned", jobID: jobID, directoryID: "folder", relativePath: "job/audio.wav", kind: "audio", appOwned: true)
        try await store.registerAsset(asset)
        let operation = FileOperation(id: "move-1", assetID: asset.id, sourceRelativePath: asset.relativePath, destinationRelativePath: ".trash/one.wav", kind: .trash)
        try await store.journalFileOperation(operation)
        await #expect(throws: StudioStoreError.invalidTransition) {
            try await store.journalFileOperation(FileOperation(id: "move-2", assetID: asset.id, sourceRelativePath: asset.relativePath, destinationRelativePath: ".trash/two.wav", kind: .trash))
        }
        try await store.finishFileOperation(id: operation.id, error: "synthetic permission denial")
        #expect(try await store.listAssets(jobID: jobID).contains(asset))
        #expect(try await store.pendingFileOperations().isEmpty)
        try await store.close()
        await #expect(throws: StudioStoreError.closed) { try await store.listLibrary() }
    }

    @Test func leasedReferencesCannotChangeAndInvalidTransitionsNeverResubmit() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let batch = try await store.createBatch(input)
        let id = try #require(batch.jobIDs.first)
        await #expect(throws: StudioStoreError.staleReference) {
            try await store.saveReference(ReferenceSnapshot(id: "voice", contentHash: "changed", fileName: "synthetic.wav", duration: 2))
        }
        #expect(try await store.cancelQueued(id: id))
        #expect(try await store.activeLeaseCount(referenceID: "voice") == 0)
        await #expect(throws: StudioStoreError.invalidTransition) { try await store.transitionJob(id: id, from: .cancelled, to: .queued) }
        _ = try await store.saveProject(id: input.project.id, expectedRevision: 1, changes: DraftFields(prompt: "后续修改"))
        #expect(try await store.createBatch(input) == batch)
        try await store.close()
    }

    @Test func killedWriterLeavesCommittedRequestInterruptedAndUncommittedProjectAbsent() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let input = try await submission(store, seeds: [10])
        let batch = try await store.createBatch(input)
        try await store.close()
        let executable = try compileLockProbe(in: url)
        let child = Process(); child.executableURL = executable
        child.arguments = [url.appendingPathComponent("instance.lock").path, "crash-writer", url.appendingPathComponent("studio.sqlite").path]
        let ready = Pipe(); child.standardOutput = ready
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        #expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([82]))
        #expect(kill(child.processIdentifier, SIGKILL) == 0)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        let reopened = try StudioStore(dataRoot: url)
        #expect(try await reopened.getProject(id: "uncommitted-project") == nil)
        #expect(try await reopened.getJob(id: batch.jobIDs[0])?.state == .interrupted)
        #expect(try await reopened.getJob(id: batch.jobIDs[0])?.resultUncertain == true)
        #expect(try await reopened.activeLeaseCount(referenceID: "voice") == 0)
        #expect(try await reopened.getBatch(id: batch.id)?.submission == input)
        try await reopened.close()
    }

    @Test func databasePragmasAndUnknownSchemaAreChecked() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let store = try StudioStore(dataRoot: url)
        let raw = try SQLiteConnection(url: url.appendingPathComponent("studio.sqlite"))
        #expect(try raw.rows("PRAGMA journal_mode").first?.first?.string == "wal")
        #expect(try raw.rows("PRAGMA foreign_keys").first?.first?.int == 1)
        #expect(try raw.rows("PRAGMA synchronous").first?.first?.int == 2)
        #expect(try raw.rows("PRAGMA busy_timeout").first?.first?.int == 5000)
        try await store.close()
        try raw.execute("PRAGMA user_version = 999")
        #expect(throws: StudioStoreError.unsupportedSchema(999)) { try StudioStore(dataRoot: url) }
    }

    @Test func lifetimeLockAcrossProcessesAndAbandonedLockFile() async throws {
        let url = try root(); defer { try? FileManager.default.removeItem(at: url) }
        let executable = try compileLockProbe(in: url)
        func probe(_ hold: Bool = false) throws -> Process {
            let child = Process(); child.executableURL = executable
            child.arguments = [url.appendingPathComponent("instance.lock").path, hold ? "hold" : "probe"]
            return child
        }
        var owner: InstanceOwnership? = try InstanceOwnership.acquire(dataRoot: url)
        let loser = try probe(); try loser.run(); loser.waitUntilExit()
        #expect(loser.terminationStatus == 73)
        #expect(owner != nil); owner = nil
        let child = try probe(true); let ready = Pipe(); child.standardOutput = ready
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        #expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([82]))
        #expect(throws: InstanceOwnershipError.alreadyOwned) { try StudioStore(dataRoot: url) }
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("studio.sqlite").path))
        child.terminate(); child.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("instance.lock").path))
        let store = try StudioStore(dataRoot: url)
        try await store.close()
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("instance.lock").path))
    }

    private func compileLockProbe(in url: URL) throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/LockProbe.c")
        let executable = url.appendingPathComponent("lock-probe")
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-lsqlite3", "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit(); #expect(compiler.terminationStatus == 0)
        return executable
    }
}
