import Foundation

/// The sole native metadata writer. Every operation is synchronous inside this actor;
/// transactions never suspend for network, bookmarks, file moves, or decoding.
public actor StudioStore {
    private let db: SQLiteConnection
    private var ownership: InstanceOwnership?
    private var busyFileJobs: Set<String> = []

    public init(dataRoot: URL) throws {
        let ownership = try InstanceOwnership.acquire(dataRoot: dataRoot)
        // Do not move any DB work above the ownership acquisition.
        let database = try SQLiteConnection(url: dataRoot.appendingPathComponent("studio.sqlite"))
        do {
            try StudioSchema.migrate(database)
            let builtins = try TemplateEngine().templates
            try database.transaction {
                for template in builtins {
                    try database.execute("INSERT INTO templates(id,builtin,template) VALUES(?,1,?) ON CONFLICT(id) DO UPDATE SET template=excluded.template WHERE templates.builtin=1",
                                         [.text(template.id), .blob(try storeEncode(template))])
                }
                try database.execute("UPDATE jobs SET result_uncertain=CASE WHEN state='requesting' THEN 1 ELSE result_uncertain END, state='interrupted', message='应用重启，任务已中断；未重新提交。' WHERE state IN ('queued','preparing','requesting','downloading','validating')")
                try database.execute("UPDATE reference_voices SET last_used_ms=? WHERE id IN (SELECT reference_id FROM reference_leases)", [.integer(Int(Date().timeIntervalSince1970 * 1000))])
                try database.execute("DELETE FROM reference_leases WHERE job_id IN (SELECT id FROM jobs WHERE state IN ('success','failed','cancelled','interrupted'))")
            }
        } catch {
            try? database.close()
            withExtendedLifetime(ownership) {}
            throw error
        }
        self.db = database; self.ownership = ownership
    }
    deinit { try? db.close() }
    /// Orderly shutdown: close SQLite before releasing the process lock.
    public func close() throws {
        guard busyFileJobs.isEmpty else { throw StudioStoreError.invalidTransition }
        try db.close(); ownership = nil
    }

    public func createProject(id: String = "proj_" + UUID().uuidString, fields: DraftFields) throws -> ProjectDraft {
        guard !id.isEmpty else { throw StudioStoreError.invalidSubmission }
        let draft = ProjectDraft(id: id, fields: fields)
        try db.execute("INSERT INTO projects(id,revision,fields) VALUES(?,1,?)", [.text(id), .blob(try storeEncode(fields))])
        return draft
    }
    public func getProject(id: String) throws -> ProjectDraft? {
        guard let row = try db.rows("SELECT id,revision,fields FROM projects WHERE id=?", [.text(id)]).first else { return nil }
        return try project(row)
    }
    public func listProjects() throws -> [ProjectDraft] {
        try db.rows("SELECT id,revision,fields FROM projects ORDER BY rowid DESC").map(project)
    }
    private func project(_ row: [SQLiteValue]) throws -> ProjectDraft {
        guard let id = row[0].string, let revision = row[1].int else { throw StudioStoreError.corruptRecord }
        return ProjectDraft(id: id, fields: try storeDecode(DraftFields.self, row[2]), revision: revision)
    }
    public func saveProject(id: String, expectedRevision: Int, changes: DraftFields) throws -> ProjectDraft {
        try db.transaction {
            let count = try db.execute("UPDATE projects SET revision=revision+1,fields=? WHERE id=? AND revision=?",
                                       [.blob(try storeEncode(changes)), .text(id), .integer(expectedRevision)])
            guard count == 1 else {
                if try getProject(id: id) == nil { throw DraftStoreError.missing }
                throw DraftStoreError.conflict
            }
            return ProjectDraft(id: id, fields: changes, revision: expectedRevision + 1)
        }
    }

    public func saveDirectory(_ directory: DirectorySnapshot) throws {
        guard !directory.id.isEmpty, directory.version > 0, !directory.bookmark.isEmpty else { throw StudioStoreError.staleDirectory }
        try db.execute("INSERT INTO directories(id,version,snapshot) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET version=excluded.version,snapshot=excluded.snapshot",
                       [.text(directory.id), .integer(directory.version), .blob(try storeEncode(directory))])
    }
    public func getDirectory(id: String) throws -> DirectorySnapshot? {
        try db.rows("SELECT snapshot FROM directories WHERE id=?", [.text(id)]).first.map { try storeDecode(DirectorySnapshot.self, $0[0]) }
    }
    public func replaceDirectory(_ updated: DirectorySnapshot, expected: DirectorySnapshot) throws {
        try db.transaction {
            guard updated.id == expected.id, updated.version == expected.version + 1,
                  try getDirectory(id: expected.id) == expected else { throw StudioStoreError.staleDirectory }
            try saveDirectory(updated)
        }
    }
    public func setDefaultDirectory(id: String) throws {
        guard try getDirectory(id: id) != nil else { throw StudioStoreError.missing }
        try db.execute("INSERT INTO output_settings(singleton,default_directory_id) VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET default_directory_id=excluded.default_directory_id", [.text(id)])
    }
    public func defaultDirectoryID() throws -> String? {
        try db.rows("SELECT default_directory_id FROM output_settings WHERE singleton=1").first?.first?.string
    }
    public func jobOutputFolder(jobID: String) throws -> JobOutputFolder? {
        guard let row = try db.rows("SELECT directory_id,relative_path,identity FROM job_output_folders WHERE job_id=?", [.text(jobID)]).first,
              let directory = row[0].string, let path = row[1].string else { return nil }
        return JobOutputFolder(jobID: jobID, directoryID: directory, relativePath: path, identity: try storeDecode(FileIdentity.self, row[2]))
    }
    public func listJobOutputFolders(directoryID: String) throws -> [JobOutputFolder] {
        try db.rows("SELECT job_id,relative_path,identity FROM job_output_folders WHERE directory_id=?", [.text(directoryID)]).map { row in
            guard let jobID = row[0].string, let path = row[1].string else { throw StudioStoreError.corruptRecord }
            return JobOutputFolder(jobID: jobID, directoryID: directoryID, relativePath: path, identity: try storeDecode(FileIdentity.self, row[2]))
        }
    }
    public func reserveJobOutputFolder(_ folder: JobOutputFolder) throws -> JobOutputFolder {
        guard Self.safeRelativePath(folder.relativePath) else { throw StudioStoreError.invalidPath }
        return try db.transaction {
            if let old = try jobOutputFolder(jobID: folder.jobID) { return old }
            guard let job = try getJob(id: folder.jobID), let batch = try getBatch(id: job.batchID), batch.submission.directory.id == folder.directoryID else { throw StudioStoreError.staleDirectory }
            try db.execute("INSERT INTO job_output_folders(job_id,directory_id,relative_path,identity) VALUES(?,?,?,?)", [.text(folder.jobID), .text(folder.directoryID), .text(folder.relativePath), .blob(try storeEncode(folder.identity))])
            return folder
        }
    }
    public func removeJobRecord(id: String, scope: AssetRemovalScope) throws {
        guard let job = try getJob(id: id), job.state.isTerminal else { throw StudioStoreError.invalidTransition }
        try db.execute("INSERT INTO removed_jobs(job_id,scope) VALUES(?,?) ON CONFLICT(job_id) DO UPDATE SET scope=excluded.scope", [.text(id), .text(scope.rawValue)])
    }
    public func restoreJobRecord(id: String) throws { try db.execute("DELETE FROM removed_jobs WHERE job_id=?", [.text(id)]) }
    public func originalAssetPath(id: String) throws -> String? {
        try db.rows("SELECT original_path FROM recycled_assets WHERE asset_id=?", [.text(id)]).first?.first?.string
    }
    public func getAsset(id: String) throws -> StoredAsset? {
        try db.rows("SELECT metadata FROM assets WHERE id=?", [.text(id)]).first.map { try storeDecode(StoredAsset.self, $0[0]) }
    }
    public func saveReference(_ reference: ReferenceSnapshot) throws {
        guard !reference.id.isEmpty, !reference.contentHash.isEmpty, reference.duration.isFinite,
              reference.duration > 0, reference.duration <= 30 else { throw StudioStoreError.staleReference }
        try db.transaction {
            guard try db.rows("SELECT reference_id FROM reference_cleanup WHERE reference_id=?", [.text(reference.id)]).isEmpty else { throw StudioStoreError.staleReference }
            if try activeLeaseCount(referenceID: reference.id) > 0, try getReference(id: reference.id) != reference {
                throw StudioStoreError.staleReference
            }
            try db.execute("INSERT INTO reference_voices(id,content_hash,snapshot,last_used_ms) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET content_hash=excluded.content_hash,snapshot=excluded.snapshot,last_used_ms=excluded.last_used_ms",
                           [.text(reference.id), .text(reference.contentHash), .blob(try storeEncode(reference)), .integer(Int(Date().timeIntervalSince1970 * 1000))])
        }
    }
    public func getReference(id: String) throws -> ReferenceSnapshot? {
        try db.rows("SELECT snapshot FROM reference_voices WHERE id=?", [.text(id)]).first.map { try storeDecode(ReferenceSnapshot.self, $0[0]) }
    }
    public func activeLeaseCount(referenceID: String) throws -> Int {
        try db.rows("SELECT COUNT(*) FROM reference_leases WHERE reference_id=?", [.text(referenceID)]).first?.first?.int ?? 0
    }

    public func listReferences() throws -> [ReferenceSnapshot] {
        try db.rows("SELECT snapshot FROM reference_voices ORDER BY rowid DESC").map { try storeDecode(ReferenceSnapshot.self, $0[0]) }
    }
    public func acquireReference(_ referenceID: String, forJob jobID: String) throws {
        try db.transaction {
            guard let job = try getJob(id: jobID), !job.state.isTerminal,
                  let batch = try getBatch(id: job.batchID),
                  batch.submission.references.contains(where: { $0.id == referenceID }),
                  try getReference(id: referenceID) != nil else { throw StudioStoreError.staleReference }
            try db.execute("INSERT OR IGNORE INTO reference_leases(job_id,reference_id) VALUES(?,?)", [.text(jobID), .text(referenceID)])
            try touchReference(referenceID)
        }
    }
    public func releaseReferences(jobID: String) throws {
        try db.transaction {
            try releaseReferenceRows(jobID: jobID)
        }
    }
    private func releaseReferenceRows(jobID: String) throws {
        try db.execute("UPDATE reference_voices SET last_used_ms=? WHERE id IN (SELECT reference_id FROM reference_leases WHERE job_id=?)", [.integer(Int(Date().timeIntervalSince1970 * 1000)), .text(jobID)])
        try db.execute("DELETE FROM reference_leases WHERE job_id=?", [.text(jobID)])
    }
    public func touchReference(_ id: String) throws {
        try db.execute("UPDATE reference_voices SET last_used_ms=? WHERE id=?", [.integer(Int(Date().timeIntervalSince1970 * 1000)), .text(id)])
    }
    /// Atomically prevents a cleanup/createBatch race. Historic consent remains
    /// in the immutable batch submission even when its expired clip is removed.
    public func removeUnleasedTemporaryReference(_ id: String, idleBefore: Date) throws -> Bool {
        try db.transaction {
            guard let reference = try getReference(id: id), reference.temporary,
                  try activeLeaseCount(referenceID: id) == 0 else { return false }
            let used = try db.rows("SELECT last_used_ms FROM reference_voices WHERE id=?", [.text(id)]).first?.first?.int ?? Int.max
            guard used <= Int(idleBefore.timeIntervalSince1970 * 1000) else { return false }
            // Durable tombstone remains after failed/uncompleted filesystem work.
            try db.execute("INSERT INTO reference_cleanup(reference_id,snapshot) VALUES(?,?)", [.text(id), .blob(try storeEncode(reference))])
            try db.execute("DELETE FROM upload_consents WHERE reference_id=?", [.text(id)])
            return try db.execute("DELETE FROM reference_voices WHERE id=?", [.text(id)]) == 1
        }
    }
    public func pendingReferenceCleanup() throws -> [ReferenceSnapshot] {
        try db.rows("SELECT snapshot FROM reference_cleanup ORDER BY rowid").map { try storeDecode(ReferenceSnapshot.self, $0[0]) }
    }
    public func finishReferenceCleanup(_ id: String) throws {
        try db.execute("DELETE FROM reference_cleanup WHERE reference_id=?", [.text(id)])
    }

    /// Returns only after a FULL-synchronous COMMIT. A caller may then claim a queued
    /// job, persist .requesting, and make one paid request. Never automatically replay.
    public func createBatch(_ submission: BatchSubmission) throws -> StoredBatch {
        let hash = try submission.requestHash()
        let encoded = try storeEncode(submission)
        return try db.transaction {
            if let row = try db.rows("SELECT id,request_hash,submission FROM batches WHERE client_request_id=?", [.text(submission.clientRequestID)]).first {
                guard row[1].string == hash, row[2].data == encoded else { throw StudioStoreError.requestConflict }
                guard let id = row[0].string, let previous = try getBatch(id: id) else { throw StudioStoreError.corruptRecord }
                return previous
            }
            guard !submission.clientRequestID.isEmpty, (1...3).contains(submission.candidateSeeds.count),
                  Set(submission.candidateSeeds).count == submission.candidateSeeds.count else { throw StudioStoreError.invalidSubmission }
            guard let current = try getProject(id: submission.project.id) else { throw DraftStoreError.missing }
            guard current == submission.project else { throw DraftStoreError.conflict }
            guard current.fields.outputDirectoryID == submission.directory.id,
                  try getDirectory(id: submission.directory.id) == submission.directory else { throw StudioStoreError.staleDirectory }
            let compiled = try PromptCompiler.compile(mode: current.fields.mode, prompt: current.fields.prompt, bindings: current.fields.referenceBindings)
            guard compiled.text == submission.compiledPrompt,
                  Set(compiled.bindings.map(\.referenceID)) == Set(submission.references.map(\.id)),
                  Set(submission.references.map(\.id)).count == submission.references.count else { throw StudioStoreError.invalidSubmission }
            for reference in submission.references {
                guard try getReference(id: reference.id) == reference else { throw StudioStoreError.staleReference }
            }
            guard submission.consent.confirmed, submission.consent.clientRequestID == submission.clientRequestID,
                  submission.consent.references == submission.references else { throw StudioStoreError.missingConsent }
            let consent = submission.consent
            let now = Date()
            guard consent.confirmedAt <= now, consent.expiresAt > now,
                  consent.expiresAt > consent.confirmedAt,
                  consent.expiresAt.timeIntervalSince(consent.confirmedAt) <= 600 else { throw StudioStoreError.expiredConsent }
            let id = "batch_" + UUID().uuidString
            try db.execute("INSERT INTO batches(id,client_request_id,request_hash,project_id,submission) VALUES(?,?,?,?,?)",
                           [.text(id), .text(submission.clientRequestID), .text(hash), .text(current.id), .blob(encoded)])
            for reference in submission.references {
                try db.execute("INSERT INTO upload_consents(batch_id,reference_id,content_hash,confirmed_at_ms,expires_at_ms) VALUES(?,?,?,?,?)",
                               [.text(id), .text(reference.id), .text(reference.contentHash),
                                .integer(Int(consent.confirmedAt.timeIntervalSince1970 * 1000)), .integer(Int(consent.expiresAt.timeIntervalSince1970 * 1000))])
            }
            var jobIDs: [String] = []
            for (index, seed) in submission.candidateSeeds.enumerated() {
                let jobID = "job_" + UUID().uuidString
                try db.execute("INSERT INTO jobs(id,batch_id,candidate_index,seed,state) VALUES(?,?,?,?,'queued')",
                               [.text(jobID), .text(id), .integer(index), .integer(seed)])
                for reference in submission.references {
                    try db.execute("INSERT INTO reference_leases(job_id,reference_id) VALUES(?,?)", [.text(jobID), .text(reference.id)])
                }
                jobIDs.append(jobID)
            }
            return StoredBatch(id: id, requestHash: hash, submission: submission, jobIDs: jobIDs)
        }
    }
    public func getBatch(id: String) throws -> StoredBatch? {
        guard let row = try db.rows("SELECT request_hash,submission FROM batches WHERE id=?", [.text(id)]).first,
              let hash = row[0].string else { return nil }
        let jobs = try db.rows("SELECT id FROM jobs WHERE batch_id=? ORDER BY candidate_index", [.text(id)]).map { row in
            guard let id = row[0].string else { throw StudioStoreError.corruptRecord }; return id
        }
        return StoredBatch(id: id, requestHash: hash, submission: try storeDecode(BatchSubmission.self, row[1]), jobIDs: jobs)
    }

    private static let jobColumns = "id,batch_id,candidate_index,seed,state,result_uncertain,message"
    private func job(_ row: [SQLiteValue]) throws -> StoredJob {
        guard let id = row[0].string, let batch = row[1].string, let index = row[2].int, let seed = row[3].int,
              let stateString = row[4].string, let state = JobState(rawValue: stateString), let uncertain = row[5].int else { throw StudioStoreError.corruptRecord }
        return StoredJob(id: id, batchID: batch, candidateIndex: index, seed: seed, state: state, resultUncertain: uncertain != 0, message: row[6].string)
    }
    public func getJob(id: String) throws -> StoredJob? {
        try db.rows("SELECT \(Self.jobColumns) FROM jobs WHERE id=?", [.text(id)]).first.map(job)
    }
    public func listLibrary() throws -> [StoredJob] {
        try db.rows("SELECT \(Self.jobColumns) FROM jobs WHERE id NOT IN (SELECT job_id FROM removed_jobs) ORDER BY rowid DESC").map(job)
    }
    public func listRemovedJobs() throws -> [StoredJob] {
        try db.rows("SELECT \(Self.jobColumns) FROM jobs WHERE id IN (SELECT job_id FROM removed_jobs) ORDER BY rowid DESC").map(job)
    }
    public func claimJob(id: String) throws -> StoredJob? {
        try db.transaction {
            guard try db.execute("UPDATE jobs SET state='preparing' WHERE id=? AND state='queued'", [.text(id)]) == 1 else { return nil }
            return try getJob(id: id)
        }
    }
    public func cancelQueued(id: String) throws -> Bool {
        try db.transaction {
            guard try db.execute("UPDATE jobs SET state='cancelled' WHERE id=? AND state='queued'", [.text(id)]) == 1 else { return false }
            try releaseReferenceRows(jobID: id)
            return true
        }
    }
    public func transitionJob(id: String, from: JobState, to: JobState, message: String? = nil) throws -> Bool {
        let valid: Bool
        switch (from, to) {
        case (.preparing, .requesting), (.preparing, .failed), (.requesting, .failed),
             (.downloading, .validating), (.downloading, .failed), (.validating, .success), (.validating, .failed): valid = true
        default: valid = false
        }
        guard valid else { throw StudioStoreError.invalidTransition }
        return try db.transaction {
            let changed = try db.execute("UPDATE jobs SET state=?,message=? WHERE id=? AND state=?", [.text(to.rawValue), message.map { .text(Self.safeJobMessage($0)) } ?? .null, .text(id), .text(from.rawValue)]) == 1
            if changed && to.isTerminal { try releaseReferenceRows(jobID: id) }
            return changed
        }
    }
    public func markResultUncertain(id: String, message: String) throws -> Bool {
        try db.transaction {
            let changed = try db.execute("UPDATE jobs SET state='interrupted',result_uncertain=1,message=? WHERE id=? AND state='requesting'", [.text(Self.safeJobMessage(message)), .text(id)]) == 1
            if changed { try releaseReferenceRows(jobID: id) }
            return changed
        }
    }

    /// The only requesting → downloading transition. Commit the receipt BEFORE GET.
    public func recordProviderResponse(id: String, response: ProviderResponseSnapshot) throws -> Bool {
        guard !response.providerRequestID.isEmpty, response.providerRequestID.utf8.count <= 128,
              response.providerRequestID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              response.audioURL.scheme?.lowercased() == "https",
              response.audioURL.host?.isEmpty == false else { throw StudioStoreError.invalidSubmission }
        return try db.transaction {
            try db.execute("UPDATE jobs SET provider_response=?,state='downloading',message=NULL WHERE id=? AND state='requesting'",
                           [.blob(try storeEncode(response)), .text(id)]) == 1
        }
    }
    /// For the download worker only; this value is deliberately absent from StoredJob/listLibrary.
    public func providerResponse(id: String) throws -> ProviderResponseSnapshot? {
        guard let row = try db.rows("SELECT provider_response FROM jobs WHERE id=?", [.text(id)]).first,
              row[0] != .null else { return nil }
        return try storeDecode(ProviderResponseSnapshot.self, row[0])
    }
    /// Explicit retry of a known GET, never of a paid POST. Exactly one caller wins.
    public func claimDownloadRetry(id: String) throws -> ProviderResponseSnapshot? {
        try db.transaction {
            guard try db.execute("UPDATE jobs SET state='downloading',message=NULL WHERE id=? AND state IN ('interrupted','failed') AND result_uncertain=0 AND provider_response IS NOT NULL", [.text(id)]) == 1 else { return nil }
            guard let response = try providerResponse(id: id) else { throw StudioStoreError.corruptRecord }
            return response
        }
    }

    public func registerAsset(_ asset: StoredAsset) throws {
        guard Self.safeRelativePath(asset.relativePath) else { throw StudioStoreError.invalidPath }
        try db.execute("INSERT INTO assets(id,job_id,directory_id,metadata) VALUES(?,?,?,?)", [.text(asset.id), .text(asset.jobID), .text(asset.directoryID), .blob(try storeEncode(asset))])
    }
    public func listAssets(jobID: String) throws -> [StoredAsset] {
        try db.rows("SELECT metadata FROM assets WHERE job_id=? ORDER BY rowid", [.text(jobID)]).map { try storeDecode(StoredAsset.self, $0[0]) }
    }
    public func listAssets(directoryID: String) throws -> [StoredAsset] {
        try db.rows("SELECT metadata FROM assets WHERE directory_id=? ORDER BY rowid", [.text(directoryID)]).map { try storeDecode(StoredAsset.self, $0[0]) }
    }
    /// Covers journal inspection, filesystem movement and final metadata commit,
    /// including actor reentrancy while the caller awaits another service.
    public func withFileJob<T: Sendable>(_ job: String, operation: @Sendable () async throws -> T) async throws -> T {
        guard busyFileJobs.insert(job).inserted else { throw StudioStoreError.invalidTransition }
        defer { busyFileJobs.remove(job) }
        return try await operation()
    }
    /// Journal first; Task 5 moves files outside this transaction, then finishes the entry.
    public func journalFileOperation(_ operation: FileOperation) throws {
        guard Self.safeRelativePath(operation.sourceRelativePath), Self.safeRelativePath(operation.destinationRelativePath),
              operation.sourceRelativePath != operation.destinationRelativePath else { throw StudioStoreError.invalidPath }
        try db.transaction {
            guard let row = try db.rows("SELECT metadata FROM assets WHERE id=?", [.text(operation.assetID)]).first else { throw StudioStoreError.missing }
            let asset = try storeDecode(StoredAsset.self, row[0])
            guard asset.appOwned, asset.relativePath == operation.sourceRelativePath else { throw StudioStoreError.invalidPath }
            guard try db.rows("SELECT id FROM file_operations WHERE asset_id=? AND state='pending'", [.text(asset.id)]).isEmpty else { throw StudioStoreError.invalidTransition }
            try db.execute("INSERT INTO file_operations(id,asset_id,state,operation) VALUES(?,?,'pending',?)", [.text(operation.id), .text(operation.assetID), .blob(try storeEncode(operation))])
            if operation.kind == .trash {
                try db.execute("INSERT OR IGNORE INTO recycled_assets(asset_id,original_path) VALUES(?,?)", [.text(asset.id), .text(asset.relativePath)])
            }
        }
    }
    public func pendingFileOperations() throws -> [FileOperation] {
        try db.rows("SELECT operation FROM file_operations WHERE state='pending' ORDER BY rowid").map { try storeDecode(FileOperation.self, $0[0]) }
    }
    /// Keep the same pending operation and recovery metadata when a newly
    /// occupied destination requires a different exclusive name.
    public func retargetPendingFileOperation(id: String, destinationRelativePath: String) throws -> FileOperation {
        guard Self.safeRelativePath(destinationRelativePath) else { throw StudioStoreError.invalidPath }
        return try db.transaction {
            guard let row = try db.rows("SELECT operation FROM file_operations WHERE id=? AND state='pending'", [.text(id)]).first else { throw StudioStoreError.missing }
            let old = try storeDecode(FileOperation.self, row[0])
            guard old.sourceRelativePath != destinationRelativePath else { throw StudioStoreError.invalidPath }
            let updated = FileOperation(id: old.id, assetID: old.assetID, sourceRelativePath: old.sourceRelativePath,
                destinationRelativePath: destinationRelativePath, kind: old.kind)
            try db.execute("UPDATE file_operations SET operation=? WHERE id=? AND state='pending'", [.blob(try storeEncode(updated)), .text(id)])
            return updated
        }
    }
    public func finishFileOperation(id: String, error: String? = nil) throws {
        try db.transaction {
            guard let row = try db.rows("SELECT operation FROM file_operations WHERE id=? AND state='pending'", [.text(id)]).first else { throw StudioStoreError.missing }
            let operation = try storeDecode(FileOperation.self, row[0])
            if error == nil {
                guard let assetRow = try db.rows("SELECT metadata FROM assets WHERE id=?", [.text(operation.assetID)]).first else { throw StudioStoreError.missing }
                let asset = try storeDecode(StoredAsset.self, assetRow[0])
                let updated = StoredAsset(id: asset.id, jobID: asset.jobID, directoryID: asset.directoryID, relativePath: operation.destinationRelativePath, kind: asset.kind, appOwned: asset.appOwned, fileIdentity: asset.fileIdentity)
                try db.execute("UPDATE assets SET metadata=? WHERE id=?", [.blob(try storeEncode(updated)), .text(asset.id)])
            }
            if (error == nil && operation.kind == .restore) || (error != nil && operation.kind == .trash) {
                try db.execute("DELETE FROM recycled_assets WHERE asset_id=?", [.text(operation.assetID)])
            }
            try db.execute("UPDATE file_operations SET state=?,error=? WHERE id=?", [.text(error == nil ? "completed" : "failed"), error.map(SQLiteValue.text) ?? .null, .text(id)])
        }
    }
    private static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }
    private static func safeJobMessage(_ input: String) -> String {
        var value = input
        for pattern in [#"(?i)(?:https?|file)://[^\s\"'<>]+"#, #"(?i)bearer\s+[^\s\"'<>]+"#,
                        #"(?i)sk-[a-z0-9_-]{8,}"#, #"(?i)(?:api[_-]?key|workspace[_-]?id)\s*[:=]\s*[^\s\"'<>]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[已脱敏]", options: .regularExpression)
        }
        return String(value.prefix(300))
    }

    public func listTemplates() throws -> [StudioTemplate] {
        try db.rows("SELECT template FROM templates ORDER BY rowid").map { try storeDecode(StudioTemplate.self, $0[0]) }
    }
    public func templateFavorites() throws -> Set<String> {
        Set(try db.rows("SELECT template_id FROM template_favorites").map {
            guard let id = $0[0].string else { throw StudioStoreError.corruptRecord }; return id
        })
    }
    public func saveTemplate(_ template: StudioTemplate) throws {
        guard !template.isBuiltin else { throw TemplateError.readOnly }
        try TemplateEngine.validate(template)
        try db.transaction {
            if try db.rows("SELECT builtin FROM templates WHERE id=?", [.text(template.id)]).first?.first?.int == 1 { throw TemplateError.readOnly }
            try db.execute("INSERT INTO templates(id,builtin,template) VALUES(?,0,?) ON CONFLICT(id) DO UPDATE SET template=excluded.template", [.text(template.id), .blob(try storeEncode(template))])
        }
    }
    public func removeTemplate(id: String) throws {
        try db.transaction {
            guard let row = try db.rows("SELECT builtin FROM templates WHERE id=?", [.text(id)]).first else { throw TemplateError.missing }
            guard row[0].int == 0 else { throw TemplateError.readOnly }
            try db.execute("DELETE FROM templates WHERE id=?", [.text(id)])
        }
    }
    public func setTemplateFavorite(id: String, favorite: Bool) throws {
        try db.transaction {
            guard try !db.rows("SELECT id FROM templates WHERE id=?", [.text(id)]).isEmpty else { throw TemplateError.missing }
            if favorite { try db.execute("INSERT OR IGNORE INTO template_favorites(template_id) VALUES(?)", [.text(id)]) }
            else { try db.execute("DELETE FROM template_favorites WHERE template_id=?", [.text(id)]) }
        }
    }
}

public struct SQLiteDraftStore: DraftStore {
    public let store: StudioStore
    public init(store: StudioStore) { self.store = store }
    public func create(_ fields: DraftFields) async throws -> ProjectDraft { try await store.createProject(fields: fields) }
    public func save(_ draft: ProjectDraft, expectedRevision: Int) async throws -> ProjectDraft {
        try await store.saveProject(id: draft.id, expectedRevision: expectedRevision, changes: draft.fields)
    }
    public func get(id: String) async throws -> ProjectDraft? { try await store.getProject(id: id) }
    public func list() async throws -> [ProjectDraft] { try await store.listProjects() }
}

public struct SQLiteTemplateStore: TemplateStore {
    public let store: StudioStore
    public init(store: StudioStore) { self.store = store }
    public func list() async throws -> [StudioTemplate] { try await store.listTemplates() }
    public func favorites() async throws -> Set<String> { try await store.templateFavorites() }
    public func save(_ template: StudioTemplate) async throws { try await store.saveTemplate(template) }
    public func remove(id: String) async throws { try await store.removeTemplate(id: id) }
    public func setFavorite(id: String, favorite: Bool) async throws { try await store.setTemplateFavorite(id: id, favorite: favorite) }
}
