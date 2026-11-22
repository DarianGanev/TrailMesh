import CryptoKit
import Foundation
import GRDB

public enum SyntheticTestReport {
    public static let notePrefix = "SYNTHETIC TrailMesh test "

    /// Match the fixture used in the isolated diagnostics store on both platforms.
    /// This is an evidence check, not a wire-level trust signal.
    static func matches(_ report: StoredReport, maxHops: Int) -> Bool {
        guard report.category == "trail", report.status == "muddy",
              report.latitude == 426977000, report.longitude == 233219000,
              [1, 10].contains(report.accuracy), report.supersedes == nil,
              report.expiresAt - report.observedAt == 3_600_000, maxHops == 3,
              report.note.hasPrefix(notePrefix) else { return false }
        let suffix = report.note.utf8.dropFirst(notePrefix.utf8.count)
        return suffix.count == 8 && suffix.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
public struct SavedTestReportEvidence: Codable, Sendable {
    public let bundleID: String
    public let canonicalCoreSHA256: String
    public let originalWireSHA256: String
    public let observedAt: Int64
    public let isExpired: Bool
    public let isQuarantined: Bool
    public let remainingHops: Int
    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id", canonicalCoreSHA256 = "canonical_core_sha256", originalWireSHA256 = "original_wire_sha256"
        case observedAt = "observed_at_ms", isExpired = "is_expired", isQuarantined = "is_quarantined", remainingHops = "remaining_hops"
    }
}
extension ReportRepository {
    /// Explicit development action only. Starting a session never authors a report.
    public func authorSyntheticTestReport(identity: ReportIdentity, now: Int64) throws -> ReportStoreOutcome {
        try authorSyntheticTestReport(identity: identity, clock: { now })
    }
    public func authorSyntheticTestReport(identity: ReportIdentity, clock: @Sendable () -> Int64) throws -> ReportStoreOutcome {
        let now = clock()
        guard (0...9_007_199_251_140_991).contains(now) else { throw ReportStoreError.clock }
        return try author(ReportDraft(category: "trail", status: "muddy", observedAt: now, latitude: 426977000, longitude: 233219000,
            accuracy: 10, note: SyntheticTestReport.notePrefix + String(UUID().uuidString.prefix(8)), expiresAt: now + 3600000, maxHops: 3), identity: identity, clock: clock)
    }
    /// At most 64 raw rows, with signed-byte verification before any hash is exposed.
    /// The caller uses the isolated diagnostic store. Fixture matching never affects admission.
    public func savedTestReportEvidence(now: Int64) throws -> [SavedTestReportEvidence] {
        try savedTestReportEvidence(clock: { now })
    }
    public func savedTestReportEvidence(clock: @Sendable () -> Int64) throws -> [SavedTestReportEvidence] {
        try Task.checkCancellation()
        let validationNow = clock()
        guard (0...9_007_199_254_740_991).contains(validationNow) else { throw ReportStoreError.clock }
        return try database.write { db in
            let now = clock()
            guard (0...9_007_199_254_740_991).contains(now), now >= validationNow else { throw ReportStoreError.clock }
            try Self.observeClock(db, now: now)
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.storedColumns) FROM reports r
                LEFT JOIN bundles b ON b.bundle_id = r.bundle_id
                LEFT JOIN relay_state s ON s.bundle_id = r.bundle_id
                LEFT JOIN quarantined_ids q ON q.bundle_id = r.bundle_id
                ORDER BY r.observed_at_ms DESC, r.bundle_id ASC LIMIT 64
                """)
            return try rows.compactMap { row in
                let verified = try Self.verifyStoredRow(row, now: now)
                let report = verified.report
                let maxHops = try row.decode(Int.self, forColumn: "max_hops")
                guard SyntheticTestReport.matches(report, maxHops: maxHops) else { return nil }
                let remaining = try Self.remainingHops(db, id: report.bundleID, cap: maxHops)
                return SavedTestReportEvidence(bundleID: report.bundleID,
                    canonicalCoreSHA256: SHA256.hash(data: verified.canonical).map { String(format: "%02x", $0) }.joined(),
                    originalWireSHA256: SHA256.hash(data: verified.wire).map { String(format: "%02x", $0) }.joined(),
                    observedAt: report.observedAt, isExpired: report.isExpired, isQuarantined: report.isQuarantined, remainingHops: remaining)
            }
        }
    }
}
public struct ReportSessionExport: Encodable, Sendable {
    public let schema = "trailmesh.report-session-log"
    public let version = 1
    public let platform = "ios"
    public let deviceModel: String
    public let osVersion: String
    public let appBuild: String
    public let sourceCommit: String?
    public let exportID: String
    public let sessionID: String
    public let state: String
    public let events: [ReportSessionEvent]
    public let savedTestReports: [SavedTestReportEvidence]
    enum CodingKeys: String, CodingKey {
        case schema, version, platform, deviceModel, osVersion, appBuild, sourceCommit, exportID, sessionID, state, events
        case savedTestReports = "saved_test_reports"
    }
    public init(deviceModel: String, osVersion: String, appBuild: String, sourceCommit: String?, sessionID: String,
                state: String, events: [ReportSessionEvent], savedTestReports: [SavedTestReportEvidence]) {
        self.deviceModel = deviceModel; self.osVersion = osVersion; self.appBuild = appBuild; self.sourceCommit = sourceCommit
        self.exportID = UUID().uuidString; self.sessionID = sessionID; self.state = state
        self.events = Array(events.suffix(512)); self.savedTestReports = Array(savedTestReports.prefix(64))
    }
}
