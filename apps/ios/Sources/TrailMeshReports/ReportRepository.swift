import CryptoKit
import Foundation
import GRDB
import Security

public enum ReportRejection: String, Equatable, Sendable {
    case invalid, unsupported, expired, quota
}

public enum ReportStoreOutcome: Equatable, Sendable {
    case stored(String)
    case duplicate(String)
    case rejected(ReportRejection)
}

public actor ReportRepository {
    private let database: DatabaseQueue

    init(path: String) throws {
        database = try ReportDatabase.open(path: path)
    }

    init(database: DatabaseQueue) {
        self.database = database
    }

    public static func open(path: String) async throws -> ReportRepository {
        try Task.checkCancellation()
        let repository = try await Task.detached { try ReportRepository(path: path) }.value
        try Task.checkCancellation()
        return repository
    }

    public func reports(now: Int64, bounds: ReportBounds, includeExpired: Bool = false) throws -> [StoredReport] {
        try Task.checkCancellation()
        guard (0...9_007_199_254_740_991).contains(now) else { throw ReportStoreError.clock }
        guard (-900_000_000...900_000_000).contains(bounds.south),
              (-900_000_000...900_000_000).contains(bounds.north), bounds.south <= bounds.north,
              (-1_800_000_000...1_800_000_000).contains(bounds.west),
              (-1_800_000_000...1_800_000_000).contains(bounds.east) else { throw ReportStoreError.invalidBounds }
        return try database.write { db in
            let last = try Int64.fetchOne(db, sql: "SELECT last_now_ms FROM repository_clock WHERE singleton = 1")
            guard let last, now >= last else { throw ReportStoreError.clock }
            try db.execute(sql: "UPDATE repository_clock SET last_now_ms = ? WHERE singleton = 1", arguments: [now])
            let longitude = bounds.west <= bounds.east ? "r.lon_e7 BETWEEN ? AND ?" : "(r.lon_e7 >= ? OR r.lon_e7 <= ?)"
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.bundle_id, b.author_key, b.admitted_at_ms, b.expires_at_ms,
                       s.local_expiry_ms, r.event_id, r.category, r.status, r.note,
                       r.lat_e7, r.lon_e7, r.accuracy_m, r.observed_at_ms, r.supersedes
                FROM reports r JOIN bundles b ON b.bundle_id = r.bundle_id
                JOIN relay_state s ON s.bundle_id = b.bundle_id
                WHERE r.lat_e7 BETWEEN ? AND ? AND \(longitude)
                  AND b.expires_at_ms > ? AND (? = 1 OR (b.expires_at_ms > ? AND s.local_expiry_ms > ?))
                ORDER BY r.observed_at_ms DESC, b.bundle_id
                """, arguments: [bounds.south, bounds.north, bounds.west, bounds.east,
                                  now - 604_800_000, includeExpired ? 1 : 0, now, now])
            return rows.map { row in
                let expiry: Int64 = row["expires_at_ms"]
                let localExpiry: Int64 = row["local_expiry_ms"]
                return StoredReport(bundleID: row["bundle_id"], eventID: row["event_id"],
                    authorKey: row["author_key"], category: row["category"], status: row["status"],
                    note: row["note"], latitude: row["lat_e7"], longitude: row["lon_e7"],
                    accuracy: row["accuracy_m"], observedAt: row["observed_at_ms"],
                    admittedAt: row["admitted_at_ms"], expiresAt: expiry, supersedes: row["supersedes"],
                    isExpired: now >= min(expiry, localExpiry))
            }
        }
    }

    public func forwardable(now: Int64) throws -> [ForwardableReport] {
        try Task.checkCancellation()
        guard (0...9_007_199_254_740_991).contains(now) else { throw ReportStoreError.clock }
        return try database.write { db in
            let last = try Int64.fetchOne(db, sql: "SELECT last_now_ms FROM repository_clock WHERE singleton = 1")
            guard let last, now >= last else { throw ReportStoreError.clock }
            try db.execute(sql: "UPDATE repository_clock SET last_now_ms = ? WHERE singleton = 1", arguments: [now])
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.bundle_id, b.original_wire FROM bundles b
                JOIN reports r ON r.bundle_id = b.bundle_id
                JOIN relay_state s ON s.bundle_id = b.bundle_id
                WHERE b.expires_at_ms > ? AND s.local_expiry_ms > ? AND s.max_hops > 0
                ORDER BY b.admitted_at_ms, b.bundle_id
                """, arguments: [now, now])
            return try rows.map { row in
                let wire: Data = row["original_wire"]
                guard !wire.isEmpty else { throw ReportStoreError.conflictingStoredBundle }
                return ForwardableReport(bundleID: row["bundle_id"], originalWire: wire)
            }
        }
    }

    public func author(_ draft: ReportDraft, identity: ReportIdentity, now: Int64) throws -> ReportStoreOutcome {
        try author(draft, identity: identity, clock: { now })
    }

    public func author(_ draft: ReportDraft, identity: ReportIdentity, clock: @Sendable () -> Int64) throws -> ReportStoreOutcome {
        try Task.checkCancellation()
        let created = clock()
        guard (0...9_007_199_254_740_991).contains(created) else { throw ReportStoreError.clock }
        let supersedes: ReportJSON = draft.supersedes.map { .string($0) } ?? .null
        let body = ReportJSON.object([
            ("event_id", .string(encodeBase64URL(try secureRandom(16)))),
            ("category", .string(draft.category)), ("status", .string(draft.status)),
            ("observed_at_ms", .integer(draft.observedAt)), ("lat_e7", .integer(draft.latitude)),
            ("lon_e7", .integer(draft.longitude)), ("accuracy_m", .integer(draft.accuracy)),
            ("note", .string(draft.note)), ("supersedes", supersedes)
        ])
        let core = ReportJSON.object([
            ("protocol", .string("trailmesh")), ("version", .integer(1)), ("kind", .string("report")),
            ("author_key", .string(encodeBase64URL(identity.publicKey))),
            ("nonce", .string(encodeBase64URL(try secureRandom(16)))),
            ("created_at_ms", .integer(created)), ("expires_at_ms", .integer(draft.expiresAt)),
            ("max_hops", .integer(draft.maxHops)), ("body", body)
        ])
        let canonical = Data(core.canonical().utf8)
        var idMessage = Data("TrailMesh/id/v1\n".utf8)
        idMessage.append(canonical)
        let id = SHA256.hash(data: idMessage).map { String(format: "%02x", $0) }.joined()
        var signedMessage = Data("TrailMesh/core/v1\n".utf8)
        signedMessage.append(canonical)
        let signature = try identity.sign(signedMessage)
        let envelope = ReportJSON.object([
            ("core", core), ("signature", .string(encodeBase64URL(signature))), ("bundle_id", .string(id))
        ])
        return try store(Data(envelope.canonical().utf8), clock: clock, local: true)
    }

    private static func observeClock(_ db: Database, now: Int64) throws {
        let lastNow = try Int64.fetchOne(db, sql: "SELECT last_now_ms FROM repository_clock WHERE singleton = 1")
        guard let lastNow, now >= lastNow else { throw ReportStoreError.clock }
        try db.execute(sql: "UPDATE repository_clock SET last_now_ms = ? WHERE singleton = 1", arguments: [now])
    }

    private func secureRandom(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ReportStoreError.random(status) }
        return bytes
    }

    private func encodeBase64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public func ingest(_ wire: Data, now: Int64) throws -> ReportStoreOutcome {
        try ingest(wire, clock: { now })
    }

    public func ingest(_ wire: Data, clock: @Sendable () -> Int64) throws -> ReportStoreOutcome {
        try store(wire, clock: clock, local: false)
    }

    private func store(_ wire: Data, clock: @Sendable () -> Int64, local: Bool) throws -> ReportStoreOutcome {
        try Task.checkCancellation()
        let validationNow = clock()
        guard (0...9_007_199_254_740_991).contains(validationNow) else { throw ReportStoreError.clock }
        let admitted = ReportAdmission.validate(wire, now: validationNow)
        try Task.checkCancellation()
        if admitted.outcome == "expired" {
            return try database.write { db in
                let now = clock()
                guard (0...9_007_199_254_740_991).contains(now), now >= validationNow else { throw ReportStoreError.clock }
                try Self.observeClock(db, now: now)
                return .rejected(.expired)
            }
        }
        guard admitted.outcome == "accepted", let id = admitted.bundleID,
              let canonical = admitted.canonicalCore else { return .rejected(ReportRejection(rawValue: admitted.outcome) ?? .invalid) }
        var parser = try StrictReportJSONParser(wire)
        let envelope = try parser.parse()
        guard let core = envelope["core"], let body = core["body"],
              let author = ReportAdmission.binary(core["author_key"], count: 32),
              let signature = ReportAdmission.binary(envelope["signature"], count: 64),
              let event = ReportAdmission.binary(body["event_id"], count: 16),
              let created = core["created_at_ms"]?.integer, let expires = core["expires_at_ms"]?.integer,
              let hops = core["max_hops"]?.integer, let category = body["category"]?.string,
              let status = body["status"]?.string, let observed = body["observed_at_ms"]?.integer,
              let lat = body["lat_e7"]?.integer, let lon = body["lon_e7"]?.integer,
              let accuracy = body["accuracy_m"]?.integer, let note = body["note"]?.string else {
            return .rejected(.invalid)
        }
        let supersedes = body["supersedes"]?.string
        // Once a transaction starts, return its committed outcome even if cancellation arrives.
        try Task.checkCancellation()
        return try database.write { db in
            let now = clock()
            guard (0...9_007_199_254_740_991).contains(now), now >= validationNow else { throw ReportStoreError.clock }
            try Self.observeClock(db, now: now)
            guard now < expires else { return .rejected(.expired) }
            if let existing = try Row.fetchOne(db, sql: """
                SELECT b.canonical_core, b.signature, b.original_wire,
                       r.bundle_id AS report_id, s.bundle_id AS relay_id, s.local_expiry_ms
                FROM bundles b LEFT JOIN reports r ON r.bundle_id = b.bundle_id
                LEFT JOIN relay_state s ON s.bundle_id = b.bundle_id WHERE b.bundle_id = ?
                """, arguments: [id]) {
                let original: Data = existing["original_wire"]
                let reportID: String? = existing["report_id"]
                let relayID: String? = existing["relay_id"]
                let localExpiry: Int64? = existing["local_expiry_ms"]
                guard !original.isEmpty, reportID == id, relayID == id, let localExpiry,
                      (existing["canonical_core"] as Data) == canonical, (existing["signature"] as Data) == signature else {
                    throw ReportStoreError.conflictingStoredBundle
                }
                guard now < localExpiry else { return .rejected(.expired) }
                return .duplicate(id)
            }
            let seen = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM seen_ids WHERE bundle_id = ? AND retain_until_ms > ?)", arguments: [id, now]) ?? false
            if seen { throw ReportStoreError.seenWithoutPayload }
            // Retain expired history for at most seven days; live local reports are never evicted.
            try db.execute(sql: "DELETE FROM bundles WHERE expires_at_ms <= ?", arguments: [now - 604_800_000])
            let total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(original_wire) + length(canonical_core) + length(signature)), 0) FROM bundles") ?? 0
            let remote = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(original_wire) + length(canonical_core) + length(signature)), 0) FROM bundles WHERE is_local = 0") ?? 0
            let size = Int64(wire.count + canonical.count + signature.count)
            let authorCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bundles WHERE is_local = 0 AND author_key = ? AND admitted_at_ms > ?", arguments: [author, now - 3_600_000]) ?? 0
            guard total + size <= 25 * 1024 * 1024,
                  local || (remote + size <= 20 * 1024 * 1024 && authorCount < 20) else {
                return .rejected(.quota)
            }
            try db.execute(sql: """
                INSERT INTO bundles (bundle_id, canonical_core, signature, original_wire, author_key,
                  created_at_ms, expires_at_ms, admitted_at_ms, is_local) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, canonical, signature, wire, author, created, expires, now, local ? 1 : 0])
            try db.execute(sql: """
                INSERT INTO reports (bundle_id, event_id, category, status, observed_at_ms, lat_e7, lon_e7, accuracy_m, note, supersedes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, event, category, status, observed, lat, lon, accuracy, note, supersedes])
            try db.execute(sql: "INSERT INTO relay_state VALUES (?, ?, ?, ?)",
                           arguments: [id, min(expires, now + 259_200_000), hops, local ? 1 : 0])
            try db.execute(sql: "DELETE FROM seen_ids WHERE retain_until_ms <= ?", arguments: [now])
            try db.execute(sql: "INSERT OR REPLACE INTO seen_ids VALUES (?, ?, 'stored')", arguments: [id, expires + 86_400_000])
            try db.execute(sql: """
                DELETE FROM seen_ids WHERE bundle_id IN (
                  SELECT bundle_id FROM seen_ids ORDER BY retain_until_ms, bundle_id
                  LIMIT MAX(0, (SELECT COUNT(*) FROM seen_ids) - 10000))
                """)
            return .stored(id)
        }
    }
}

