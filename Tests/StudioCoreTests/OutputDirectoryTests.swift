import Foundation
import Testing
@testable import StudioCore

struct OutputFixture {
    let root: URL
    let output: URL
    let store: StudioStore
    let directories: OutputDirectoryStore
    init(bookmarks: any DirectoryBookmarking = FixtureBookmarks()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        output = root.appendingPathComponent("中文 空格 输出", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        store = try StudioStore(dataRoot: root.appendingPathComponent("metadata"))
        directories = OutputDirectoryStore(store: store, bookmarks: bookmarks)
    }
    func cleanup() async throws {
        try await store.close()
        try FileManager.default.removeItem(at: root)
    }
    func job() async throws -> (String, String) {
        let directoryID = try await directories.register(selectedURL: output)
        let snapshot = try #require(try await store.getDirectory(id: directoryID))
        let project = try await store.createProject(fields: DraftFields(prompt: "合成测试", outputDirectoryID: directoryID))
        let request = UUID().uuidString
        let compiled = try PromptCompiler.compile(mode: project.fields.mode, prompt: project.fields.prompt, bindings: [])
        let batch = try await store.createBatch(BatchSubmission(clientRequestID: request, project: project,
            compiledPrompt: compiled.text, candidateSeeds: [1], directory: snapshot, references: [],
            consent: UploadConsent(clientRequestID: request, references: [], confirmed: true)))
        return (batch.jobIDs[0], directoryID)
    }
}

struct FixtureBookmarks: DirectoryBookmarking {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> BookmarkResolution {
        guard let path = String(data: data, encoding: .utf8), path.hasPrefix("/") else { throw OutputDirectoryError.reauthorizationRequired }
        return BookmarkResolution(url: URL(fileURLWithPath: path), stale: false)
    }
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
}

final class BookmarkAccessProbe: DirectoryBookmarking, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    private var closed = 0
    let stale: Bool
    let authorized: Bool
    init(stale: Bool = false, authorized: Bool = true) { self.stale = stale; self.authorized = authorized }
    var balance: Int { lock.lock(); defer { lock.unlock() }; return opened - closed }
    func create(for url: URL) throws -> Data { try FixtureBookmarks().create(for: url) }
    func resolve(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(url: try FixtureBookmarks().resolve(data).url, stale: stale)
    }
    func start(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if authorized { opened += 1 }
        return authorized
    }
    func stop(_ url: URL) { lock.lock(); closed += 1; lock.unlock() }
}

struct OutputDirectoryTests {
    @Test func staleBookmarkRefreshesAndLeaseKeepsAccessUntilClose() async throws {
        let probe = BookmarkAccessProbe(stale: true)
        let f = try OutputFixture(bookmarks: probe)
        let id = try await f.directories.register(selectedURL: f.output)
        #expect(probe.balance == 0)
        let lease = try await f.directories.resolve(id)
        #expect(probe.balance == 1)
        #expect(try await f.store.getDirectory(id: id)?.version == 2)
        try lease.withAccess { try $0.probe() }
        lease.close(); lease.close()
        #expect(probe.balance == 0)
        #expect(throws: OutputDirectoryError.closed) { try lease.withAccess { try $0.probe() } }
        try FileManager.default.removeItem(at: f.output)
        await #expect(throws: (any Error).self) { try await f.directories.resolve(id) }
        #expect(probe.balance == 0)
        try await f.cleanup()
    }

    @Test func deniedGrantNeverUsesReadablePlainLocation() async throws {
        let f = try OutputFixture(bookmarks: BookmarkAccessProbe(authorized: false))
        let id = try await f.directories.register(selectedURL: f.output)
        await #expect(throws: OutputDirectoryError.reauthorizationRequired) { try await f.directories.resolve(id) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.output.path).isEmpty)
        try await f.cleanup()
    }

