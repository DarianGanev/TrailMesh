import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ExchangeSessionTests: XCTestCase {
    func testDuplexRealStoresAndLostAcknowledgementReconnect() async throws {
        let (wire, now, id) = try exchangeFixture()
        let a = try ReportRepository(path: ":memory:"), b = try ReportRepository(path: ":memory:")
        _ = try await a.ingest(wire, now: now)
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        let draft = ReportDraft(category: "note", status: "observed", observedAt: now, latitude: 0, longitude: 0, accuracy: 1, note: "duplex synthetic", expiresAt: now + 10000, maxHops: 2)
        guard case let .stored(otherID) = try await b.author(draft, identity: identity, now: now) else { return XCTFail("Author second direction") }
        let left = ExchangeSession(store: a, nonce: Data(repeating: 1, count: 16), generation: 1, wallClock: { now })
        let right = ExchangeSession(store: b, nonce: Data(repeating: 2, count: 16), generation: 2, wallClock: { now })
        var toRight = await left.start(elapsed: 0)
        var toLeft = await right.start(elapsed: 0)
        var dropped = false
        for _ in 0..<100 {
            var nextLeft: [ExchangeAction] = [], nextRight: [ExchangeAction] = []
            for action in toRight { nextLeft += await right.receive(action.bytes, generation: 2, elapsed: 1) }
            for action in toLeft {
                let frame = try ExchangeWire.decode(action.bytes)
                if case .received = frame.body { dropped = true; continue }
                nextRight += await left.receive(action.bytes, generation: 1, elapsed: 1)
            }
            toLeft = nextLeft; toRight = nextRight
            if toLeft.isEmpty && toRight.isEmpty { break }
        }
        XCTAssertTrue(dropped)
        let present = try await b.currentIDs([id], now: now)
        XCTAssertEqual(present, [id])
        let reverse = try await a.currentIDs([otherID], now: now)
        XCTAssertEqual(reverse, [otherID])
        await left.cancel(); await right.cancel()
        let nextA = ExchangeSession(store: a, nonce: Data(repeating: 3, count: 16), generation: 3, wallClock: { now })
        let nextB = ExchangeSession(store: b, nonce: Data(repeating: 4, count: 16), generation: 4, wallClock: { now })
        var qa = await nextA.start(elapsed: 0), qb = await nextB.start(elapsed: 0)
        for _ in 0..<100 {
            var na: [ExchangeAction] = [], nb: [ExchangeAction] = []
            for x in qa { nb += await nextB.receive(x.bytes, generation: 4, elapsed: 1) }
            for x in qb { na += await nextA.receive(x.bytes, generation: 3, elapsed: 1) }
            qa = na; qb = nb
            if qa.isEmpty && qb.isEmpty { break }
        }
        let saved = try await b.loadOutgoing(id, now: now)
        XCTAssertEqual(saved?.wire, wire)
        let stale = await nextA.receive(Data([0,0,0,0]), generation: 1, elapsed: 1)
        XCTAssertTrue(stale.isEmpty)
    }
    func testDeadlineAndCancelledGenerationSuppressCallbacks() async throws {
        let store = try ReportRepository(path: ":memory:")
        let session = ExchangeSession(store: store, nonce: Data(repeating: 1, count: 16), generation: 42, wallClock: { 0 })
        _ = await session.start(elapsed: 0)
        let timeout = await session.tick(elapsed: 5000)
        XCTAssertTrue(timeout.isEmpty)
        let failure = await session.failureReason
        XCTAssertEqual(failure, 5)
        await session.cancel()
        let actions = await session.receive(Data([0]), generation: 42, elapsed: 5001)
        XCTAssertTrue(actions.isEmpty)
    }
}

