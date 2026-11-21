import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class ReportPageTests: XCTestCase {
    private let world = ReportBounds(south: -900_000_000, north: 900_000_000, west: -1_800_000_000, east: 1_800_000_000)
    private func draft(_ i: Int, now: Int64, latitude: Int64 = 0) -> ReportDraft {
        ReportDraft(category: "note", status: "observed", observedAt: now - Int64(i % 3), latitude: latitude,
                    longitude: 0, accuracy: 1, note: "page fixture \(i)", expiresAt: now + 10000, maxHops: 2)
    }
    func testRaw64BoundStableOrderingAndConcurrentIngest() async throws {
        let (_, now, _) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:")
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        for i in 0..<65 { _ = try await repository.author(draft(i, now: now), identity: identity, now: now) }
        let first = try await repository.reportPage(now: now, bounds: world)
        XCTAssertEqual(first.inspectedCount, 64); XCTAssertEqual(first.reports.count, 64); XCTAssertTrue(first.hasMore)
        // An admission between page transactions cannot duplicate prior IDs.
        let incoming = draft(100, now: now), queryBounds = world
        async let admission = repository.author(incoming, identity: identity, now: now)
        async let continuation = repository.reportPage(now: now, bounds: queryBounds, after: first.nextCursor)
        _ = try await admission
        let second = try await continuation
        XCTAssertTrue(Set(first.reports.map(\.bundleID)).isDisjoint(with: second.reports.map(\.bundleID)))
        XCTAssertLessThanOrEqual(second.inspectedCount, 64)
        let combined = first.reports + second.reports
        XCTAssertEqual(combined.map(\.bundleID), combined.sorted {
            $0.observedAt == $1.observedAt ? $0.bundleID < $1.bundleID : $0.observedAt > $1.observedAt
        }.map(\.bundleID))
    }
    func testEmptyFilteredPageContinuesAndHistoryRemainsAvailable() async throws {
        let (_, now, _) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:")
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        for i in 0..<65 { _ = try await repository.author(draft(i, now: now), identity: identity, now: now) }
        let outside = ReportBounds(south: 1000, north: 2000, west: 0, east: 0)
        let page = try await repository.reportPage(now: now, bounds: outside)
        XCTAssertTrue(page.reports.isEmpty); XCTAssertTrue(page.hasMore); XCTAssertEqual(page.inspectedCount, 64)
        let next = try await repository.reportPage(now: now, bounds: world, after: page.nextCursor)
        XCTAssertEqual(next.reports.count, 1); XCTAssertFalse(next.hasMore)
        let expired = try await repository.reportPage(now: now + 10000, bounds: world)
        XCTAssertTrue(expired.reports.isEmpty); XCTAssertTrue(expired.hasMore)
        let history = try await repository.reportPage(now: now + 10000, bounds: world, includeExpired: true)
        XCTAssertEqual(history.reports.count, 64); XCTAssertTrue(history.reports.allSatisfy(\.isExpired))
    }
    func testMapScansPastFourFilteredPagesAndCapsCurrentMarkers() async throws {
        let (_, now, _) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:")
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        for i in 0..<130 {
            _ = try await repository.author(draft(i, now: now, latitude: 2_000), identity: identity, now: now)
        }
        // Older in-bounds reports come after all 130 out-of-bounds rows.
        for i in 130..<230 {
            let candidate = ReportDraft(category: "note", status: "observed", observedAt: now - Int64(i + 10),
                                        latitude: 0, longitude: 0, accuracy: 1, note: "map fixture",
                                        expiresAt: now + 10_000, maxHops: 2)
            _ = try await repository.author(candidate, identity: identity, now: now)
        }
        let local = ReportBounds(south: -1, north: 1, west: -1, east: 1)
        let markers = try await repository.currentMapReports(bounds: local, clock: { now })
        XCTAssertEqual(markers.count, 96)
        XCTAssertTrue(markers.allSatisfy { $0.latitude == 0 && !$0.isExpired })
        XCTAssertEqual(markers.map(\.observedAt), (130..<226).map { now - Int64($0 + 10) })
    }

    func testPageExposesVerifiedEffectiveExpiryAlongsideSignedExpiry() async throws {
        let (_, now, _) = try exchangeFixture()
        let source = try ReportRepository(path: ":memory:"), destination = try ReportRepository(path: ":memory:")
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        let observed = now + 240_000
        let expiry = observed + 259_200_000
        let draft = ReportDraft(category: "note", status: "observed", observedAt: observed, latitude: 0,
                                longitude: 0, accuracy: 1, note: "future within tolerance", expiresAt: expiry, maxHops: 2)
        guard case .stored(let id) = try await source.author(draft, identity: identity, now: observed) else {
            return XCTFail("source report rejected")
        }
        let outgoing = try await source.loadOutgoing(id, now: observed)
        _ = try await destination.ingest(XCTUnwrap(outgoing).wire, now: now)
        let page = try await destination.reportPage(now: now, bounds: world)
        let saved = try XCTUnwrap(page.reports.first)
        XCTAssertEqual(saved.expiresAt, expiry)
        XCTAssertEqual(saved.effectiveExpiresAt, now + 259_200_000)
        XCTAssertFalse(saved.isExpired)
        let history = try await destination.reportPage(now: saved.effectiveExpiresAt, bounds: world, includeExpired: true)
        XCTAssertEqual(history.reports.first?.isExpired, true)
    }

    func testTamperingClockQuarantineAndPageLimitAreChecked() async throws {
        let (wire, now, _) = try exchangeFixture()
        let database = try ReportDatabase.open(path: ":memory:")
        let repository = ReportRepository(database: database)
        _ = try await repository.ingest(wire, now: now)
        do { _ = try await repository.reportPage(now: now, bounds: world, limit: 65); XCTFail("limit") } catch ReportStoreError.invalidPage { }
        do { _ = try await repository.reportPage(now: now - 1, bounds: world); XCTFail("clock") } catch ReportStoreError.clock { }
        _ = try await repository.recoverClockAfterUserConfirmation(now: now - 1)
        let current = try await repository.reportPage(now: now, bounds: world)
        XCTAssertTrue(current.reports.isEmpty)
        let history = try await repository.reportPage(now: now, bounds: world, includeExpired: true)
        XCTAssertEqual(history.reports.count, 1); XCTAssertTrue(history.reports[0].isQuarantined)
        try await database.write { try $0.execute(sql: "UPDATE reports SET lat_e7 = lat_e7 + 1") }
        do { _ = try await repository.reportPage(now: now, bounds: world, includeExpired: true); XCTFail("tamper") } catch ReportStoreError.conflictingStoredBundle { }
    }
    func testSelectedExchangeKeepsRawCursorAndRechecksExpiryAndGPSOnLoad() async throws {
        let (_, now, _) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:")
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        var ids: [String] = []
        for i in 0..<9 {
            guard case let .stored(id) = try await repository.author(draft(i, now: now), identity: identity, now: now) else { return XCTFail("fixture") }
            ids.append(id)
        }
        ids.sort()
        let empty = SelectedReportExchangeStore(repository: repository, context: RelevanceContext())
        let filtered = try await empty.inventoryPage(after: nil, limit: 8, now: now)
        XCTAssertTrue(filtered.entries.isEmpty); XCTAssertTrue(filtered.hasMore); XCTAssertEqual(filtered.nextCursor, ids[7])
        let configured = SelectedReportExchangeStore(repository: repository, context: RelevanceContext(manualArea: RelevanceArea(center: RelevancePoint(latitude: 0, longitude: 0), radius: 1000)))
        let tail = try await configured.inventoryPage(after: filtered.nextCursor, limit: 8, now: now)
        XCTAssertEqual(tail.entries.map(\.id), [ids[8]]); XCTAssertFalse(tail.hasMore)
        let gps = SelectedReportExchangeStore(repository: repository, context: RelevanceContext(gpsArea: RelevanceGPSArea(center: RelevancePoint(latitude: 0, longitude: 0), radius: 1000, accuracy: 1, fixAt: now - 300000)))
        let offered = try await gps.inventoryPage(after: nil, limit: 8, now: now)
        XCTAssertEqual(offered.entries.map(\.id), Array(ids.prefix(8)))
        let stale = try await gps.loadOutgoing(ids[0], clock: { now + 1 })
        XCTAssertNil(stale)
        let expired = try await configured.loadOutgoing(ids[0], clock: { now + 10000 })
        XCTAssertNil(expired)
    }
    func testSelectedIngressKeepsAdmissionIndependentAndAuthorQuotaAuthoritative() async throws {
        let (_, now, _) = try exchangeFixture()
        let source = try ReportRepository(path: ":memory:"), destination = try ReportRepository(path: ":memory:")
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        let noConfiguration = SelectedReportExchangeStore(repository: destination, context: RelevanceContext())
        let relevant = SelectedReportExchangeStore(repository: destination, context: RelevanceContext(manualArea: RelevanceArea(center: RelevancePoint(latitude: 0, longitude: 0), radius: 1000)))
        var firstID = ""
        for i in 0..<21 {
            guard case let .stored(id) = try await source.author(draft(i, now: now), identity: identity, now: now) else { return XCTFail("signed source") }
            let loaded = try await source.loadOutgoing(id, now: now)
            let wire = try XCTUnwrap(loaded).wire
            if i == 0 { firstID = id }
            if i < 20 {
                let admitted = try await noConfiguration.ingestTransferred(wire, offeredHops: 2, clock: { now })
                XCTAssertEqual(admitted, .stored(id), "Local relevance must not reject otherwise valid ingress")
            } else {
                let rejected = try await relevant.ingestTransferred(wire, offeredHops: 2, clock: { now })
                XCTAssertEqual(rejected, .rejected(.quota), "Relevant selection cannot bypass the author-hour quota")
            }
        }
        let hidden = try await noConfiguration.inventoryPage(after: nil, limit: 8, now: now)
        XCTAssertTrue(hidden.entries.isEmpty); XCTAssertTrue(hidden.hasMore)
        let membership = try await noConfiguration.currentIDs([firstID], now: now)
        XCTAssertEqual(membership, [firstID], "Local configuration must not change durable membership")
        let loaded = try await relevant.loadOutgoing(firstID, clock: { now })
        XCTAssertEqual(loaded?.descriptor.hops, 1, "Selection must preserve the decremented forwarding budget")
    }
    func testLookaheadIsNotVerifiedUntilNextPageAndZeroHopsStayReadable() async throws {
        let (_, now, _) = try exchangeFixture()
        let database = try ReportDatabase.open(path: ":memory:")
        let repository = ReportRepository(database: database)
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        for i in 0..<65 { _ = try await repository.author(draft(i, now: now), identity: identity, now: now) }
        try await database.write { db in
            try db.execute(sql: "UPDATE reports SET accuracy_m = accuracy_m + 1 WHERE bundle_id = (SELECT bundle_id FROM reports ORDER BY observed_at_ms DESC, bundle_id ASC LIMIT 1 OFFSET 64)")
            try db.execute(sql: "INSERT INTO report_forwarding SELECT bundle_id, 0 FROM bundles")
        }
        let first = try await repository.reportPage(now: now, bounds: world)
        XCTAssertEqual(first.reports.count, 64); XCTAssertEqual(first.inspectedCount, 64); XCTAssertTrue(first.hasMore)
        do { _ = try await repository.reportPage(now: now, bounds: world, after: first.nextCursor); XCTFail("Lookahead corruption must fail when inspected") } catch ReportStoreError.conflictingStoredBundle { }
        let current = try await repository.currentIDs(Array(first.reports.prefix(8)).map(\.bundleID), now: now)
        XCTAssertEqual(current.count, 8)
        let outgoing = try await repository.loadOutgoing(first.reports[0].bundleID, now: now)
        XCTAssertNil(outgoing)
    }
    func testV4UpgradeAddsOrderIndexWithoutChangingBytes() async throws {
        let (wire, now, id) = try exchangeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("v4.sqlite").path
        let before = try ReportRepository(path: path)
        _ = try await before.ingest(wire, now: now)
        let database = try ReportDatabase.open(path: path)
        try await database.write { try $0.execute(sql: "DROP INDEX reports_observation_id; DELETE FROM grdb_migrations WHERE identifier = 'v5'") }
        let migrated = try ReportDatabase.open(path: path)
        let after = ReportRepository(database: migrated)
        let page = try await after.reportPage(now: now, bounds: world)
        XCTAssertEqual(page.reports.map(\.bundleID), [id])
        let outgoing = try await after.loadOutgoing(id, now: now)
        XCTAssertEqual(outgoing?.wire, wire)
        // EXPLAIN on an older connection can retain its pre-migration schema.
        for query in ReportPageQuery.allCases {
            let plan = try await migrated.read {
                let arguments: StatementArguments
                switch query {
                case .first: arguments = [65]
                case .sameObservation: arguments = [now, id, 65]
                case .olderObservation: arguments = [now, 65]
                }
                return try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN " + query.sql, arguments: arguments)
                    .map { try $0.decode(String.self, forColumn: "detail") }
            }
            XCTAssertTrue(plan.contains { $0.contains("reports_observation_id") }, "\(plan)")
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
            if query != .first {
                XCTAssertTrue(plan.contains { $0.contains("SEARCH") && $0.contains("reports_observation_id") }, "\(plan)")
            }
        }
    }
}
