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
    func testRouteRequestKeepsDefaultDifficultyAndBoundsExplicitSelection() throws {
        let manifest = RegionManifest(
            format: 1, id: "rila", revision: "test", name: "Rila", dataDate: "2026-11-16",
            boundsE7: [0, 0, 100, 100], minZoom: 0, maxZoom: 14, engine: "valhalla-3.9.2",
            attribution: "Test", files: []
        )
        let from = MapPoint(latE7: 10, lonE7: 20), to = MapPoint(latE7: 30, lonE7: 40)
        func encodedDifficulty(_ request: String) throws -> Int {
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
            let options = try XCTUnwrap(result["costing_options"] as? [String: [String: Int]])
            XCTAssertEqual(options["pedestrian"]?["use_ferry"], 0)
            let locations = try XCTUnwrap(result["locations"] as? [[String: Double]])
            XCTAssertEqual(locations.compactMap { $0["search_cutoff"] }, [100, 100])
            return try XCTUnwrap(options["pedestrian"]?["max_hiking_difficulty"])
        }
        XCTAssertEqual(try encodedDifficulty(HikingRoute.request(from: from, to: to, manifest: manifest)), 2)
        for difficulty in [0, 3, 6] {
            let request = try HikingRoute.request(from: from, to: to, manifest: manifest, maximumHikingDifficulty: difficulty)
            XCTAssertEqual(try encodedDifficulty(request), difficulty)
        }
        for difficulty in [-1, 7] {
            XCTAssertThrowsError(try HikingRoute.request(from: from, to: to, manifest: manifest, maximumHikingDifficulty: difficulty)) {
                XCTAssertEqual($0 as? MapFailure, .invalidDifficulty)
            }
        }
    }
    func testRouteErrorBodyAndMalformedJSONHaveDistinctFailures() {
        let point = MapPoint(latE7: 0, lonE7: 0)
        for (body, expected) in [(#"{"error_code":442,"error":"No path could be found"}"#, MapFailure.noRoute),
                                 (#"{"code":442,"error":"No path could be found"}"#, MapFailure.noRoute),
                                 (#"{"code":-1,"error":"unknown exception"}"#, MapFailure.invalidEngine),
                                 (#"{"code":999,"error":"unknown error"}"#, MapFailure.invalidEngine),
                                 (#"{"error":"missing error code"}"#, MapFailure.invalidEngine),
                                 ("malformed", MapFailure.invalidEngine)] {
            XCTAssertThrowsError(try HikingRoute.parse(Data(body.utf8), from: point, to: point)) {
                XCTAssertEqual($0 as? MapFailure, expected)
            }
        }
    }
    func testRouteManeuversReferToValidOrderedShapePoints() throws {
        let origin = MapPoint(latE7: 0, lonE7: 0)
        let end = MapPoint(latE7: 100, lonE7: 100)
        func route(_ maneuvers: [[String: Any]]) throws -> HikingRoute {
            let response: [String: Any] = ["trip": [
                "status": 0, "units": "kilometers", "summary": ["length": 0.01, "time": 5],
                "legs": [["shape": "??SS", "maneuvers": maneuvers]]
            ]]
            return try HikingRoute.parse(JSONSerialization.data(withJSONObject: response), from: origin, to: end)
        }
        let first: [String: Any] = ["instruction": "Follow the trail", "begin_shape_index": 0]
        let second: [String: Any] = ["instruction": "Arrive at the hut", "begin_shape_index": 1]
        let result = try route([first, second])
        XCTAssertEqual(result.maneuvers.map(\.instruction), ["Follow the trail", "Arrive at the hut"])
        XCTAssertThrowsError(try route([second, first]))
        XCTAssertThrowsError(try route([["instruction": "Arrive", "begin_shape_index": 2]]))
        XCTAssertThrowsError(try route([["instruction": "", "begin_shape_index": 1]]))
    }

    func testGuidanceUsesTheReturnLegAndSuppressesArrivalUntilNearDestination() throws {
        let a = MapPoint(latE7: 0, lonE7: 0)
        let b = MapPoint(latE7: 10_000, lonE7: 0)
        let middle = MapPoint(latE7: 5_000, lonE7: 0)
        let route = HikingRoute(points: [a, b, a], distanceKm: 0.22, timeSeconds: 200, maneuvers: [
            .init(pointIndex: 1, instruction: "Turn back"),
            .init(pointIndex: 2, instruction: "Arrive", type: 4)
        ])
        let start = try XCTUnwrap(route.match(a))
        XCTAssertFalse(route.isAtDestination(start, tolerance: 12))
        let outbound = try XCTUnwrap(route.match(middle, following: start))
        XCTAssertEqual(route.nextInstruction(at: outbound), "Turn back")
        let turnaround = try XCTUnwrap(route.match(b, following: outbound))
        let returning = try XCTUnwrap(route.match(middle, following: turnaround))
        XCTAssertNil(route.nextInstruction(at: returning))
        XCTAssertFalse(route.isAtDestination(returning, tolerance: 12))
        let arrival = try XCTUnwrap(route.match(a, following: returning))
        XCTAssertTrue(route.isAtDestination(arrival, tolerance: 12))
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
        XCTAssertEqual(places.search("elan-hut").first?.id, "node/2")
        XCTAssertTrue(places.search(" --- ").isEmpty)
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
