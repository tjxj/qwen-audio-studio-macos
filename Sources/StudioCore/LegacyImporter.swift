import Foundation
import CryptoKit
import SQLite3
import Darwin

public enum LegacyImportError: Error, LocalizedError {
    case invalidSource, sourceBusy, corrupt(String), changedSource, destinationConflict, unsafeAsset, stagingFailed, interrupted
    public var errorDescription: String? {
        switch self {
        case .invalidSource: "请选择旧版应用的数据目录。"
        case .sourceBusy: "旧版应用仍在使用该目录，请先退出旧版应用再导入。"
        case .corrupt(let detail): "旧版元数据无法读取：\(detail)"
        case .changedSource: "预览后旧版数据发生变化，请重新预览。"
        case .destinationConflict: "原生作品库中已有同 ID 数据，导入已安全取消。"
        case .unsafeAsset: "旧版音频路径不安全；音频未复制。"
        case .stagingFailed: "原生导入暂存目录写入失败，作品库保持不变。"
        case .interrupted: "导入在激活前中断，原生作品库保持不变。"
        }
    }
}

public struct LegacyImportCounts: Sendable {
    public let projects: Int
    public let jobs: Int
    public let assets: Int
    public let issues: [String]
    public let fingerprint: String
}

public struct LegacyImportReport: Sendable {
    public let importedProjects: Int
    public let importedJobs: Int
    public let copiedAssets: Int
    public let issues: [String]
}

struct LegacyProject: Sendable {
    let id: String, name: String, mode: CreationMode, prompt: String
    let revision: Int, archived: Bool, finalJobID: String?
    let params: GenerationParams
    let hadVoiceBindings: Bool
}
struct LegacyJob: Sendable {
    let id: String, projectID: String, batchID: String, displayName: String, note: String
    let state: JobState, favorite: Bool, outputAssetID: String?, candidateIndex: Int, seed: Int
    let createdAtMS: Int
    let deleted: Bool
}
struct LegacyAsset: Sendable { let id: String, source: URL, mime: String, ownerJobID: String? }
struct LegacySnapshot: Sendable {
    let projects: [LegacyProject], jobs: [LegacyJob], assets: [LegacyAsset]
    let issues: [String], fingerprint: String
}
struct LegacyImportedAsset: Sendable { let asset: StoredAsset }

private final class LegacySourceLease: @unchecked Sendable {
    private let source: URL
    private let scoped: Bool
    private let descriptor: Int32
    init(_ source: URL) throws {
        guard source.isFileURL,
              (try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else { throw LegacyImportError.invalidSource }
        self.source = source
        scoped = source.startAccessingSecurityScopedResource()
        let path = source.appendingPathComponent("instance.lock")
        if FileManager.default.fileExists(atPath: path.path) {
            let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { if scoped { source.stopAccessingSecurityScopedResource() }; throw LegacyImportError.sourceBusy }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd); if scoped { source.stopAccessingSecurityScopedResource() }; throw LegacyImportError.sourceBusy
            }
            descriptor = fd
        } else { descriptor = -1 }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) }; if scoped { source.stopAccessingSecurityScopedResource() } }
}

/// An explicit, scoped one-time import. The old tree is never a destination.
/// A private source snapshot and backup are taken under a compatible nonblocking
/// flock. Native metadata appears in one transaction only after all eligible
/// audio has been staged in the app-owned LegacyAudio directory.
public final class LegacyImporter: @unchecked Sendable {
    private let dataRoot: URL
    private let store: StudioStore
    public init(dataRoot: URL, store: StudioStore) { self.dataRoot = dataRoot; self.store = store }

    public func preview(source: URL) throws -> LegacyImportCounts {
        let lease = try LegacySourceLease(source); defer { withExtendedLifetime(lease) {} }
        let snapshot = try readUnlocked(source: source)
        return LegacyImportCounts(projects: snapshot.projects.count, jobs: snapshot.jobs.count,
                                  assets: snapshot.assets.count, issues: snapshot.issues, fingerprint: snapshot.fingerprint)
    }

    public func `import`(source: URL, preview: LegacyImportCounts,
                         beforeActivation: (@Sendable () throws -> Void)? = nil) async throws -> LegacyImportReport {
        try await store.withFileJob("__legacy_import__") { [self] in
            try await performImport(source: source, preview: preview, beforeActivation: beforeActivation)
        }
    }

