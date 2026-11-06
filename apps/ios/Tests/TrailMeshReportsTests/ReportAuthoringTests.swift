import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ReportAuthoringTests: XCTestCase {
    func testAuthoringStoresValidSignedReportAndOutboxTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let store = MemoryKeyStore()
        let identity = try ReportIdentity.create(store: store)
        let repository = try ReportRepository(path: path)
        let now: Int64 = 1_789_647_000_000
        let draft = ReportDraft(category: "water", status: "dry", observedAt: now - 1_000,
                                latitude: 421_790_000, longitude: 235_850_000, accuracy: 30,
                                note: "No flow", expiresAt: now + 3_600_000, maxHops: 3)
        let outcome = try await repository.author(draft, identity: identity, now: now)
        guard case .stored(let id) = outcome else { return XCTFail("Authoring did not commit a report") }
        let database = try ReportDatabase.open(path: path)
        let saved = try await database.read { db -> (Data, Int64, Int64)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT b.original_wire, b.is_local, r.outbox FROM bundles b
                JOIN relay_state r ON r.bundle_id = b.bundle_id WHERE b.bundle_id = ?
                """, arguments: [id]) else { return nil }
            return (row["original_wire"], row["is_local"], row["outbox"])
        }
        let row = try XCTUnwrap(saved)
        if let path = ProcessInfo.processInfo.environment["TRAILMESH_TEST_REPORT_OUTPUT"] {
            try row.0.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertEqual(ReportAdmission.validate(row.0, now: now).outcome, "accepted")
        XCTAssertEqual(ReportAdmission.validate(row.0, now: now).bundleID, id)
        XCTAssertEqual(row.1, 1)
        XCTAssertEqual(row.2, 1)
        let privateKey = try XCTUnwrap(store.data)
        for suffix in ["", "-wal", "-journal"] {
            let file = URL(fileURLWithPath: path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                let bytes = try Data(contentsOf: file)
                XCTAssertNil(bytes.range(of: privateKey), "Private key material must not be stored in SQLite files")
            }
        }
    }

    func testAuthorPreservesSupersedesInSignedProjection() async throws {
        let identity = try ReportIdentity.create(store: MemoryKeyStore())
        let repository = try ReportRepository(path: ":memory:")
        let now: Int64 = 1_789_647_000_000
        let prior = String(repeating: "a", count: 64)
        let draft = ReportDraft(category: "water", status: "dry", observedAt: now, latitude: 0,
                                longitude: 0, accuracy: 1, note: "test", expiresAt: now + 1_000,
                                maxHops: 1, supersedes: prior)
        guard case .stored = try await repository.author(draft, identity: identity, now: now) else {
            return XCTFail("Report was not stored")
        }
        let bounds = ReportBounds(south: -1, north: 1, west: -1, east: 1)
        let reports = try await repository.reports(now: now, bounds: bounds)
        XCTAssertEqual(reports.first?.supersedes, prior)
    }

}

private final class MemoryKeyStore: IdentityKeyStore {
    var data: Data?
    func load() throws -> Data? { data }
    func saveNew(_ bytes: Data) throws {
        guard data == nil else { throw IdentityError.alreadyExists }
        data = bytes
    }
}