extension ExchangeSessionTests {
    private static func remote(_ body: ExchangeBody) throws -> Data {
        try ExchangeWire.encode(ExchangeFrame(source: Data(repeating: 2, count: 16), destination: Data(repeating: 1, count: 16), body: body))
    }
    private func prepare(_ store: any ReportExchangeStore, descriptor: ExchangeDescriptor, now: Int64) async throws -> ExchangeSession {
        let session = ExchangeSession(store: store, nonce: Data(repeating: 1, count: 16), generation: 1, wallClock: { now })
        _ = await session.start(elapsed: 0)
        let hello = ExchangeFrame(source: Data(repeating: 2, count: 16), destination: Data(repeating: 0, count: 16), body: .hello(features: 1, maxFrame: 16_384, maxChunk: 1024))
        _ = await session.receive(try ExchangeWire.encode(hello), generation: 1, elapsed: 1)
        let request = await session.receive(try Self.remote(.summary(page: 0, more: false, entries: [descriptor])), generation: 1, elapsed: 2)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(request.first).bytes).body, .request([descriptor.id]))
        _ = await session.receive(try Self.remote(.offer(transfer: 1, descriptor: descriptor)), generation: 1, elapsed: 3)
        return session
    }
    private static func send(_ wire: Data, to session: ExchangeSession, now: Int64) async throws -> [ExchangeAction] {
        var actions: [ExchangeAction] = []
        for offset in stride(from: 0, to: wire.count, by: 1024).reversed() {
            actions += await session.receive(try Self.remote(.chunk(transfer: 1, offset: offset, total: wire.count, bytes: wire.subdata(in: offset..<min(wire.count, offset + 1024)))), generation: 1, elapsed: 4)
        }
        return actions
    }
    func testOutOfOrderIdenticalOverlapReplayWritesOnlyOnce() async throws {
        let (wire, now, id) = try exchangeFixture()
        let database = try ReportDatabase.open(path: ":memory:")
        let store = ReportRepository(database: database)
        let session = try await prepare(store, descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        let first = try Self.remote(.chunk(transfer: 1, offset: 0, total: wire.count, bytes: wire.prefix(10)))
        _ = await session.receive(first, generation: 1, elapsed: 4)
        _ = await session.receive(first, generation: 1, elapsed: 4)
        let actions = try await Self.send(wire, to: session, now: now)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(actions.last).bytes).body, .received(transfer: 1, id: id, result: 0))
        let replay = await session.receive(first, generation: 1, elapsed: 4)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(replay.first).bytes).body, .received(transfer: 1, id: id, result: 0))
        let count = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 1)
    }
    func testInconsistentOverlapClosesWithoutPersisting() async throws {
        let (wire, now, id) = try exchangeFixture()
        let store = try ReportRepository(path: ":memory:")
        let session = try await prepare(store, descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        _ = await session.receive(try Self.remote(.chunk(transfer: 1, offset: 0, total: wire.count, bytes: wire.prefix(10))), generation: 1, elapsed: 4)
        let result = await session.receive(try Self.remote(.chunk(transfer: 1, offset: 0, total: wire.count, bytes: Data(repeating: 255, count: 10))), generation: 1, elapsed: 4)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(result.first).bytes).body, .close(3))
        let known = try await store.currentIDs([id], now: now)
        XCTAssertTrue(known.isEmpty)
    }
    func testInvalidExpiredUnsupportedAndQuotaAreFixedOutcomes() async throws {
        let (wire, now, id) = try exchangeFixture()
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        var core = try XCTUnwrap(envelope["core"] as? [String: Any])
        let expiry = try XCTUnwrap(core["expires_at_ms"] as? Int64)
        core["version"] = 2; envelope["core"] = core
        let unsupported = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertNotEqual(unsupported, wire)
        for (payload, clock, expected) in [(Data([1, 2, 3]), now, 3), (wire, expiry, 2), (unsupported, now, 5), (wire, now, 4)] {
            let db = try ReportDatabase.open(path: ":memory:")
            if expected == 4 {
                try await db.write { db in
                    try db.execute(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO seen_ids SELECT printf('%064x', x), ?, 'test' FROM n", arguments: [clock + 1000])
                }
            }
            let session = try await prepare(ReportRepository(database: db), descriptor: ExchangeDescriptor(id: id, total: payload.count, hops: 2), now: clock)
            let result = try await Self.send(payload, to: session, now: clock)
            XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(result.last).bytes).body, .received(transfer: 1, id: id, result: expected))
        }
    }
    func testStorageFailureDoesNotEmitReceived() async throws {
        let (wire, now, id) = try exchangeFixture()
        let db = try ReportDatabase.open(path: ":memory:")
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_forwarding BEFORE INSERT ON report_forwarding BEGIN SELECT RAISE(ABORT, 'injected failure'); END") }
        let session = try await prepare(ReportRepository(database: db), descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        let actions = try await Self.send(wire, to: session, now: now)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(actions.last).bytes).body, .close(4))
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bundles") }
        XCTAssertEqual(count, 0)
    }
    func testCancelAfterCommitSuppressesAcknowledgementButKeepsBytes() async throws {
        let (wire, now, id) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:")
        let gate = CommitGateStore(repository: repository)
        let session = try await prepare(gate, descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        let transfer = Task { try await Self.send(wire, to: session, now: now) }
        await gate.waitForCommit()
        await session.cancel()
        await gate.release()
        let actions = try await transfer.value
        XCTAssertTrue(actions.isEmpty)
        let stored = try await repository.loadOutgoing(id, now: now)
        XCTAssertEqual(stored?.wire, wire)
    }
    func testWrongNonceUnsolicitedAckAndPrematureDoneCloseProtocol() async throws {
        let (wire, now, id) = try exchangeFixture()
        for body in [ExchangeBody.received(transfer: 1, id: id, result: 0), .done] {
            let session = try await prepare(ReportRepository(path: ":memory:"), descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
            let actions = await session.receive(try Self.remote(body), generation: 1, elapsed: 4)
            XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(actions.first).bytes).body, .close(3))
        }
        let session = try await prepare(ReportRepository(path: ":memory:"), descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        let wrong = ExchangeFrame(source: Data(repeating: 9, count: 16), destination: Data(repeating: 1, count: 16), body: .done)
        let actions = await session.receive(try ExchangeWire.encode(wrong), generation: 1, elapsed: 4)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(actions.first).bytes).body, .close(3))
    }
}

