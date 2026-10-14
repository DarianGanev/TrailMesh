import XCTest

@testable import TrailMeshTransportProbe

final class ForegroundFrameTests: XCTestCase {
    private let sessionID = "000102030405060708090a0b0c0d0e0f"
    private let peerSessionID = "101112131415161718191a1b1c1d1e1f"

    func testLegacyRawFrameAndAcknowledgementAcceptSlicedData() throws {
        let prefix = Data(repeating: 0, count: 64)
        let payload = Data([3, 4, 5, 6])
        let rawFrame = try ForegroundFrame.encode(payload)
        let slicedFrame = (prefix + rawFrame).dropFirst(64)
        XCTAssertEqual(slicedFrame.startIndex, 64)
        let decodedFrame = try ForegroundFrame.decode(slicedFrame)
        XCTAssertEqual(decodedFrame.payload, payload)
        XCTAssertEqual(ForegroundFrame.hex(decodedFrame.digest), "0488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070")

        let ack = try ForegroundFrame.encodeAckMessage(attemptIndex: 3, accepted: true, digest: decodedFrame.digest)
        let slicedAck = (prefix + ack).dropFirst(64)
        XCTAssertEqual(slicedAck.startIndex, 64)
        XCTAssertTrue(ForegroundFrame.isAckMessage(slicedAck))
        let decodedAck = try ForegroundFrame.decodeAckMessage(slicedAck)
        XCTAssertEqual(decodedAck.attemptIndex, 3)
        XCTAssertTrue(decodedAck.accepted)
        XCTAssertEqual(ForegroundFrame.hex(decodedAck.digest), "0488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070")
    }

    func testSessionMessagesAcceptSlicedData() throws {
        let prefix = Data(repeating: 0, count: 64)
        let payload = Data([3, 4, 5, 6])
        let digest = hexBytes("0488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070")
        let hello = (prefix + (try ForegroundFrame.encodeHelloMessage(sessionID: sessionID, peerSessionID: peerSessionID, payloadSize: 2048))).dropFirst(64)
        XCTAssertEqual(try ForegroundFrame.decodeHelloMessage(hello).peerSessionID, peerSessionID)
        let data = (prefix + (try ForegroundFrame.encodeSessionDataMessage(sessionID: sessionID, attemptIndex: 3, payload: payload))).dropFirst(64)
        XCTAssertEqual(try ForegroundFrame.decodeSessionDataMessage(data).frame.payload, payload)
        let ack = (prefix + (try ForegroundFrame.encodeSessionAckMessage(sessionID: sessionID, attemptIndex: 3, accepted: true, digest: digest))).dropFirst(64)
        XCTAssertEqual(try ForegroundFrame.decodeSessionAckMessage(ack).digest, digest)
        let finish = (prefix + (try ForegroundFrame.encodeFinishMessage(sessionID: sessionID, peerSessionID: peerSessionID, acknowledgement: true, successfulAttempts: 19, failedAttempts: 1))).dropFirst(64)
        XCTAssertTrue(try ForegroundFrame.decodeFinishMessage(finish).acknowledgement)
    }

    func testLegacyPayloadGenerationDoesNotOverflowAtLargestSignedAttempt() throws {
        XCTAssertEqual(ForegroundFrame.digestHex(try ForegroundFrame.makeTestPayload(size: 256, attemptIndex: Int(Int32.max))),
                       "a93ad1a83211655a5a8ede8c88e0724f0d72e48bb8232150e5f9a6fa2a05a16e")
        XCTAssertThrowsError(try ForegroundFrame.encodeDataMessage(attemptIndex: Int.max, payload: Data([1])))
        XCTAssertThrowsError(try ForegroundFrame.encodeAckMessage(attemptIndex: Int.max, accepted: true, digest: Data(repeating: 0, count: 32)))
    }

