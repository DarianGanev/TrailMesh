import Foundation
import XCTest
@testable import TrailMeshReports

final class RelevanceTests: XCTestCase {
    func testDiagnosticsCountTypedReasonsAndDeduplicationWithoutGeometry() {
        let context = RelevanceContext(manualArea: RelevanceArea(center: RelevancePoint(latitude: 0, longitude: 0), radius: 1000))
        let a = RelevanceReport(id: "a", observedAt: 3, expiresAt: 100, latitude: 0, longitude: 0)
        let b = RelevanceReport(id: "b", observedAt: 2, expiresAt: 100, latitude: 0, longitude: 0)
        let expired = RelevanceReport(id: "old", observedAt: 1, expiresAt: 10, latitude: 0, longitude: 0)
        let distant = RelevanceReport(id: "far", observedAt: 4, expiresAt: 100, latitude: 10000000, longitude: 0)
        let reports = [distant, a, expired, b, a]
        let selection = RelevancePolicy.selectWithDiagnostics(reports, context: context, now: 10)
        XCTAssertEqual(selection.reports.map(\.id), ["a", "b"])
        XCTAssertEqual(selection.diagnostics.candidateCount, 5)
        XCTAssertEqual(selection.diagnostics.decisionCounts[.eligible], 3)
        XCTAssertEqual(selection.diagnostics.decisionCounts[.expired], 1)
        XCTAssertEqual(selection.diagnostics.decisionCounts[.notRelevant], 1)
        XCTAssertEqual(selection.diagnostics.decisionCounts[.configurationRequired], 0)
        XCTAssertEqual(selection.diagnostics.decisionCounts[.invalidConfiguration], 0)
        XCTAssertEqual(selection.diagnostics.duplicateCount, 1)
        XCTAssertEqual(selection.diagnostics.selectedCount, 2)
        XCTAssertEqual(RelevancePolicy.diagnostics(reports, context: context, now: 10), selection.diagnostics)
        XCTAssertEqual(RelevancePolicy.select(reports, context: context, now: 10).map(\.id), selection.reports.map(\.id))
        let missing = RelevancePolicy.diagnostics(reports, context: nil, now: 10)
        XCTAssertEqual(missing.decisionCounts[.configurationRequired], 4)
        XCTAssertEqual(missing.decisionCounts[.expired], 1)
        let invalid = RelevancePolicy.diagnostics(reports, context: RelevanceContext.parse(Data("[]".utf8)), now: 10)
        XCTAssertEqual(invalid.decisionCounts[.invalidConfiguration], 5)
        XCTAssertEqual(invalid.selectedCount, 0)
    }
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
