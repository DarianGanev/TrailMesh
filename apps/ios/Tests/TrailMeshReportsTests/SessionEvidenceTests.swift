import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import TrailMeshReports

final class SessionEvidenceTests: XCTestCase {
    func testProductionReadsResampleClockWhileFixedNowStillRejectsRollback() async throws {
        let (wire, now, id) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:")
        _ = try await repository.ingest(wire, now: now)
        let previouslySampled = now
        _ = try await repository.currentIDs([id], now: now + 1)
        let context = RelevanceContext(manualArea: RelevanceArea(center: RelevancePoint(latitude: 426977000, longitude: 233219000), radius: 5000))
        let selected = SelectedReportExchangeStore(repository: repository, context: context, clock: { now + 1 })
        _ = try await selected.inventoryPage(after: nil, limit: 8, now: previouslySampled)
        let current = try await selected.currentIDs([id], now: previouslySampled)
        XCTAssertEqual(current, [id])
        _ = try await repository.savedTestReportEvidence(clock: { now + 1 })
        do { _ = try await repository.inventoryPage(after: nil, limit: 8, now: previouslySampled); XCTFail("fixed stale sample") } catch ReportStoreError.clock { }
        do { _ = try await repository.currentIDs([id], clock: { now }); XCTFail("real backward clock") } catch ReportStoreError.clock { }
        do { _ = try await repository.savedTestReportEvidence(clock: { now }); XCTFail("backward evidence clock") } catch ReportStoreError.clock { }
    }
    func testEvidenceUsesVerifiedOriginalBytesAndExcludesNormalReports() async throws {
        let (_, now, _) = try exchangeFixture()
        let database = try ReportDatabase.open(path: ":memory:")
        let repository = ReportRepository(database: database)
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        let outcome = try await repository.authorSyntheticTestReport(identity: identity, now: now)
        guard case let .stored(id) = outcome else { return XCTFail("author") }
        let records = try await repository.savedTestReportEvidence(now: now)
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].bundleID, id); XCTAssertEqual(records[0].remainingHops, 3)
        let loaded = try await repository.loadOutgoing(id, now: now)
        let outgoing = try XCTUnwrap(loaded)
        XCTAssertEqual(records[0].originalWireSHA256, SHA256.hash(data: outgoing.wire).map { String(format: "%02x", $0) }.joined())
        _ = try await repository.author(ReportDraft(category: "note", status: "observed", observedAt: now, latitude: 0, longitude: 0, accuracy: 1, note: "normal report", expiresAt: now + 10000, maxHops: 1), identity: identity, now: now)
        let filtered = try await repository.savedTestReportEvidence(now: now)
        XCTAssertEqual(filtered.count, 1)
        try await database.write { try $0.execute(sql: "UPDATE reports SET observed_at_ms = observed_at_ms + 1 WHERE bundle_id = ?", arguments: [id]) }
        do { _ = try await repository.savedTestReportEvidence(now: now); XCTFail("tampered evidence") } catch ReportStoreError.conflictingStoredBundle { }
    }
}
