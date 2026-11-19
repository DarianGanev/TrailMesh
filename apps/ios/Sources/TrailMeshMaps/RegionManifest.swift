import Foundation
import CryptoKit

public enum MapFailure: Error, Equatable, Sendable {
    case unavailable, corrupt, space, cancelled, outsideCoverage, noRoute, invalidEngine, busy, relevanceTooComplex, invalidDifficulty
}

public struct MapPoint: Equatable, Codable, Sendable {
    public let latE7: Int64
    public let lonE7: Int64
    public init(latE7: Int64, lonE7: Int64) { self.latE7 = latE7; self.lonE7 = lonE7 }
    public var valid: Bool { (-900_000_000...900_000_000).contains(latE7) && (-1_800_000_000...1_800_000_000).contains(lonE7) }
}

public struct RegionManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String, asset: String, sha256: String
        public let bytes: Int64
    }
    public let format: Int
    public let id: String, revision: String, name: String, dataDate: String
    public let boundsE7: [Int64]
    public let minZoom: Int, maxZoom: Int
    public let engine: String, attribution: String
    public let files: [File]
    public var key: String { "\(id)/\(revision)" }
    public func contains(_ p: MapPoint) -> Bool {
        p.valid && p.lonE7 >= boundsE7[0] && p.latE7 >= boundsE7[1] && p.lonE7 <= boundsE7[2] && p.latE7 <= boundsE7[3]
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    public static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 160 && matches(path, "^[A-Za-z0-9_ ./,@+\\-]+$") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func text(_ text: String, maximum: Int) -> Bool {
        (1...maximum).contains(text.unicodeScalars.count) && !text.unicodeScalars.contains(where: { $0.value < 32 })
    }
    public static func parse(_ data: Data, expectedSHA256: String) throws -> RegionManifest {
        guard data.count <= 262144, digest(data) == expectedSHA256 else { throw MapFailure.corrupt }
        var reader = try StrictMapJSONParser(data)
        _ = try reader.parse()
        let keys: Set<String> = ["format","id","revision","name","dataDate","boundsE7","minZoom","maxZoom","engine","attribution","files"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys,
              let entries = object["files"] as? [[String: Any]], entries.allSatisfy({ Set($0.keys) == ["path","asset","bytes","sha256"] }) else { throw MapFailure.corrupt }
        let m = try JSONDecoder().decode(Self.self, from: data)
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX"); dateFormat.calendar = Calendar(identifier: .gregorian)
        dateFormat.timeZone = TimeZone(secondsFromGMT: 0); dateFormat.dateFormat = "yyyy-MM-dd"; dateFormat.isLenient = false
        guard let date = dateFormat.date(from: m.dataDate), dateFormat.string(from: date) == m.dataDate else { throw MapFailure.corrupt }
        guard m.format == 1, m.id.utf8.count <= 64, m.revision.utf8.count <= 64,
              matches(m.id, "^[a-z0-9]+(?:-[a-z0-9]+)*$"), matches(m.revision, "^[a-z0-9]+(?:-[a-z0-9]+)*$"),
              text(m.name, maximum: 120), matches(m.dataDate, "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"),
              m.boundsE7.count == 4, m.boundsE7[0] >= -1_800_000_000, m.boundsE7[2] <= 1_800_000_000,
              m.boundsE7[1] >= -900_000_000, m.boundsE7[3] <= 900_000_000, m.boundsE7[0] < m.boundsE7[2], m.boundsE7[1] < m.boundsE7[3],
              m.minZoom == 0, m.maxZoom == 14, m.engine == "valhalla-3.9.2", text(m.attribution, maximum: 1000),
              (1...256).contains(m.files.count) else { throw MapFailure.corrupt }
        var paths = Set<String>(), assets = Set<String>(), total: Int64 = 0
        for f in m.files {
            guard safePath(f.path), safePath(f.asset), !f.asset.contains("/"), paths.insert(f.path.lowercased()).inserted,
                  assets.insert(f.asset.lowercased()).inserted, (1...2_147_483_647).contains(f.bytes), matches(f.sha256, "^[a-f0-9]{64}$") else { throw MapFailure.corrupt }
            total += f.bytes
            if f.path == "places.json", f.bytes > 8 * 1024 * 1024 { throw MapFailure.corrupt }
            if f.path == "style.json", f.bytes > 1024 * 1024 { throw MapFailure.corrupt }
        }
        guard total <= 2_147_483_647, Set(["map.pmtiles","routing.tar","places.json","style.json","licenses/OSM.txt"]).isSubset(of: Set(m.files.map(\.path))) else { throw MapFailure.corrupt }
        return m
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 65536), !block.isEmpty { hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
