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
        let tone = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ReferenceAudio/tone.wav")
        let expectedAudio = try Data(contentsOf: tone)
        try expectedAudio.write(to: audio)
        let originals = [audio, source.appendingPathComponent("projects/project-a.json"), source.appendingPathComponent("jobs/job-a.json"), source.appendingPathComponent("assets.json")]
        let before = try originals.map { (try digest($0), try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        let store = try StudioStore(dataRoot: target)
        let storageBefore = try await store.localStorageBytes()
        let importer = LegacyImporter(dataRoot: target, store: store)
        let preview = try importer.preview(source: source)
        #expect(preview.lockFileAbsent)
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
        #expect(importedAsset.kind == "audio")
        #expect(try Data(contentsOf: lease.url.appendingPathComponent(importedAsset.relativePath)) == expectedAudio)
        lease.close()
        let assets = GeneratedAssetStore(store: store, directories: OutputDirectoryStore(store: store))
        #expect(try await assets.readRegisteredAudio(importedAsset.id) == expectedAudio)
        #expect(try await assets.decodeRegisteredAudio(importedAsset.id).duration > 1.9)
        #expect(try await store.localStorageBytes() - storageBefore >= Int64(expectedAudio.count))
        await #expect(throws: OutputDirectoryError.unavailable) {
            try await OutputDirectoryStore(store: store).reauthorize(directoryID: importedAsset.directoryID, selectedURL: source)
        }
        let after = try originals.map { (try digest($0), try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        #expect(before.map(\.0) == after.map(\.0))
        #expect(before.map(\.1) == after.map(\.1))
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("instance.lock").path))
        try await assets.trash(job: "job-a", scope: .generatedFiles)
        #expect(try await store.listRemovedJobs().map(\.id) == ["job-a"])
        let owned = try await OutputDirectoryStore(store: store).resolve(importedAsset.directoryID)
        try Data("unrelated".utf8).write(to: owned.rootURL.appendingPathComponent(importedAsset.relativePath))
        owned.close()
        try await assets.restore(job: "job-a")
        let restored = try #require(try await store.getAsset(id: importedAsset.id))
        #expect(!restored.relativePath.hasPrefix("/"))
        #expect(restored.relativePath != importedAsset.relativePath)
        #expect(try await assets.decodeRegisteredAudio(restored.id).duration > 1.9)
        let check = try await OutputDirectoryStore(store: store).resolve(importedAsset.directoryID)
        #expect(try Data(contentsOf: check.rootURL.appendingPathComponent(importedAsset.relativePath)) == Data("unrelated".utf8))
        check.close()
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
        let backups = target.appendingPathComponent("LegacyBackups")
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
        #expect(try await store.listProjects().isEmpty)
        #expect(try await store.listLibrary().isEmpty)
        let report = try await importer.import(source: source, preview: preview)
        #expect(report.importedJobs == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
        await #expect(throws: LegacyImportError.self) { _ = try await importer.import(source: source, preview: preview) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
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

    @Test func explicitExternalFolderGrantCopiesExactFileAndDetectsLaterChange() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        let external = base.appendingPathComponent("authorized-output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        _ = try v1(source)
        let tone = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ReferenceAudio/tone.wav")
        let audio = external.appendingPathComponent("approved.wav")
        try Data(contentsOf: tone).write(to: audio)
        try put(["asset-a":["path":audio.path, "mime_type":"audio/wav"]], source.appendingPathComponent("assets.json"))
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        #expect(try importer.preview(source: source).issues.count == 1)
        let approved = try importer.preview(source: source, externalFolder: external)
        #expect(approved.issues.isEmpty)
        try Data("changed".utf8).write(to: audio)
        await #expect(throws: LegacyImportError.self) {
            _ = try await importer.import(source: source, preview: approved, externalFolder: external)
        }
        #expect(try await store.listProjects().isEmpty)
        try Data(contentsOf: tone).write(to: audio)
        let fresh = try importer.preview(source: source, externalFolder: external)
        let report = try await importer.import(source: source, preview: fresh, externalFolder: external)
        #expect(report.copiedAssets == 1)
        let copied = try #require(try await store.listAssets(jobID: "job-a").first)
        #expect(try await GeneratedAssetStore(store: store, directories: OutputDirectoryStore(store: store)).decodeRegisteredAudio(copied.id).duration > 1.9)
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
        try db.execute("CREATE TABLE jobs(id TEXT,project_id TEXT,batch_id TEXT,display_name TEXT,note TEXT,status TEXT,favorite INTEGER,output_asset_id TEXT,variant_index INTEGER,params_json TEXT,created_at TEXT,deleted_at TEXT,project_name TEXT,mode TEXT,prompt TEXT,compiled_prompt TEXT)")
        try db.execute("CREATE TABLE assets(id TEXT,canonical_path TEXT,mime_type TEXT)")
        try db.execute("INSERT INTO projects VALUES('project-b','播客','podcast','你好','{}',3,0,'job-b',NULL,'[]')")
        try db.execute("INSERT INTO jobs VALUES('job-b','project-b','batch-b','最终版','保留','success',1,'asset-b',0,'{\"seed\":19}','2026-01-01T00:00:00Z',NULL,'播客','podcast','你好','你好')")
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
        let malformed = try SQLiteConnection(url: dbFile)
        try malformed.execute("UPDATE jobs SET params_json='{' WHERE id='job-b'")
        try malformed.close()
        #expect(throws: LegacyImportError.self) { _ = try importer.preview(source: source) }
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
        let oldBackup = target.appendingPathComponent("LegacyBackups/import_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("QwenAudioStudioLegacyImport-v1".utf8).write(to: orphan.appendingPathComponent(".import-marker"))
        try Data("preserve".utf8).write(to: unrelated)
        try FileManager.default.createDirectory(at: oldBackup, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 64).utf8).write(to: oldBackup.appendingPathComponent("source.sha256"))
        try await importer.recoverAbandonedStages()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: oldBackup.path))
        #expect(try Data(contentsOf: unrelated) == Data("preserve".utf8))
        try await store.close()
    }

    @Test func v2PerJobSnapshotsAndVariantGapSurviveEditedProject() async throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("old"), target = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let pcm = source.appendingPathComponent("output/old.pcm")
        try FileManager.default.createDirectory(at: pcm.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16000 * 2).write(to: pcm)
        let db = try SQLiteConnection(url: source.appendingPathComponent("studio.sqlite3"))
        try db.execute("CREATE TABLE projects(id TEXT,name TEXT,mode TEXT,prompt TEXT,params_json TEXT,revision INTEGER,archived INTEGER,final_job_id TEXT,deleted_at TEXT,reference_bindings_json TEXT)")
        try db.execute("CREATE TABLE jobs(id TEXT,project_id TEXT,batch_id TEXT,project_name TEXT,display_name TEXT,note TEXT,mode TEXT,prompt TEXT,compiled_prompt TEXT,status TEXT,favorite INTEGER,output_asset_id TEXT,variant_index INTEGER,params_json TEXT,created_at TEXT,deleted_at TEXT)")
        try db.execute("CREATE TABLE assets(id TEXT,canonical_path TEXT,mime_type TEXT)")
        try db.execute("INSERT INTO projects VALUES('project-history','最新版','podcast','已编辑的新稿','{}',4,0,'job-v2',NULL,'[]')")
        try db.execute("INSERT INTO jobs VALUES('job-v0','project-history','batch-history','广告旧名','版本一','','advertisement','广告旧稿','广告成稿','success',0,NULL,0,'{\"seed\":11}','2026-01-01T00:00:00Z',NULL)")
        try db.execute("INSERT INTO jobs VALUES('job-v2','project-history','batch-history','旁白旧名','版本三','','narration','旁白旧稿','旁白成稿','success',1,'asset-pcm',2,'{\"seed\":22,\"format\":\"pcm\",\"sample_rate\":16000,\"channels\":1}','2026-01-01T00:00:01Z',NULL)")
        try db.execute("INSERT INTO assets VALUES('asset-pcm',?,'audio/pcm')", [.text(pcm.path)])
        try db.close()
        let store = try StudioStore(dataRoot: target)
        let importer = LegacyImporter(dataRoot: target, store: store)
        _ = try await importer.import(source: source, preview: importer.preview(source: source))
        #expect(try await store.getProject(id: "project-history")?.fields.prompt == "已编辑的新稿")
        #expect(try await store.getBatch(id: "batch-history")?.jobIDs == ["job-v0", "job-v2"])
        #expect(try await store.getJob(id: "job-v2")?.candidateIndex == 2)
        #expect(try await store.finalJobID(batchID: "batch-history") == "job-v2")
        #expect(try await store.legacyJobSnapshot(id: "job-v0")?.compiledPrompt == "广告成稿")
        #expect(try await store.legacyJobSnapshot(id: "job-v2")?.params.format == "pcm")
        #expect(try await store.compiledPrompt(jobID: "job-v2") == "旁白成稿")
        let filtered = try await store.libraryPage(.init(mode: .narration))
        #expect(filtered.items.map(\.job.id) == ["job-v2"])
        #expect(filtered.items.first?.project.fields.name == "旁白旧名")
        #expect(filtered.items.first?.project.fields.prompt == "旁白旧稿")
        #expect(filtered.items.first?.project.fields.mode == .narration)
        #expect(try await store.libraryPage(.init(search: "旁白旧稿")).items.map(\.job.id) == ["job-v2"])
        let copied = try #require(try await store.listAssets(jobID: "job-v2").first)
        let decoder = GeneratedAssetStore(store: store, directories: OutputDirectoryStore(store: store))
        #expect(abs(try await decoder.decodeRegisteredAudio(copied.id).duration - 1) < 0.001)
        try await store.close()
    }
}
