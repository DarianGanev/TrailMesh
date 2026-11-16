import Foundation
import GRDB

public struct ReportPageCursor: Equatable, Sendable {
    public let observedAt: Int64
    public let bundleID: String
    public init(observedAt: Int64, bundleID: String) { self.observedAt = observedAt; self.bundleID = bundleID }
}
public struct ReportPage: Sendable {
    public let reports: [StoredReport]
    public let nextCursor: ReportPageCursor?
    public let hasMore: Bool
    /// Number of raw rows verified, excluding the single unverified lookahead.
    public let inspectedCount: Int
}
extension ReportRepository {
    /// Keyset page in observation DESC / ID ASC order. A filtered empty page can
    /// have more raw candidates. Each call releases the actor and transaction.
    public func reportPage(now: Int64, bounds: ReportBounds, includeExpired: Bool = false,
                           after: ReportPageCursor? = nil, limit: Int = 64) throws -> ReportPage {
        try Task.checkCancellation()
        guard (1...64).contains(limit) else { throw ReportStoreError.invalidPage }
        guard (0...9_007_199_254_740_991).contains(now) else { throw ReportStoreError.clock }
        guard (-900_000_000...900_000_000).contains(bounds.south),
              (-900_000_000...900_000_000).contains(bounds.north), bounds.south <= bounds.north,
              (-1_800_000_000...1_800_000_000).contains(bounds.west),
              (-1_800_000_000...1_800_000_000).contains(bounds.east) else { throw ReportStoreError.invalidBounds }
        if let after {
            guard (0...9_007_199_254_740_991).contains(after.observedAt) else { throw ReportStoreError.invalidPage }
            _ = try ExchangeWire.idBytes(after.bundleID)
        }
        return try database.write { db in
            try Self.observeClock(db, now: now)
            // LIMIT applies before verification/expiry/bounds filtering. Otherwise
            // an expired or quarantined prefix could hide an unbounded scan.
            func fetch(_ predicate: String, _ arguments: StatementArguments) throws -> [Row] {
                try Row.fetchAll(db, sql: """
                    SELECT \(Self.storedColumns) FROM reports r
                    LEFT JOIN bundles b ON b.bundle_id = r.bundle_id
                    LEFT JOIN relay_state s ON s.bundle_id = r.bundle_id
                    LEFT JOIN quarantined_ids q ON q.bundle_id = r.bundle_id
                    \(predicate) ORDER BY r.observed_at_ms DESC, r.bundle_id ASC LIMIT ?
                    """, arguments: arguments)
            }
            let rows: [Row]
            if let after {
                // Separate index seeks avoid rescanning the earlier prefix, even
                // when thousands of reports share the cursor's observation time.
                let equal = try fetch("WHERE r.observed_at_ms = ? AND r.bundle_id > ?", [after.observedAt, after.bundleID, limit + 1])
                if equal.count > limit { rows = equal }
                else {
                    rows = equal + (try fetch("WHERE r.observed_at_ms < ?", [after.observedAt, limit + 1 - equal.count]))
                }
            } else { rows = try fetch("", [limit + 1]) }
            let scanned = rows.prefix(limit)
            var selected: [StoredReport] = []
            var cursor = after
            for row in scanned {
                let report = try Self.verifyStoredRow(row, now: now).report
                cursor = ReportPageCursor(observedAt: report.observedAt, bundleID: report.bundleID)
                let longitude = bounds.west <= bounds.east
                    ? (bounds.west...bounds.east).contains(report.longitude)
                    : report.longitude >= bounds.west || report.longitude <= bounds.east
                guard (bounds.south...bounds.north).contains(report.latitude), longitude,
                      includeExpired || !report.isExpired else { continue }
                selected.append(report)
            }
            return ReportPage(reports: selected, nextCursor: cursor, hasMore: rows.count > limit, inspectedCount: scanned.count)
        }
    }
}

/// Freeze one instance per encounter. Recreate/cancel the encounter when local
/// interests change. Peer membership and durable receipt semantics stay unchanged.
public struct SelectedReportExchangeStore: ReportExchangeStore {
    public let repository: ReportRepository
    public let context: RelevanceContext
    private let freshClock: (@Sendable () -> Int64)?
    public init(repository: ReportRepository, context: RelevanceContext, clock: (@Sendable () -> Int64)? = nil) {
        self.repository = repository; self.context = context; self.freshClock = clock
    }
    public func inventoryPage(after: String?, limit: Int, now: Int64) async throws -> ExchangeInventoryPage {
        if let freshClock { return try await repository.selectedInventoryPage(after: after, limit: limit, clock: freshClock, context: context) }
        return try await repository.selectedInventoryPage(after: after, limit: limit, now: now, context: context)
    }
    public func currentIDs(_ ids: [String], now: Int64) async throws -> Set<String> {
        if let freshClock { return try await repository.currentIDs(ids, clock: freshClock) }
        return try await repository.currentIDs(ids, now: now)
    }
    public func loadOutgoing(_ id: String, clock: @Sendable () -> Int64) async throws -> ExchangeOutgoing? {
        try await repository.selectedLoadOutgoing(id, clock: clock, context: context)
    }
    public func ingestTransferred(_ wire: Data, offeredHops: Int, clock: @Sendable () -> Int64) async throws -> ReportStoreOutcome {
        try await repository.ingestTransferred(wire, offeredHops: offeredHops, clock: clock)
    }
}
