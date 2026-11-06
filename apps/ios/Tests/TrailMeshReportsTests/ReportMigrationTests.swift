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
        } catch { }
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
        try await v1.write { db in
            try db.execute(sql: "DROP TABLE repository_clock")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2'")
        }
        let upgraded = try ReportDatabase.open(path: path)
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
        } catch { }
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 0)
    }


    func testDuplicatePastLocalExpiryIsNotConfirmed() async throws {
        let (wire, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        _ = try await repository.ingest(wire, now: now)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in try db.execute(sql: "UPDATE relay_state SET local_expiry_ms = ?", arguments: [now + 1]) }
        let result = try await repository.ingest(wire, now: now + 1)
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
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2'")
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

}
