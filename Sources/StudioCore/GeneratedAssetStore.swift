import Foundation
public enum AssetRemovalScope: String, Codable, Sendable { case recordOnly, generatedFiles }
public actor GeneratedAssetStore {
    private let store: StudioStore
    private let directories: OutputDirectoryStore
    private var busyJobs: Set<String> = []
    public init(store: StudioStore, directories: OutputDirectoryStore) { self.store = store; self.directories = directories }

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
        guard busyJobs.insert(job).inserted else { throw StudioStoreError.invalidTransition }
        defer { busyJobs.remove(job) }
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
        guard busyJobs.insert(job).inserted else { throw StudioStoreError.invalidTransition }
        defer { busyJobs.remove(job) }
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
                return original.split(separator: "/").dropLast().joined(separator: "/") + "/" + name
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
        try await reconcile(job: nil)
    }
    private func reconcile(job: String?) async throws {
        for operation in try await store.pendingFileOperations() {
            guard let asset = try await store.getAsset(id: operation.assetID), asset.appOwned,
                  let identity = asset.fileIdentity else { throw OutputDirectoryError.invalidPath }
            if let job, asset.jobID != job { continue }
            let lease = try await directories.resolve(asset.directoryID); defer { lease.close() }
            let sourceExists = try lease.withAccess { try $0.exists(operation.sourceRelativePath) }
            if sourceExists, try lease.withAccess({ try $0.exists(operation.destinationRelativePath) }) {
                // The planned name was occupied while the app was stopped. Record
                // a fresh exclusive move, preserving the conflicting user's file.
                let destination = operation.destinationRelativePath + "-恢复-" + UUID().uuidString
                try await store.finishFileOperation(id: operation.id, error: "目标已存在，改用新的恢复名称。")
                try await move(asset: asset, to: destination, kind: operation.kind, lease: lease)
                continue
            }
            try lease.withAccess { access in
                if sourceExists {
                    try access.move(source: operation.sourceRelativePath, destination: operation.destinationRelativePath, identity: identity)
                } else {
                    guard try access.identity(operation.destinationRelativePath) == identity else { throw OutputDirectoryError.invalidPath }
                }
            }
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
}