    func testSessionMessagesMatchIndependentSharedGoldenVectors() throws {
        let hello = try ForegroundFrame.encodeHelloMessage(sessionID: sessionID, peerSessionID: peerSessionID, payloadSize: 2048)
        XCTAssertEqual(ForegroundFrame.hex(hello), "544d4832000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0000080000000014")
        XCTAssertTrue(ForegroundFrame.isHelloMessage(hello))
        let decodedHello = try ForegroundFrame.decodeHelloMessage(hello)
        XCTAssertEqual(decodedHello.sessionID, sessionID)
        XCTAssertEqual(decodedHello.peerSessionID, peerSessionID)
        XCTAssertEqual(decodedHello.payloadSize, 2048)
        XCTAssertEqual(decodedHello.attemptCount, 20)

        let payload = Data([3, 4, 5, 6])
        let data = try ForegroundFrame.encodeSessionDataMessage(sessionID: sessionID, attemptIndex: 3, payload: payload)
        XCTAssertEqual(ForegroundFrame.hex(data), "544d4432000102030405060708090a0b0c0d0e0f00000003000000040488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d507003040506")
        let decoded = try ForegroundFrame.decodeSessionDataMessage(data)
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.attemptIndex, 3)
        XCTAssertEqual(decoded.frame.payload, payload)
        XCTAssertEqual(Data(data.dropFirst(24)), try ForegroundFrame.encode(payload))

        let digest = hexBytes("0488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070")
        let ack = try ForegroundFrame.encodeSessionAckMessage(sessionID: sessionID, attemptIndex: 3, accepted: true, digest: digest)
        XCTAssertEqual(ForegroundFrame.hex(ack), "544d4132000102030405060708090a0b0c0d0e0f00000003010488cd1104793edb7467998202babda2bef3061a13d7a940b6cb50f70c5d5070")
        XCTAssertTrue(ForegroundFrame.isSessionAckMessage(ack))
        XCTAssertFalse(ForegroundFrame.isAckMessage(ack))
        let decodedAck = try ForegroundFrame.decodeSessionAckMessage(ack)
        XCTAssertEqual(decodedAck.sessionID, sessionID)
        XCTAssertEqual(decodedAck.attemptIndex, 3)
        XCTAssertTrue(decodedAck.accepted)
        XCTAssertEqual(decodedAck.digest, digest)

