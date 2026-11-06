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
        for _ in 0..<22 {
            guard case .stored = try await source.author(draft, identity: identity, now: now) else {
                return XCTFail("Could not generate independent signed reports")
            }
        }
        let sourceDB = try ReportDatabase.open(path: sourcePath)
        let wires = try await sourceDB.read { db in try Data.fetchAll(db, sql: "SELECT original_wire FROM bundles ORDER BY rowid") }
        XCTAssertEqual(wires.count, 22)
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
        _ = try await reopened.recoverClockAfterUserConfirmation(now: now - 1)
        let afterRecovery = try await reopened.ingest(wires[21], now: now - 1)
        XCTAssertEqual(afterRecovery, .rejected(.quota), "Clock recovery must not reset the author limit")
        _ = try await reopened.forwardable(now: now + 1)
        _ = try await reopened.recoverClockAfterUserConfirmation(now: now - 2)
        let afterSecondRecovery = try await reopened.ingest(wires[21], now: now - 2)
        XCTAssertEqual(afterSecondRecovery, .rejected(.quota))
        let afterHold = try await reopened.ingest(wires[21], now: now + 3_599_998)
        guard case .stored = afterHold else { return XCTFail("Rate hold did not expire after one hour") }
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
        let full = try await repository.ingest(wire, now: now)
        XCTAssertEqual(full, .rejected(.quota))
        let retained = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_ids") }
        XCTAssertEqual(retained, 10_000)
        _ = try await repository.reclaimExpiredReportsAfterUserConfirmation(now: now + 1_000)
        guard case .stored = try await repository.ingest(wire, now: now + 1_000) else { return XCTFail("Confirmed cleanup should free seen-ID capacity") }
        let remaining = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_ids") }
        XCTAssertEqual(remaining, 1)
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


    func testExpiredHistoryRemainsUntilConfirmedCleanup() async throws {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let core = try XCTUnwrap(envelope["core"] as? [String: Any])
        let expires = try XCTUnwrap(core["expires_at_ms"] as? Int64)
        let repository = try ReportRepository(path: ":memory:")
        guard case .stored = try await repository.ingest(wire, now: now) else { return XCTFail("Report was not stored") }
        let later = expires + 604_800_001
        let world = ReportBounds(south: -900_000_000, north: 900_000_000, west: -1_800_000_000, east: 1_800_000_000)
        let history = try await repository.reports(now: later, bounds: world, includeExpired: true)
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history[0].isExpired)
        let reclaimed = try await repository.reclaimExpiredReportsAfterUserConfirmation(now: later)
        XCTAssertEqual(reclaimed, 1)
        let after = try await repository.reports(now: later, bounds: world, includeExpired: true)
        XCTAssertTrue(after.isEmpty)
    }

    func testConfirmedCleanupRemovesExpiredReportButKeepsSeenID() async throws {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let core = try XCTUnwrap(envelope["core"] as? [String: Any])
        let id = try XCTUnwrap(envelope["bundle_id"] as? String)
        let expires = try XCTUnwrap(core["expires_at_ms"] as? Int64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        _ = try await repository.ingest(wire, now: now)
        let reclaimed = try await repository.reclaimExpiredReportsAfterUserConfirmation(now: expires)
        XCTAssertEqual(reclaimed, 1)
        let database = try ReportDatabase.open(path: path)
        let counts = try await database.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles WHERE bundle_id = ?", arguments: [id]) ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_ids WHERE bundle_id = ?", arguments: [id]) ?? -1)
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
    }

    func testQuotaDoesNotEvictQuarantinedReportBeforeSignedExpiry() async throws {
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
                VALUES ('quarantined-remote', X'01', zeroblob(64), zeroblob(20971455), zeroblob(32), ?, ?, ?, 0)
                """, arguments: [now - 1000, now + 1000, now - 1000])
            try db.execute(sql: "INSERT INTO relay_state VALUES ('quarantined-remote', ?, 1, 0)", arguments: [now - 1])
            try db.execute(sql: "INSERT INTO quarantined_ids VALUES ('quarantined-remote', ?)", arguments: [now + 3_600_000])
        }
        let result = try await repository.ingest(wire, now: now)
        XCTAssertEqual(result, .rejected(.quota))
        let reclaimed = try await repository.reclaimExpiredReportsAfterUserConfirmation(now: now)
        XCTAssertEqual(reclaimed, 0)
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles WHERE bundle_id = 'quarantined-remote'") }
        XCTAssertEqual(count, 1)
    }


    func testQuotaKeepsExpiredRemoteWhileNeededForRateAccounting() async throws {
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
                VALUES ('rate-held', X'01', zeroblob(64), zeroblob(20971455), zeroblob(32), ?, ?, ?, 0)
                """, arguments: [now - 1000, now - 1, now - 1000])
            try db.execute(sql: "INSERT INTO relay_state VALUES ('rate-held', ?, 1, 0)", arguments: [now - 1])
        }
        let result = try await repository.ingest(wire, now: now)
        XCTAssertEqual(result, .rejected(.quota))
        let reclaimed = try await repository.reclaimExpiredReportsAfterUserConfirmation(now: now)
        XCTAssertEqual(reclaimed, 0)
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles WHERE bundle_id = 'rate-held'") }
        XCTAssertEqual(count, 1)
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
