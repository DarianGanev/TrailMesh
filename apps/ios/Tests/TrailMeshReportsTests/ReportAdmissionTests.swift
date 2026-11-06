import CryptoKit
import Foundation
import XCTest
@testable import TrailMeshReports

final class ReportAdmissionTests: XCTestCase {
    private func cases() throws -> [[String: Any]] {
        let resource = try XCTUnwrap(TestResources.bundle.url(forResource: "report-v1-vectors", withExtension: "json"))
        let data = try Data(contentsOf: resource)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 24, "The authoritative vector file must be present and complete")
        return cases
    }

    func testEverySharedAdmissionVector() throws {
        for item in try cases() {
            let name = try XCTUnwrap(item["name"] as? String)
            let encoded = try XCTUnwrap(item["wire_base64"] as? String)
            let wire = try XCTUnwrap(Data(base64Encoded: encoded))
            let now = try XCTUnwrap(item["now_ms"] as? Int64)
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])
            let outcome = try XCTUnwrap(expected["outcome"] as? String)
            let actual = ReportAdmission.validate(wire, now: now)
            XCTAssertEqual(actual.outcome, outcome, name)
            if outcome == "accepted" {
                XCTAssertEqual(actual.bundleID, expected["bundle_id"] as? String, name)
                XCTAssertEqual(actual.canonicalCore?.base64EncodedString(), expected["canonical_core_base64"] as? String, name)
                XCTAssertEqual(actual.canonicalEnvelope?.base64EncodedString(), expected["canonical_envelope_base64"] as? String, name)
            }
        }
    }

    func testCryptoKitVerifiesFrozenSignatureAndRejectsMutation() throws {
        let item = try XCTUnwrap(try cases().first { $0["name"] as? String == "frozen-v1" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let core = try XCTUnwrap(envelope["core"] as? [String: Any])
        func base64url(_ text: String) throws -> Data {
            let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            return try XCTUnwrap(Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4)))
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: base64url(try XCTUnwrap(core["author_key"] as? String)))
        let signature = try base64url(try XCTUnwrap(envelope["signature"] as? String))
        let expected = try XCTUnwrap(item["expected"] as? [String: Any])
        let canonical = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(expected["canonical_core_base64"] as? String)))
        var message = Data("TrailMesh/core/v1\n".utf8)
        message.append(canonical)
        XCTAssertTrue(key.isValidSignature(signature, for: message))
        message.append(0)
        XCTAssertFalse(key.isValidSignature(signature, for: message))
    }

    func testAcceptedVectorsPreserveEveryReportProjectionField() async throws {
        let world = ReportBounds(south: -900_000_000, north: 900_000_000, west: -1_800_000_000, east: 1_800_000_000)
        for item in try cases() {
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])
            guard expected["outcome"] as? String == "accepted" else { continue }
            let name = try XCTUnwrap(item["name"] as? String)
            let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
            let now = try XCTUnwrap(item["now_ms"] as? Int64)
            let expectedReport = try XCTUnwrap(expected["report"] as? [String: Any])
            let repository = try ReportRepository(path: ":memory:")
            guard case .stored = try await repository.ingest(wire, now: now) else { XCTFail(name); continue }
            let reports = try await repository.reports(now: now, bounds: world)
            let actual = try XCTUnwrap(reports.first, name)
            XCTAssertEqual(reports.count, 1, name)
            XCTAssertEqual(actual.bundleID, expected["bundle_id"] as? String, name)
            XCTAssertEqual(actual.eventID.map { String(format: "%02x", $0) }.joined(), expectedReport["event_id"] as? String, name)
            XCTAssertEqual(actual.category, expectedReport["category"] as? String, name)
            XCTAssertEqual(actual.status, expectedReport["status"] as? String, name)
            XCTAssertEqual(Data(actual.note.utf8), Data(try XCTUnwrap(expectedReport["note"] as? String).utf8), name)
            XCTAssertEqual(actual.latitude, expectedReport["lat_e7"] as? Int64, name)
            XCTAssertEqual(actual.longitude, expectedReport["lon_e7"] as? Int64, name)
            XCTAssertEqual(actual.accuracy, expectedReport["accuracy_m"] as? Int64, name)
            XCTAssertEqual(actual.observedAt, expectedReport["observed_at_ms"] as? Int64, name)
            XCTAssertNil(actual.supersedes, name)
        }
    }

    func testBadSignatureIsInvalidEvenAfterExpiry() throws {
        let item = try XCTUnwrap(try cases().first { $0["name"] as? String == "invalid-signature" })
        let wire = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(item["wire_base64"] as? String)))
        XCTAssertEqual(ReportAdmission.validate(wire, now: 1_789_732_800_001).outcome, "invalid")
    }

}