    @Test func versionOneMetadataMigratesWithoutLosingProject() async throws {
        let f = try OutputFixture()
        let project = try await f.store.createProject(fields: DraftFields(prompt: "迁移保留"))
        try await f.store.close()
        let raw = try SQLiteConnection(url: f.root.appendingPathComponent("metadata/studio.sqlite"))
        for table in ["recycled_assets", "removed_jobs", "job_output_folders", "output_settings"] { try raw.execute("DROP TABLE \(table)") }
        try raw.execute("PRAGMA user_version = 1")
        try raw.close()
        let reopened = try StudioStore(dataRoot: f.root.appendingPathComponent("metadata"))
        #expect(try await reopened.getProject(id: project.id) == project)
        let dirs = OutputDirectoryStore(store: reopened, bookmarks: FixtureBookmarks())
        let id = try await dirs.register(selectedURL: f.output)
        try await dirs.setDefault(id)
        #expect(try await dirs.defaultDirectoryID() == id)
        try await reopened.close()
        try FileManager.default.removeItem(at: f.root)
    }
    @Test func nativeBookmarkSurvivesTwoIndependentProcessRestarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repo = tests.deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("bookmark-probe")
        func run(_ executable: URL, _ arguments: [String]) throws {
            let child = Process(); child.executableURL = executable; child.arguments = arguments
            try child.run()
            let deadline = Date().addingTimeInterval(30)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            #expect(child.terminationStatus == 0)
        }
        try run(URL(fileURLWithPath: "/usr/bin/swiftc"), [repo.appendingPathComponent("Sources/StudioCore/DirectoryBookmarks.swift").path,
            tests.appendingPathComponent("Fixtures/BookmarkProbe.swift").path, "-o", binary.path])
        try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", "--identifier", "studio.synthetic.bookmark-probe", binary.path])
        try run(binary, ["create", root.path])
        try run(binary, ["resolve", root.path])
        try run(binary, ["resolve", root.path])
    }
    @Test func nativeSecurityScopedBookmarkReopensWithinSameProcess() async throws {
        let f = try OutputFixture(bookmarks: SecurityScopedBookmarks())
        let id = try await f.directories.register(selectedURL: f.output)
        let lease = try await f.directories.resolve(id)
        #expect(lease.rootURL.resolvingSymlinksInPath() == f.output.resolvingSymlinksInPath())
        lease.close()
        try await f.cleanup()
    }
    @Test func cancellationPreservesSelectionAndDefaultSurvivesRestart() async throws {
        let f = try OutputFixture()
        let id = try await f.directories.register(selectedURL: f.output)
        try await f.directories.setDefault(id)
        #expect(try await f.directories.applySelection(nil, currentID: id) == id)
        #expect(try await f.directories.defaultDirectoryID() == id)
        try await f.store.close()
        let reopened = try StudioStore(dataRoot: f.root.appendingPathComponent("metadata"))
        let dirs = OutputDirectoryStore(store: reopened, bookmarks: FixtureBookmarks())
        #expect(try await dirs.defaultDirectoryID() == id)
        let lease = try await dirs.resolve(id)
        #expect(lease.rootURL.lastPathComponent == "中文 空格 输出")
        lease.close()
        try await reopened.close()
        try FileManager.default.removeItem(at: f.root)
    }

    @Test func jobDirectoriesAreUniqueReservedAndWritableBeforeSubmission() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        let one = try await f.directories.resolveForJob(job, directoryID: id)
        let two = try await f.directories.resolveForJob(job, directoryID: id)
        #expect(one.url == two.url)
        #expect(one.url.deletingLastPathComponent() == one.rootURL)
        let (otherJob, otherID) = try await f.job()
        let other = try await f.directories.resolveForJob(otherJob, directoryID: otherID)
        #expect(other.url != one.url)
        #expect(FileManager.default.fileExists(atPath: one.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: one.url.path).isEmpty)
        one.close(); two.close(); other.close()
        try await f.cleanup()
    }

    @Test func disconnectedReadOnlyAndUnregisteredFoldersNeverFallback() async throws {
        let f = try OutputFixture()
        let (job, id) = try await f.job()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.output.path)
        await #expect(throws: (any Error).self) { try await f.directories.resolveForJob(job, directoryID: id) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.output.path)
        try FileManager.default.removeItem(at: f.output)
        await #expect(throws: (any Error).self) { try await f.directories.resolveForJob(job, directoryID: id) }
        await #expect(throws: OutputDirectoryError.unregistered) { try await f.directories.resolve("unknown") }
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
        try await f.cleanup()
    }

    @Test func invalidBookmarkRequiresReselection() async throws {
        let f = try OutputFixture()
        try await f.store.saveDirectory(DirectorySnapshot(id: "invalid", version: 1, bookmark: Data([0])))
        await #expect(throws: OutputDirectoryError.reauthorizationRequired) { try await f.directories.resolve("invalid") }
        try await f.cleanup()
    }
}
