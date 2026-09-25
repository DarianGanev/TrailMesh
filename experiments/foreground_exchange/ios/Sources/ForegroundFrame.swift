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

enum ForegroundFrame {
    static let maxPayloadBytes = 16 * 1024
    private static let frameHeaderBytes = 4 + 32
    private static let dataMagic = Data("TMD1".utf8)
    private static let ackMagic = Data("TMA1".utf8)

    static func makeTestPayload(size: Int, attemptIndex: Int) throws -> Data {
        guard (1...maxPayloadBytes).contains(size) else { throw ForegroundFrameError.invalidSize }
        guard attemptIndex >= 0 else { throw ForegroundFrameError.invalidAttempt }
        return Data((0..<size).map { UInt8(($0 + attemptIndex) % 251) })
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
        let expectedDigest = Data(frame[4..<36])
        let payload = Data(frame[36..<frame.count])
        let actualDigest = digest(payload)
        guard expectedDigest == actualDigest else { throw ForegroundFrameError.checksumMismatch }
        return DecodedFrame(payload: payload, digest: actualDigest)
    }

    static func encodeDataMessage(attemptIndex: Int, payload: Data) throws -> Data {
        guard attemptIndex >= 0 else { throw ForegroundFrameError.invalidAttempt }
        var message = dataMagic
        appendUInt32(UInt32(attemptIndex), to: &message)
        message.append(try encode(payload))
        return message
    }

    static func decodeDataMessage(_ message: Data) throws -> ProbeDataMessage {
        guard message.count >= 8 + frameHeaderBytes,
              Data(message.prefix(4)) == dataMagic else {
            throw ForegroundFrameError.unknownMessage
        }
        let attemptIndex = Int(try readUInt32(message, at: 4))
        let frame = Data(message.dropFirst(8))
        return ProbeDataMessage(attemptIndex: attemptIndex, frame: try decode(frame))
    }

    static func encodeAckMessage(attemptIndex: Int, accepted: Bool, digest: Data) throws -> Data {
        guard attemptIndex >= 0 else { throw ForegroundFrameError.invalidAttempt }
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
        let acceptedByte = message[8]
        guard acceptedByte == 0 || acceptedByte == 1 else {
            throw ForegroundFrameError.invalidAcknowledgement
        }
        return ProbeAckMessage(
            attemptIndex: attemptIndex,
            accepted: acceptedByte == 1,
            digest: Data(message[9..<41]))
    }

    static func isAckMessage(_ message: Data) -> Bool {
        message.count >= 4 && Data(message.prefix(4)) == ackMagic
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, data.count >= offset + 4 else { throw ForegroundFrameError.truncated }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
