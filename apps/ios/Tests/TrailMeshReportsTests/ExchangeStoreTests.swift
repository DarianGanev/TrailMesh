import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ExchangeStoreTests: XCTestCase {
    func testReceiptPersistsDecrementAndDuplicateNeverResetsAfterRestart() async throws {
        let (wire, now, id) = try exchangeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("exchange.sqlite").path
        let first = try ReportRepository(path: path)
        let outcome = try await first.ingestTransferred(wire, offeredHops: 2, now: now)
        XCTAssertEqual(outcome, .stored(id))
        let reopened = try ReportRepository(path: path)
        let page = try await reopened.inventoryPage(after: nil, limit: 8, now: now)
        XCTAssertEqual(page.entries.map(\.hops), [1])
        let duplicate = try await reopened.ingestTransferred(wire, offeredHops: 1, now: now)
        XCTAssertEqual(duplicate, .duplicate(id))
        _ = try await reopened.ingestTransferred(wire, offeredHops: 2, now: now)
        let final = try ReportRepository(path: path)
        let exhausted = try await final.inventoryPage(after: nil, limit: 8, now: now)
        XCTAssertTrue(exhausted.entries.isEmpty)
        XCTAssertEqual(exhausted.nextCursor, id)
        let db = try ReportDatabase.open(path: path)
        let saved = try await db.read { try Data.fetchOne($0, sql: "SELECT original_wire FROM bundles") }
        XCTAssertEqual(saved, wire)
    }

    func testCorruptForwardingMetadataFailsInsteadOfResettingCap() async throws {
        let (wire, now, _) = try exchangeFixture()
        let db = try ReportDatabase.open(path: ":memory:")
        let store = ReportRepository(database: db)
        _ = try await store.ingest(wire, now: now)
        try await db.write { try $0.execute(sql: "PRAGMA ignore_check_constraints = ON; INSERT INTO report_forwarding SELECT bundle_id, 'bad' FROM bundles") }
        do { _ = try await store.inventoryPage(after: nil, limit: 8, now: now); XCTFail("Corruption must fail") }
        catch ReportStoreError.conflictingStoredBundle { }
    }
}

func exchangeFixture() throws -> (Data, Int64, String) {
    let url = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
    let item = try XCTUnwrap(cases.first { $0["name"] as? String == "frozen-v1" })
    let expected = try XCTUnwrap(item["expected"] as? [String: Any])
    return (try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String))),
            try XCTUnwrap(item["now_ms"] as? Int64), try XCTUnwrap(expected["bundle_id"] as? String))
}

extension ExchangeStoreTests {
    func testV3MigrationPreservesSignedBytesAndUsesAuthorCap() async throws {
        let (wire, now, id) = try exchangeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v3.sqlite").path
        let before = try ReportRepository(path: path)
        _ = try await before.ingest(wire, now: now)
        let database = try ReportDatabase.open(path: path)
        try await database.write { db in
            try db.execute(sql: "DROP TABLE exchange_cursor; DROP TABLE report_forwarding; DELETE FROM grdb_migrations WHERE identifier = 'v4'")
        }
        let after = try ReportRepository(path: path)
        let loaded = try await after.loadOutgoing(id, now: now)
        XCTAssertEqual(loaded?.wire, wire)
        XCTAssertGreaterThan(try XCTUnwrap(loaded).descriptor.hops, 0)
    }
    func testForwardingInsertFailureRollsBackReportAndSeenID() async throws {
        let (wire, now, _) = try exchangeFixture()
        let db = try ReportDatabase.open(path: ":memory:")
        try await db.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_forwarding BEFORE INSERT ON report_forwarding BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        let store = ReportRepository(database: db)
        do { _ = try await store.ingestTransferred(wire, offeredHops: 2, now: now); XCTFail("Expected rollback") } catch { }
        let counts = try await db.read { db in
            try ["bundles", "reports", "relay_state", "seen_ids", "report_forwarding"].map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") }
        }
        XCTAssertEqual(counts, [0, 0, 0, 0, 0])
    }
    func testClockRollbackAndInvalidOfferCannotMutateHopBudget() async throws {
        let (wire, now, id) = try exchangeFixture()
        let store = try ReportRepository(path: ":memory:")
        let invalid = try await store.ingestTransferred(wire, offeredHops: 13, now: now)
        XCTAssertEqual(invalid, .rejected(.invalid))
        _ = try await store.ingestTransferred(wire, offeredHops: 2, now: now)
        do { _ = try await store.inventoryPage(after: nil, limit: 8, now: now - 1); XCTFail("Rollback clock") } catch ReportStoreError.clock { }
        let current = try await store.loadOutgoing(id, now: now)
        XCTAssertEqual(current?.descriptor.hops, 1)
    }
}