private actor CommitGateStore: ReportExchangeStore {
    let repository: ReportRepository
    private var committed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    init(repository: ReportRepository) { self.repository = repository }
    func inventoryPage(after: String?, limit: Int, now: Int64) async throws -> ExchangeInventoryPage { try await repository.inventoryPage(after: after, limit: limit, now: now) }
    func currentIDs(_ ids: [String], now: Int64) async throws -> Set<String> { try await repository.currentIDs(ids, now: now) }
    func loadOutgoing(_ id: String, now: Int64) async throws -> ExchangeOutgoing? { try await repository.loadOutgoing(id, now: now) }
    func ingestTransferred(_ wire: Data, offeredHops: Int, clock: @Sendable () -> Int64) async throws -> ReportStoreOutcome {
        let result = try await repository.ingestTransferred(wire, offeredHops: offeredHops, clock: clock)
        committed = true
        await withCheckedContinuation { continuation in
            gate = continuation; waiter?.resume(); waiter = nil
        }
        return result
    }
    func waitForCommit() async { if !committed { await withCheckedContinuation { waiter = $0 } } }
    func release() { gate?.resume(); gate = nil }
}

extension ExchangeSessionTests {
    func testChangedCompletedReplayClosesProtocol() async throws {
        let (wire, now, id) = try exchangeFixture()
        let store = try ReportRepository(path: ":memory:")
        let session = try await prepare(store, descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        _ = try await Self.send(wire, to: session, now: now)
        let actions = await session.receive(try Self.remote(.chunk(transfer: 1, offset: 0, total: wire.count, bytes: Data([255]))), generation: 1, elapsed: 4)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(actions.first).bytes).body, .close(3))
    }
    func testQueuedCallbacksDuringCommitAndTickCancellation() async throws {
        let (wire, now, id) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:")
        let gate = CommitGateStore(repository: repository)
        let session = try await prepare(gate, descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        let transfer = Task { try await Self.send(wire, to: session, now: now) }
        await gate.waitForCommit()
        let replayBytes = try Self.remote(.chunk(transfer: 1, offset: 0, total: wire.count, bytes: wire.prefix(1)))
        let replay = Task { await session.receive(replayBytes, generation: 1, elapsed: 5) }
        // Observe admission rather than assuming a fixed number of scheduler yields.
        for _ in 0..<5000 {
            if await session.queuedInputCount > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let queuedCount = await session.queuedInputCount
        XCTAssertEqual(queuedCount, 1)
        let stillLive = await session.tick(elapsed: 6)
        XCTAssertTrue(stillLive.isEmpty)
        await gate.release()
        let first = try await transfer.value, repeated = await replay.value
        let failure = await session.failureReason
        XCTAssertNil(failure)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(first.last).bytes).body, .received(transfer: 1, id: id, result: 0))
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(repeated.last).bytes).body, .received(transfer: 1, id: id, result: 0))

        let secondStore = try ReportRepository(path: ":memory:")
        let secondGate = CommitGateStore(repository: secondStore)
        let timed = try await prepare(secondGate, descriptor: ExchangeDescriptor(id: id, total: wire.count, hops: 2), now: now)
        let pending = Task { try await Self.send(wire, to: timed, now: now) }
        await secondGate.waitForCommit()
        let closed = await timed.tick(elapsed: 30000)
        XCTAssertEqual(try ExchangeWire.decode(XCTUnwrap(closed.first).bytes).body, .close(5))
        await secondGate.release()
        let suppressed = try await pending.value
        XCTAssertTrue(suppressed.isEmpty)
    }
}

