import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ReportMigrationTests: XCTestCase {
    private func fixture() throws -> (Data, Int64) {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let bytes = try Data(contentsOf: resource)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        return (try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String))), try XCTUnwrap(item["now_ms"] as? Int64))
    }

    func testMissingProjectionCannotBeConfirmedAsDuplicate() async throws {
        let (wire, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        _ = try await repository.ingest(wire, now: now)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in try db.execute(sql: "DELETE FROM reports") }
        do {
            _ = try await repository.ingest(wire, now: now + 1)
            XCTFail("A missing projection must not be reported as a stored duplicate")
        } catch ReportStoreError.conflictingStoredBundle { }
    }

    func testV1DatabaseUpgradePreservesReportAndInitializesClock() async throws {
        let (wire, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        _ = try await repository.ingest(wire, now: now)
        let v1 = try ReportDatabase.open(path: path)
        let snapshotSQL = """
            SELECT quote(b.bundle_id) || '|' || quote(b.canonical_core) || '|' || quote(b.signature) || '|' ||
                   quote(b.original_wire) || '|' || quote(b.author_key) || '|' || quote(b.created_at_ms) || '|' ||
                   quote(b.expires_at_ms) || '|' || quote(b.admitted_at_ms) || '|' || quote(b.is_local) || '|' ||
                   quote(r.event_id) || '|' || quote(r.category) || '|' || quote(r.status) || '|' ||
                   quote(r.observed_at_ms) || '|' || quote(r.lat_e7) || '|' || quote(r.lon_e7) || '|' ||
                   quote(r.accuracy_m) || '|' || quote(r.note) || '|' || quote(r.supersedes) || '|' ||
                   quote(s.local_expiry_ms) || '|' || quote(s.max_hops) || '|' || quote(s.outbox)
            FROM bundles b JOIN reports r USING(bundle_id) JOIN relay_state s USING(bundle_id)
            """
        let before = try await v1.read { db -> ([String], [String]) in
            (try String.fetchAll(db, sql: snapshotSQL),
             try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name"))
        }
        XCTAssertEqual(before.0.count, 1)
        try await v1.write { db in
            try db.execute(sql: "DROP TABLE quarantined_ids")
            try db.execute(sql: "DROP TABLE repository_clock")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v2', 'v3')")
        }
        let upgraded = try ReportDatabase.open(path: path)
        let after = try await upgraded.read { db -> ([String], [String]) in
            (try String.fetchAll(db, sql: snapshotSQL),
             try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name"))
        }
        XCTAssertEqual(before.0, after.0)
        XCTAssertEqual(before.1, after.1)
        let saved = try await upgraded.read { db -> (Data, Int64, Int64) in
            let wire = try Data.fetchOne(db, sql: "SELECT original_wire FROM bundles")!
            let clock = try Int64.fetchOne(db, sql: "SELECT last_now_ms FROM repository_clock")!
            let count = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM reports JOIN relay_state USING(bundle_id)")!
            return (wire, clock, count)
        }
        XCTAssertEqual(saved.0, wire)
        XCTAssertEqual(saved.1, now)
        XCTAssertEqual(saved.2, 1)
    }

    func testUnknownMigrationDoesNotOpenDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let database = try ReportDatabase.open(path: path)
        try database.write { db in try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('future')") }
        XCTAssertThrowsError(try ReportDatabase.open(path: path))
    }

    func testSeenIDWithoutPayloadIsNotAcknowledgedOrReadmitted() async throws {
        let (wire, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        _ = try await repository.ingest(wire, now: now)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in try db.execute(sql: "DELETE FROM bundles") }
        do {
            _ = try await repository.ingest(wire, now: now + 1)
            XCTFail("A seen ID without its payload must not be reported as stored or duplicate")
        } catch ReportStoreError.seenWithoutPayload { }
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 0)
    }


    func testDuplicatePastLocalExpiryIsNotConfirmed() async throws {
        let (_, now) = try fixture()
        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let sourcePath = sourceDirectory.appendingPathComponent("source.sqlite").path
        let source = try ReportRepository(path: sourcePath)
        let identity = try ReportIdentity.create(store: MigrationKeyStore())
        let created = now + 300_000
        let draft = ReportDraft(category: "water", status: "dry", observedAt: created, latitude: 0,
                                longitude: 0, accuracy: 1, note: "test", expiresAt: created + 259_200_000, maxHops: 1)
        guard case .stored = try await source.author(draft, identity: identity, now: created) else { return XCTFail("Source report was not stored") }
        let sourceDB = try ReportDatabase.open(path: sourcePath)
        let sourceWire = try await sourceDB.read { db in try Data.fetchOne(db, sql: "SELECT original_wire FROM bundles") }
        let wire = try XCTUnwrap(sourceWire)
        let repository = try ReportRepository(path: ":memory:")
        _ = try await repository.ingest(wire, now: now)
        let result = try await repository.ingest(wire, now: now + 259_200_000)
        XCTAssertEqual(result, .rejected(.expired))
    }

    func testFailedUpgradePreservesOriginalDataAndCanBeRetried() async throws {
        let (wire, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        _ = try await repository.ingest(wire, now: now)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in
            // Simulate v1 metadata with a conflicting table so migration v2 must fail.
            try db.execute(sql: "DROP TABLE quarantined_ids")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v2', 'v3')")
        }
        XCTAssertThrowsError(try ReportDatabase.open(path: path))
        let saved = try await database.read { db -> (Data?, Int) in
            (try Data.fetchOne(db, sql: "SELECT original_wire FROM bundles"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v2'") ?? -1)
        }
        XCTAssertEqual(saved.0, wire)
        XCTAssertEqual(saved.1, 0)
        try await database.write { db in try db.execute(sql: "DROP TABLE repository_clock") }
        _ = try ReportDatabase.open(path: path)
        let after = try await database.read { db in try Data.fetchOne(db, sql: "SELECT original_wire FROM bundles") }
        XCTAssertEqual(after, wire)
    }


    func testCorruptedWireAndProjectionAreNeverConfirmedOrReturned() async throws {
        let (wire, now) = try fixture()
        for column in ["original_wire", "wrong_wire_type", "status"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("reports.sqlite").path
            let repository = try ReportRepository(path: path)
            _ = try await repository.ingest(wire, now: now)
            let database = try ReportDatabase.open(path: path)
            try await database.write { db in
                if column == "original_wire" {
                    try db.execute(sql: "UPDATE bundles SET original_wire = X'010203'")
                } else if column == "wrong_wire_type" {
                    try db.execute(sql: "UPDATE bundles SET original_wire = 123")
                } else {
                    try db.execute(sql: "UPDATE reports SET status = 'flowing'")
                }
            }
            do { _ = try await repository.ingest(wire, now: now); XCTFail("Confirmed corrupt \(column)") } catch ReportStoreError.conflictingStoredBundle { }
            do { _ = try await repository.forwardable(now: now); XCTFail("Forwarded corrupt \(column)") } catch ReportStoreError.conflictingStoredBundle { }
            let world = ReportBounds(south: -900_000_000, north: 900_000_000, west: -1_800_000_000, east: 1_800_000_000)
            do { _ = try await repository.reports(now: now, bounds: world); XCTFail("Displayed corrupt \(column)") } catch ReportStoreError.conflictingStoredBundle { }
        }
    }


    func testCleanupRejectsCorruptExpiryWithoutDeletingReport() async throws {
        let (wire, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        _ = try await repository.ingest(wire, now: now)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in
            try db.execute(sql: "UPDATE bundles SET expires_at_ms = ?, is_local = 1", arguments: [now + 1])
            try db.execute(sql: "UPDATE relay_state SET local_expiry_ms = ?", arguments: [now + 1])
        }
        do {
            _ = try await repository.reclaimExpiredReportsAfterUserConfirmation(now: now + 1)
            XCTFail("Corrupt expiry must not authorize deletion")
        } catch ReportStoreError.conflictingStoredBundle { }
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 1)
    }

}

private final class MigrationKeyStore: IdentityKeyStore {
    var data: Data?
    func load() throws -> Data? { data }
    func saveNew(_ bytes: Data) throws {
        guard data == nil else { throw IdentityError.alreadyExists }
        data = bytes
    }
}
