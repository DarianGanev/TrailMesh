import XCTest
@testable import TrailMeshMaps

final class ManifestVectorTests: XCTestCase {
    func testSharedLiteralManifestVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "region-v1-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let input = try Data(contentsOf: url)
        let cases = try literalCases(input)
        XCTAssertGreaterThan(cases.count, 10)
        for literal in cases {
            let key = try XCTUnwrap(literal.range(of: Data("\"manifest\"".utf8)))
            let start = try XCTUnwrap(literal[key.upperBound...].firstIndex(of: 123))
            let range = try objectRange(literal, start: start)
            let data = literal.subdata(in: range)
            var metadata = literal
            metadata.replaceSubrange(range, with: Data("{}".utf8))
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
            let id = try XCTUnwrap(fixture["id"] as? String)
            let valid = try XCTUnwrap(fixture["valid"] as? Bool)
            if valid {
                let manifest = try RegionManifest.parse(data, expectedSHA256: RegionManifest.digest(data))
                let b = manifest.boundsE7
                let start = MapPoint(latE7: b[1], lonE7: b[0])
                let outside = MapPoint(latE7: b[3] + 1, lonE7: b[2])
                let route = HikingRoute(points: [start, outside, start], distanceKm: 1, timeSeconds: 1)
                XCTAssertThrowsError(try route.validateCoverage(manifest)) { XCTAssertEqual($0 as? MapFailure, .outsideCoverage) }
                let longRoute = HikingRoute(points: Array(repeating: start, count: 2049), distanceKm: 1, timeSeconds: 1)
                XCTAssertNoThrow(try longRoute.validateCoverage(manifest))
                XCTAssertThrowsError(try longRoute.relevancePoints())
            } else {
                XCTAssertThrowsError(try RegionManifest.parse(data, expectedSHA256: RegionManifest.digest(data)), id)
            }
        }
    }
    // Keep each manifest's literal bytes, including invalid Unicode escapes and
    // numeric lexemes. Foundation cannot decode the entire fixture when one
    // deliberately invalid case contains an unpaired surrogate.
    private func literalCases(_ data: Data) throws -> [Data] {
        let key = try XCTUnwrap(data.range(of: Data("\"cases\"".utf8)))
        var index = try XCTUnwrap(data[key.upperBound...].firstIndex(of: 91)) + 1
        var result: [Data] = []
        while index < data.endIndex {
            if data[index] == 93 { return result }
            if data[index] == 123 {
                let range = try objectRange(data, start: index)
                result.append(data.subdata(in: range)); index = range.upperBound
            } else { index += 1 }
        }
        throw MapFailure.corrupt
    }
    private func objectRange(_ data: Data, start: Int) throws -> Range<Int> {
        var depth = 0, quoted = false, escaped = false
        for index in start..<data.endIndex {
            let byte = data[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0 { return start..<(index + 1) }
            }
        }
        throw MapFailure.corrupt
    }
}
