import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ReportQuotaTests: XCTestCase {
    func testRemoteAuthorRatePersistsAndDuplicatesDoNotConsumeAllowance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourcePath = directory.appendingPathComponent("source.sqlite").path
        let destinationPath = directory.appendingPathComponent("destination.sqlite").path
        let identity = try ReportIdentity.create(store: QuotaKeyStore())
        let source = try ReportRepository(path: sourcePath)
        let now: Int64 = 1_789_647_000_000
        let draft = ReportDraft(category: "water", status: "dry", observedAt: now,
                                latitude: 0, longitude: 0, accuracy: 1, note: "test",
                                expiresAt: now + 7_200_000, maxHops: 1)
        for _ in 0..<21 {
            guard case .stored = try await source.author(draft, identity: identity, now: now) else {
                return XCTFail("Could not generate independent signed reports")
            }
        }
        let sourceDB = try ReportDatabase.open(path: sourcePath)
        let wires = try await sourceDB.read { db in try Data.fetchAll(db, sql: "SELECT original_wire FROM bundles ORDER BY rowid") }
        XCTAssertEqual(wires.count, 21)
        let destination = try ReportRepository(path: destinationPath)
        for wire in wires.prefix(20) {
            guard case .stored = try await destination.ingest(wire, now: now) else { return XCTFail("Within-limit report rejected") }
        }
        let duplicate = try await destination.ingest(wires[0], now: now)
        guard case .duplicate = duplicate else { return XCTFail("Duplicate consumed allowance") }
        let reopened = try ReportRepository(path: destinationPath)
        let overLimit = try await reopened.ingest(wires[20], now: now)
        XCTAssertEqual(overLimit, .rejected(.quota))
        let afterWindow = try await reopened.ingest(wires[20], now: now + 3_600_000)
        guard case .stored = afterWindow else { return XCTFail("Hourly allowance did not recover") }
    }

    func testSeenIDsAreBoundedAfterAdmission() async throws {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in
            try db.execute(sql: """
                WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 10000)
                INSERT INTO seen_ids SELECT printf('%064x', n), ?, 'test' FROM numbers
                """, arguments: [now + 1_000])
        }
        _ = try await repository.ingest(wire, now: now)
        let remaining = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_ids") }
        XCTAssertEqual(remaining, 10_000)
        let first = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_ids WHERE bundle_id = printf('%064x', 1)") }
        XCTAssertEqual(first, 0)
    }

    func testRemoteCapacityReservesRoomForLocalReports() async throws {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO bundles (bundle_id, canonical_core, signature, original_wire, author_key,
                  created_at_ms, expires_at_ms, admitted_at_ms, is_local)
                VALUES ('quota-fixture', zeroblob(1), zeroblob(64), zeroblob(20971455), zeroblob(32), ?, ?, ?, 0)
                """, arguments: [now - 1, now + 7_200_000, now])
        }
        let rejected = try await repository.ingest(wire, now: now)
        XCTAssertEqual(rejected, .rejected(.quota))
        let identity = try ReportIdentity.create(store: QuotaKeyStore())
        let draft = ReportDraft(category: "water", status: "dry", observedAt: now,
                                latitude: 0, longitude: 0, accuracy: 1, note: "test",
                                expiresAt: now + 3_600_000, maxHops: 1)
        guard case .stored = try await repository.author(draft, identity: identity, now: now) else {
            return XCTFail("Remote capacity must reserve room for a local report")
        }
        let counts = try await database.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles WHERE is_local = 0") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles WHERE is_local = 1") ?? 0)
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }


    func testExpiredHistoryOlderThanSevenDaysIsCleanedDuringAdmission() async throws {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO bundles (bundle_id, canonical_core, signature, original_wire, author_key,
                  created_at_ms, expires_at_ms, admitted_at_ms, is_local)
                VALUES ('expired-history', X'01', zeroblob(64), X'01', zeroblob(32), ?, ?, ?, 1)
                """, arguments: [now - 604_800_010, now - 604_800_001, now - 604_800_010])
        }
        _ = try await repository.ingest(wire, now: now)
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles WHERE bundle_id = 'expired-history'") }
        XCTAssertEqual(count, 0)
    }

}

private final class QuotaKeyStore: IdentityKeyStore {
    var data: Data?
    func load() throws -> Data? { data }
    func saveNew(_ bytes: Data) throws {
        guard data == nil else { throw IdentityError.alreadyExists }
        data = bytes
    }
}
