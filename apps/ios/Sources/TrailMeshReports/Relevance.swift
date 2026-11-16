import Foundation
import CoreFoundation

/// Local selection inputs only. These types are never serialized into exchange frames.
public struct RelevancePoint: Codable, Equatable, Sendable {
    public let latitude: Int64, longitude: Int64
    public init(latitude: Int64, longitude: Int64) { self.latitude = latitude; self.longitude = longitude }
    enum CodingKeys: String, CodingKey { case latitude = "lat_e7", longitude = "lon_e7" }
    var valid: Bool { (-900_000_000...900_000_000).contains(latitude) && (-1_800_000_000...1_800_000_000).contains(longitude) }
}
public struct RelevanceArea: Codable, Sendable {
    public let center: RelevancePoint
    public let radius: Int64
    public init(center: RelevancePoint, radius: Int64) { self.center = center; self.radius = radius }
    enum CodingKeys: String, CodingKey { case center; case radius = "radius_m" }
    var valid: Bool { center.valid && (100...50_000).contains(radius) }
}
public struct RelevanceGPSArea: Codable, Sendable {
    public let center: RelevancePoint
    public let radius: Int64
    public let accuracy: Double
    public let fixAt: Int64
    public init(center: RelevancePoint, radius: Int64, accuracy: Double, fixAt: Int64) {
        self.center = center; self.radius = radius; self.accuracy = accuracy; self.fixAt = fixAt
    }
    enum CodingKeys: String, CodingKey { case center; case radius = "radius_m", accuracy = "accuracy_m", fixAt = "fix_at_ms" }
}
public struct RelevanceRoute: Codable, Sendable {
    public let points: [RelevancePoint]
    public let corridor: Int64
    public init(points: [RelevancePoint], corridor: Int64 = 1000) { self.points = points; self.corridor = corridor }
    enum CodingKeys: String, CodingKey { case points; case corridor = "corridor_m" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([RelevancePoint].self, forKey: .points)
        corridor = try c.decodeIfPresent(Int64.self, forKey: .corridor) ?? 1000
    }
}
public struct RelevanceContext: Sendable {
    public let manualArea: RelevanceArea?
    public let gpsArea: RelevanceGPSArea?
    public let route: RelevanceRoute?
    private var malformed = false
    public init(manualArea: RelevanceArea? = nil, gpsArea: RelevanceGPSArea? = nil, route: RelevanceRoute? = nil) {
        self.manualArea = manualArea; self.gpsArea = gpsArea; self.route = route
    }
    private struct Configuration: Decodable {
        let manualArea: RelevanceArea?
        let gpsArea: RelevanceGPSArea?
        let route: RelevanceRoute?
        enum CodingKeys: String, CodingKey { case manualArea = "manual_area", gpsArea = "gps_area", route }
    }
    /// Converts malformed local configuration into a typed policy result.
    public static func parse(_ data: Data) -> RelevanceContext {
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if object is NSNull { return RelevanceContext() }
            guard Self.validJSON(object), Self.integerLexemesValid(data) else { var result = RelevanceContext(); result.malformed = true; return result }
            let decoded = try JSONDecoder().decode(Configuration.self, from: data)
            return RelevanceContext(manualArea: decoded.manualArea, gpsArea: decoded.gpsArea, route: decoded.route)
        }
        catch { var result = RelevanceContext(); result.malformed = true; return result }
    }
    /// Foundation may normalize 1000.0 into an integral NSNumber. Inspect original
    /// numeric tokens as well, so all integer fields retain the literal JSON type.
    /// The surrounding document has already passed Foundation's JSON grammar.
    private static func integerLexemesValid(_ data: Data) -> Bool {
        let bytes = Array(data)
        var i = 0, property: String?
        while i < bytes.count {
            if bytes[i] == 34 {
                let start = i
                i += 1
                while i < bytes.count {
                    if bytes[i] == 92 { i += 2; continue }
                    if bytes[i] == 34 { i += 1; break }
                    i += 1
                }
                var next = i
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58 {
                    property = (try? JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: [.fragmentsAllowed])) as? String
                }
            } else if bytes[i] == 45 || (48...57).contains(bytes[i]) {
                let start = i
                while i < bytes.count && ([45, 43, 46, 69, 101].contains(bytes[i]) || (48...57).contains(bytes[i])) { i += 1 }
                if property != "accuracy_m" && bytes[start..<i].contains(where: { [46, 69, 101].contains($0) }) { return false }
            } else { i += 1 }
        }
        return true
    }
    private static func validJSON(_ value: Any) -> Bool {
        func integer(_ value: Any?) -> Bool {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            return !["f", "d"].contains(String(cString: n.objCType))
        }
        func point(_ value: Any?) -> Bool {
            guard let p = value as? [String: Any], Set(p.keys) == ["lat_e7", "lon_e7"] else { return false }
            return integer(p["lat_e7"]) && integer(p["lon_e7"])
        }
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: ["manual_area", "gps_area", "route"]) else { return false }
        for key in ["manual_area", "gps_area"] where object[key] != nil {
            let keys: Set<String> = key == "gps_area" ? ["center", "radius_m", "accuracy_m", "fix_at_ms"] : ["center", "radius_m"]
            guard let area = object[key] as? [String: Any], Set(area.keys) == keys,
                  point(area["center"]), integer(area["radius_m"]) else { return false }
            if key == "gps_area" {
                guard let accuracy = area["accuracy_m"] as? NSNumber, CFGetTypeID(accuracy) != CFBooleanGetTypeID(),
                      accuracy.doubleValue.isFinite, integer(area["fix_at_ms"]) else { return false }
            }
        }
        if let supplied = object["route"] {
            guard let route = supplied as? [String: Any], route["points"] != nil,
                  Set(route.keys).isSubset(of: ["points", "corridor_m"]),
                  let points = route["points"] as? [Any], points.allSatisfy({ point($0) }),
                  route["corridor_m"] == nil || integer(route["corridor_m"]) else { return false }
        }
        return true
    }
    fileprivate var valid: Bool {
        guard !malformed, manualArea?.valid != false else { return false }
        if let gpsArea {
            guard gpsArea.center.valid, (100...50_000).contains(gpsArea.radius), gpsArea.accuracy.isFinite,
                  gpsArea.accuracy >= 0, gpsArea.accuracy <= 9_007_199_254_740_991, (0...9_007_199_254_740_991).contains(gpsArea.fixAt) else { return false }
        }
        if let route {
            guard (1...2048).contains(route.points.count), (100...10_000).contains(route.corridor), route.points.allSatisfy(\.valid) else { return false }
            for (a, b) in zip(route.points, route.points.dropFirst()) {
                if Sphere.vector(a).dot(Sphere.vector(b)) <= -1 + 1e-12 { return false }
            }
        }
        return true
    }
}
/// Projection of an already signature-verified, admitted report. This local policy
/// is selection/ranking only: it cannot admit bytes, validate authenticity, change
/// signed accuracy/expiry, override repository quotas/hops, or establish truth.
public struct RelevanceReport: Codable, Equatable, Sendable {
    public let id: String
    public let observedAt: Int64, expiresAt: Int64, latitude: Int64, longitude: Int64
    public init(id: String, observedAt: Int64, expiresAt: Int64, latitude: Int64, longitude: Int64) {
        self.id = id; self.observedAt = observedAt; self.expiresAt = expiresAt; self.latitude = latitude; self.longitude = longitude
    }
    enum CodingKeys: String, CodingKey { case id; case observedAt = "observed_at_ms", expiresAt = "expires_at_ms", latitude = "lat_e7", longitude = "lon_e7" }
    init(_ report: StoredReport) { self.init(id: report.bundleID, observedAt: report.observedAt, expiresAt: report.expiresAt, latitude: report.latitude, longitude: report.longitude) }
}
public enum RelevanceResult: String, CaseIterable, Hashable, Sendable { case eligible, notRelevant, expired, configurationRequired, invalidConfiguration }
/// Counts only: no report identifiers, coordinates, areas or routes. Each input
/// projection contributes one decision, including duplicate eligible inputs.
/// duplicateCount counts eligible copies removed by immutable-ID deduplication;
/// selectedCount = eligible count - duplicateCount.
public struct RelevanceDiagnostics: Equatable, Sendable {
    public let decisionCounts: [RelevanceResult: Int]
    public let candidateCount: Int
    public let duplicateCount: Int
    public let selectedCount: Int
}
public struct RelevanceSelection: Sendable {
    public let reports: [RelevanceReport]
    public let diagnostics: RelevanceDiagnostics
}
public enum RelevancePolicy {
    public static func evaluate(_ report: RelevanceReport, context: RelevanceContext?, now: Int64) -> RelevanceResult {
        let context = context ?? RelevanceContext()
        guard context.valid, (0...9_007_199_254_740_991).contains(now) else { return .invalidConfiguration }
        guard now < report.expiresAt else { return .expired }
        var areas: [RelevanceArea] = context.manualArea.map { [$0] } ?? []
        if let gps = context.gpsArea, gps.accuracy <= 1000, gps.fixAt <= now, now - gps.fixAt <= 300_000 {
            areas.append(RelevanceArea(center: gps.center, radius: gps.radius))
        }
        guard !areas.isEmpty || context.route != nil else { return .configurationRequired }
        let point = Sphere.vector(RelevancePoint(latitude: report.latitude, longitude: report.longitude))
        for area in areas where Sphere.angle(point, Sphere.vector(area.center)) * Sphere.radius <= Double(area.radius) + 1e-6 { return .eligible }
        if let route = context.route {
            let vertices = route.points.map(Sphere.vector)
            if vertices.count == 1, Sphere.angle(point, vertices[0]) * Sphere.radius <= Double(route.corridor) + 1e-6 { return .eligible }
            for (a, b) in zip(vertices, vertices.dropFirst()) where Sphere.segmentDistance(point, a, b) <= Double(route.corridor) + 1e-6 { return .eligible }
        }
        return .notRelevant
    }
    /// Local ranking over verified projections; encounter traffic and admission
    /// budgets remain authoritative in ExchangeSession and ReportRepository.
    public static func select(_ reports: [RelevanceReport], context: RelevanceContext?, now: Int64) -> [RelevanceReport] {
        selectWithDiagnostics(reports, context: context, now: now).reports
    }
    public static func diagnostics(_ reports: [RelevanceReport], context: RelevanceContext?, now: Int64) -> RelevanceDiagnostics {
        selectWithDiagnostics(reports, context: context, now: now).diagnostics
    }
    public static func selectWithDiagnostics(_ reports: [RelevanceReport], context: RelevanceContext?, now: Int64) -> RelevanceSelection {
        var counts = Dictionary(uniqueKeysWithValues: RelevanceResult.allCases.map { ($0, 0) })
        var seen: Set<String> = []
        var selected: [RelevanceReport] = []
        var duplicates = 0
        for report in reports.sorted(by: { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt > $1.observedAt }) {
            let reason = evaluate(report, context: context, now: now)
            counts[reason, default: 0] += 1
            guard reason == .eligible else { continue }
            if seen.insert(report.id).inserted { selected.append(report) }
            else { duplicates += 1 }
        }
        return RelevanceSelection(reports: selected, diagnostics: RelevanceDiagnostics(decisionCounts: counts,
            candidateCount: reports.count, duplicateCount: duplicates, selectedCount: selected.count))
    }
}
private enum Sphere {
    static let radius = 6_371_008.8
    struct V {
        let x: Double, y: Double, z: Double
        func dot(_ b: V) -> Double { x*b.x + y*b.y + z*b.z }
        func cross(_ b: V) -> V { V(x: y*b.z-z*b.y, y: z*b.x-x*b.z, z: x*b.y-y*b.x) }
        var norm: Double { sqrt(dot(self)) }
        func scaled(_ k: Double) -> V { V(x: x*k, y: y*k, z: z*k) }
        func minus(_ b: V) -> V { V(x: x-b.x, y: y-b.y, z: z-b.z) }
    }
    static func vector(_ p: RelevancePoint) -> V {
        let lat = Double(p.latitude) / 1e7 * .pi / 180, lon = Double(p.longitude) / 1e7 * .pi / 180
        return V(x: cos(lat)*cos(lon), y: cos(lat)*sin(lon), z: sin(lat))
    }
    static func angle(_ a: V, _ b: V) -> Double { atan2(a.cross(b).norm, max(-1, min(1, a.dot(b)))) }
    static func segmentDistance(_ p: V, _ a: V, _ b: V) -> Double {
        let arc = angle(a, b), normal = a.cross(b)
        var best = min(angle(p, a), angle(p, b))
        guard normal.norm > 1e-15 else { return best * radius }
        let n = normal.scaled(1 / normal.norm), projection = p.minus(n.scaled(p.dot(n)))
        if projection.norm > 1e-15 {
            let q = projection.scaled(1 / projection.norm)
            for candidate in [q, q.scaled(-1)] where abs(angle(a, candidate) + angle(candidate, b) - arc) <= 1e-12 {
                best = min(best, angle(p, candidate))
            }
        }
        return best * radius
    }
}
