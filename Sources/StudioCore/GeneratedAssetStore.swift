import Foundation
public enum AssetRemovalScope: String, Codable, Sendable { case recordOnly, generatedFiles }
public struct RegisteredStorageUsage: Sendable {
    public let bytes: Int64
    public let unavailableCount: Int
}
public actor GeneratedAssetStore {
    private let store: StudioStore
    private let directories: OutputDirectoryStore
    public init(store: StudioStore, directories: OutputDirectoryStore) { self.store = store; self.directories = directories }

    /// Counts only app-owned registered assets, including files in the app's
    /// recycle area. Unregistered user files in the selected folder are ignored.
    public func registeredStorageBytes() async throws -> RegisteredStorageUsage {
        var bytes: Int64 = 0
        var unavailable = 0
        for asset in try await store.listRegisteredAssets() where asset.appOwned {
            guard let identity = asset.fileIdentity else { unavailable += 1; continue }
            do {
                let lease = try await directories.resolve(asset.directoryID)
                defer { lease.close() }
                bytes += try lease.withAccess { try $0.size(asset.relativePath, expected: identity) }
            } catch { unavailable += 1 }
        }
        return RegisteredStorageUsage(bytes: bytes, unavailableCount: unavailable)
    }

    public func write(data: Data, fileName: String, kind: String, job: String, lease: DirectoryLease) async throws -> StoredAsset {
        guard try ScopedFileAccess.components(fileName).count == 1,
              lease.jobID == job, let folder = try await store.jobOutputFolder(jobID: job),
              folder.directoryID == lease.directoryID, folder.relativePath == lease.relativeDirectory else { throw OutputDirectoryError.invalidPath }
        let path = folder.relativePath + "/" + fileName
        let identity = try lease.withAccess {
            guard try $0.identity(folder.relativePath, directory: true) == folder.identity else { throw OutputDirectoryError.invalidPath }
            return try $0.write(data, path: path)
        }
        let asset = StoredAsset(id: "asset_" + UUID().uuidString, jobID: job, directoryID: lease.directoryID,
            relativePath: path, kind: kind, appOwned: true, fileIdentity: identity)
        // A failed metadata commit leaves a visible unregistered file. Recovery
        // never guesses ownership or moves it; surface the failure to the caller.
        try await store.registerAsset(asset)
        return asset
    }
    public func writeSidecars(prompt: String, report: String, job: String, lease: DirectoryLease) async throws {
        _ = try await write(data: Data(prompt.utf8), fileName: "prompt.txt", kind: "prompt", job: job, lease: lease)
        _ = try await write(data: Data(report.utf8), fileName: "report.txt", kind: "report", job: job, lease: lease)
    }
    public func trash(job: String, scope: AssetRemovalScope) async throws {
        try await store.withFileJob(job) { try await self.trashClaimed(job: job, scope: scope) }
    }
    private func trashClaimed(job: String, scope: AssetRemovalScope) async throws {
        guard let item = try await store.getJob(id: job), item.state.isTerminal else { throw StudioStoreError.invalidTransition }
        try await reconcile(job: job)
        if scope == .generatedFiles {
            for asset in try await store.listAssets(jobID: job) where asset.appOwned {
                if try await store.originalAssetPath(id: asset.id) != nil { continue }
                let lease = try await directories.resolve(asset.directoryID); defer { lease.close() }
                guard let identity = asset.fileIdentity else { throw OutputDirectoryError.invalidPath }
                let destination = ".QwenAudioStudio-Recycle/" + UUID().uuidString + "/" + URL(fileURLWithPath: asset.relativePath).lastPathComponent
                try lease.withAccess {
                    guard try $0.identity(asset.relativePath) == identity else { throw OutputDirectoryError.invalidPath }
                    try $0.ensureDirectory(".QwenAudioStudio-Recycle")
                    _ = try $0.mkdir(String(destination.split(separator: "/").dropLast().joined(separator: "/")))
                }
                try await move(asset: asset, to: destination, kind: .trash, lease: lease)
            }
        }
        try await store.removeJobRecord(id: job, scope: scope)
    }
    public func restore(job: String) async throws {
        try await store.withFileJob(job) { try await self.restoreClaimed(job: job) }
    }
    private func restoreClaimed(job: String) async throws {
        try await reconcile(job: job)
        for asset in try await store.listAssets(jobID: job) where asset.appOwned {
            guard let original = try await store.originalAssetPath(id: asset.id) else { continue }
            let lease = try await directories.resolve(asset.directoryID); defer { lease.close() }
            // Parent must still be an ordinary directory; never recreate a missing
            // or symlinked user folder and never overwrite an existing target.
            let destination = try lease.withAccess { access -> String in
                if try !access.exists(original) { return original }
                let url = URL(fileURLWithPath: original)
                let suffix = "-恢复-" + UUID().uuidString
                let name = url.deletingPathExtension().lastPathComponent + suffix + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
                let parent = original.split(separator: "/").dropLast().joined(separator: "/")
                return parent.isEmpty ? name : parent + "/" + name
            }
            try await move(asset: asset, to: destination, kind: .restore, lease: lease)
        }
        try await store.restoreJobRecord(id: job)
    }
    private func move(asset: StoredAsset, to destination: String, kind: FileOperation.Kind, lease: DirectoryLease) async throws {
        guard let identity = asset.fileIdentity else { throw OutputDirectoryError.invalidPath }
        let operation = FileOperation(id: UUID().uuidString, assetID: asset.id, sourceRelativePath: asset.relativePath, destinationRelativePath: destination, kind: kind)
        try await store.journalFileOperation(operation)
        do { try lease.withAccess { try $0.move(source: asset.relativePath, destination: destination, identity: identity) } }
        catch {
            try await store.finishFileOperation(id: operation.id, error: "文件未移动；请检查目录授权、文件是否被替换或同名冲突。")
            throw error
        }
        // Keep pending if this commit fails: reconcile checks the moved inode.
        try await store.finishFileOperation(id: operation.id)
    }
    /// Resume local journal entries after a crash, never any generation request.
    /// Unavailable disks keep entries pending for explicit retry after reconnect.
    public func reconcilePendingOperations() async throws {
        var jobs: Set<String> = []
        for operation in try await store.pendingFileOperations() {
            guard let asset = try await store.getAsset(id: operation.assetID), asset.appOwned,
                  asset.fileIdentity != nil else { throw OutputDirectoryError.invalidPath }
            jobs.insert(asset.jobID)
        }
        for job in jobs.sorted() {
            try await store.withFileJob(job) { try await self.reconcile(job: job) }
        }
    }
    private func reconcile(job: String?) async throws {
        for operation in try await store.pendingFileOperations() {
            guard let asset = try await store.getAsset(id: operation.assetID), asset.appOwned,
                  let identity = asset.fileIdentity else { throw OutputDirectoryError.invalidPath }
            if let job, asset.jobID != job { continue }
            let lease = try await directories.resolve(asset.directoryID); defer { lease.close() }
            let targetMatches = try lease.withAccess { access in
                // A completed rename remains completed when a user subsequently
                // occupies the old path. Never infer ownership from existence.
                (try? access.identity(operation.destinationRelativePath)) == identity
            }
            if targetMatches {
                try await store.finishFileOperation(id: operation.id)
                continue
            }
            let targetOccupied = try lease.withAccess { access in
                guard (try? access.identity(operation.sourceRelativePath)) == identity else { throw OutputDirectoryError.invalidPath }
                return try access.exists(operation.destinationRelativePath)
            }
            let resumed: FileOperation
            if targetOccupied {
                resumed = try await store.retargetPendingFileOperation(id: operation.id,
                    destinationRelativePath: operation.destinationRelativePath + "-恢复-" + UUID().uuidString)
            } else { resumed = operation }
            // On any uncertain result leave this journal pending and preserve its
            // original recovery path, so a subsequent run can inspect identities.
            try lease.withAccess { try $0.move(source: resumed.sourceRelativePath, destination: resumed.destinationRelativePath, identity: identity) }
            try await store.finishFileOperation(id: operation.id)
        }
    }
    /// Finder consumers get a lease, and must keep it until reveal completes.
    public func resolveRegisteredAsset(_ id: String) async throws -> (DirectoryLease, URL) {
        guard let asset = try await store.getAsset(id: id) else { throw OutputDirectoryError.unregistered }
        let lease = try await directories.resolve(asset.directoryID)
        do {
            try lease.withAccess { access in
                let actual = try access.identity(asset.relativePath)
                if let expected = asset.fileIdentity, actual != expected { throw OutputDirectoryError.invalidPath }
            }
            return (lease, lease.rootURL.appendingPathComponent(asset.relativePath))
        } catch { lease.close(); throw error }
    }
    public func readRegisteredAudio(_ id: String) async throws -> Data {
        guard let asset = try await store.getAsset(id: id), asset.kind == "audio",
              let identity = asset.fileIdentity else { throw OutputDirectoryError.unregistered }
        let lease = try await directories.resolve(asset.directoryID)
        defer { lease.close() }
        return try lease.withAccess { try $0.read(asset.relativePath, expected: identity, maximumBytes: 256 * 1024 * 1024) }
    }
    public func decodeRegisteredAudio(_ id: String) async throws -> DecodedAudio {
        guard let asset = try await store.getAsset(id: id), asset.kind == "audio" else { throw OutputDirectoryError.unregistered }
        let bytes = try await readRegisteredAudio(id)
        if URL(fileURLWithPath: asset.relativePath).pathExtension.lowercased() == "pcm" {
            guard let job = try await store.getJob(id: asset.jobID),
                  let batch = try await store.getBatch(id: job.batchID) else { throw AudioDecodeError.invalidAudio }
            let params = try await store.legacyJobSnapshot(id: job.id)?.params ?? batch.submission.project.fields.params
            guard params.format == "pcm" else { throw AudioDecodeError.invalidAudio }
            return try AudioDecoder.decode(data: bytes, rawPCMFormat: RawPCMFormat(sampleRate: params.sampleRate, channels: params.channels))
        }
        return try AudioDecoder.decode(data: bytes)
    }
}
