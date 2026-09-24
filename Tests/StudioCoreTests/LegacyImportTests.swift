import Foundation
import Testing
import SQLite3
import CryptoKit
import Darwin
@testable import StudioCore

struct LegacyImportTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func put(_ value: Any, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
    private func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    private func v1(_ source: URL, missing: Bool = false) throws -> URL {
        let audio = source.appendingPathComponent("output/synthetic.wav")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !missing { try Data("synthetic audio".utf8).write(to: audio) }
        try put(["id":"project-a", "name":"章节", "mode":"audiobook", "prompt":"从前", "revision":2,
                 "archived":true, "final_job_id":"job-a"], source.appendingPathComponent("projects/project-a.json"))
        try put(["id":"job-a", "project_id":"project-a", "display_name":"终稿", "note":"注意停顿", "favorite":true,
                 "status":"success", "output_asset_id":"asset-a", "params":["seed":17]], source.appendingPathComponent("jobs/job-a.json"))
        try put(["asset-a":["path":audio.path, "mime_type":"audio/wav"]], source.appendingPathComponent("assets.json"))
        return audio
    }

    @Test func v1PreviewAndImportKeepIDsMetadataAndSourceUnchanged() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let audio = try v1(source)
        let originals = [audio, source.appendingPathComponent("projects/project-a.json"), source.appendingPathComponent("jobs/job-a.json"), source.appendingPathComponent("assets.json")]
        let before = try originals.map { (try digest($0), try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.projects == 1 && preview.jobs == 1 && preview.assets == 1)
        let result = try await importer.import(source: source, preview: preview)
        #expect(result.importedProjects == 1 && result.importedJobs == 1 && result.copiedAssets == 1)
        #expect(try await store.getProject(id: "project-a")?.revision == 2)
        #expect(try await store.projectArchived(id: "project-a"))
        #expect(try await store.getJobMetadata(id: "job-a") == JobMetadata(name: "终稿", favorite: true, note: "注意停顿"))
        let job = try #require(try await store.getJob(id: "job-a"))
        #expect(try await store.finalJobID(batchID: job.batchID) == "job-a")
        #expect(try await store.listAssets(jobID: "job-a").map(\.id) == ["asset-a"])
        let importedAsset = try #require(try await store.listAssets(jobID: "job-a").first)
        let lease = try await OutputDirectoryStore(store: store).resolve(importedAsset.directoryID)
        #expect(try Data(contentsOf: lease.url.appendingPathComponent(importedAsset.relativePath)) == Data("synthetic audio".utf8))
        lease.close()
        await #expect(throws: OutputDirectoryError.unavailable) {
            try await OutputDirectoryStore(store: store).reauthorize(directoryID: importedAsset.directoryID, selectedURL: source)
        }
        let after = try originals.map { (try digest($0), try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        #expect(before.map(\.0) == after.map(\.0))
        #expect(before.map(\.1) == after.map(\.1))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("instance.lock").path))
        try await store.close()
    }

    @Test func missingAssetIsReportedWithoutInventingPermission() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source, missing: true)
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.issues.count == 1)
        let result = try await importer.import(source: source, preview: preview)
        #expect(result.copiedAssets == 0 && result.issues.count == 1)
        #expect(try await store.getJob(id: "job-a") != nil)
        #expect(try await store.listAssets(jobID: "job-a").isEmpty)
        try await store.close()
    }

    @Test func jobReferencingAbsentAssetHasExplicitIssue() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        try put([String: Any](), source.appendingPathComponent("assets.json"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.issues.contains(where: { $0.contains("asset-a") }))
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.issues.contains(where: { $0.contains("asset-a") }))
        #expect(try await store.listAssets(jobID: "job-a").isEmpty)
        try await store.close()
    }

    @Test func heldLegacyLockRefusesPreviewAndDoesNotMutateSource() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        let lock = source.appendingPathComponent("instance.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let descriptor = open(lock.path, O_RDWR | O_NOFOLLOW)
        #expect(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let store = try StudioStore(dataRoot: base.appendingPathComponent("new"))
        #expect(throws: LegacyImportError.self) { _ = try LegacyImporter(dataRoot: base.appendingPathComponent("new"), store: store).preview(source: source) }
    }

    @Test func malformedMetadataAndPathTraversalDoNotActivate() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: source.appendingPathComponent("projects/bad.json"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        #expect(throws: LegacyImportError.self) { _ = try importer.preview(source: source) }
        #expect(try await store.listProjects().isEmpty)
        try await store.close()
    }

    @Test func destinationConflictAndPrecommitFaultNeverExposePartialImport() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        await #expect(throws: LegacyImportError.self) {
            _ = try await importer.import(source: source, preview: preview, beforeActivation: { throw LegacyImportError.interrupted })
        }
        #expect(try await store.listProjects().isEmpty)
        #expect(try await store.listLibrary().isEmpty)
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.importedJobs == 1)
        await #expect(throws: LegacyImportError.self) { _ = try await importer.import(source: source, preview: preview) }
        #expect(try await store.listProjects().count == 1)
        #expect(try await store.listLibrary().count == 1)
        try await store.close()
    }

    @Test func sourceChangeAfterPreviewRequiresFreshConfirmation() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        try put(["id":"project-a", "name":"预览后改变", "mode":"audiobook", "prompt":"从前"], source.appendingPathComponent("projects/project-a.json"))
        do {
            _ = try await importer.import(source: source, preview: preview)
            Issue.record("预览后变化必须被拒绝")
        } catch LegacyImportError.changedSource {} catch { Issue.record("错误类型不符：\(error)") }
        #expect(try await store.listProjects().isEmpty)
        try await store.close()
    }

    @Test func symlinkedAssetIsReportedButCannotEscapeSelectedRoot() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let audio = try v1(source)
        let outside = base.appendingPathComponent("outside.wav")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.issues.count == 1)
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.copiedAssets == 0)
        #expect(try await store.listAssets(jobID: "job-a").isEmpty)
        try await store.close()
    }

    @Test func traversalAssetPathIsOnlyAnIssueNeverAnAccessGrant() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        let outside = base.appendingPathComponent("outside.wav")
        try Data("private synthetic".utf8).write(to: outside)
        try put(["asset-a":["path":"../outside.wav", "mime_type":"audio/wav"]], source.appendingPathComponent("assets.json"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.issues.count == 1)
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.copiedAssets == 0)
        #expect(try await store.listAssets(jobID: "job-a").isEmpty)
        #expect(try Data(contentsOf: outside) == Data("private synthetic".utf8))
        try await store.close()
    }

    @Test func relativeAssetInsideSelectedRootCopiesSafely() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        try put(["asset-a":["path":"output/synthetic.wav", "mime_type":"audio/wav"]], source.appendingPathComponent("assets.json"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.issues.isEmpty)
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.copiedAssets == 1)
        try await store.close()
    }

    @Test func legacyDeletedJobRemainsInRecoverableTrash() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        try put(["id":"job-a", "project_id":"project-a", "display_name":"已移除版本", "status":"success",
                 "output_asset_id":"asset-a", "deleted_at":"2026-01-01T00:00:00Z"], source.appendingPathComponent("jobs/job-a.json"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        _ = try await importer.import(source: source, preview: importer.preview(source: source))
        #expect(try await store.listLibrary().isEmpty)
        #expect(try await store.listRemovedJobs().map(\.id) == ["job-a"])
        try await store.close()
    }

    @Test func oldVoiceBindingNeedsFreshNativeSelectionAndConsent() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try v1(source)
        try put(["id":"project-a", "name":"带旧音色", "mode":"podcast", "prompt":"@voice1 你好",
                 "reference_bindings":[["reference_id":"old-voice", "slot":1]]], source.appendingPathComponent("projects/project-a.json"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.issues.contains(where: { $0.contains("音色") }))
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.issues.contains(where: { $0.contains("音色") }))
        #expect(try await store.getProject(id: "project-a")?.fields.referenceBindings.isEmpty == true)
        try await store.close()
    }

    @Test func v2SQLiteFixtureImportsStableIDs() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let audio = source.appendingPathComponent("output/synthetic.wav")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic audio".utf8).write(to: audio)
        let db = try SQLiteConnection(url: source.appendingPathComponent("studio.sqlite3"))
        try db.execute("CREATE TABLE projects(id TEXT,name TEXT,mode TEXT,prompt TEXT,params_json TEXT,revision INTEGER,archived INTEGER,final_job_id TEXT,deleted_at TEXT,reference_bindings_json TEXT)")
        try db.execute("CREATE TABLE jobs(id TEXT,project_id TEXT,batch_id TEXT,display_name TEXT,note TEXT,status TEXT,favorite INTEGER,output_asset_id TEXT,variant_index INTEGER,params_json TEXT,created_at TEXT,deleted_at TEXT)")
        try db.execute("CREATE TABLE assets(id TEXT,canonical_path TEXT,mime_type TEXT)")
        try db.execute("INSERT INTO projects VALUES('project-b','播客','podcast','你好','{}',3,0,'job-b',NULL,'[]')")
        try db.execute("INSERT INTO jobs VALUES('job-b','project-b','batch-b','最终版','保留','success',1,'asset-b',0,'{\"seed\":19}','2026-01-01T00:00:00Z',NULL)")
        try db.execute("INSERT INTO assets VALUES(?,?,?)", [.text("asset-b"), .text(audio.path), .text("audio/wav")])
        let dbFile = source.appendingPathComponent("studio.sqlite3")
        let walFile = source.appendingPathComponent("studio.sqlite3-wal")
        #expect(FileManager.default.fileExists(atPath: walFile.path))
        let originalHash = try digest(dbFile)
        let originalWALHash = try digest(walFile)
        let originalWALMtime = try walFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let originalMtime = try dbFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.projects == 1 && preview.jobs == 1 && preview.assets == 1)
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.copiedAssets == 1)
        #expect(try await store.getProject(id: "project-b")?.revision == 3)
        #expect(try await store.finalJobID(batchID: "batch-b") == "job-b")
        #expect(try digest(dbFile) == originalHash)
        #expect(try digest(walFile) == originalWALHash)
        #expect(try walFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalWALMtime)
        #expect(try dbFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalMtime)
        try await store.close()
        try db.close()
    }

    @Test func corruptV2DatabaseAndOrphanRecoveryAreBounded() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("invalid database".utf8).write(to: source.appendingPathComponent("studio.sqlite3"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        #expect(throws: LegacyImportError.self) { _ = try importer.preview(source: source) }
        let audioRoot = target.appendingPathComponent("LegacyAudio")
        let orphan = audioRoot.appendingPathComponent(".stage_\(UUID().uuidString)")
        let unrelated = audioRoot.appendingPathComponent("user_notes")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("QwenAudioStudioLegacyImport-v1".utf8).write(to: orphan.appendingPathComponent(".import-marker"))
        try Data("preserve".utf8).write(to: unrelated)
        try await importer.recoverAbandonedStages()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Data(contentsOf: unrelated) == Data("preserve".utf8))
        try await store.close()
    }
}
