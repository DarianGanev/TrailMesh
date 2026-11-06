import GRDB

/// Opens the report database and applies its non-destructive migrations.
enum ReportDatabase {
    static func open(path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try queue.read { db in
            let hasMigrations = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'grdb_migrations')") ?? false
            if hasMigrations {
                let applied = Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
                guard applied.isSubset(of: ["v1", "v2"]), !applied.contains("v2") || applied.contains("v1") else {
                    throw ReportDatabaseError.unsupportedSchema
                }
            }
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE bundles (
                    bundle_id TEXT PRIMARY KEY NOT NULL,
                    canonical_core BLOB NOT NULL,
                    signature BLOB NOT NULL CHECK (length(signature) = 64),
                    original_wire BLOB NOT NULL,
                    author_key BLOB NOT NULL CHECK (length(author_key) = 32),
                    created_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    admitted_at_ms INTEGER NOT NULL,
                    is_local INTEGER NOT NULL CHECK (is_local IN (0, 1)),
                    CHECK (created_at_ms >= 0 AND created_at_ms < expires_at_ms),
                    CHECK (admitted_at_ms >= 0)
                );
                CREATE TABLE reports (
                    bundle_id TEXT PRIMARY KEY NOT NULL REFERENCES bundles(bundle_id) ON DELETE CASCADE,
                    event_id BLOB NOT NULL CHECK (length(event_id) = 16),
                    category TEXT NOT NULL,
                    status TEXT NOT NULL,
                    observed_at_ms INTEGER NOT NULL,
                    lat_e7 INTEGER NOT NULL,
                    lon_e7 INTEGER NOT NULL,
                    accuracy_m INTEGER NOT NULL,
                    note TEXT NOT NULL,
                    supersedes TEXT
                );
                CREATE TABLE relay_state (
                    bundle_id TEXT PRIMARY KEY NOT NULL REFERENCES bundles(bundle_id) ON DELETE CASCADE,
                    local_expiry_ms INTEGER NOT NULL,
                    max_hops INTEGER NOT NULL CHECK (max_hops BETWEEN 0 AND 12),
                    outbox INTEGER NOT NULL CHECK (outbox IN (0, 1))
                );
                CREATE TABLE seen_ids (
                    bundle_id TEXT PRIMARY KEY NOT NULL,
                    retain_until_ms INTEGER NOT NULL,
                    reason TEXT NOT NULL
                );
                CREATE INDEX bundles_expiry ON bundles(expires_at_ms);
                CREATE INDEX bundles_author_admission ON bundles(author_key, admitted_at_ms);
                CREATE INDEX reports_event ON reports(event_id);
                CREATE INDEX reports_location ON reports(lat_e7, lon_e7);
                CREATE INDEX relay_expiry ON relay_state(local_expiry_ms);
                CREATE INDEX seen_retention ON seen_ids(retain_until_ms, bundle_id);
                """)
        }
        // v1 was a pre-release schema; v2 adds a persisted clock high-water mark.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE repository_clock (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    last_now_ms INTEGER NOT NULL CHECK (last_now_ms >= 0)
                );
                INSERT INTO repository_clock (singleton, last_now_ms)
                SELECT 1, COALESCE(MAX(admitted_at_ms), 0) FROM bundles;
                """)
        }
        try migrator.migrate(queue)
        return queue
    }
}


public enum ReportDatabaseError: Error {
    case unsupportedSchema
}
