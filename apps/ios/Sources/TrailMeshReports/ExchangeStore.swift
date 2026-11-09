import Foundation
import GRDB

/// At most eight eligible descriptors from a bounded raw-candidate scan. nextCursor
/// is the last scanned ID, even for an empty filtered page; hasMore tracks candidates.
public struct ExchangeInventoryPage: Sendable {
    public let entries: [ExchangeDescriptor]
    public let nextCursor: String?
    public let hasMore: Bool
    public init(entries: [ExchangeDescriptor], nextCursor: String?, hasMore: Bool) { self.entries = entries; self.nextCursor = nextCursor; self.hasMore = hasMore }
}
public struct ExchangeOutgoing: Sendable {
    public let descriptor: ExchangeDescriptor
    public let wire: Data
    public init(descriptor: ExchangeDescriptor, wire: Data) { self.descriptor = descriptor; self.wire = wire }
}
/// Authoritative durable adapter. Implementations must verify stored signed bytes,
/// projections, clock, expiry, quarantine, and hop metadata before exposing reports.
/// Ingest commits the original wire and offeredHops-1 atomically; duplicates may only
/// decrease their budget. Storage/clock failures throw and must never produce ACK.
public protocol ReportExchangeStore: Sendable {
    /// Scans at most limit<=8 rows plus lookahead. nil resumes the durable global
    /// cursor; EOF resets it for the next encounter, without wrapping this encounter.
    func inventoryPage(after: String?, limit: Int, now: Int64) async throws -> ExchangeInventoryPage
    /// Checks at most eight current IDs, including readable zero-hop reports.
    func currentIDs(_ ids: [String], now: Int64) async throws -> Set<String>
    /// Rechecks current forwarding eligibility and resamples clock inside the transaction.
    func loadOutgoing(_ id: String, clock: @Sendable () -> Int64) async throws -> ExchangeOutgoing?
    func ingestTransferred(_ wire: Data, offeredHops: Int, clock: @Sendable () -> Int64) async throws -> ReportStoreOutcome
}

extension ReportRepository: ReportExchangeStore {
    static func remainingHops(_ db: Database, id: String, cap: Int) throws -> Int {
        guard let row = try Row.fetchOne(db, sql: "SELECT remaining_hops, typeof(remaining_hops) AS storage_type FROM report_forwarding WHERE bundle_id = ?", arguments: [id]) else { return cap }
        guard try row.decode(String.self, forColumn: "storage_type") == "integer" else { throw ReportStoreError.conflictingStoredBundle }
        let hops = try row.decode(Int.self, forColumn: "remaining_hops")
        guard (0...cap).contains(hops) else { throw ReportStoreError.conflictingStoredBundle }; return hops
    }
    private static func exchangeRow(_ db: Database, row: Row, now: Int64) throws -> ExchangeOutgoing? {
        let checked = try verifyStoredRow(row, now: now)
        let cap = try row.decode(Int.self, forColumn: "max_hops")
        let hops = try remainingHops(db, id: checked.report.bundleID, cap: cap)
        guard !checked.report.isExpired, hops > 0 else { return nil }
        return ExchangeOutgoing(descriptor: ExchangeDescriptor(id: checked.report.bundleID, total: checked.wire.count, hops: hops), wire: checked.wire)
    }
    public func inventoryPage(after: String?, limit: Int = 8, now: Int64) throws -> ExchangeInventoryPage {
        try Task.checkCancellation()
        guard (1...8).contains(limit), (0...9_007_199_254_740_991).contains(now) else { throw ReportStoreError.clock }
        if let after { _ = try ExchangeWire.idBytes(after) }
        return try database.write { db in
            try Self.observeClock(db, now: now)
            let start: String?
            if let after { start = after }
            else {
                guard let saved = try Row.fetchOne(db, sql: "SELECT last_scanned, typeof(last_scanned) AS storage_type FROM exchange_cursor WHERE singleton = 1") else { throw ReportStoreError.conflictingStoredBundle }
                let type = try saved.decode(String.self, forColumn: "storage_type")
                guard type == "null" || type == "text" else { throw ReportStoreError.conflictingStoredBundle }
                start = try saved.decode(String?.self, forColumn: "last_scanned")
                if let start { do { _ = try ExchangeWire.idBytes(start) } catch { throw ReportStoreError.conflictingStoredBundle } }
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.storedColumns) FROM bundles b
                LEFT JOIN reports r ON r.bundle_id = b.bundle_id
                LEFT JOIN relay_state s ON s.bundle_id = b.bundle_id
                LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id
                WHERE b.bundle_id > ? ORDER BY b.bundle_id LIMIT ?
                """, arguments: [start ?? "", limit + 1])
            let scanned = rows.prefix(limit)
            let entries = try scanned.compactMap { try Self.exchangeRow(db, row: $0, now: now)?.descriptor }
            let nextCursor = try scanned.last?.decode(String.self, forColumn: "bundle_id") ?? start
            try db.execute(sql: "UPDATE exchange_cursor SET last_scanned = ? WHERE singleton = 1", arguments: [rows.count > limit ? nextCursor : nil])
            return ExchangeInventoryPage(entries: entries, nextCursor: nextCursor, hasMore: rows.count > limit)
        }
    }
    public func loadOutgoing(_ id: String, now: Int64) throws -> ExchangeOutgoing? {
        try loadOutgoing(id, clock: { now })
    }
    public func loadOutgoing(_ id: String, clock: @Sendable () -> Int64) throws -> ExchangeOutgoing? {
        try Task.checkCancellation()
        let validationNow = clock()
        _ = try ExchangeWire.idBytes(id)
        guard (0...9_007_199_254_740_991).contains(validationNow) else { throw ReportStoreError.clock }
        return try database.write { db in
            let now = clock()
            guard (0...9_007_199_254_740_991).contains(now), now >= validationNow else { throw ReportStoreError.clock }
            try Self.observeClock(db, now: now)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT \(Self.storedColumns) FROM bundles b
                LEFT JOIN reports r ON r.bundle_id = b.bundle_id
                LEFT JOIN relay_state s ON s.bundle_id = b.bundle_id
                LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id WHERE b.bundle_id = ?
                """, arguments: [id]) else { return nil }
            return try Self.exchangeRow(db, row: row, now: now)
        }
    }
    public func currentIDs(_ ids: [String], now: Int64) throws -> Set<String> {
        guard ids.count <= 8 else { throw ExchangeWireError.malformed }
        // Membership includes exhausted reports: receiving a duplicate must not reset its budget.
        guard (0...9_007_199_254_740_991).contains(now) else { throw ReportStoreError.clock }
        return try database.write { db in
            try Self.observeClock(db, now: now)
            var present: Set<String> = []
            for id in ids {
                _ = try ExchangeWire.idBytes(id)
                if let row = try Row.fetchOne(db, sql: """
                    SELECT \(Self.storedColumns) FROM bundles b
                    LEFT JOIN reports r ON r.bundle_id = b.bundle_id
                    LEFT JOIN relay_state s ON s.bundle_id = b.bundle_id
                    LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id WHERE b.bundle_id = ?
                    """, arguments: [id]) {
                    let checked = try Self.verifyStoredRow(row, now: now)
                    _ = try Self.remainingHops(db, id: id, cap: row.decode(Int.self, forColumn: "max_hops"))
                    if !checked.report.isExpired { present.insert(id) }
                }
            }
            return present
        }
    }
}