extension ExchangeSessionTests {
    func testBudgetAndBackwardMonotonicClockCloseEncounter() async throws {
        let store = try ReportRepository(path: ":memory:")
        let session = ExchangeSession(store: store, nonce: Data(repeating: 1, count: 16), generation: 1, wallClock: { 0 })
        _ = await session.start(elapsed: 0)
        let overBudget = await session.receive(Data(count: 262145), generation: 1, elapsed: 1)
        XCTAssertTrue(overBudget.isEmpty)
        let budgetReason = await session.failureReason
        XCTAssertEqual(budgetReason, 2)
        let next = ExchangeSession(store: store, nonce: Data(repeating: 1, count: 16), generation: 2, wallClock: { 0 })
        _ = await next.start(elapsed: 10)
        let rollback = await next.tick(elapsed: 9)
        XCTAssertTrue(rollback.isEmpty)
        let clockReason = await next.failureReason
        XCTAssertEqual(clockReason, 5)
    }
}

extension ExchangeSessionTests {
    private static func drive(_ a: ReportRepository, _ b: ReportRepository, now: Int64) async throws {
        let left = ExchangeSession(store: a, nonce: Data(repeating: 5, count: 16), generation: 5, wallClock: { now })
        let right = ExchangeSession(store: b, nonce: Data(repeating: 6, count: 16), generation: 6, wallClock: { now })
        var qa = await left.start(elapsed: 0), qb = await right.start(elapsed: 0)
        for _ in 0..<200 {
            var na: [ExchangeAction] = [], nb: [ExchangeAction] = []
            for x in qa { nb += await right.receive(x.bytes, generation: 6, elapsed: 1) }
            for x in qb { na += await left.receive(x.bytes, generation: 5, elapsed: 1) }
            qa = na; qb = nb
            if qa.isEmpty && qb.isEmpty { return }
        }
        XCTFail("Fake link failed to quiesce")
    }
    func testTwoHopChainExhaustsAfterDatabaseReopen() async throws {
        let (_, now, _) = try exchangeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try ReportRepository(path: ":memory:")
        let bPath = directory.appendingPathComponent("b.sqlite").path
        let cPath = directory.appendingPathComponent("c.sqlite").path
        let b = try ReportRepository(path: bPath), c = try ReportRepository(path: cPath)
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        let draft = ReportDraft(category: "note", status: "observed", observedAt: now, latitude: 0, longitude: 0, accuracy: 1, note: "two hop synthetic", expiresAt: now + 10000, maxHops: 2)
        guard case let .stored(id) = try await a.author(draft, identity: identity, now: now) else { return XCTFail("Author") }
        let original = try await a.loadOutgoing(id, now: now)
        try await Self.drive(a, b, now: now)
        let reopenedB = try ReportRepository(path: bPath)
        let one = try await reopenedB.loadOutgoing(id, now: now)
        XCTAssertEqual(one?.descriptor.hops, 1)
        try await Self.drive(reopenedB, c, now: now)
        let reopenedC = try ReportRepository(path: cPath)
        let exhausted = try await reopenedC.loadOutgoing(id, now: now)
        XCTAssertNil(exhausted)
        let db = try ReportDatabase.open(path: cPath)
        let saved = try await db.read { try Data.fetchOne($0, sql: "SELECT original_wire FROM bundles") }
        XCTAssertEqual(saved, original?.wire)
        let remaining = try await db.read { try Int.fetchOne($0, sql: "SELECT remaining_hops FROM report_forwarding") }
        XCTAssertEqual(remaining, 0)
    }
}
