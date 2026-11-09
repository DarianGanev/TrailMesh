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


    func testAuthoringRejectsClockRollbackAfterCreation() async throws {
        let identity = try ReportIdentity.create(store: MemoryKeyStore())
        let repository = try ReportRepository(path: ":memory:")
        let now: Int64 = 1_789_647_000_000
        let draft = ReportDraft(category: "water", status: "dry", observedAt: now - 1,
                                latitude: 0, longitude: 0, accuracy: 1, note: "test",
                                expiresAt: now + 1_000, maxHops: 1)
        let clock = AuthorClock([now, now - 1, now - 1])
        do {
            _ = try await repository.author(draft, identity: identity, clock: { clock.next() })
            XCTFail("A backward authoring clock must fail")
        } catch ReportStoreError.clock { }
        guard case .stored = try await repository.author(draft, identity: identity, now: now) else {
            return XCTFail("A failed authoring attempt must leave no report")
        }
    }


    func testSignedNoteWithNULSurvivesStorageAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let identity = try ReportIdentity.create(store: MemoryKeyStore())
        let repository = try ReportRepository(path: path)
        let now: Int64 = 1_789_647_000_000
        let note = "before\u{0}after"
        let draft = ReportDraft(category: "note", status: "observed", observedAt: now,
                                latitude: 0, longitude: 0, accuracy: 1, note: note,
                                expiresAt: now + 1_000, maxHops: 1)
        guard case .stored = try await repository.author(draft, identity: identity, now: now) else {
            return XCTFail("Report was not stored")
        }
        let reopened = try ReportRepository(path: path)
        let reports = try await reopened.reports(now: now, bounds: ReportBounds(south: -1, north: 1, west: -1, east: 1))
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first.map { Data($0.note.utf8) }, Data(note.utf8))
    }


    func testLegacyTruncatedNoteIsRecoveredFromSignedWireDuringMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let identity = try ReportIdentity.create(store: MemoryKeyStore())
        let repository = try ReportRepository(path: path)
        let now: Int64 = 1_789_647_000_000
        let note = "before\u{0}after"
        let draft = ReportDraft(category: "note", status: "observed", observedAt: now,
                                latitude: 0, longitude: 0, accuracy: 1, note: note,
                                expiresAt: now + 1_000, maxHops: 1)
        _ = try await repository.author(draft, identity: identity, now: now)
        let old = try ReportDatabase.open(path: path)
        try await old.write { db in
            try db.execute(sql: "UPDATE reports SET note = 'before'")
            try db.execute(sql: "DROP TABLE exchange_cursor; DROP TABLE report_forwarding")
            try db.execute(sql: "DROP TABLE quarantined_ids")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v3', 'v4')")
        }
        let upgraded = try ReportRepository(path: path)
        let reports = try await upgraded.reports(now: now, bounds: ReportBounds(south: -1, north: 1, west: -1, east: 1))
        XCTAssertEqual(reports.first.map { Data($0.note.utf8) }, Data(note.utf8))
    }


    func testEmptySignedNoteSurvivesStorageAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let identity = try ReportIdentity.create(store: MemoryKeyStore())
        let repository = try ReportRepository(path: path)
        let now: Int64 = 1_789_647_000_000
        let draft = ReportDraft(category: "note", status: "observed", observedAt: now,
                                latitude: 0, longitude: 0, accuracy: 1, note: "",
                                expiresAt: now + 1_000, maxHops: 1)
        guard case .stored = try await repository.author(draft, identity: identity, now: now) else {
            return XCTFail("Report was not stored")
        }
        let reopened = try ReportRepository(path: path)
        let reports = try await reopened.reports(now: now, bounds: ReportBounds(south: -1, north: 1, west: -1, east: 1))
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.note, "")
    }


    func testFutureClockCannotDeleteReportsBeforeRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reports.sqlite").path
        let identity = try ReportIdentity.create(store: MemoryKeyStore())
        let repository = try ReportRepository(path: path)
        let now: Int64 = 1_789_647_000_000
        func draft(_ time: Int64) -> ReportDraft {
            ReportDraft(category: "note", status: "observed", observedAt: time, latitude: 0, longitude: 0,
                        accuracy: 1, note: "kept", expiresAt: time + 3_600_000, maxHops: 1)
        }
        guard case .stored(let originalID) = try await repository.author(draft(now), identity: identity, now: now) else {
            return XCTFail("Initial report was not stored")
        }
        let database = try ReportDatabase.open(path: path)
        let original = try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT original_wire FROM bundles WHERE bundle_id = ?", arguments: [originalID])
        }
        try await database.write { db in
            try db.execute(sql: "INSERT INTO seen_ids VALUES ('retained-marker', ?, 'stored')", arguments: [now + 1_000])
        }
        let incorrectFuture = now + 8 * 86_400_000
        guard case .stored = try await repository.author(draft(incorrectFuture), identity: identity, now: incorrectFuture) else {
            return XCTFail("Future-clock report was not stored")
        }
        _ = try await repository.recoverClockAfterUserConfirmation(now: now + 1)
        let after = try await database.read { db in
            try Data.fetchOne(db, sql: "SELECT original_wire FROM bundles WHERE bundle_id = ?", arguments: [originalID])
        }
        XCTAssertEqual(after, original)
        let marker = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_ids WHERE bundle_id = 'retained-marker'") }
        XCTAssertEqual(marker, 1)
        let world = ReportBounds(south: -1, north: 1, west: -1, east: 1)
        let history = try await repository.reports(now: now + 1, bounds: world, includeExpired: true)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy(\.isQuarantined))
        let forwardable = try await repository.forwardable(now: now + 1)
        XCTAssertTrue(forwardable.isEmpty)
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


private final class AuthorClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]
    init(_ values: [Int64]) { self.values = values }
    func next() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
    }
}
