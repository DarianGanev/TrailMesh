import Foundation
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
                guard applied.isSubset(of: ["v1", "v2", "v3"]),
                      !applied.contains("v2") || applied.contains("v1"),
                      !applied.contains("v3") || applied.contains("v2") else {
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
                    note BLOB NOT NULL,
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
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE quarantined_ids (
                    bundle_id TEXT PRIMARY KEY NOT NULL REFERENCES bundles(bundle_id) ON DELETE CASCADE,
                    rate_hold_until_ms INTEGER NOT NULL
                );
                """)
            // Pre-release v1/v2 used TEXT. Rebuild note bytes from authenticated wire
            // so an embedded NUL is not lost during migration.
            let legacy = try Row.fetchAll(db, sql: """
                SELECT b.bundle_id, b.original_wire, b.canonical_core, b.signature, b.admitted_at_ms
                FROM bundles b JOIN reports r ON r.bundle_id = b.bundle_id WHERE typeof(r.note) = 'text'
                """)
            for row in legacy {
                let id = try row.decode(String.self, forColumn: "bundle_id")
                let wire = try row.decode(Data.self, forColumn: "original_wire")
                let canonical = try row.decode(Data.self, forColumn: "canonical_core")
                let signature = try row.decode(Data.self, forColumn: "signature")
                let admitted = try row.decode(Int64.self, forColumn: "admitted_at_ms")
                let verified = ReportAdmission.validate(wire, now: admitted)
                var parser = try StrictReportJSONParser(wire)
                let envelope = try parser.parse()
                guard verified.outcome == "accepted", verified.bundleID == id, verified.canonicalCore == canonical,
                      ReportAdmission.binary(envelope["signature"], count: 64) == signature,
                      let note = envelope["core"]?["body"]?["note"]?.string else {
                    throw ReportDatabaseError.corruptLegacyReport
                }
                try db.execute(sql: "UPDATE reports SET note = CASE WHEN ? = 0 THEN zeroblob(0) ELSE ? END WHERE bundle_id = ?", arguments: [note.utf8.count, Data(note.utf8), id])
            }
        }
        try migrator.migrate(queue)
        return queue
    }
}


public enum ReportDatabaseError: Error {
    case unsupportedSchema
    case corruptLegacyReport
}