    private func performImport(source: URL, preview: LegacyImportCounts,
                               beforeActivation: (@Sendable () throws -> Void)?) async throws -> LegacyImportReport {
        let lease = try LegacySourceLease(source); defer { withExtendedLifetime(lease) {} }
        let snapshot = try readUnlocked(source: source)
        guard snapshot.fingerprint == preview.fingerprint,
              snapshot.projects.count == preview.projects, snapshot.jobs.count == preview.jobs,
              snapshot.assets.count == preview.assets else { throw LegacyImportError.changedSource }
        try await recoverAbandonedStages()
        let id = UUID().uuidString
        let audioRoot = dataRoot.appendingPathComponent("LegacyAudio", isDirectory: true)
        let staged = audioRoot.appendingPathComponent(".stage_\(id)", isDirectory: true)
        let final = audioRoot.appendingPathComponent("import_\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("QwenAudioStudioLegacyImport-v1".utf8).write(to: staged.appendingPathComponent(".import-marker"))
        var activated = false
        defer { if !activated { try? FileManager.default.removeItem(at: staged); try? FileManager.default.removeItem(at: final) } }
        var copied: [String: (name: String, identity: FileIdentity)] = [:]
        var issues = snapshot.issues
        for asset in snapshot.assets {
            guard asset.ownerJobID != nil else {
                issues.append("音频 \(asset.id)：缺少任务归属，本次未复制。")
                continue
            }
            guard Self.safeAsset(asset.source, inside: source) else {
                issues.append("音频 \(asset.id)：位于所选数据目录外，需单独授权。")
                continue
            }
            guard (try? asset.source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true else {
                issues.append("音频 \(asset.id)：源文件缺失。")
                continue
            }
            let ext = asset.source.pathExtension.lowercased()
            guard ["wav", "mp3", "m4a", "ogg", "pcm"].contains(ext) else {
                issues.append("音频 \(asset.id)：文件格式未获准复制。")
                continue
            }
            let name = "asset_\(UUID().uuidString).\(ext)"
            let destination = staged.appendingPathComponent(name)
            do { try Self.copyNoFollow(from: asset.source, to: destination) }
            catch LegacyImportError.unsafeAsset {
                try? FileManager.default.removeItem(at: destination)
                issues.append("音频 \(asset.id)：源文件不可安全读取。")
                continue
            }
            copied[asset.id] = (name, try Self.identity(destination))
        }
        // Source backup is private and write-once; source data and its mtime remain untouched.
        let backup = dataRoot.appendingPathComponent("LegacyBackups/import_\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data(snapshot.fingerprint.utf8).write(to: backup.appendingPathComponent("source.sha256"))
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("studio.sqlite3").path) {
            for name in ["studio.sqlite3", "studio.sqlite3-wal", "studio.sqlite3-shm"] {
                let url = source.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path), Self.safeMetadata(url, inside: source) {
                    try FileManager.default.copyItem(at: url, to: backup.appendingPathComponent(name))
                }
            }
        } else {
            for name in ["projects", "jobs"] {
                let directory = source.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: directory.path) {
                    let destination = backup.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                        guard Self.safeMetadata(url, inside: source) else { throw LegacyImportError.corrupt("备份中发现越界元数据。") }
                        try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
                    }
                }
            }
            let assetFile = source.appendingPathComponent("assets.json")
            if FileManager.default.fileExists(atPath: assetFile.path) { try FileManager.default.copyItem(at: assetFile, to: backup.appendingPathComponent("assets.json")) }
        }
        guard try readUnlocked(source: source).fingerprint == snapshot.fingerprint else { throw LegacyImportError.changedSource }
        try FileManager.default.moveItem(at: staged, to: final)
        let directory = DirectorySnapshot(id: "legacy_dir_\(id)", version: 1, bookmark: Data("app-owned-legacy-v1".utf8),
                                          rootIdentity: try Self.identity(final))
        let storedAssets = snapshot.assets.compactMap { old -> LegacyImportedAsset? in
            guard let jobID = old.ownerJobID, let file = copied[old.id] else { return nil }
            return LegacyImportedAsset(asset: StoredAsset(id: old.id, jobID: jobID, directoryID: directory.id,
                                                           relativePath: file.name, kind: "generated_audio", appOwned: true,
                                                           fileIdentity: file.identity))
        }
        try beforeActivation?()
        try await store.activateLegacyImport(projects: snapshot.projects, jobs: snapshot.jobs,
                                             directory: directory, assets: storedAssets)
        activated = true
        return LegacyImportReport(importedProjects: snapshot.projects.count, importedJobs: snapshot.jobs.count,
                                  copiedAssets: storedAssets.count, issues: Array(Set(issues)).sorted())
    }

    /// Only UUID-named app-owned stages with our marker and no registered native
    /// directory are eligible. User-selected output folders are never scanned.
    public func recoverAbandonedStages() async throws {
        let root = dataRoot.appendingPathComponent("LegacyAudio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = url.lastPathComponent
            let suffix: String
            if name.hasPrefix(".stage_") { suffix = String(name.dropFirst(7)) }
            else if name.hasPrefix("import_") { suffix = String(name.dropFirst(7)) }
            else { continue }
            guard UUID(uuidString: suffix) != nil,
                  (try? Data(contentsOf: url.appendingPathComponent(".import-marker"))) == Data("QwenAudioStudioLegacyImport-v1".utf8),
                  try await store.getDirectory(id: "legacy_dir_\(suffix)") == nil else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func readUnlocked(source: URL) throws -> LegacySnapshot {
        let sqlite = source.appendingPathComponent("studio.sqlite3")
        if FileManager.default.fileExists(atPath: sqlite.path) { return try readV2(source: source) }
        return try readV1(source: source)
    }

    private func readV1(source: URL) throws -> LegacySnapshot {
        var files: [URL] = []
        for folder in ["projects", "jobs"] {
            let dir = source.appendingPathComponent(folder)
            if FileManager.default.fileExists(atPath: dir.path) {
                files += try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
                    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        let assetFile = source.appendingPathComponent("assets.json")
        if FileManager.default.fileExists(atPath: assetFile.path) { files.append(assetFile) }
        guard !files.isEmpty else { throw LegacyImportError.invalidSource }
        var hash = SHA256()
        var projects: [LegacyProject] = [], jobs: [LegacyJob] = [], assets: [LegacyAsset] = []
        var assetRecords: [String: [String: Any]] = [:]
        for url in files {
            guard Self.safeMetadata(url, inside: source) else { throw LegacyImportError.corrupt("包含符号链接或越界元数据。") }
            let data = try Data(contentsOf: url)
            hash.update(data: Data(url.path.replacingOccurrences(of: source.path, with: "").utf8)); hash.update(data: data)
            guard let object = try? JSONSerialization.jsonObject(with: data) else { throw LegacyImportError.corrupt("\(url.lastPathComponent) JSON 损坏。") }
            if url.lastPathComponent == "assets.json" {
                guard let values = object as? [String: [String: Any]] else { throw LegacyImportError.corrupt("assets.json 格式错误。") }
                assetRecords = values
            } else {
                guard let dict = object as? [String: Any], dict["id"] as? String == url.deletingPathExtension().lastPathComponent else {
                    throw LegacyImportError.corrupt("\(url.lastPathComponent) 的 ID 不符。")
                }
                if url.deletingLastPathComponent().lastPathComponent == "projects" { projects.append(try Self.project(dict)) }
                else { jobs.append(try Self.job(dict)) }
            }
        }
        var jobOwners: [String: String] = [:]
        for job in jobs { if let assetID = job.outputAssetID { jobOwners[assetID] = jobOwners[assetID] ?? job.id } }
        for (id, record) in assetRecords.sorted(by: { $0.key < $1.key }) {
            guard Self.safeID(id), let path = record["path"] as? String else { throw LegacyImportError.corrupt("资产字段损坏。") }
            assets.append(LegacyAsset(id: id, source: Self.assetURL(path, source: source), mime: record["mime_type"] as? String ?? "application/octet-stream", ownerJobID: jobOwners[id]))
        }
        return try Self.validate(LegacySnapshot(projects: projects, jobs: jobs, assets: assets,
            issues: Self.assetIssues(assets, source: source) + Self.voiceIssues(projects), fingerprint: Self.hex(hash.finalize())))
    }

    private func readV2(source: URL) throws -> LegacySnapshot {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-sqlite-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var hash = SHA256()
        for name in ["studio.sqlite3", "studio.sqlite3-wal", "studio.sqlite3-shm"] {
            let file = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard Self.safeMetadata(file, inside: source) else { throw LegacyImportError.corrupt("SQLite 文件包含符号链接。") }
            let data = try Data(contentsOf: file)
            hash.update(data: Data(name.utf8)); hash.update(data: data)
            try data.write(to: scratch.appendingPathComponent(name))
        }
        let copiedDB: SQLiteConnection
        do { copiedDB = try SQLiteConnection(url: scratch.appendingPathComponent("studio.sqlite3")) }
        catch { throw LegacyImportError.corrupt("SQLite 快照损坏或无法打开。") }
        defer { try? copiedDB.close() }
        do {
            let projects = try copiedDB.rows("SELECT id,name,mode,prompt,params_json,revision,archived,final_job_id,deleted_at,reference_bindings_json FROM projects ORDER BY id").map { row in
                try Self.project(["id":row[0].string ?? "", "name":row[1].string ?? "", "mode":row[2].string ?? "", "prompt":row[3].string ?? "", "params":Self.json(row[4].string), "revision":row[5].int ?? 1, "archived":(row[6].int ?? 0) != 0,
                                  "final_job_id":row[7].string as Any, "deleted_at":row[8].string as Any,
                                  "reference_bindings":Self.jsonArray(row[9].string)])
            }
            let jobs = try copiedDB.rows("SELECT id,project_id,batch_id,display_name,note,status,favorite,output_asset_id,variant_index,params_json,created_at,deleted_at FROM jobs ORDER BY id").map { row in
                try Self.job(["id":row[0].string ?? "", "project_id":row[1].string ?? "", "batch_id":row[2].string as Any,
                              "display_name":row[3].string ?? "", "note":row[4].string ?? "", "status":row[5].string ?? "interrupted",
                              "favorite":(row[6].int ?? 0) != 0, "output_asset_id":row[7].string as Any,
                              "variant_index":row[8].int ?? 0, "params":Self.json(row[9].string), "created_at":row[10].string ?? "",
                              "deleted_at":row[11].string as Any])
            }
            var owners: [String: String] = [:]
            for job in jobs { if let assetID = job.outputAssetID { owners[assetID] = owners[assetID] ?? job.id } }
            let assets = try copiedDB.rows("SELECT id,canonical_path,mime_type FROM assets ORDER BY id").map { row -> LegacyAsset in
                guard let id = row[0].string, Self.safeID(id), let path = row[1].string else { throw LegacyImportError.corrupt("资产字段损坏。") }
                return LegacyAsset(id: id, source: Self.assetURL(path, source: source), mime: row[2].string ?? "application/octet-stream", ownerJobID: owners[id])
            }
            return try Self.validate(LegacySnapshot(projects: projects, jobs: jobs, assets: assets,
                issues: Self.assetIssues(assets, source: source) + Self.voiceIssues(projects), fingerprint: Self.hex(hash.finalize())))
        } catch { throw LegacyImportError.corrupt("SQLite 快照无法读取或校验：\(error.localizedDescription)") }
    }

    private static func project(_ object: [String: Any]) throws -> LegacyProject {
        guard let id = object["id"] as? String, safeID(id) else { throw LegacyImportError.corrupt("项目 ID 无效。") }
        let mode = CreationMode(rawValue: object["mode"] as? String ?? "auto") ?? .auto
        return LegacyProject(id: id, name: object["name"] as? String ?? id, mode: mode,
            prompt: object["prompt"] as? String ?? "", revision: max(1, object["revision"] as? Int ?? 1),
            archived: (object["archived"] as? Bool ?? false) || object["deleted_at"] is String,
            finalJobID: object["final_job_id"] as? String,
            params: params(object["params"]), hadVoiceBindings: !(object["reference_bindings"] as? [Any] ?? []).isEmpty)
    }
    private static func job(_ object: [String: Any]) throws -> LegacyJob {
        guard let id = object["id"] as? String, safeID(id), let projectID = object["project_id"] as? String, safeID(projectID) else { throw LegacyImportError.corrupt("任务 ID 无效。") }
        let status = object["status"] as? String ?? "interrupted"
        let state: JobState = status == "success" ? .success : status == "failed" ? .failed : status == "cancelled" ? .cancelled : .interrupted
        let batch = object["batch_id"] as? String ?? "legacy_batch_\(id)"
        guard safeID(batch) else { throw LegacyImportError.corrupt("批次 ID 无效。") }
        let date = ISO8601DateFormatter().date(from: object["created_at"] as? String ?? "") ?? Date(timeIntervalSince1970: 0)
        return LegacyJob(id: id, projectID: projectID, batchID: batch, displayName: object["display_name"] as? String ?? id,
            note: object["note"] as? String ?? "", state: state, favorite: object["favorite"] as? Bool ?? false,
            outputAssetID: object["output_asset_id"] as? String, candidateIndex: object["variant_index"] as? Int ?? 0,
            seed: (object["params"] as? [String: Any])?["seed"] as? Int ?? 42,
            createdAtMS: Int(date.timeIntervalSince1970 * 1000), deleted: object["deleted_at"] is String)
    }
    private static func params(_ raw: Any?) -> GenerationParams {
        let dict = raw as? [String: Any] ?? [:]
        return GenerationParams(format: dict["format"] as? String ?? "wav", sampleRate: dict["sample_rate"] as? Int ?? 48000,
            channels: dict["channels"] as? Int ?? 2, volume: dict["volume"] as? Int ?? 50,
            rate: dict["rate"] as? Double ?? 1, seed: dict["seed"] as? Int ?? 42,
            enableCBR: dict["enable_cbr"] as? Bool ?? false, bitRate: dict["bit_rate"] as? Int ?? 128,
            quality: dict["quality"] as? Int ?? 5, enableAIGCTag: dict["enable_aigc_tag"] as? Bool ?? false)
    }
    private static func validate(_ snapshot: LegacySnapshot) throws -> LegacySnapshot {
        let ids = Set(snapshot.projects.map(\.id))
        guard ids.count == snapshot.projects.count, Set(snapshot.jobs.map(\.id)).count == snapshot.jobs.count,
              Set(snapshot.assets.map(\.id)).count == snapshot.assets.count else { throw LegacyImportError.corrupt("存在重复 ID。") }
        let outputIDs = snapshot.jobs.compactMap(\.outputAssetID)
        guard Set(outputIDs).count == outputIDs.count else { throw LegacyImportError.corrupt("多个任务指向同一音频资产。") }
        for job in snapshot.jobs where !ids.contains(job.projectID) { throw LegacyImportError.corrupt("任务指向缺失项目。") }
        let jobs = Dictionary(uniqueKeysWithValues: snapshot.jobs.map { ($0.id, $0) })
        for project in snapshot.projects {
            if let final = project.finalJobID, jobs[final]?.projectID != project.id { throw LegacyImportError.corrupt("最终版本关系无效。") }
        }
        let assets = Set(snapshot.assets.map(\.id))
        let missing = outputIDs.filter { !assets.contains($0) }.map { "任务引用的音频 \($0) 未在旧版资产表中登记。" }
        return LegacySnapshot(projects: snapshot.projects, jobs: snapshot.jobs, assets: snapshot.assets,
                              issues: snapshot.issues + missing, fingerprint: snapshot.fingerprint)
    }
    private static func assetIssues(_ assets: [LegacyAsset], source: URL) -> [String] {
        assets.compactMap { asset in
            if !safeAsset(asset.source, inside: source) { return "音频 \(asset.id)：位于所选数据目录外，需单独授权。" }
            return FileManager.default.fileExists(atPath: asset.source.path) ? nil : "音频 \(asset.id)：源文件缺失。"
        }
    }
    private static func voiceIssues(_ projects: [LegacyProject]) -> [String] {
        projects.filter(\.hadVoiceBindings).map { "项目 \($0.id)：旧音色绑定需在原生版重新选择，本次不会沿用上传授权。" }
    }
    private static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-" )).contains($0) }
    }
    private static func safeMetadata(_ url: URL, inside root: URL) -> Bool {
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }
    private static func safeAsset(_ url: URL, inside root: URL) -> Bool {
        guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return false }
        return url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }
    private static func json(_ string: String?) -> [String: Any] {
        guard let string, let data = string.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private static func jsonArray(_ string: String?) -> [Any] {
        guard let string, let data = string.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
    }
    private static func assetURL(_ path: String, source: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : source.appendingPathComponent(path)
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private static func identity(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw LegacyImportError.unsafeAsset }
        return FileIdentity(device: Int32(info.st_dev), inode: UInt64(info.st_ino))
    }
    private static func copyNoFollow(from source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw LegacyImportError.unsafeAsset }
        defer { Darwin.close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw LegacyImportError.unsafeAsset }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw LegacyImportError.stagingFailed }
        defer { Darwin.close(output) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(input, &buffer, buffer.count)
            guard count >= 0 else { throw LegacyImportError.unsafeAsset }
            if count == 0 { break }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { raw in
                    write(output, raw.baseAddress!.advanced(by: written), count - written)
                }
                guard result > 0 else { throw LegacyImportError.stagingFailed }
                written += result
            }
        }
        guard fsync(output) == 0 else { throw LegacyImportError.stagingFailed }
    }
}
