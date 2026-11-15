import Foundation
import XCTest
@testable import TrailMeshReports

final class RelevanceTests: XCTestCase {
    func testSharedLiteralDecisionsAndSelection() throws {
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "relevance-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for item in try XCTUnwrap(document["cases"] as? [[String: Any]]) {
            let context = RelevanceContext.parse(try JSONSerialization.data(withJSONObject: item["context"]!, options: [.fragmentsAllowed, .sortedKeys]))
            let report = try JSONDecoder().decode(RelevanceReport.self, from: JSONSerialization.data(withJSONObject: item["report"]!))
            let now = try XCTUnwrap(item["now_ms"] as? Int64)
            XCTAssertEqual(RelevancePolicy.evaluate(report, context: context, now: now).rawValue, item["expected"] as? String, item["name"] as? String ?? "case")
        }
        for item in try XCTUnwrap(document["selection_cases"] as? [[String: Any]]) {
            let context = RelevanceContext.parse(try JSONSerialization.data(withJSONObject: item["context"]!, options: [.fragmentsAllowed, .sortedKeys]))
            let reports = try JSONDecoder().decode([RelevanceReport].self, from: JSONSerialization.data(withJSONObject: item["reports"]!))
            let selected = RelevancePolicy.select(reports, context: context, now: try XCTUnwrap(item["now_ms"] as? Int64))
            XCTAssertEqual(selected.map(\.id), item["expected_ids"] as? [String], item["name"] as? String ?? "selection")
        }
    }
    func testOriginalJSONTypesCannotBypassStrictConfigurationParsing() {
        let report = RelevanceReport(id: "test", observedAt: 0, expiresAt: 100, latitude: 0, longitude: 0)
        let invalid = [
            #"{"manual_area":{"center":{"lat_e7":0,"lon_e7":0},"radius_m":1000.0}}"#,
            #"{"manual_area":{"center":{"lat_e7":0,"lon_e7":0},"radius_m":1e3}}"#,
            #"{"manual_area":{"center":{"lat_e7":0,"lon_e7":0},"radius_m":true}}"#,
            #"{"manual_area":{"center":{"lat_e7":0,"lon_e7":0},"radius_m":1000},"unknown":1}"#,
            #"{"manual_area":null}"#,
            #"{"route":{"points":[{"lat_e7":0,"lon_e7":0}],"corridor_m":null}}"#,
            #"{"manual_area":{"center":{"lat_e7":0.0,"lon_e7":0},"radius_m":1000}}"#,
            #"{"manual_area":{"center":{"lat_e7":0,"lon_e7":0},"\u0072adius_m":1000.0}}"#
        ]
        for literal in invalid {
            XCTAssertEqual(RelevancePolicy.evaluate(report, context: RelevanceContext.parse(Data(literal.utf8)), now: 0), .invalidConfiguration, literal)
        }
        let valid = #"{"gps_area":{"center":{"lat_e7":0,"lon_e7":0},"radius_m":1000,"accuracy_m":1.5,"fix_at_ms":0}}"#
        XCTAssertEqual(RelevancePolicy.evaluate(report, context: RelevanceContext.parse(Data(valid.utf8)), now: 0), .eligible)
    }
    func testOverlongRouteAndNonfiniteGPSAreTypedInvalidConfiguration() {
        let point = RelevancePoint(latitude: 0, longitude: 0)
        let report = RelevanceReport(id: "test", observedAt: 0, expiresAt: 100, latitude: 0, longitude: 0)
        let route = RelevanceContext(route: RelevanceRoute(points: Array(repeating: point, count: 2049)))
        XCTAssertEqual(RelevancePolicy.evaluate(report, context: route, now: 0), .invalidConfiguration)
        let gps = RelevanceContext(gpsArea: RelevanceGPSArea(center: point, radius: 1000, accuracy: .infinity, fixAt: 0))
        XCTAssertEqual(RelevancePolicy.evaluate(report, context: gps, now: 0), .invalidConfiguration)
    }
}