        let finish = try ForegroundFrame.encodeFinishMessage(sessionID: sessionID, peerSessionID: peerSessionID, acknowledgement: false, successfulAttempts: 19, failedAttempts: 1)
        XCTAssertEqual(ForegroundFrame.hex(finish), "544d4632000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000000001300000001")
        XCTAssertTrue(ForegroundFrame.isFinishMessage(finish))
        let decodedFinish = try ForegroundFrame.decodeFinishMessage(finish)
        XCTAssertEqual(decodedFinish.sessionID, sessionID)
        XCTAssertEqual(decodedFinish.peerSessionID, peerSessionID)
        XCTAssertFalse(decodedFinish.acknowledgement)
        XCTAssertEqual(decodedFinish.successfulAttempts, 19)
        XCTAssertEqual(decodedFinish.failedAttempts, 1)
        let finishAck = try ForegroundFrame.encodeFinishMessage(sessionID: peerSessionID, peerSessionID: sessionID, acknowledgement: true, successfulAttempts: 19, failedAttempts: 1)
        XCTAssertEqual(ForegroundFrame.hex(finishAck), "544d4632101112131415161718191a1b1c1d1e1f000102030405060708090a0b0c0d0e0f010000001300000001")
        XCTAssertTrue(try ForegroundFrame.decodeFinishMessage(finishAck).acknowledgement)
    }

    func testSessionDataRejectsInvalidBoundsCorruptionAndAttempts() throws {
        for index in [-1, 20, Int.max] {
            XCTAssertThrowsError(try ForegroundFrame.encodeSessionDataMessage(sessionID: sessionID, attemptIndex: index, payload: Data([1])))
        }
        XCTAssertThrowsError(try ForegroundFrame.encodeSessionDataMessage(sessionID: sessionID, attemptIndex: 0, payload: Data()))
        XCTAssertThrowsError(try ForegroundFrame.encodeSessionDataMessage(sessionID: sessionID, attemptIndex: 0, payload: Data(repeating: 0, count: 16385)))
        let maximum = try ForegroundFrame.encodeSessionDataMessage(sessionID: sessionID, attemptIndex: 19, payload: Data(repeating: 0, count: 16384))
        XCTAssertEqual(try ForegroundFrame.decodeSessionDataMessage(maximum).frame.payload.count, 16384)
        let valid = try ForegroundFrame.encodeSessionDataMessage(sessionID: sessionID, attemptIndex: 0, payload: Data([1]))
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionDataMessage(valid + Data([0])))
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionDataMessage(Data(valid.dropLast())))
        var corrupt = valid
        corrupt[corrupt.count - 1] = 2
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionDataMessage(corrupt))
        var badIndex = valid
        badIndex[23] = 20
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionDataMessage(badIndex))
        badIndex[20] = 255
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionDataMessage(badIndex))
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionDataMessage(Data(repeating: 0, count: 16445)))
        let empty = hexBytes("544d4432" + sessionID + "00000000") + (try ForegroundFrame.encode(Data()))
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionDataMessage(empty))
    }

    func testSessionControlMessagesRejectMalformedFields() throws {
        for invalid in ["", sessionID.uppercased(), String(sessionID.dropLast()), String(repeating: "z", count: 32)] {
            XCTAssertThrowsError(try ForegroundFrame.encodeHelloMessage(sessionID: invalid, peerSessionID: peerSessionID, payloadSize: 2048))
            XCTAssertThrowsError(try ForegroundFrame.encodeSessionDataMessage(sessionID: invalid, attemptIndex: 0, payload: Data([1])))
        }
        XCTAssertThrowsError(try ForegroundFrame.encodeHelloMessage(sessionID: sessionID, peerSessionID: sessionID, payloadSize: 2048))
        XCTAssertThrowsError(try ForegroundFrame.encodeHelloMessage(sessionID: sessionID, peerSessionID: peerSessionID, payloadSize: 1024))
        var hello = try ForegroundFrame.encodeHelloMessage(sessionID: sessionID, peerSessionID: peerSessionID, payloadSize: 2048)
        XCTAssertThrowsError(try ForegroundFrame.decodeHelloMessage(hello + Data([0])))
        hello[43] = 21
        XCTAssertThrowsError(try ForegroundFrame.decodeHelloMessage(hello))
        hello[0] = 0
        XCTAssertThrowsError(try ForegroundFrame.decodeHelloMessage(hello))

        for (success, failure) in [(0, 19), (20, 1), (-1, 21), (Int.max, 0)] {
            XCTAssertThrowsError(try ForegroundFrame.encodeFinishMessage(sessionID: sessionID, peerSessionID: peerSessionID, acknowledgement: false, successfulAttempts: success, failedAttempts: failure))
        }
        var finish = try ForegroundFrame.encodeFinishMessage(sessionID: sessionID, peerSessionID: peerSessionID, acknowledgement: false, successfulAttempts: 20, failedAttempts: 0)
        XCTAssertThrowsError(try ForegroundFrame.decodeFinishMessage(finish + Data([0])))
        finish[36] = 2
        XCTAssertThrowsError(try ForegroundFrame.decodeFinishMessage(finish))
        finish[36] = 0
        finish[40] = 19
        XCTAssertThrowsError(try ForegroundFrame.decodeFinishMessage(finish))

        var ack = try ForegroundFrame.encodeSessionAckMessage(sessionID: sessionID, attemptIndex: 19, accepted: false, digest: Data(repeating: 0, count: 32))
        XCTAssertFalse(try ForegroundFrame.decodeSessionAckMessage(ack).accepted)
        XCTAssertThrowsError(try ForegroundFrame.encodeSessionAckMessage(sessionID: sessionID, attemptIndex: 20, accepted: true, digest: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try ForegroundFrame.encodeSessionAckMessage(sessionID: sessionID, attemptIndex: 0, accepted: true, digest: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionAckMessage(ack + Data([0])))
        ack[24] = 2
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionAckMessage(ack))
        ack[24] = 0
        ack[23] = 20
        XCTAssertThrowsError(try ForegroundFrame.decodeSessionAckMessage(ack))
    }

    private func hexBytes(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }

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
