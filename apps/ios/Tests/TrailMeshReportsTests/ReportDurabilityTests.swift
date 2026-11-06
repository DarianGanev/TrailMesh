import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ReportDurabilityTests: XCTestCase {
    private func fixture() throws -> (Data, Int64, Int64, String) {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let core = try XCTUnwrap(envelope["core"] as? [String: Any])
        return (wire, try XCTUnwrap(item["now_ms"] as? Int64), try XCTUnwrap(core["expires_at_ms"] as? Int64), try XCTUnwrap(envelope["bundle_id"] as? String))
    }

    func testForwardingExcludesExpiredReports() async throws {
        let (wire, now, expires, id) = try fixture()
        let repository = try ReportRepository(path: ":memory:")
        _ = try await repository.ingest(wire, now: now)
        let current = try await repository.forwardable(now: now)
        XCTAssertEqual(current, [ForwardableReport(bundleID: id, originalWire: wire)])
        let expired = try await repository.forwardable(now: expires)
        XCTAssertTrue(expired.isEmpty)
    }

    func testConcurrentIngestAcrossConnectionsStoresExactlyOnce() async throws {
        let (wire, now, _, id) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let first = try ReportRepository(path: path)
        let second = try ReportRepository(path: path)
        async let a = first.ingest(wire, now: now)
        async let b = second.ingest(wire, now: now)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0 == .stored(id) }.count, 1)
        XCTAssertEqual(results.filter { $0 == .duplicate(id) }.count, 1)
    }

    func testFailedProjectionInsertRollsBackAndRetrySucceeds() async throws {
        let (wire, now, _, id) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let repository = try ReportRepository(path: path)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in
            try db.execute(sql: "CREATE TRIGGER test_fail BEFORE INSERT ON reports BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        do { _ = try await repository.ingest(wire, now: now); XCTFail("Expected storage failure") } catch { }
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 0)
        try await database.write { db in try db.execute(sql: "DROP TRIGGER test_fail") }
        let retried = try await repository.ingest(wire, now: now)
        XCTAssertEqual(retried, .stored(id))
    }

    func testMapQueriesFilterBoundsAndRequireExplicitExpiredHistory() async throws {
        let (wire, now, expires, id) = try fixture()
        let repository = try ReportRepository(path: ":memory:")
        _ = try await repository.ingest(wire, now: now)
        let nearby = ReportBounds(south: 421_000_000, north: 422_000_000, west: 235_000_000, east: 236_000_000)
        let away = ReportBounds(south: 0, north: 1, west: 0, east: 1)
        let current = try await repository.reports(now: now, bounds: nearby)
        XCTAssertEqual(current.map(\.bundleID), [id])
        XCTAssertEqual(current.first?.category, "water")
        XCTAssertEqual(current.first?.status, "dry")
        let outside = try await repository.reports(now: now, bounds: away)
        XCTAssertTrue(outside.isEmpty)
        let expired = try await repository.reports(now: expires, bounds: nearby)
        XCTAssertTrue(expired.isEmpty)
        let history = try await repository.reports(now: expires, bounds: nearby, includeExpired: true)
        XCTAssertEqual(history.map(\.bundleID), [id])
    }


    func testMapBoundsCanCrossTheAntimeridian() async throws {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "unicode-and-boundaries" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        let expected = try XCTUnwrap(item["expected"] as? [String: Any])
        let id = try XCTUnwrap(expected["bundle_id"] as? String)
        let repository = try ReportRepository(path: ":memory:")
        _ = try await repository.ingest(wire, now: now)
        let bounds = ReportBounds(south: -900_000_000, north: -890_000_000, west: 1_700_000_000, east: -1_700_000_000)
        let reports = try await repository.reports(now: now, bounds: bounds)
        XCTAssertEqual(reports.map(\.bundleID), [id])
    }


    func testCancelledIngestBeforeTransactionLeavesNoStoredReport() async throws {
        let (wire, now, _, id) = try fixture()
        let repository = try ReportRepository(path: ":memory:")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.ingest(wire, now: now)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled operation must not start an ingest")
        } catch is CancellationError { }
        let retry = try await repository.ingest(wire, now: now)
        XCTAssertEqual(retry, .stored(id))
    }


    func testSQLiteFullRollsBackAndRetrySucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let database = try ReportDatabase.open(path: path)
        let pages = try await database.write { db -> Int in
            let count = try XCTUnwrap(Int.fetchOne(db, sql: "PRAGMA page_count"))
            _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = \(count)")
            return count
        }
        let repository = ReportRepository(database: database)
        let identity = try ReportIdentity.create(store: DurabilityKeyStore())
        let now: Int64 = 1_789_647_000_000
        let draft = ReportDraft(category: "note", status: "observed", observedAt: now,
                                latitude: 0, longitude: 0, accuracy: 1,
                                note: String(repeating: "\u{1f3d4}", count: 500),
                                expiresAt: now + 3_600_000, maxHops: 1)
        do {
            _ = try await repository.author(draft, identity: identity, now: now)
            XCTFail("A full SQLite database must report a write failure")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_FULL)
        }
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 0)
        try await database.write { db in _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = \(pages + 100)") }
        guard case .stored = try await repository.author(draft, identity: identity, now: now) else {
            return XCTFail("A write must succeed after storage becomes available")
        }
    }

}


private final class DurabilityKeyStore: IdentityKeyStore {
    var data: Data?
    func load() throws -> Data? { data }
    func saveNew(_ bytes: Data) throws {
        guard data == nil else { throw IdentityError.alreadyExists }
        data = bytes
    }
}
