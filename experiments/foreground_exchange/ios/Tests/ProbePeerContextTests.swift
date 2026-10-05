import XCTest

@testable import TrailMeshTransportProbe

final class ProbePeerContextTests: XCTestCase {
    private let first = "00112233445566778899aabbccddeeff"
    private let second = "ffeeddccbbaa99887766554433221100"

    func testContextRoundTripsStrictAsciiMetadata() {
        let android = ProbePeerContext(platform: .android, sessionID: first, payloadSize: 2048)
        XCTAssertEqual(android.encoded, "TM2|A|00112233445566778899aabbccddeeff|2048")
        XCTAssertEqual(ProbePeerContext.parse(Data(android.encoded.utf8)), android)
        XCTAssertEqual(ProbePeerContext.parse(Data("TM2|I|\(second)|8192".utf8)), ProbePeerContext(platform: .ios, sessionID: second, payloadSize: 8192))
        XCTAssertEqual(ProbePeerContext.parse(Data("TM2|A|\(first)|256".utf8))?.payloadSize, 256)
    }

    func testContextRejectsNoncanonicalUnsupportedAndUnboundedMetadata() {
        for invalid in [
            "", "TM1|A|\(first)|2048", "TM2|X|\(first)|2048", "TM2|A|\(first.uppercased())|2048",
            "TM2|A|\(first.dropLast())|2048", "TM2|A|\(String(repeating: "z", count: 32))|2048",
            "TM2|A|\(first)|02048", "TM2|A|\(first)|1024", "TM2|A|\(first)|0", "TM2|A|\(first)|-256",
            "TM2|A|\(first)|2048|extra", " TM2|A|\(first)|2048", "TM2|A|\(first)|2048\n",
            "TM2|A|\(first)|2048\u{0}", String(repeating: "x", count: 4096),
        ] {
            XCTAssertNil(ProbePeerContext.parse(Data(invalid.utf8)), invalid)
        }
        XCTAssertNil(ProbePeerContext.parse(Data(repeating: 255, count: 43)))
    }

    func testCompatibilityRequiresDistinctSessionsSameSizeAndSupportedPlatformPair() {
        let android = ProbePeerContext(platform: .android, sessionID: first, payloadSize: 2048)
        XCTAssertTrue(android.isCompatible(with: ProbePeerContext(platform: .ios, sessionID: second, payloadSize: 2048)))
        XCTAssertFalse(android.isCompatible(with: ProbePeerContext(platform: .ios, sessionID: first, payloadSize: 2048)))
        XCTAssertFalse(android.isCompatible(with: ProbePeerContext(platform: .ios, sessionID: second, payloadSize: 8192)))
        XCTAssertFalse(ProbePeerContext(platform: .ios, sessionID: first, payloadSize: 2048).isCompatible(with: ProbePeerContext(platform: .ios, sessionID: second, payloadSize: 2048)))
    }

    func testInitiationElectsExactlyOneCompatibleDevice() {
        let android = ProbePeerContext(platform: .android, sessionID: first, payloadSize: 2048)
        let otherAndroid = ProbePeerContext(platform: .android, sessionID: second, payloadSize: 2048)
        let ios = ProbePeerContext(platform: .ios, sessionID: second, payloadSize: 2048)
        XCTAssertTrue(android.canInitiate(to: otherAndroid))
        XCTAssertFalse(otherAndroid.canInitiate(to: android))
        XCTAssertFalse(android.canInitiate(to: ios))
        XCTAssertTrue(ios.canInitiate(to: android))
        XCTAssertFalse(android.canInitiate(to: android))
        XCTAssertFalse(android.canInitiate(to: ProbePeerContext(platform: .ios, sessionID: second, payloadSize: 8192)))
    }
}
