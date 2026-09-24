import Foundation

/// Owns the access grant until close/deinit. Callers must retain the lease for the
/// entire paid request, download and write pipeline; a bare URL grants no access.
public final class DirectoryLease: @unchecked Sendable {
    public let directoryID: String
    public let rootURL: URL
    public let url: URL
    public let jobID: String?
    public let relativeDirectory: String?
    private let lock = NSLock()
    private var access: ScopedFileAccess?
    private var release: (@Sendable () -> Void)?
    init(directoryID: String, rootURL: URL, jobID: String? = nil, relativeDirectory: String? = nil,
         access: ScopedFileAccess, release: @escaping @Sendable () -> Void) {
        self.directoryID = directoryID; self.rootURL = rootURL; self.jobID = jobID
        self.relativeDirectory = relativeDirectory
        self.url = relativeDirectory.map { rootURL.appendingPathComponent($0, isDirectory: true) } ?? rootURL
        self.access = access; self.release = release
    }
    func withAccess<T>(_ operation: (ScopedFileAccess) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let access else { throw OutputDirectoryError.closed }
        return try operation(access)
    }
    public func close() {
        lock.lock(); let stop = release; release = nil; access = nil; lock.unlock()
        stop?()
    }
    deinit { close() }
}
public actor OutputDirectoryStore {
    private let store: StudioStore
    private let bookmarks: any DirectoryBookmarking
    public init(store: StudioStore, bookmarks: any DirectoryBookmarking = SecurityScopedBookmarks()) {
        self.store = store; self.bookmarks = bookmarks
    }
    public func register(selectedURL: URL) async throws -> String {
        guard selectedURL.isFileURL else { throw OutputDirectoryError.invalidPath }
        let started = bookmarks.start(selectedURL)
        defer { if started { bookmarks.stop(selectedURL) } }
        let access = try ScopedFileAccess(url: selectedURL)
        try access.probe()
        let data = try bookmarks.create(for: selectedURL)
        let id = "dir_" + UUID().uuidString
        try await store.saveDirectory(DirectorySnapshot(id: id, version: 1, bookmark: data, rootIdentity: try access.rootIdentity()))
        return id
    }
    public func setDefault(_ id: String) async throws {
        let lease = try await resolve(id); defer { lease.close() }
        try await store.setDefaultDirectory(id: id)
    }
    public func reauthorize(directoryID: String, selectedURL: URL) async throws {
        if directoryID.hasPrefix("legacy_dir_") { throw OutputDirectoryError.unavailable }
        guard selectedURL.isFileURL else { throw OutputDirectoryError.invalidPath }
        guard let snapshot = try await store.getDirectory(id: directoryID) else { throw OutputDirectoryError.unregistered }
        let started = bookmarks.start(selectedURL)
        defer { if started { bookmarks.stop(selectedURL) } }
        let access = try ScopedFileAccess(url: selectedURL)
        let identity = try access.rootIdentity()
        if let expected = snapshot.rootIdentity {
            guard identity == expected else { throw OutputDirectoryError.directoryMismatch }
        } else {
            guard try await provesLegacyDirectory(directoryID, access: access) else { throw OutputDirectoryError.directoryMismatch }
        }
        // Verify the newly created grant before changing the old record. A
        // cancelled picker, wrong folder or failed grant leaves ID/version intact.
        let data = try bookmarks.create(for: selectedURL)
        let resolved = try bookmarks.resolve(data)
        guard bookmarks.start(resolved.url) else { throw OutputDirectoryError.reauthorizationRequired }
        defer { bookmarks.stop(resolved.url) }
        let reopened = try ScopedFileAccess(url: resolved.url)
        guard try reopened.rootIdentity() == identity else { throw OutputDirectoryError.directoryMismatch }
        try reopened.probe()
        try await store.replaceDirectory(DirectorySnapshot(id: directoryID, version: snapshot.version + 1,
            bookmark: data, rootIdentity: identity), expected: snapshot)
    }
    private func provesLegacyDirectory(_ id: String, access: ScopedFileAccess) async throws -> Bool {
        for folder in try await store.listJobOutputFolders(directoryID: id) {
            if (try? access.identity(folder.relativePath, directory: true)) == folder.identity { return true }
        }
        let pending = try await store.pendingFileOperations()
        for asset in try await store.listAssets(directoryID: id) where asset.appOwned {
            guard let identity = asset.fileIdentity else { continue }
            // An interrupted move may already have reached its destination while
            // the stored asset still names its old path, now occupied by a user.
            let targets = pending.filter { $0.assetID == asset.id }.map(\.destinationRelativePath) + [asset.relativePath]
            if targets.contains(where: { (try? access.identity($0)) == identity }) { return true }
        }
        return false
    }
    public func defaultDirectoryID() async throws -> String? { try await store.defaultDirectoryID() }
    public func applySelection(_ url: URL?, currentID: String?) async throws -> String? {
        guard let url else { return currentID }
        return try await register(selectedURL: url)
    }
    public func resolve(_ id: String) async throws -> DirectoryLease {
        guard let snapshot = try await store.getDirectory(id: id) else { throw OutputDirectoryError.unregistered }
        return try await open(snapshot)
    }
    private func open(_ snapshot: DirectorySnapshot, jobID: String? = nil, relativeDirectory: String? = nil) async throws -> DirectoryLease {
        if snapshot.id.hasPrefix("legacy_dir_"),
           let uuid = UUID(uuidString: String(snapshot.id.dropFirst("legacy_dir_".count))),
           snapshot.bookmark == Data("app-owned-legacy-v1".utf8) {
            let root = await store.applicationDataRoot().appendingPathComponent("LegacyAudio/import_\(uuid.uuidString)", isDirectory: true)
            let access = try ScopedFileAccess(url: root)
            guard try access.rootIdentity() == snapshot.rootIdentity else { throw OutputDirectoryError.directoryMismatch }
            return DirectoryLease(directoryID: snapshot.id, rootURL: root, jobID: jobID,
                relativeDirectory: relativeDirectory, access: access, release: {})
        }
        let result = try bookmarks.resolve(snapshot.bookmark)
        guard bookmarks.start(result.url) else { throw OutputDirectoryError.reauthorizationRequired }
        do {
            let access = try ScopedFileAccess(url: result.url)
            let identity = try access.rootIdentity()
            if let expected = snapshot.rootIdentity, expected != identity { throw OutputDirectoryError.directoryMismatch }
            if result.stale || snapshot.rootIdentity == nil {
                let refreshed = result.stale ? try bookmarks.create(for: result.url) : snapshot.bookmark
                try await store.replaceDirectory(DirectorySnapshot(id: snapshot.id, version: snapshot.version + 1,
                    bookmark: refreshed, rootIdentity: identity), expected: snapshot)
            }
            let provider = bookmarks
            return DirectoryLease(directoryID: snapshot.id, rootURL: result.url, jobID: jobID,
                relativeDirectory: relativeDirectory, access: access, release: { provider.stop(result.url) })
        } catch { bookmarks.stop(result.url); throw error }
    }
    /// Final pre-POST gate: resolve grant, exclusively reserve a UUID directory,
    /// persist its identity and actually write+fsync a probe there.
    public func resolveForJob(_ job: String, directoryID: String) async throws -> DirectoryLease {
        guard let storedJob = try await store.getJob(id: job),
              let batch = try await store.getBatch(id: storedJob.batchID),
              batch.submission.directory.id == directoryID,
              let snapshot = try await store.getDirectory(id: directoryID) else { throw OutputDirectoryError.unregistered }
        let root = try await open(snapshot); defer { root.close() }
        let folder: JobOutputFolder
        if let existing = try await store.jobOutputFolder(jobID: job) { folder = existing }
        else {
            let name = "Qwen-" + UUID().uuidString
            let identity = try root.withAccess { try $0.mkdir(name) }
            let candidate = JobOutputFolder(jobID: job, directoryID: directoryID, relativePath: name, identity: identity)
            do {
                folder = try await store.reserveJobOutputFolder(candidate)
                if folder != candidate { try root.withAccess { try $0.removeEmptyDirectory(name) } }
            } catch { try? root.withAccess { try $0.removeEmptyDirectory(name) }; throw error }
        }
        guard folder.directoryID == directoryID else { throw OutputDirectoryError.invalidPath }
        guard let refreshedSnapshot = try await store.getDirectory(id: directoryID) else { throw OutputDirectoryError.unregistered }
        let lease = try await open(refreshedSnapshot, jobID: job, relativeDirectory: folder.relativePath)
        do {
            try lease.withAccess {
                guard try $0.identity(folder.relativePath, directory: true) == folder.identity else { throw OutputDirectoryError.invalidPath }
                try $0.probe(folder.relativePath)
            }
            return lease
        } catch { lease.close(); throw error }
    }
    public func withResolvedDirectory<T: Sendable>(_ id: String, operation: @Sendable (DirectoryLease) async throws -> T) async throws -> T {
        let lease = try await resolve(id); defer { lease.close() }
        return try await operation(lease)
    }
}
