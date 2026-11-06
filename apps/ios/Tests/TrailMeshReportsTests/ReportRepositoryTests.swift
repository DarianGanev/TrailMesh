import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ReportRepositoryTests: XCTestCase {
    func testRemoteIngestPersistsFirstWireAndDeduplicatesAfterReopen() async throws {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let data = try Data(contentsOf: resource)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let expected = try XCTUnwrap(item["expected"] as? [String: Any])
        let id = try XCTUnwrap(expected["bundle_id"] as? String)
        let firstWire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let secondWire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(expected["canonical_envelope_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path

        let first = try ReportRepository(path: path)
        let stored = try await first.ingest(firstWire, now: now)
        XCTAssertEqual(stored, .stored(id))
        let reopened = try ReportRepository(path: path)
        let duplicate = try await reopened.ingest(secondWire, now: now + 1)
        XCTAssertEqual(duplicate, .duplicate(id))
        let db = try ReportDatabase.open(path: path)
        let row = try await db.read { db -> (Data, Int64)? in
            guard let saved = try Row.fetchOne(db, sql: "SELECT original_wire, admitted_at_ms FROM bundles WHERE bundle_id = ?", arguments: [id]) else { return nil }
            return (saved["original_wire"], saved["admitted_at_ms"])
        }
        let saved = try XCTUnwrap(row)
        XCTAssertEqual(saved.0, firstWire)
        XCTAssertEqual(saved.1, now)
        let counts = try await db.read { db in
            try ["bundles", "reports", "relay_state", "seen_ids"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [1, 1, 1, 1])
    }

    private func frozenFixture() throws -> (Data, Int64, Int64) {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let data = try Data(contentsOf: resource)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let core = try XCTUnwrap(envelope["core"] as? [String: Any])
        return (wire, try XCTUnwrap(item["now_ms"] as? Int64), try XCTUnwrap(core["expires_at_ms"] as? Int64))
    }

    func testClockRollbackAfterReopenIsFailure() async throws {
        let (wire, now, _) = try frozenFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let first = try ReportRepository(path: path)
        _ = try await first.ingest(wire, now: now)
        let reopened = try ReportRepository(path: path)
        do {
            _ = try await reopened.ingest(wire, now: now - 1)
            XCTFail("A backward clock must not refresh or confirm a report")
        } catch { }
    }

    func testReportExpiringBeforeTransactionIsRejected() async throws {
        let (wire, now, expires) = try frozenFixture()
        let repository = try ReportRepository(path: ":memory:")
        let clock = SequenceClock([now, expires])
        let result = try await repository.ingest(wire, clock: { clock.next() })
        XCTAssertEqual(result, .rejected(.expired))
    }


    func testExpiredRejectionCannotBeUndoneByClockRollback() async throws {
        let (wire, now, expires) = try frozenFixture()
        let repository = try ReportRepository(path: ":memory:")
        let expired = try await repository.ingest(wire, now: expires)
        XCTAssertEqual(expired, .rejected(.expired))
        do {
            _ = try await repository.ingest(wire, now: now)
            XCTFail("A backward clock must not make an expired report current again")
        } catch { }
    }


    func testExpiryAtCommitCannotBeUndoneByClockRollback() async throws {
        let (wire, now, expires) = try frozenFixture()
        let repository = try ReportRepository(path: ":memory:")
        let clock = SequenceClock([now, expires])
        let expired = try await repository.ingest(wire, clock: { clock.next() })
        XCTAssertEqual(expired, .rejected(.expired))
        do {
            _ = try await repository.ingest(wire, now: now)
            XCTFail("A backward clock must not undo expiry observed at commit")
        } catch { }
    }

}


private final class SequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]
    init(_ values: [Int64]) { self.values = values }
    func next() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
    }
}
