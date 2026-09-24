import Foundation

enum StudioSchema {
    static func migrate(_ db: SQLiteConnection) throws {
        let version = try db.rows("PRAGMA user_version").first?.first?.int ?? 0
        guard version <= 6 else { throw StudioStoreError.unsupportedSchema(version) }
        if version == 0 {
        try db.transaction {
            for statement in [
                "CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), fields BLOB NOT NULL)",
                "CREATE TABLE directories (id TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL CHECK(version > 0), snapshot BLOB NOT NULL)",
                "CREATE TABLE reference_voices (id TEXT PRIMARY KEY NOT NULL, content_hash TEXT NOT NULL, snapshot BLOB NOT NULL)",
                "CREATE TABLE batches (id TEXT PRIMARY KEY NOT NULL, client_request_id TEXT NOT NULL UNIQUE, request_hash TEXT NOT NULL, project_id TEXT NOT NULL REFERENCES projects(id), submission BLOB NOT NULL)",
                "CREATE TABLE jobs (id TEXT PRIMARY KEY NOT NULL, batch_id TEXT NOT NULL REFERENCES batches(id), candidate_index INTEGER NOT NULL CHECK(candidate_index BETWEEN 0 AND 2), seed INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('queued','preparing','requesting','downloading','validating','success','failed','cancelled','interrupted')), result_uncertain INTEGER NOT NULL DEFAULT 0 CHECK(result_uncertain IN (0,1)), message TEXT, provider_response BLOB, UNIQUE(batch_id,candidate_index), UNIQUE(batch_id,seed))",
                "CREATE INDEX jobs_state ON jobs(state)",
                "CREATE TABLE upload_consents (batch_id TEXT NOT NULL REFERENCES batches(id), reference_id TEXT NOT NULL REFERENCES reference_voices(id), content_hash TEXT NOT NULL, confirmed_at_ms INTEGER NOT NULL, expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms > confirmed_at_ms AND expires_at_ms <= confirmed_at_ms + 600000), PRIMARY KEY(batch_id,reference_id))",
                "CREATE TABLE reference_leases (job_id TEXT NOT NULL REFERENCES jobs(id), reference_id TEXT NOT NULL REFERENCES reference_voices(id), PRIMARY KEY(job_id,reference_id))",
                "CREATE TABLE assets (id TEXT PRIMARY KEY NOT NULL, job_id TEXT NOT NULL REFERENCES jobs(id), directory_id TEXT NOT NULL REFERENCES directories(id), metadata BLOB NOT NULL)",
                "CREATE TABLE file_operations (id TEXT PRIMARY KEY NOT NULL, asset_id TEXT NOT NULL REFERENCES assets(id), state TEXT NOT NULL CHECK(state IN ('pending','completed','failed')), operation BLOB NOT NULL, error TEXT)",
                "CREATE TABLE templates (id TEXT PRIMARY KEY NOT NULL, builtin INTEGER NOT NULL CHECK(builtin IN (0,1)), template BLOB NOT NULL)",
                "CREATE TABLE template_favorites (template_id TEXT PRIMARY KEY NOT NULL REFERENCES templates(id) ON DELETE CASCADE)",
                "PRAGMA user_version = 1"
            ] { try db.execute(statement) }
        }
        }
        if version < 2 {
            try db.transaction {
                for statement in [
                    "CREATE TABLE output_settings (singleton INTEGER PRIMARY KEY CHECK(singleton=1), default_directory_id TEXT REFERENCES directories(id))",
                    "CREATE TABLE job_output_folders (job_id TEXT PRIMARY KEY NOT NULL REFERENCES jobs(id), directory_id TEXT NOT NULL REFERENCES directories(id), relative_path TEXT NOT NULL, identity BLOB NOT NULL, UNIQUE(directory_id,relative_path))",
                    "CREATE TABLE removed_jobs (job_id TEXT PRIMARY KEY NOT NULL REFERENCES jobs(id), scope TEXT NOT NULL CHECK(scope IN ('recordOnly','generatedFiles')))",
                    "CREATE TABLE recycled_assets (asset_id TEXT PRIMARY KEY NOT NULL REFERENCES assets(id), original_path TEXT NOT NULL)",
                    "PRAGMA user_version = 2"
                ] { try db.execute(statement) }
            }
        }
        if version < 3 {
            try db.transaction {
                try db.execute("ALTER TABLE reference_voices ADD COLUMN last_used_ms INTEGER NOT NULL DEFAULT 0")
                try db.execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try db.transaction {
                try db.execute("CREATE TABLE reference_cleanup (reference_id TEXT PRIMARY KEY NOT NULL, snapshot BLOB NOT NULL)")
                try db.execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try db.transaction {
                try db.execute("CREATE TABLE job_metadata (job_id TEXT PRIMARY KEY NOT NULL REFERENCES jobs(id), name TEXT NOT NULL DEFAULT '', favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0,1)), note TEXT NOT NULL DEFAULT '')")
                try db.execute("CREATE TABLE batch_final (batch_id TEXT PRIMARY KEY NOT NULL REFERENCES batches(id), job_id TEXT NOT NULL REFERENCES jobs(id))")
                try db.execute("CREATE TABLE project_metadata (project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(id), archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)))")
                try db.execute("ALTER TABLE jobs ADD COLUMN created_at_ms INTEGER NOT NULL DEFAULT 0")
                try db.execute("CREATE TABLE workspace_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), current_project_id TEXT REFERENCES projects(id))")
                try db.execute("PRAGMA user_version = 5")
            }
        }
        if version < 6 {
            try db.transaction {
                try db.execute("CREATE TABLE legacy_job_snapshots (job_id TEXT PRIMARY KEY NOT NULL REFERENCES jobs(id), snapshot BLOB NOT NULL)")
                try db.execute("PRAGMA user_version = 6")
            }
        }
    }
}
