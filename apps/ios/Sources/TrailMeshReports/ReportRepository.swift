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
    let database: DatabaseQueue
    static let storedColumns = """
        b.bundle_id, b.canonical_core, b.signature, b.original_wire, b.author_key,
        b.created_at_ms, b.expires_at_ms, b.admitted_at_ms,
        r.event_id, r.category, r.status, r.observed_at_ms, r.lat_e7, r.lon_e7,
        r.accuracy_m, r.note, r.supersedes, s.local_expiry_ms, s.max_hops,
        typeof(b.canonical_core) AS core_type, typeof(b.signature) AS signature_type,
        typeof(b.original_wire) AS wire_type, typeof(b.author_key) AS author_type,
        typeof(r.event_id) AS event_type, typeof(b.bundle_id) AS id_type,
        typeof(r.category) AS category_type, typeof(r.status) AS status_type, typeof(r.note) AS note_type,
        typeof(r.supersedes) AS supersedes_type, typeof(b.created_at_ms) AS created_type,
        typeof(b.expires_at_ms) AS expires_type, typeof(b.admitted_at_ms) AS admitted_type,
        typeof(r.observed_at_ms) AS observed_type, typeof(r.lat_e7) AS latitude_type,
        typeof(r.lon_e7) AS longitude_type, typeof(r.accuracy_m) AS accuracy_type,
        typeof(s.local_expiry_ms) AS local_expiry_type, typeof(s.max_hops) AS hops_type,
        CASE WHEN q.bundle_id IS NULL THEN 0 ELSE 1 END AS quarantined
        """

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
                SELECT \(Self.storedColumns)
                FROM reports r JOIN bundles b ON b.bundle_id = r.bundle_id
                JOIN relay_state s ON s.bundle_id = b.bundle_id
                LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id
                WHERE r.lat_e7 BETWEEN ? AND ? AND \(longitude)
                  AND (? = 1 OR (q.bundle_id IS NULL AND b.expires_at_ms > ? AND s.local_expiry_ms > ?))
                ORDER BY r.observed_at_ms DESC, b.bundle_id
                """, arguments: [bounds.south, bounds.north, bounds.west, bounds.east,
                                  includeExpired ? 1 : 0, now, now])
            return try rows.map { try Self.verifyStoredRow($0, now: now).report }
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
                SELECT \(Self.storedColumns) FROM bundles b
                JOIN reports r ON r.bundle_id = b.bundle_id
                JOIN relay_state s ON s.bundle_id = b.bundle_id
                LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id
                WHERE q.bundle_id IS NULL AND b.expires_at_ms > ? AND s.local_expiry_ms > ? AND s.max_hops > 0
                ORDER BY b.admitted_at_ms, b.bundle_id
                """, arguments: [now, now])
            return try rows.compactMap { row -> ForwardableReport? in
                let checked = try Self.verifyStoredRow(row, now: now)
                guard try Self.remainingHops(db, id: checked.report.bundleID, cap: Int(row.decode(Int64.self, forColumn: "max_hops"))) > 0 else { return nil }
                return ForwardableReport(bundleID: checked.report.bundleID, originalWire: checked.wire)
            }
        }
    }

    /// Call only after the user confirms the device clock is corrected. Existing
    /// reports remain available as history but cannot become current or be relayed.
    @discardableResult
    public func recoverClockAfterUserConfirmation(now: Int64) throws -> Int {
        try Task.checkCancellation()
        guard (0...9_007_199_254_740_991).contains(now) else { throw ReportStoreError.clock }
        return try database.write { db in
            guard let last = try Int64.fetchOne(db, sql: "SELECT last_now_ms FROM repository_clock WHERE singleton = 1"), now < last else {
                throw ReportStoreError.clock
            }
            let rateHoldUntil = now + 3_600_000
            try db.execute(sql: "INSERT OR IGNORE INTO quarantined_ids (bundle_id, rate_hold_until_ms) SELECT bundle_id, ? FROM bundles", arguments: [rateHoldUntil])
            try db.execute(sql: "UPDATE quarantined_ids SET rate_hold_until_ms = ?", arguments: [rateHoldUntil])
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quarantined_ids") ?? 0
            try db.execute(sql: "UPDATE repository_clock SET last_now_ms = ? WHERE singleton = 1", arguments: [now])
            return count
        }
    }

    /// Call only after the user confirms the clock and agrees to remove expired
    /// history. Recent remote admissions remain until their rate window ends.
    @discardableResult
    public func reclaimExpiredReportsAfterUserConfirmation(now: Int64) throws -> Int {
        try Task.checkCancellation()
        guard (0...9_007_199_254_740_991).contains(now) else { throw ReportStoreError.clock }
        return try database.write { db in
            try Self.observeClock(db, now: now)
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.storedColumns) FROM bundles b
                LEFT JOIN reports r ON r.bundle_id = b.bundle_id
                LEFT JOIN relay_state s ON s.bundle_id = b.bundle_id
                LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id
                WHERE (b.is_local = 1 OR (q.bundle_id IS NULL AND b.admitted_at_ms <= ?)
                       OR (q.bundle_id IS NOT NULL AND q.rate_hold_until_ms <= ?))
                  AND (b.expires_at_ms <= ? OR (q.bundle_id IS NULL AND s.local_expiry_ms <= ?))
                ORDER BY MIN(b.expires_at_ms, COALESCE(s.local_expiry_ms, b.expires_at_ms)), b.bundle_id
                """, arguments: [now - 3_600_000, now, now, now])
            let ids = try rows.map { try Self.verifyStoredRow($0, now: now).report.bundleID }
            for id in ids { try db.execute(sql: "DELETE FROM bundles WHERE bundle_id = ?", arguments: [id]) }
            try db.execute(sql: "DELETE FROM seen_ids WHERE retain_until_ms <= ?", arguments: [now])
            return ids.count
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
        return try store(Data(envelope.canonical().utf8), clock: clock, local: true, minimumNow: created)
    }

    static func verifyStoredRow(_ row: Row, now: Int64) throws -> (report: StoredReport, wire: Data, canonical: Data, signature: Data) {
        do {
            for column in ["core_type", "signature_type", "wire_type", "author_type", "event_type", "note_type"] {
                guard try row.decode(String.self, forColumn: column) == "blob" else { throw ReportStoreError.conflictingStoredBundle }
            }
            for column in ["id_type", "category_type", "status_type"] {
                guard try row.decode(String.self, forColumn: column) == "text" else { throw ReportStoreError.conflictingStoredBundle }
            }
            for column in ["created_type", "expires_type", "admitted_type", "observed_type", "latitude_type", "longitude_type", "accuracy_type", "local_expiry_type", "hops_type"] {
                guard try row.decode(String.self, forColumn: column) == "integer" else { throw ReportStoreError.conflictingStoredBundle }
            }
            let supersedesType = try row.decode(String.self, forColumn: "supersedes_type")
            guard supersedesType == "null" || supersedesType == "text" else { throw ReportStoreError.conflictingStoredBundle }
            let id = try row.decode(String.self, forColumn: "bundle_id")
            let wire = try row.decode(Data.self, forColumn: "original_wire")
            let canonical = try row.decode(Data.self, forColumn: "canonical_core")
            let signature = try row.decode(Data.self, forColumn: "signature")
            let author = try row.decode(Data.self, forColumn: "author_key")
            let event = try row.decode(Data.self, forColumn: "event_id")
            let created = try row.decode(Int64.self, forColumn: "created_at_ms")
            let expires = try row.decode(Int64.self, forColumn: "expires_at_ms")
            let admitted = try row.decode(Int64.self, forColumn: "admitted_at_ms")
            let localExpiry = try row.decode(Int64.self, forColumn: "local_expiry_ms")
            let quarantined = try row.decode(Bool.self, forColumn: "quarantined")
            let hops = try row.decode(Int64.self, forColumn: "max_hops")
            let category = try row.decode(String.self, forColumn: "category")
            let status = try row.decode(String.self, forColumn: "status")
            let noteBytes = try row.decode(Data.self, forColumn: "note")
            guard let note = String(data: noteBytes, encoding: .utf8) else { throw ReportStoreError.conflictingStoredBundle }
            let lat = try row.decode(Int64.self, forColumn: "lat_e7")
            let lon = try row.decode(Int64.self, forColumn: "lon_e7")
            let accuracy = try row.decode(Int64.self, forColumn: "accuracy_m")
            let observed = try row.decode(Int64.self, forColumn: "observed_at_ms")
            let supersedes = try row.decode(String?.self, forColumn: "supersedes")
            guard (1...9_007_199_254_740_991).contains(expires),
                  (0...9_007_199_254_740_991).contains(admitted), localExpiry >= admitted,
                  localExpiry == min(expires, admitted + 259_200_000) else { throw ReportStoreError.conflictingStoredBundle }
            let checked = ReportAdmission.validate(wire, now: admitted)
            guard checked.outcome == "accepted", checked.bundleID == id, checked.canonicalCore == canonical else {
                throw ReportStoreError.conflictingStoredBundle
            }
            var parser = try StrictReportJSONParser(wire)
            let envelope = try parser.parse()
            guard let core = envelope["core"], let body = core["body"],
                  ReportAdmission.binary(envelope["signature"], count: 64) == signature,
                  ReportAdmission.binary(core["author_key"], count: 32) == author,
                  ReportAdmission.binary(body["event_id"], count: 16) == event,
                  core["created_at_ms"]?.integer == created, core["expires_at_ms"]?.integer == expires,
                  core["max_hops"]?.integer == hops, body["category"]?.string == category,
                  body["status"]?.string == status, let signedNote = body["note"]?.string,
                  Data(signedNote.utf8) == noteBytes,
                  body["lat_e7"]?.integer == lat, body["lon_e7"]?.integer == lon,
                  body["accuracy_m"]?.integer == accuracy, body["observed_at_ms"]?.integer == observed,
                  body["supersedes"]?.string == supersedes else { throw ReportStoreError.conflictingStoredBundle }
            let report = StoredReport(bundleID: id, eventID: event, authorKey: author, category: category,
                status: status, note: note, latitude: lat, longitude: lon, accuracy: accuracy,
                observedAt: observed, admittedAt: admitted, expiresAt: expires, supersedes: supersedes,
                isExpired: quarantined || now >= min(expires, localExpiry), isQuarantined: quarantined)
            return (report, wire, canonical, signature)
        } catch {
            throw ReportStoreError.conflictingStoredBundle
        }
    }

    static func observeClock(_ db: Database, now: Int64) throws {
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

    public func ingestTransferred(_ wire: Data, offeredHops: Int, now: Int64) throws -> ReportStoreOutcome {
        guard (1...12).contains(offeredHops) else { return .rejected(.invalid) }
        return try ingestTransferred(wire, offeredHops: offeredHops, clock: { now })
    }

    public func ingestTransferred(_ wire: Data, offeredHops: Int, clock: @Sendable () -> Int64) throws -> ReportStoreOutcome {
        guard (1...12).contains(offeredHops) else { return .rejected(.invalid) }
        return try store(wire, clock: clock, local: false, offeredHops: offeredHops)
    }

    private func store(_ wire: Data, clock: @Sendable () -> Int64, local: Bool, minimumNow: Int64? = nil, offeredHops: Int? = nil) throws -> ReportStoreOutcome {
        try Task.checkCancellation()
        let validationNow = clock()
        guard (0...9_007_199_254_740_991).contains(validationNow), validationNow >= (minimumNow ?? 0) else { throw ReportStoreError.clock }
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
        if let offeredHops, offeredHops < 1 || offeredHops > Int(hops) { return .rejected(.invalid) }
        let supersedes = body["supersedes"]?.string
        // Once a transaction starts, return its committed outcome even if cancellation arrives.
        try Task.checkCancellation()
        return try database.write { db in
            let now = clock()
            guard (0...9_007_199_254_740_991).contains(now), now >= validationNow else { throw ReportStoreError.clock }
            try Self.observeClock(db, now: now)
            guard now < expires else { return .rejected(.expired) }
            if let existing = try Row.fetchOne(db, sql: """
                SELECT \(Self.storedColumns)
                FROM bundles b LEFT JOIN reports r ON r.bundle_id = b.bundle_id
                LEFT JOIN relay_state s ON s.bundle_id = b.bundle_id
                LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id WHERE b.bundle_id = ?
                """, arguments: [id]) {
                let stored = try Self.verifyStoredRow(existing, now: now)
                guard stored.report.bundleID == id, stored.canonical == canonical,
                      stored.signature == signature else { throw ReportStoreError.conflictingStoredBundle }
                guard !stored.report.isExpired else { return .rejected(.expired) }
                if let offeredHops {
                    let previous = try Self.remainingHops(db, id: id, cap: Int(hops))
                    try db.execute(sql: "INSERT INTO report_forwarding VALUES (?, ?) ON CONFLICT(bundle_id) DO UPDATE SET remaining_hops = excluded.remaining_hops", arguments: [id, min(previous, offeredHops - 1)])
                }
                return .duplicate(id)
            }
            let seen = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM seen_ids WHERE bundle_id = ? AND retain_until_ms > ?)", arguments: [id, now]) ?? false
            if seen { throw ReportStoreError.seenWithoutPayload }
            let total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(original_wire) + length(canonical_core) + length(signature)), 0) FROM bundles") ?? 0
            let remote = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(original_wire) + length(canonical_core) + length(signature)), 0) FROM bundles WHERE is_local = 0") ?? 0
            let size = Int64(wire.count + canonical.count + signature.count)
            let authorCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM bundles b LEFT JOIN quarantined_ids q ON q.bundle_id = b.bundle_id
                WHERE b.is_local = 0 AND b.author_key = ?
                  AND ((q.bundle_id IS NULL AND b.admitted_at_ms > ?) OR (q.bundle_id IS NOT NULL AND q.rate_hold_until_ms > ?))
                """, arguments: [author, now - 3_600_000, now]) ?? 0
            let seenCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_ids") ?? 0
            guard total + size <= 25 * 1024 * 1024, seenCount < 10_000,
                  local || (remote + size <= 20 * 1024 * 1024 && authorCount < 20) else {
                return .rejected(.quota)
            }
            try db.execute(sql: """
                INSERT INTO bundles (bundle_id, canonical_core, signature, original_wire, author_key,
                  created_at_ms, expires_at_ms, admitted_at_ms, is_local) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, canonical, signature, wire, author, created, expires, now, local ? 1 : 0])
            try db.execute(sql: """
                INSERT INTO reports (bundle_id, event_id, category, status, observed_at_ms, lat_e7, lon_e7, accuracy_m, note, supersedes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, CASE WHEN ? = 0 THEN zeroblob(0) ELSE ? END, ?)
                """, arguments: [id, event, category, status, observed, lat, lon, accuracy, note.utf8.count, Data(note.utf8), supersedes])
            try db.execute(sql: "INSERT INTO relay_state VALUES (?, ?, ?, ?)",
                           arguments: [id, min(expires, now + 259_200_000), hops, local ? 1 : 0])
            try db.execute(sql: "INSERT OR REPLACE INTO seen_ids VALUES (?, ?, 'stored')", arguments: [id, expires + 86_400_000])
            if let offeredHops { try db.execute(sql: "INSERT INTO report_forwarding VALUES (?, ?)", arguments: [id, offeredHops - 1]) }
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
    public let isQuarantined: Bool
}
