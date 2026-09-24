import Foundation
import Testing
@testable import StudioCore

final class PausedBookmarkResolution: DirectoryBookmarking, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    func create(for url: URL) throws -> Data { try FixtureBookmarks().create(for: url) }
    func resolve(_ data: Data) throws -> BookmarkResolution {
        entered.signal()
        guard proceed.wait(timeout: .now() + 10) == .success else { throw OutputDirectoryError.unavailable }
        return try FixtureBookmarks().resolve(data)
    }
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 10) == .success)
            }
        }
    }
    func resume() { proceed.signal() }
}

struct AssetRecoveryTests {
    @Test func storeCannotCloseWhileFileJobOwnsPendingJournal() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        let destination = lease.relativeDirectory! + "/pending-close.wav"
        try await f.store.journalFileOperation(FileOperation(id: UUID().uuidString, assetID: audio.id,
            sourceRelativePath: audio.relativePath, destinationRelativePath: destination, kind: .trash))
        let gate = PausedBookmarkResolution()
        let first = GeneratedAssetStore(store: f.store, directories: OutputDirectoryStore(store: f.store, bookmarks: gate))
        let pending = Task { try await first.reconcilePendingOperations() }
        #expect(await gate.waitUntilEntered())
        await #expect(throws: StudioStoreError.invalidTransition) { try await f.store.close() }
        #expect(try await f.store.pendingFileOperations().count == 1)
        gate.resume()
        try await pending.value
        #expect(try await f.store.getAsset(id: audio.id)?.relativePath == destination)
        #expect(try String(contentsOf: f.output.appendingPathComponent(destination), encoding: .utf8) == "owned")
        lease.close()
        try await f.store.close()
        try FileManager.default.removeItem(at: f.root)
    }

    @Test func twoReconcilersDoNotReplayOnePendingJournalTogether() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        let destination = lease.relativeDirectory! + "/recycled.wav"
        try await f.store.journalFileOperation(FileOperation(id: UUID().uuidString, assetID: audio.id,
            sourceRelativePath: audio.relativePath, destinationRelativePath: destination, kind: .trash))
        try Data("new user target".utf8).write(to: f.output.appendingPathComponent(destination))
        let gate = PausedBookmarkResolution()
        let first = GeneratedAssetStore(store: f.store, directories: OutputDirectoryStore(store: f.store, bookmarks: gate))
        let pending = Task { try await first.reconcilePendingOperations() }
        #expect(await gate.waitUntilEntered())
        await #expect(throws: StudioStoreError.invalidTransition) { try await assets.reconcilePendingOperations() }
        #expect(try await f.store.pendingFileOperations().count == 1)
        #expect(try await f.store.getAsset(id: audio.id)?.relativePath == audio.relativePath)
        gate.resume()
        try await pending.value
        let recorded = try #require(try await f.store.getAsset(id: audio.id))
        #expect(recorded.relativePath != destination)
        #expect(try String(contentsOf: f.output.appendingPathComponent(recorded.relativePath), encoding: .utf8) == "owned")
        #expect(try String(contentsOf: f.output.appendingPathComponent(destination), encoding: .utf8) == "new user target")
        lease.close()
        try await f.cleanup()
    }

    @Test func trashCannotCompeteWithPendingReconcile() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        _ = try await f.store.cancelQueued(id: job)
        let destination = lease.relativeDirectory! + "/pending-trash.wav"
        try await f.store.journalFileOperation(FileOperation(id: UUID().uuidString, assetID: audio.id,
            sourceRelativePath: audio.relativePath, destinationRelativePath: destination, kind: .trash))
        let gate = PausedBookmarkResolution()
        let first = GeneratedAssetStore(store: f.store, directories: OutputDirectoryStore(store: f.store, bookmarks: gate))
        let pending = Task { try await first.reconcilePendingOperations() }
        #expect(await gate.waitUntilEntered())
        await #expect(throws: StudioStoreError.invalidTransition) { try await assets.trash(job: job, scope: .generatedFiles) }
        gate.resume()
        try await pending.value
        #expect(try await f.store.getAsset(id: audio.id)?.relativePath == destination)
        #expect(try await f.store.listLibrary().contains { $0.id == job })
        #expect(try String(contentsOf: f.output.appendingPathComponent(destination), encoding: .utf8) == "owned")
        lease.close()
        try await f.cleanup()
    }

    @Test func restoreCannotCompeteWithPendingReconcile() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        _ = try await f.store.cancelQueued(id: job)
        try await assets.trash(job: job, scope: .generatedFiles)
        let recycled = try #require(try await f.store.getAsset(id: audio.id))
        let destination = audio.relativePath
        try await f.store.journalFileOperation(FileOperation(id: UUID().uuidString, assetID: audio.id,
            sourceRelativePath: recycled.relativePath, destinationRelativePath: destination, kind: .restore))
        let gate = PausedBookmarkResolution()
        let first = GeneratedAssetStore(store: f.store, directories: OutputDirectoryStore(store: f.store, bookmarks: gate))
        let pending = Task { try await first.reconcilePendingOperations() }
        #expect(await gate.waitUntilEntered())
        await #expect(throws: StudioStoreError.invalidTransition) { try await assets.restore(job: job) }
        gate.resume()
        try await pending.value
        #expect(try await f.store.getAsset(id: audio.id)?.relativePath == destination)
        #expect(try await f.store.listLibrary().isEmpty)
        #expect(try String(contentsOf: f.output.appendingPathComponent(destination), encoding: .utf8) == "owned")
        lease.close()
        try await f.cleanup()
    }

    @Test func movedTrashJournalFinishesWhenOriginalSourceIsReoccupied() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned audio".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        let destination = lease.relativeDirectory! + "/recycled.wav"
        let operation = FileOperation(id: "moved-trash", assetID: audio.id, sourceRelativePath: audio.relativePath, destinationRelativePath: destination, kind: .trash)
        try await f.store.journalFileOperation(operation)
        try FileManager.default.moveItem(at: f.output.appendingPathComponent(audio.relativePath), to: f.output.appendingPathComponent(destination))
        try Data("new user source".utf8).write(to: f.output.appendingPathComponent(audio.relativePath))
        try await assets.reconcilePendingOperations()
        #expect(try await f.store.pendingFileOperations().isEmpty)
        #expect(try await f.store.getAsset(id: audio.id)?.relativePath == destination)
        #expect(try await f.store.originalAssetPath(id: audio.id) == audio.relativePath)
        #expect(try String(contentsOf: f.output.appendingPathComponent(audio.relativePath), encoding: .utf8) == "new user source")
        #expect(try String(contentsOf: f.output.appendingPathComponent(destination), encoding: .utf8) == "owned audio")
        try await assets.restore(job: job)
        let recovered = try #require(try await f.store.getAsset(id: audio.id))
        #expect(recovered.relativePath != audio.relativePath)
        #expect(try String(contentsOf: f.output.appendingPathComponent(recovered.relativePath), encoding: .utf8) == "owned audio")
        lease.close()
        try await f.cleanup()
    }

    @Test func movedRestoreJournalFinishesWhenRecycleSourceIsReoccupied() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned audio".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        _ = try await f.store.cancelQueued(id: job)
        try await assets.trash(job: job, scope: .generatedFiles)
        let recycled = try #require(try await f.store.getAsset(id: audio.id))
        try await f.store.journalFileOperation(FileOperation(id: "moved-restore", assetID: audio.id, sourceRelativePath: recycled.relativePath, destinationRelativePath: audio.relativePath, kind: .restore))
        try FileManager.default.moveItem(at: f.output.appendingPathComponent(recycled.relativePath), to: f.output.appendingPathComponent(audio.relativePath))
        try Data("new recycle occupant".utf8).write(to: f.output.appendingPathComponent(recycled.relativePath))
        try await assets.restore(job: job)
        #expect(try await f.store.pendingFileOperations().isEmpty)
        #expect(try await f.store.getAsset(id: audio.id)?.relativePath == audio.relativePath)
        #expect(try await f.store.originalAssetPath(id: audio.id) == nil)
        #expect(try await f.store.listLibrary().contains { $0.id == job })
        #expect(try String(contentsOf: f.output.appendingPathComponent(recycled.relativePath), encoding: .utf8) == "new recycle occupant")
        #expect(try String(contentsOf: f.output.appendingPathComponent(audio.relativePath), encoding: .utf8) == "owned audio")
        lease.close()
        try await f.cleanup()
    }

    @Test func unconfirmedJournalPreservesPendingAndRecoveryMetadata() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned audio".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        let destination = lease.relativeDirectory! + "/recycled.wav"
        let operation = FileOperation(id: "unconfirmed", assetID: audio.id, sourceRelativePath: audio.relativePath, destinationRelativePath: destination, kind: .trash)
        try await f.store.journalFileOperation(operation)
        try FileManager.default.moveItem(at: f.output.appendingPathComponent(audio.relativePath), to: lease.url.appendingPathComponent("moved-by-user.wav"))
        for path in [audio.relativePath, destination] { try Data("user file".utf8).write(to: f.output.appendingPathComponent(path)) }
        await #expect(throws: OutputDirectoryError.invalidPath) { try await assets.reconcilePendingOperations() }
        #expect(try await f.store.pendingFileOperations() == [operation])
        #expect(try await f.store.originalAssetPath(id: audio.id) == audio.relativePath)
        for path in [audio.relativePath, destination] { #expect(try String(contentsOf: f.output.appendingPathComponent(path), encoding: .utf8) == "user file") }
        lease.close()
        try await f.cleanup()
    }
    @Test func writesRejectTraversalOverwriteAndClosedLeaseAndFinderRequiresRegistration() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        await #expect(throws: OutputDirectoryError.invalidPath) {
            try await assets.write(data: Data(), fileName: "../outside.wav", kind: "audio", job: job, lease: lease)
        }
        await #expect(throws: OutputDirectoryError.conflict) {
            try await assets.write(data: Data("overwrite".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        }
        #expect(try String(contentsOf: lease.url.appendingPathComponent("audio.wav"), encoding: .utf8) == "owned")
        await #expect(throws: OutputDirectoryError.unregistered) { try await assets.resolveRegisteredAsset("unknown") }
        let (revealLease, url) = try await assets.resolveRegisteredAsset(audio.id)
        #expect(url == f.output.appendingPathComponent(audio.relativePath))
        revealLease.close(); lease.close()
        await #expect(throws: OutputDirectoryError.closed) {
            try await assets.write(data: Data(), fileName: "closed.wav", kind: "audio", job: job, lease: lease)
        }
        try await f.cleanup()
    }
    @Test func interruptedRestoreWithNewConflictChoosesAnotherName() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned audio".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        _ = try await f.store.cancelQueued(id: job)
        try await assets.trash(job: job, scope: .generatedFiles)
        let recycled = try #require(try await f.store.getAsset(id: audio.id))
        try await f.store.journalFileOperation(FileOperation(id: "restore-before-crash", assetID: audio.id,
            sourceRelativePath: recycled.relativePath, destinationRelativePath: audio.relativePath, kind: .restore))
        try Data("user conflict".utf8).write(to: f.output.appendingPathComponent(audio.relativePath))
        try await assets.restore(job: job)
        let restored = try #require(try await f.store.getAsset(id: audio.id))
        #expect(restored.relativePath != audio.relativePath)
        #expect(try String(contentsOf: f.output.appendingPathComponent(restored.relativePath), encoding: .utf8) == "owned audio")
        #expect(try String(contentsOf: f.output.appendingPathComponent(audio.relativePath), encoding: .utf8) == "user conflict")
        #expect(try await f.store.pendingFileOperations().isEmpty)
        lease.close()
        try await f.cleanup()
    }
    @Test func recordOnlyRemovalLeavesAllFilesAndIsReversible() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let audio = try await assets.write(data: Data("synthetic audio".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        _ = try await f.store.cancelQueued(id: job)
        try await assets.trash(job: job, scope: .recordOnly)
        #expect(try await f.store.listLibrary().isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.output.appendingPathComponent(audio.relativePath).path))
        try await assets.restore(job: job)
        #expect(try await f.store.listLibrary().count == 1)
        lease.close()
        try await f.cleanup()
    }

    @Test func generatedFilesRecoverWithConflictsAndLeaveSentinelsAndExternalImports() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("synthetic audio".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        try await assets.writeSidecars(prompt: "中文  保留空格！", report: "合成测试报告", job: job, lease: lease)
        let sentinel = lease.url.appendingPathComponent("unregistered.txt")
        let external = f.output.appendingPathComponent("external.wav")
        try Data("sentinel".utf8).write(to: sentinel)
        try Data("external".utf8).write(to: external)
        try await f.store.registerAsset(StoredAsset(id: "external", jobID: job, directoryID: id, relativePath: "external.wav", kind: "audio", appOwned: false))
        _ = try await f.store.cancelQueued(id: job)
        try await assets.trash(job: job, scope: .generatedFiles)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "sentinel")
        #expect(try String(contentsOf: external, encoding: .utf8) == "external")
        let original = f.output.appendingPathComponent(audio.relativePath)
        try Data("conflicting user file".utf8).write(to: original)
        try await assets.restore(job: job)
        #expect(try String(contentsOf: original, encoding: .utf8) == "conflicting user file")
        let restored = try #require(try await f.store.listAssets(jobID: job).first { $0.id == audio.id })
        #expect(restored.relativePath != audio.relativePath)
        #expect(try String(contentsOf: f.output.appendingPathComponent(restored.relativePath), encoding: .utf8) == "synthetic audio")
        #expect(try String(contentsOf: lease.url.appendingPathComponent("prompt.txt"), encoding: .utf8) == "中文  保留空格！")
        #expect(try await f.store.pendingFileOperations().isEmpty)
        lease.close()
        try await f.cleanup()
    }

    @Test func replacedSymlinkAndParentSymlinkNeverMoveExternalSentinel() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("synthetic".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        let sentinel = f.root.appendingPathComponent("external-sentinel")
        try Data("never move".utf8).write(to: sentinel)
        let path = f.output.appendingPathComponent(audio.relativePath)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: sentinel)
        _ = try await f.store.cancelQueued(id: job)
        await #expect(throws: (any Error).self) { try await assets.trash(job: job, scope: .generatedFiles) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "never move")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == sentinel.path)
        lease.close()
        try await f.cleanup()
    }

    @Test func symlinkedParentAndReplacedRegularFileAreRejected() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("owned".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        _ = try await f.store.cancelQueued(id: job)
        let moved = f.root.appendingPathComponent("moved-folder")
        try FileManager.default.moveItem(at: lease.url, to: moved)
        try FileManager.default.createSymbolicLink(at: lease.url, withDestinationURL: moved)
        await #expect(throws: OutputDirectoryError.invalidPath) { try await assets.trash(job: job, scope: .generatedFiles) }
        #expect(try String(contentsOf: moved.appendingPathComponent("audio.wav"), encoding: .utf8) == "owned")
        try FileManager.default.removeItem(at: lease.url)
        try FileManager.default.moveItem(at: moved, to: lease.url)
        let replacement = lease.url.appendingPathComponent("replacement.wav")
        try Data("user replacement".utf8).write(to: replacement)
        let audioURL = f.output.appendingPathComponent(audio.relativePath)
        try FileManager.default.removeItem(at: audioURL)
        try FileManager.default.moveItem(at: replacement, to: audioURL)
        await #expect(throws: OutputDirectoryError.invalidPath) { try await assets.trash(job: job, scope: .generatedFiles) }
        #expect(try String(contentsOf: audioURL, encoding: .utf8) == "user replacement")
        lease.close()
        try await f.cleanup()
    }

    @Test func pendingMoveReconcilesBeforeAndAfterFilesystemMove() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let lease = try await f.directories.resolveForJob(job, directoryID: id)
        let assets = GeneratedAssetStore(store: f.store, directories: f.directories)
        let audio = try await assets.write(data: Data("recoverable".utf8), fileName: "audio.wav", kind: "audio", job: job, lease: lease)
        let destination = lease.relativeDirectory! + "/recoverable.wav"
        let operation = FileOperation(id: "interrupted-trash", assetID: audio.id, sourceRelativePath: audio.relativePath, destinationRelativePath: destination, kind: .trash)
        try await f.store.journalFileOperation(operation)
        try await assets.reconcilePendingOperations()
        #expect(try await f.store.pendingFileOperations().isEmpty)
        let restore = FileOperation(id: "interrupted-restore", assetID: audio.id, sourceRelativePath: destination, destinationRelativePath: audio.relativePath, kind: .restore)
        try await f.store.journalFileOperation(restore)
        try FileManager.default.moveItem(at: f.output.appendingPathComponent(destination), to: f.output.appendingPathComponent(audio.relativePath))
        lease.close()
        try await f.store.close()
        let reopened = try StudioStore(dataRoot: f.root.appendingPathComponent("metadata"))
        let reopenedAssets = GeneratedAssetStore(store: reopened, directories: OutputDirectoryStore(store: reopened, bookmarks: FixtureBookmarks()))
        try await reopenedAssets.reconcilePendingOperations()
        #expect(try await reopened.pendingFileOperations().isEmpty)
        #expect(try await reopened.listAssets(jobID: job).first?.relativePath == audio.relativePath)
        #expect(try String(contentsOf: f.output.appendingPathComponent(audio.relativePath), encoding: .utf8) == "recoverable")
        try await reopened.close()
        try FileManager.default.removeItem(at: f.root)
    }
}
