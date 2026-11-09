import Foundation

/// An immutable-wire identifier, byte length, and current cooperative forwarding budget.
public struct ExchangeDescriptor: Equatable, Sendable {
    public let id: String
    public let total: Int
    public let hops: Int
    public init(id: String, total: Int, hops: Int) { self.id = id; self.total = total; self.hops = hops }
}
public enum ExchangeBody: Equatable, Sendable {
    case hello(features: UInt32, maxFrame: Int, maxChunk: Int)
    case summary(page: Int, more: Bool, entries: [ExchangeDescriptor])
    case request([String])
    case offer(transfer: Int, descriptor: ExchangeDescriptor)
    case chunk(transfer: Int, offset: Int, total: Int, bytes: Data)
    case received(transfer: Int, id: String, result: Int)
    case close(Int)
    case done
}
public struct ExchangeFrame: Equatable, Sendable {
    public let source: Data
    public let destination: Data
    public let body: ExchangeBody
    public init(source: Data, destination: Data, body: ExchangeBody) { self.source = source; self.destination = destination; self.body = body }
}
public enum ExchangeWireError: Error, Equatable { case malformed, unsupported }

/// Strict v1.0 binary frames. Unknown versions or missing required capabilities throw unsupported; malformed
/// fields, nonces, ordering, or trailing bytes throw malformed. Encoding applies the
/// same validation as decoding. The negotiated payload ceiling is 512...16384 bytes.
public enum ExchangeWire {
    public static func encode(_ frame: ExchangeFrame, maxFrame: Int = 16_384) throws -> Data {
        guard (512...16384).contains(maxFrame), frame.source.count == 16, frame.destination.count == 16 else { throw ExchangeWireError.malformed }
        var fields = Data(); let kind: UInt8
        func number(_ value: Int, _ width: Int) throws {
            guard value >= 0, UInt64(value) < (UInt64(1) << (width * 8)) else { throw ExchangeWireError.malformed }
            for shift in stride(from: (width - 1) * 8, through: 0, by: -8) { fields.append(UInt8((value >> shift) & 255)) }
        }
        func id(_ value: String) throws { fields.append(try idBytes(value)) }
        func descriptor(_ value: ExchangeDescriptor) throws { try id(value.id); try number(value.total, 2); try number(value.hops, 1) }
        switch frame.body {
        case let .hello(features, maxFrame, maxChunk): kind = 1; try number(Int(features), 4); try number(maxFrame, 2); try number(maxChunk, 2)
        case let .summary(page, more, entries): kind = 2; try number(page, 2); try number(more ? 1 : 0, 1); try number(entries.count, 1); for entry in entries { try descriptor(entry) }
        case let .request(ids): kind = 3; try number(ids.count, 1); for value in ids { try id(value) }
        case let .offer(transfer, value): kind = 4; try number(transfer, 4); try descriptor(value)
        case let .chunk(transfer, offset, total, bytes): kind = 5; try number(transfer, 4); try number(offset, 2); try number(total, 2); fields.append(bytes)
        case let .received(transfer, value, result): kind = 6; try number(transfer, 4); try id(value); try number(result, 1)
        case let .close(reason): kind = 7; try number(reason, 1)
        case .done: kind = 8
        }
        var payload = Data([84, 77, 88, 82, 1, 0, kind]); payload.append(frame.source); payload.append(frame.destination); payload.append(fields)
        guard payload.count <= maxFrame, payload.count <= 16_384 else { throw ExchangeWireError.malformed }
        var output = Data(); for shift in [24, 16, 8, 0] { output.append(UInt8((payload.count >> shift) & 255)) }; output.append(payload)
        _ = try decode(output, maxFrame: maxFrame)
        return output
    }
    public static func decode(_ wire: Data, maxFrame: Int = 16_384) throws -> ExchangeFrame {
        guard (512...16384).contains(maxFrame), wire.count >= 43, wire.count <= maxFrame + 4 else { throw ExchangeWireError.malformed }
        let bytes = Array(wire); var position = 0
        func take(_ count: Int) throws -> Data { guard count >= 0, position + count <= bytes.count else { throw ExchangeWireError.malformed }; defer { position += count }; return Data(bytes[position..<position + count]) }
        func number(_ count: Int) throws -> Int { try take(count).reduce(0) { ($0 << 8) | Int($1) } }
        func id() throws -> String { try take(32).map { String(format: "%02x", $0) }.joined() }
        func descriptor() throws -> ExchangeDescriptor {
            let value = try ExchangeDescriptor(id: id(), total: number(2), hops: number(1))
            guard (1...8192).contains(value.total), (1...12).contains(value.hops) else { throw ExchangeWireError.malformed }; return value
        }
        let size = try number(4)
        guard size >= 39, size <= min(maxFrame, 16_384), size == bytes.count - 4, try take(4) == Data("TMXR".utf8) else { throw ExchangeWireError.malformed }
        guard try number(1) == 1, try number(1) == 0 else { throw ExchangeWireError.unsupported }
        let kind = try number(1), source = try take(16), destination = try take(16)
        guard source != destination, source != Data(repeating: 0, count: 16), (destination == Data(repeating: 0, count: 16)) == (kind == 1) else { throw ExchangeWireError.malformed }
        let body: ExchangeBody
        switch kind {
        case 1:
            let features = try number(4), frame = try number(2), chunk = try number(2)
            guard (512...16384).contains(frame), (64...1024).contains(chunk) else { throw ExchangeWireError.malformed }
            guard features & 1 == 1 else { throw ExchangeWireError.unsupported }
            body = .hello(features: UInt32(features), maxFrame: frame, maxChunk: chunk)
        case 2:
            let page = try number(2), more = try number(1), count = try number(1)
            guard page < 8, more <= 1, !(page == 7 && more == 1), count <= 8 else { throw ExchangeWireError.malformed }
            var entries: [ExchangeDescriptor] = []; for _ in 0..<count { entries.append(try descriptor()) }
            guard zip(entries, entries.dropFirst()).allSatisfy({ pair in pair.0.id < pair.1.id }) else { throw ExchangeWireError.malformed }
            body = .summary(page: page, more: more == 1, entries: entries)
        case 3:
            let count = try number(1); guard count <= 8 else { throw ExchangeWireError.malformed }
            var ids: [String] = []; for _ in 0..<count { ids.append(try id()) }
            guard zip(ids, ids.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else { throw ExchangeWireError.malformed }; body = .request(ids)
        case 4:
            let transfer = try number(4); guard (1...32).contains(transfer) else { throw ExchangeWireError.malformed }; body = .offer(transfer: transfer, descriptor: try descriptor())
        case 5:
            let transfer = try number(4), offset = try number(2), total = try number(2), raw = try take(bytes.count - position)
            guard (1...32).contains(transfer), (1...8192).contains(total), (1...1024).contains(raw.count), offset + raw.count <= total else { throw ExchangeWireError.malformed }
            body = .chunk(transfer: transfer, offset: offset, total: total, bytes: raw)
        case 6:
            let transfer = try number(4), value = try id(), result = try number(1)
            guard (1...32).contains(transfer), result <= 5 else { throw ExchangeWireError.malformed }; body = .received(transfer: transfer, id: value, result: result)
        case 7: let reason = try number(1); guard reason <= 7 else { throw ExchangeWireError.malformed }; body = .close(reason)
        case 8: body = .done
        default: throw ExchangeWireError.malformed
        }
        guard position == bytes.count else { throw ExchangeWireError.malformed }
        return ExchangeFrame(source: source, destination: destination, body: body)
    }
    static func idBytes(_ id: String) throws -> Data {
        let bytes = Array(id.utf8); guard bytes.count == 64 else { throw ExchangeWireError.malformed }
        func nibble(_ byte: UInt8) throws -> UInt8 { switch byte { case 48...57: return byte - 48; case 97...102: return byte - 87; default: throw ExchangeWireError.malformed } }
        var output = Data(); for offset in stride(from: 0, to: 64, by: 2) { output.append(try (nibble(bytes[offset]) << 4) | nibble(bytes[offset + 1])) }; return output
    }
}

/// Holds at most one partial frame. Each callback accepts at most 256 KiB and emits
/// at most 64 frames; split and coalesced callbacks preserve frame boundaries.
/// Call finish at EOF to detect truncation. Discard the decoder after an error.
public struct ExchangeStreamDecoder: Sendable {
    private var buffer = Data()
    public var maxFrame = 16_384
    public init() {}
    public mutating func feed(_ input: Data) throws -> [ExchangeFrame] {
        guard (512...16384).contains(maxFrame), input.count <= 262_144 else { throw ExchangeWireError.malformed }
        var frames: [ExchangeFrame] = []
        try consume(input) { guard frames.count < 64 else { throw ExchangeWireError.malformed }; frames.append($0) }; return frames
    }
    public mutating func consume(_ input: Data, emit: (ExchangeFrame) throws -> Void) throws {
        guard (512...16384).contains(maxFrame), input.count <= 262_144 else { throw ExchangeWireError.malformed }
        var emitted = 0
        for byte in input {
            buffer.append(byte)
            if buffer.count >= 4 {
                let count = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard (39...min(maxFrame, 16384)).contains(count) else { buffer.removeAll(); throw ExchangeWireError.malformed }
                if buffer.count == count + 4 {
                    guard emitted < 64 else { throw ExchangeWireError.malformed }; emitted += 1
                    let frame = try ExchangeWire.decode(buffer, maxFrame: maxFrame); buffer.removeAll(keepingCapacity: true); try emit(frame) }
            }
        }
    }
    public func finish() throws { guard buffer.isEmpty else { throw ExchangeWireError.malformed } }
}
