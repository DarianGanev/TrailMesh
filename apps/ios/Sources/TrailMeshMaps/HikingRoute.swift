import Foundation

public struct HikingRoute: Sendable {
    public let points: [MapPoint]
    public let distanceKm: Double, timeSeconds: Double
    public init(points: [MapPoint], distanceKm: Double, timeSeconds: Double) {
        self.points = points; self.distanceKm = distanceKm; self.timeSeconds = timeSeconds
    }
    public func relevancePoints() throws -> [MapPoint] {
        guard points.count >= 2, points.count <= 2048 else { throw MapFailure.relevanceTooComplex }
        return points
    }
    public func validateCoverage(_ manifest: RegionManifest) throws {
        guard points.allSatisfy(manifest.contains) else { throw MapFailure.outsideCoverage }
    }
    public static func decodePolyline6(_ shape: String) throws -> [MapPoint] {
        let bytes = Array(shape.utf8)
        guard bytes.count <= 4 * 1024 * 1024 else { throw MapFailure.invalidEngine }
        var offset = 0, lat: Int64 = 0, lon: Int64 = 0, result: [MapPoint] = []
        func component() throws -> Int64 {
            var value: UInt64 = 0, shift = 0
            while true {
                guard offset < bytes.count, (63...126).contains(bytes[offset]), shift <= 30 else { throw MapFailure.invalidEngine }
                let chunk = UInt64(bytes[offset] - 63); offset += 1
                value |= (chunk & 31) << shift
                if chunk < 32 { break }
                shift += 5
            }
            let magnitude = Int64(value >> 1)
            return value & 1 == 0 ? magnitude : -magnitude - 1
        }
        while offset < bytes.count {
            guard result.count < 100000 else { throw MapFailure.invalidEngine }
            lat += try component(); lon += try component()
            guard (-90_000_000...90_000_000).contains(lat), (-180_000_000...180_000_000).contains(lon) else { throw MapFailure.invalidEngine }
            result.append(MapPoint(latE7: lat * 10, lonE7: lon * 10))
        }
        guard result.count >= 2 else { throw MapFailure.invalidEngine }
        return result
    }
    public static func request(from: MapPoint, to: MapPoint, manifest: RegionManifest, maximumHikingDifficulty: Int = 2) throws -> String {
        guard (0...6).contains(maximumHikingDifficulty) else { throw MapFailure.invalidDifficulty }
        guard manifest.contains(from), manifest.contains(to) else { throw MapFailure.outsideCoverage }
        let locations = [from, to].map { ["lat": Double($0.latE7) / 1e7, "lon": Double($0.lonE7) / 1e7, "search_cutoff": 100.0] }
        let value: [String: Any] = ["locations": locations, "costing": "pedestrian", "units": "kilometers", "shape_format": "polyline6",
            "costing_options": ["pedestrian": ["max_hiking_difficulty": maximumHikingDifficulty, "use_ferry": 0]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    public static func parse(_ data: Data, from: MapPoint, to: MapPoint) throws -> HikingRoute {
        guard data.count <= 4 * 1024 * 1024,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw MapFailure.invalidEngine }
        if ["error", "error_code", "code"].contains(where: object.keys.contains) {
            let code = (object["error_code"] ?? object["code"]) as? Int
            switch code {
            case 170, 171, 441, 442: throw MapFailure.noRoute
            default: throw MapFailure.invalidEngine
            }
        }
        guard let trip = object["trip"] as? [String: Any] else { throw MapFailure.invalidEngine }
        guard trip["status"] as? Int == 0 else { throw MapFailure.noRoute }
        guard trip["units"] as? String == "kilometers", let summary = trip["summary"] as? [String: Any],
              let distance = summary["length"] as? Double, let time = summary["time"] as? Double,
              distance.isFinite, time.isFinite, distance >= 0, time >= 0,
              let legs = trip["legs"] as? [[String: Any]], legs.count == 1, let shape = legs[0]["shape"] as? String else { throw MapFailure.invalidEngine }
        let points = try decodePolyline6(shape)
        guard meters(points[0], from) <= 100, meters(points[points.count - 1], to) <= 100 else { throw MapFailure.invalidEngine }
        return HikingRoute(points: points, distanceKm: distance, timeSeconds: time)
    }
    static func meters(_ a: MapPoint, _ b: MapPoint) -> Double {
        let lat1 = Double(a.latE7) * .pi / 1.8e9, lat2 = Double(b.latE7) * .pi / 1.8e9
        let dlat = lat2 - lat1, dlon = Double(b.lonE7 - a.lonE7) * .pi / 1.8e9
        let h = pow(sin(dlat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dlon / 2), 2)
        return 2 * 6_371_008.8 * asin(sqrt(min(1, max(0, h))))
    }
}
