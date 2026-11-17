import XCTest
@testable import TrailMeshMaps

final class MapsTests: XCTestCase {
    func testSnapDistanceUsesSharedMeanEarthRadius() {
        let from = MapPoint(latE7: 0, lonE7: 0), to = MapPoint(latE7: 0, lonE7: 10_000_000)
        XCTAssertEqual(HikingRoute.meters(from, to), 6_371_008.8 * .pi / 180, accuracy: 0.000001)
    }
    func testPlaceIdentifiersFollowOSMContract() throws {
        for id in ["node/1", "way/123", "relation/999", "arbitrary", "node/0", "node/01", "way/-1", "node/1\n", "NODE/1", "node/1/2"] {
            let place: [String: Any] = ["id": id, "name": "Hut", "aliases": [], "kind": "hut", "latE7": 420000000, "lonE7": 230000000]
            let data = try JSONSerialization.data(withJSONObject: ["format": 1, "places": [place]])
            if ["node/1", "way/123", "relation/999"].contains(id) { XCTAssertNoThrow(try PlaceIndex(data: data), id) }
            else { XCTAssertThrowsError(try PlaceIndex(data: data), id) }
        }
    }
    func testTextLimitsCountUnicodeScalarsInsteadOfGraphemes() {
        XCTAssertFalse(RegionManifest.text(String(repeating: "e\u{0301}", count: 120), maximum: 120))
        XCTAssertFalse(RegionManifest.text(String(repeating: "\u{1f469}\u{200d}\u{1f4bb}", count: 41), maximum: 120))
        XCTAssertTrue(RegionManifest.text(String(repeating: "\u{1f3d4}", count: 120), maximum: 120))
        XCTAssertFalse(RegionManifest.text(String(repeating: "\u{1f3d4}", count: 121), maximum: 120))
        XCTAssertFalse(RegionManifest.text(String(repeating: "e\u{0301}", count: 501), maximum: 1000))
    }
    func testPlaceNamesAndAliasesUseScalarLimits() throws {
        for field in ["name", "aliases"] {
            var place: [String: Any] = ["id": "node/1", "name": "Hut", "aliases": [], "kind": "hut", "latE7": 420000000, "lonE7": 230000000]
            let text = String(repeating: "e\u{0301}", count: 61)
            if field == "name" { place[field] = text } else { place[field] = [text] }
            let data = try JSONSerialization.data(withJSONObject: ["format": 1, "places": [place]])
            XCTAssertThrowsError(try PlaceIndex(data: data), field)
        }
    }
    func testReleaseCDNRedirectPolicy() {
        XCTAssertTrue(PackRedirectPolicy.allowed(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/x")))
        XCTAssertFalse(PackRedirectPolicy.allowed(URL(string: "http://release-assets.githubusercontent.com/x")))
        XCTAssertFalse(PackRedirectPolicy.allowed(URL(string: "https://user:password@example.com/x")))
    }
    func testUnsafePathsAndCaseCollisions() throws {
        for path in ["../x", "/map.pmtiles", "a//b", "a/./b", "a%2fb", "a\\b", "é"] {
            XCTAssertFalse(RegionManifest.safePath(path))
        }
        XCTAssertTrue(RegionManifest.safePath("glyphs/Noto Sans/1024-1279.pbf"))
    }
    func testPolylineBoundsAndPrecision() throws {
        XCTAssertEqual(try HikingRoute.decodePolyline6("??SS"), [MapPoint(latE7: 0, lonE7: 0), MapPoint(latE7: 100, lonE7: 100)])
        for shape in ["?", "~~~~~~~~~~~~~~~~~~~~?", "\u{00e9}?"] {
            XCTAssertThrowsError(try HikingRoute.decodePolyline6(shape))
        }
        XCTAssertThrowsError(try HikingRoute.decodePolyline6(String(repeating: "??", count: 100001)))
    }
    func testSearchNormalizationAndStableOrdering() throws {
        let json = #"{"format":1,"places":[{"id":"node/2","name":"Élan Hut","aliases":["Хижа"],"kind":"hut","latE7":420000000,"lonE7":230000000},{"id":"node/1","name":"Elan Peak","aliases":[],"kind":"peak","latE7":420000000,"lonE7":230000000}]}"#
        let places = try PlaceIndex(data: Data(json.utf8))
        XCTAssertEqual(places.search("elan").map(\.id), ["node/2", "node/1"])
        XCTAssertEqual(places.search("хи").first?.id, "node/2")
        XCTAssertTrue(places.search(" ").isEmpty)
    }
    func testStyleRejectsExternalResources() throws {
        let files: Set<String> = ["map.pmtiles"]
        XCTAssertThrowsError(try LocalStyle.resolve(Data(#"{"version":8,"sources":{"x":{"type":"vector","url":"https://example.com/x"}},"layers":[]}"#.utf8), root: URL(fileURLWithPath: "/tmp/pack"), files: files))
        XCTAssertThrowsError(try LocalStyle.resolve(Data(#"{"version":8,"sources":{},"imports":[],"layers":[]}"#.utf8), root: URL(fileURLWithPath: "/tmp/pack"), files: files))
    }
    func testRouteRelevanceNeverTruncates() throws {
        let route = HikingRoute(points: Array(repeating: MapPoint(latE7: 0, lonE7: 0), count: 2049), distanceKm: 1, timeSeconds: 1)
        XCTAssertThrowsError(try route.relevancePoints())
    }
    func testPMTilesMetadataCannotOverrideLocalTiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var header = Data(repeating: 0, count: 127)
        header.replaceSubrange(0..<8, with: Array("PMTiles".utf8) + [3])
        let metadata = Data(#"{"tiles":["https://example.com/{z}/{x}/{y}"]}"#.utf8)
        header[24] = 127; header[32] = UInt8(metadata.count); header[97] = 1; header[98] = 1
        header.append(metadata); try header.write(to: root)
        XCTAssertThrowsError(try PMTilesMetadata.validate(root))
    }
    func testLeasesBlockRemovalUntilExplicitRelease() throws {
        let registry = PackLeases()
        let lease = registry.acquire("rila/v1")
        XCTAssertThrowsError(try registry.withRemoval("rila/v1") {})
        lease.close()
        try registry.withRemoval("rila/v1") {}
    }
}
