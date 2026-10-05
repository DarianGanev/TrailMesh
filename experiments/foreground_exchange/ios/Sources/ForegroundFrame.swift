import CryptoKit
import Foundation

enum ForegroundFrameError: Error, Equatable {
    case invalidSize
    case invalidAttempt
    case truncated
    case invalidLength
    case checksumMismatch
    case unknownMessage
    case invalidAcknowledgement
    case invalidSession
    case invalidHello
    case invalidFinish
}

struct DecodedFrame {
    let payload: Data
    let digest: Data
}

struct ProbeDataMessage {
    let attemptIndex: Int
    let frame: DecodedFrame
}

struct ProbeAckMessage {
    let attemptIndex: Int
    let accepted: Bool
    let digest: Data
}

struct ProbeHelloMessage {
    let sessionID: String
    let peerSessionID: String
    let payloadSize: Int
    let attemptCount: Int
}

struct ProbeSessionDataMessage {
    let sessionID: String
    let attemptIndex: Int
    let frame: DecodedFrame
}

struct ProbeSessionAckMessage {
    let sessionID: String
    let attemptIndex: Int
    let accepted: Bool
    let digest: Data
}

struct ProbeFinishMessage {
    let sessionID: String
    let peerSessionID: String
    let acknowledgement: Bool
    let successfulAttempts: Int
    let failedAttempts: Int
}

enum ForegroundFrame {
    static let maxPayloadBytes = 16 * 1024
    static let attemptsPerBatch = 20
    private static let frameHeaderBytes = 4 + 32
    private static let sessionDataHeaderBytes = 4 + 16 + 4 + frameHeaderBytes
    private static let dataMagic = Data("TMD1".utf8)
    private static let ackMagic = Data("TMA1".utf8)
    private static let helloMagic = Data("TMH2".utf8)
    private static let sessionDataMagic = Data("TMD2".utf8)
    private static let sessionAckMagic = Data("TMA2".utf8)
    private static let finishMagic = Data("TMF2".utf8)

    static func makeTestPayload(size: Int, attemptIndex: Int) throws -> Data {
        guard (1...maxPayloadBytes).contains(size) else { throw ForegroundFrameError.invalidSize }
        guard (0...Int(Int32.max)).contains(attemptIndex) else { throw ForegroundFrameError.invalidAttempt }
        return Data((0..<size).map { UInt8(($0 + attemptIndex % 251) % 251) })
    }

    static func digest(_ payload: Data) -> Data {
        Data(SHA256.hash(data: payload))
    }

    static func digestHex(_ payload: Data) -> String {
        hex(digest(payload))
    }