public enum ReportStoreError: Error {
    case clock
    case invalidBounds
    case seenWithoutPayload
    case random(OSStatus)
    case conflictingStoredBundle
}

public struct ReportDraft: Sendable {
    public let category: String
    public let status: String
    public let observedAt: Int64
    public let latitude: Int64
    public let longitude: Int64
    public let accuracy: Int64
    public let note: String
    public let supersedes: String?
    public let expiresAt: Int64
    public let maxHops: Int64

    public init(category: String, status: String, observedAt: Int64, latitude: Int64,
                longitude: Int64, accuracy: Int64, note: String, expiresAt: Int64, maxHops: Int64,
                supersedes: String? = nil) {
        self.category = category
        self.status = status
        self.observedAt = observedAt
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.note = note
        self.supersedes = supersedes
        self.expiresAt = expiresAt
        self.maxHops = maxHops
    }
}

public struct ForwardableReport: Equatable, Sendable {
    public let bundleID: String
    public let originalWire: Data
}

public struct ReportBounds: Sendable {
    public let south: Int64, north: Int64, west: Int64, east: Int64
    public init(south: Int64, north: Int64, west: Int64, east: Int64) {
        self.south = south; self.north = north; self.west = west; self.east = east
    }
}

public struct StoredReport: Sendable {
    public let bundleID: String
    public let eventID: Data
    public let authorKey: Data
    public let category: String
    public let status: String
    public let note: String
    public let latitude: Int64
    public let longitude: Int64
    public let accuracy: Int64
    public let observedAt: Int64
    public let admittedAt: Int64
    public let expiresAt: Int64
    public let supersedes: String?
    public let isExpired: Bool
}