extension ExchangeStoreTests {
    func testBoundedPagesRotateAcrossRestartWithoutWrappingInsideEncounter() async throws {
        let (_, now, _) = try exchangeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("rotation.sqlite").path
        let store = try ReportRepository(path: path)
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        var ids: [String] = []
        for i in 0..<65 {
            let draft = ReportDraft(category: "note", status: "observed", observedAt: now, latitude: 0, longitude: 0, accuracy: 1, note: "synthetic \(i)", expiresAt: now + 10000, maxHops: 2)
            guard case let .stored(id) = try await store.author(draft, identity: identity, now: now) else { return XCTFail("Author fixture") }
            ids.append(id)
        }
        ids.sort()
        var after: String?, scanned: [String] = []
        for _ in 0..<8 {
            let page = try await store.inventoryPage(after: after, limit: 8, now: now)
            XCTAssertTrue(page.hasMore)
            scanned += page.entries.map(\.id); after = page.nextCursor
        }
        XCTAssertEqual(scanned, Array(ids.prefix(64)))
        let reopened = try ReportRepository(path: path)
        let nextEncounter = try await reopened.inventoryPage(after: nil, limit: 8, now: now)
        XCTAssertEqual(nextEncounter.entries.map(\.id), [ids.last!])
        XCTAssertFalse(nextEncounter.hasMore)
        let wrapped = try await reopened.inventoryPage(after: nil, limit: 8, now: now)
        XCTAssertEqual(wrapped.entries.map(\.id), Array(ids.prefix(8)))
    }
}
final class ExchangeMemoryKeyStore: IdentityKeyStore {
    private var bytes: Data?
    func load() throws -> Data? { bytes }
    func saveNew(_ value: Data) throws { bytes = value }
}

extension ExchangeStoreTests {
    func testReceiptSamplesClockAgainBeforeAtomicCommit() async throws {
        let (wire, now, _) = try exchangeFixture()
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let core = try XCTUnwrap(envelope["core"] as? [String: Any])
        let expires = try XCTUnwrap(core["expires_at_ms"] as? Int64)
        let store = try ReportRepository(path: ":memory:")
        let clock = ExchangeSequenceClock([now, expires])
        let outcome = try await store.ingestTransferred(wire, offeredHops: 2, clock: { clock.next() })
        XCTAssertEqual(outcome, .rejected(.expired))
        let db = try ReportDatabase.open(path: ":memory:")
        let rollbackStore = ReportRepository(database: db)
        let backwards = ExchangeSequenceClock([now, now - 1])
        do { _ = try await rollbackStore.ingestTransferred(wire, offeredHops: 2, clock: { backwards.next() }); XCTFail("Clock changed during verification") } catch ReportStoreError.clock { }
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 0)
    }
}
private final class ExchangeSequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int64]
    init(_ samples: [Int64]) { self.samples = samples }
    func next() -> Int64 { lock.lock(); defer { lock.unlock() }; if samples.count > 1 { return samples.removeFirst() }; return samples[0] }
}

extension ExchangeStoreTests {
    func testZeroAuthorHopCapRejectsTransferredOfferWithoutWriting() async throws {
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        let item = try XCTUnwrap(cases.first { $0["name"] as? String == "unicode-and-boundaries" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let now = try XCTUnwrap(item["now_ms"] as? Int64)
        XCTAssertEqual(ReportAdmission.validate(wire, now: now).outcome, "accepted")
        let db = try ReportDatabase.open(path: ":memory:")
        let store = ReportRepository(database: db)
        let outcome = try await store.ingestTransferred(wire, offeredHops: 1, now: now)
        XCTAssertEqual(outcome, .rejected(.invalid))
        let counts = try await db.read { db in
            try ["bundles", "reports", "relay_state", "seen_ids", "report_forwarding"].map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") }
        }
        XCTAssertEqual(counts, [0, 0, 0, 0, 0])
    }
}

extension ExchangeStoreTests {
    func testOutgoingLoadSamplesClockAgainInsideDatabaseTransaction() async throws {
        let (wire, now, id) = try exchangeFixture()
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let core = try XCTUnwrap(envelope["core"] as? [String: Any])
        let expires = try XCTUnwrap(core["expires_at_ms"] as? Int64)
        let store = try ReportRepository(path: ":memory:")
        _ = try await store.ingest(wire, now: now)
        let clock = ExchangeSequenceClock([now, expires])
        let expired = try await store.loadOutgoing(id, clock: { clock.next() })
        XCTAssertNil(expired)
        let backwards = ExchangeSequenceClock([expires, expires - 1])
        do { _ = try await store.loadOutgoing(id, clock: { backwards.next() }); XCTFail("Clock changed while waiting for database") } catch ReportStoreError.clock { }
    }
}