    static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxPayloadBytes else { throw ForegroundFrameError.invalidSize }
        var frame = Data()
        appendUInt32(UInt32(payload.count), to: &frame)
        frame.append(digest(payload))
        frame.append(payload)
        return frame
    }

    static func decode(_ frame: Data) throws -> DecodedFrame {
        guard frame.count >= frameHeaderBytes else { throw ForegroundFrameError.truncated }
        let payloadSize = Int(try readUInt32(frame, at: 0))
        guard payloadSize <= maxPayloadBytes,
              frame.count == frameHeaderBytes + payloadSize else {
            throw ForegroundFrameError.invalidLength
        }
        let expectedDigest = slice(frame, from: 4, count: 32)
        let payload = slice(frame, from: 36, count: payloadSize)
        let actualDigest = digest(payload)
        guard expectedDigest == actualDigest else { throw ForegroundFrameError.checksumMismatch }
        return DecodedFrame(payload: payload, digest: actualDigest)
    }

    static func encodeDataMessage(attemptIndex: Int, payload: Data) throws -> Data {
        guard (0...Int(Int32.max)).contains(attemptIndex) else { throw ForegroundFrameError.invalidAttempt }
        var message = dataMagic
        appendUInt32(UInt32(attemptIndex), to: &message)
        message.append(try encode(payload))
        return message
    }

    static func decodeDataMessage(_ message: Data) throws -> ProbeDataMessage {
        guard message.count >= 8 + frameHeaderBytes,
              message.count <= 8 + frameHeaderBytes + maxPayloadBytes,
              Data(message.prefix(4)) == dataMagic else {
            throw ForegroundFrameError.unknownMessage
        }
        let attemptIndex = Int(try readUInt32(message, at: 4))
        guard attemptIndex <= Int(Int32.max) else { throw ForegroundFrameError.invalidAttempt }
        let frame = Data(message.dropFirst(8))
        return ProbeDataMessage(attemptIndex: attemptIndex, frame: try decode(frame))
    }

    static func encodeAckMessage(attemptIndex: Int, accepted: Bool, digest: Data) throws -> Data {
        guard (0...Int(Int32.max)).contains(attemptIndex) else { throw ForegroundFrameError.invalidAttempt }
        guard digest.count == 32 else { throw ForegroundFrameError.invalidAcknowledgement }
        var message = ackMagic
        appendUInt32(UInt32(attemptIndex), to: &message)
        message.append(accepted ? 1 : 0)
        message.append(digest)
        return message
    }

    static func decodeAckMessage(_ message: Data) throws -> ProbeAckMessage {
        guard message.count == 41, Data(message.prefix(4)) == ackMagic else {
            throw ForegroundFrameError.invalidAcknowledgement
        }
        let attemptIndex = Int(try readUInt32(message, at: 4))
        guard attemptIndex <= Int(Int32.max) else { throw ForegroundFrameError.invalidAttempt }
        let acceptedByte = message[message.startIndex + 8]
        guard acceptedByte == 0 || acceptedByte == 1 else {
            throw ForegroundFrameError.invalidAcknowledgement
        }
        return ProbeAckMessage(
            attemptIndex: attemptIndex,
            accepted: acceptedByte == 1,
            digest: slice(message, from: 9, count: 32))
    }

    static func isAckMessage(_ message: Data) -> Bool {
        message.count >= 4 && Data(message.prefix(4)) == ackMagic
    }

    static func encodeHelloMessage(sessionID: String, peerSessionID: String, payloadSize: Int) throws -> Data {
        guard sessionID != peerSessionID,
              ProbePeerContext.supportedPayloadSizes.contains(payloadSize) else { throw ForegroundFrameError.invalidHello }
        var message = helloMagic
        message.append(try sessionBytes(sessionID))
        message.append(try sessionBytes(peerSessionID))
        appendUInt32(UInt32(payloadSize), to: &message)
        appendUInt32(UInt32(attemptsPerBatch), to: &message)
        return message
    }

    static func decodeHelloMessage(_ message: Data) throws -> ProbeHelloMessage {
        try requireMessage(message, count: 44, magic: helloMagic)
        let sessionID = readSessionID(message, at: 4)
        let peerSessionID = readSessionID(message, at: 20)
        let payloadSize = Int(try readUInt32(message, at: 36))
        let attemptCount = Int(try readUInt32(message, at: 40))
        guard sessionID != peerSessionID, ProbePeerContext.supportedPayloadSizes.contains(payloadSize),
              attemptCount == attemptsPerBatch else { throw ForegroundFrameError.invalidHello }
        return ProbeHelloMessage(sessionID: sessionID, peerSessionID: peerSessionID, payloadSize: payloadSize, attemptCount: attemptCount)
    }

    static func encodeSessionDataMessage(sessionID: String, attemptIndex: Int, payload: Data) throws -> Data {
        try requireAttempt(attemptIndex)
        guard (1...maxPayloadBytes).contains(payload.count) else { throw ForegroundFrameError.invalidSize }
        var message = sessionDataMagic
        message.append(try sessionBytes(sessionID))
        appendUInt32(UInt32(attemptIndex), to: &message)
        message.append(try encode(payload))
        return message
    }

    static func decodeSessionDataMessage(_ message: Data) throws -> ProbeSessionDataMessage {
        guard ((sessionDataHeaderBytes + 1)...(sessionDataHeaderBytes + maxPayloadBytes)).contains(message.count),
              isMessage(message, magic: sessionDataMagic) else { throw ForegroundFrameError.invalidLength }
        let attemptIndex = Int(try readUInt32(message, at: 20))
        try requireAttempt(attemptIndex)
        let payloadSize = Int(try readUInt32(message, at: 24))
        guard (1...maxPayloadBytes).contains(payloadSize),
              message.count == sessionDataHeaderBytes + payloadSize else { throw ForegroundFrameError.invalidLength }
        return ProbeSessionDataMessage(sessionID: readSessionID(message, at: 4), attemptIndex: attemptIndex,
                                       frame: try decode(Data(message.dropFirst(24))))
    }

    static func encodeSessionAckMessage(sessionID: String, attemptIndex: Int, accepted: Bool, digest: Data) throws -> Data {
        try requireAttempt(attemptIndex)
        guard digest.count == 32 else { throw ForegroundFrameError.invalidAcknowledgement }
        var message = sessionAckMagic
        message.append(try sessionBytes(sessionID))
        appendUInt32(UInt32(attemptIndex), to: &message)
        message.append(accepted ? 1 : 0)
        message.append(digest)
        return message
    }

    static func decodeSessionAckMessage(_ message: Data) throws -> ProbeSessionAckMessage {
        try requireMessage(message, count: 57, magic: sessionAckMagic)
        let attemptIndex = Int(try readUInt32(message, at: 20))
        try requireAttempt(attemptIndex)
        let status = message[message.startIndex + 24]
        guard status == 0 || status == 1 else { throw ForegroundFrameError.invalidAcknowledgement }
        return ProbeSessionAckMessage(sessionID: readSessionID(message, at: 4), attemptIndex: attemptIndex,
                                      accepted: status == 1, digest: slice(message, from: 25, count: 32))
    }

    static func encodeFinishMessage(sessionID: String, peerSessionID: String, acknowledgement: Bool, successfulAttempts: Int, failedAttempts: Int) throws -> Data {
        guard sessionID != peerSessionID else { throw ForegroundFrameError.invalidSession }
        try requireTotals(successfulAttempts, failedAttempts)
        var message = finishMagic
        message.append(try sessionBytes(sessionID))
        message.append(try sessionBytes(peerSessionID))
        message.append(acknowledgement ? 1 : 0)
        appendUInt32(UInt32(successfulAttempts), to: &message)
        appendUInt32(UInt32(failedAttempts), to: &message)
        return message
    }

    static func decodeFinishMessage(_ message: Data) throws -> ProbeFinishMessage {
        try requireMessage(message, count: 45, magic: finishMagic)
        let sessionID = readSessionID(message, at: 4)
        let peerSessionID = readSessionID(message, at: 20)
        let kind = message[message.startIndex + 36]
        let successfulAttempts = Int(try readUInt32(message, at: 37))
        let failedAttempts = Int(try readUInt32(message, at: 41))
        guard sessionID != peerSessionID, kind == 0 || kind == 1 else { throw ForegroundFrameError.invalidFinish }
        try requireTotals(successfulAttempts, failedAttempts)
        return ProbeFinishMessage(sessionID: sessionID, peerSessionID: peerSessionID, acknowledgement: kind == 1,
                                  successfulAttempts: successfulAttempts, failedAttempts: failedAttempts)
    }

    static func isHelloMessage(_ message: Data) -> Bool { isMessage(message, magic: helloMagic) }
    static func isSessionAckMessage(_ message: Data) -> Bool { isMessage(message, magic: sessionAckMagic) }
    static func isFinishMessage(_ message: Data) -> Bool { isMessage(message, magic: finishMagic) }

    private static func requireAttempt(_ attemptIndex: Int) throws {
        guard (0..<attemptsPerBatch).contains(attemptIndex) else { throw ForegroundFrameError.invalidAttempt }
    }

    private static func requireTotals(_ success: Int, _ failure: Int) throws {
        guard (0...attemptsPerBatch).contains(success), (0...attemptsPerBatch).contains(failure),
              success + failure == attemptsPerBatch else { throw ForegroundFrameError.invalidFinish }
    }

    private static func sessionBytes(_ sessionID: String) throws -> Data {
        guard ProbePeerContext.isValidSessionID(sessionID) else { throw ForegroundFrameError.invalidSession }
        let chars = Array(sessionID.utf8)
        func digit(_ char: UInt8) -> UInt8 { char <= 57 ? char - 48 : char - 87 }
        return Data(stride(from: 0, to: 32, by: 2).map { (digit(chars[$0]) << 4) | digit(chars[$0 + 1]) })
    }

    private static func readSessionID(_ message: Data, at offset: Int) -> String { hex(slice(message, from: offset, count: 16)) }

    private static func slice(_ data: Data, from offset: Int, count: Int) -> Data {
        Data(data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
    }

    private static func requireMessage(_ message: Data, count: Int, magic: Data) throws {
        guard message.count == count, isMessage(message, magic: magic) else { throw ForegroundFrameError.invalidLength }
    }

    private static func isMessage(_ message: Data, magic: Data) -> Bool { message.count >= 4 && Data(message.prefix(4)) == magic }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, data.count >= offset + 4 else { throw ForegroundFrameError.truncated }
        return data[(data.startIndex + offset)..<(data.startIndex + offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
