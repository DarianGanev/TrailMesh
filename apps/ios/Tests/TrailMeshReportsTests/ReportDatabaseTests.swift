import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ReportDatabaseTests: XCTestCase {
    func testNewDatabaseHasAllReportTablesAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let expected = Set(["bundles", "reports", "relay_state", "seen_ids"])
        do {
            let database = try ReportDatabase.open(path: path)
            let names = try database.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            }
            XCTAssertTrue(expected.isSubset(of: Set(names)), "Missing tables: \(expected.subtracting(names))")
        }
        let reopened = try ReportDatabase.open(path: path)
        let names = try reopened.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertTrue(expected.isSubset(of: Set(names)))
    }

    func testConstraintFailureRollsBackBundleInsert() throws {
        let database = try ReportDatabase.open(path: ":memory:")
        XCTAssertThrowsError(try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bundles
                      (bundle_id, canonical_core, signature, original_wire, author_key,
                       created_at_ms, expires_at_ms, admitted_at_ms, is_local)
                    VALUES (?, ?, ?, ?, ?, 1, 2, 1, 0)
                    """,
                arguments: ["test", Data([1]), Data(repeating: 0, count: 64),
                            Data([2]), Data(repeating: 0, count: 32)])
            try db.execute(
                sql: """
                    INSERT INTO reports
                      (bundle_id, event_id, category, status, observed_at_ms, lat_e7,
                       lon_e7, accuracy_m, note)
                    VALUES (?, ?, 'water', 'dry', 1, 0, 0, 0, '')
                    """,
                arguments: ["test", Data(repeating: 0, count: 15)])
        })
        let count = try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 0)
    }

    func testRelayStateCannotReferenceMissingBundle() throws {
        let database = try ReportDatabase.open(path: ":memory:")
        XCTAssertThrowsError(try database.write { db in
            try db.execute(sql: "INSERT INTO relay_state VALUES ('missing', 10, 1, 0)")
        })
    }

}
