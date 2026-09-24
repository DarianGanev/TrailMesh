import XCTest

@testable import TrailMeshTransportProbe

final class ForegroundFrameTests: XCTestCase {
    func testDeterministicTwoKiBPayloadMatchesGoldenSha256() throws {
        let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 0)

        XCTAssertEqual(payload.count, 2048)
        XCTAssertEqual(
            ForegroundFrame.digestHex(payload),
            "b2a8170614e23194ae2951423d601987f518ce2f11205d7b0b708080103b9f76")
    }

    func testFrameRoundTripsPayloadAndAttempt() throws {
        let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 7)
        let encoded = try ForegroundFrame.encodeDataMessage(attemptIndex: 7, payload: payload)
        let decoded = try ForegroundFrame.decodeDataMessage(encoded)

        XCTAssertEqual(decoded.attemptIndex, 7)
        XCTAssertEqual(decoded.frame.payload, payload)
        XCTAssertEqual(decoded.frame.digest, ForegroundFrame.digest(payload))
    }

    func testFrameHeaderMatchesTheSharedPythonAndAndroidWireVector() throws {
        let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 0)
        let frame = try ForegroundFrame.encode(payload)

        XCTAssertEqual(ForegroundFrame.hex(Data(frame.prefix(4))), "00000800")
        XCTAssertEqual(
            ForegroundFrame.hex(Data(frame[4..<36])),
            "b2a8170614e23194ae2951423d601987f518ce2f11205d7b0b708080103b9f76")
    }

    func testFrameRejectsCorruptionAndOversizedPayloads() throws {
        var damaged = try ForegroundFrame.encode(Data(repeating: 0, count: 8))
        damaged[damaged.count - 1] = 1

        XCTAssertThrowsError(try ForegroundFrame.decode(damaged))
        XCTAssertThrowsError(try ForegroundFrame.encode(Data(repeating: 0, count: ForegroundFrame.maxPayloadBytes + 1)))
    }

    func testAcknowledgementRoundTrips() throws {
        let digest = ForegroundFrame.digest(try ForegroundFrame.makeTestPayload(size: 256, attemptIndex: 3))
        let encoded = try ForegroundFrame.encodeAckMessage(attemptIndex: 3, accepted: true, digest: digest)
        let decoded = try ForegroundFrame.decodeAckMessage(encoded)

        XCTAssertTrue(ForegroundFrame.isAckMessage(encoded))
        XCTAssertEqual(
            ForegroundFrame.hex(encoded),
            "544d41310000000301fab20605b31d3530c3072e00e660a170d3be0a06dcf1fd465726e2ef2630ea03")
        XCTAssertEqual(decoded.attemptIndex, 3)
        XCTAssertTrue(decoded.accepted)
        XCTAssertEqual(decoded.digest, digest)
    }
}
