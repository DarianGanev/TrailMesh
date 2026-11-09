import Foundation
import XCTest
@testable import TrailMeshReports

final class ExchangeWireTests: XCTestCase {
    func testFragmentedAndCoalescedFramesRoundTrip() throws {
        let frame = ExchangeFrame(source: Data(repeating: 1, count: 16), destination: Data(repeating: 0, count: 16), body: .hello(features: 1, maxFrame: 512, maxChunk: 64))
        let wire = try ExchangeWire.encode(frame)
        var decoder = ExchangeStreamDecoder()
        var received: [ExchangeFrame] = []
        for byte in wire + wire { received += try decoder.feed(Data([byte])) }
        XCTAssertEqual(received, [frame, frame])
        try decoder.finish()
    }
    func testOversizePrefixRejectedImmediatelyAndTruncatedEOFFails() throws {
        var decoder = ExchangeStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(Data([255, 255, 255, 255])))
        var partial = ExchangeStreamDecoder()
        _ = try partial.feed(Data([0]))
        XCTAssertThrowsError(try partial.finish())
    }
    func testTrailingBytesAndUnsupportedVersionRejected() throws {
        let hello = ExchangeFrame(source: Data(repeating: 1, count: 16), destination: Data(repeating: 0, count: 16), body: .hello(features: 1, maxFrame: 512, maxChunk: 64))
        var wire = try ExchangeWire.encode(hello)
        wire[8] = 2
        XCTAssertThrowsError(try ExchangeWire.decode(wire)) { XCTAssertEqual($0 as? ExchangeWireError, .unsupported) }
        wire = try ExchangeWire.encode(hello)
        wire.append(0)
        XCTAssertThrowsError(try ExchangeWire.decode(wire))
    }
}

extension ExchangeWireTests {
    func testSharedLiteralVectorsAndNativeExport() throws {
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "exchange-v1-vectors", withExtension: "json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 40)
        var exports: [[String: String]] = []
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let wire = try hex(XCTUnwrap(item["wire_hex"] as? String))
            let expected = try XCTUnwrap(item["expected"] as? String)
            if expected != "valid" {
                XCTAssertThrowsError(try ExchangeWire.decode(wire), name) {
                    XCTAssertEqual($0 as? ExchangeWireError, expected == "unsupported" ? .unsupported : .malformed, name)
                }
                continue
            }
            let value = try XCTUnwrap(item["frame"] as? [String: Any])
            let fields = try XCTUnwrap(value["fields"] as? [String: Any])
            let kind = try XCTUnwrap(value["kind"] as? String)
            func n(_ key: String) throws -> Int { try XCTUnwrap(fields[key] as? Int) }
            func id(_ key: String) throws -> String { try XCTUnwrap(fields[key] as? String) }
            func descriptor(_ fields: [String: Any]) throws -> ExchangeDescriptor {
                ExchangeDescriptor(id: try XCTUnwrap(fields["id"] as? String), total: try XCTUnwrap((fields["total"] ?? fields["size"]) as? Int), hops: try XCTUnwrap(fields["hops"] as? Int))
            }
            let body: ExchangeBody
            switch kind {
            case "HELLO": body = .hello(features: UInt32(try n("features")), maxFrame: try n("max_frame"), maxChunk: try n("max_chunk"))
            case "SUMMARY":
                let entries = try XCTUnwrap(fields["entries"] as? [[String: Any]])
                body = .summary(page: try n("page"), more: try n("more") == 1, entries: try entries.map(descriptor))
            case "REQUEST": body = .request(try XCTUnwrap(fields["ids"] as? [String]))
            case "OFFER": body = .offer(transfer: try n("transfer"), descriptor: try descriptor(fields))
            case "CHUNK": body = .chunk(transfer: try n("transfer"), offset: try n("offset"), total: try n("total"), bytes: try hex(id("data")))
            case "RECEIVED": body = .received(transfer: try n("transfer"), id: try id("id"), result: try n("result"))
            case "CLOSE": body = .close(try n("reason"))
            case "DONE": body = .done
            default: XCTFail(kind); continue
            }
            let expectedFrame = ExchangeFrame(source: try hex(XCTUnwrap(value["source"] as? String)), destination: try hex(XCTUnwrap(value["destination"] as? String)), body: body)
            XCTAssertEqual(try ExchangeWire.decode(wire), expectedFrame, name)
            let native = try ExchangeWire.encode(expectedFrame)
            XCTAssertEqual(native, wire, name)
            exports.append(["wire_hex": native.map { String(format: "%02x", $0) }.joined()])
        }
        if let path = ProcessInfo.processInfo.environment["TRAILMESH_EXCHANGE_EXPORT"] {
            try JSONSerialization.data(withJSONObject: exports).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    private func hex(_ value: String) throws -> Data {
        guard value.count % 2 == 0 else { throw ExchangeWireError.malformed }
        let bytes = Array(value); var output = Data()
        for i in stride(from: 0, to: bytes.count, by: 2) {
            let pair = String(bytes[i...i + 1]); output.append(try XCTUnwrap(UInt8(pair, radix: 16)))
        }
        return output
    }
}

extension ExchangeWireTests {
    func testCallbackFrameCountAndInputBytesAreBounded() throws {
        let frame = ExchangeFrame(source: Data(repeating: 1, count: 16), destination: Data(repeating: 2, count: 16), body: .done)
        let wire = try ExchangeWire.encode(frame)
        var burst = Data(); for _ in 0..<65 { burst.append(wire) }
        var decoder = ExchangeStreamDecoder()
        XCTAssertThrowsError(try decoder.feed(burst))
        var oversized = ExchangeStreamDecoder()
        XCTAssertThrowsError(try oversized.feed(Data(count: 262145)))
    }
}

extension ExchangeWireTests {
    func testEncoderRejectsUnorderedRequestsEqualNoncesAndPageOverflow() throws {
        let first = String(repeating: "01", count: 32), second = String(repeating: "02", count: 32)
        let source = Data(repeating: 1, count: 16), peer = Data(repeating: 2, count: 16)
        XCTAssertThrowsError(try ExchangeWire.encode(ExchangeFrame(source: source, destination: peer, body: .request([second, first]))))
        XCTAssertThrowsError(try ExchangeWire.encode(ExchangeFrame(source: source, destination: source, body: .done)))
        XCTAssertThrowsError(try ExchangeWire.encode(ExchangeFrame(source: source, destination: peer, body: .summary(page: 7, more: true, entries: []))))
        let descending = [ExchangeDescriptor(id: second, total: 1, hops: 1), ExchangeDescriptor(id: first, total: 1, hops: 1)]
        XCTAssertThrowsError(try ExchangeWire.encode(ExchangeFrame(source: source, destination: peer, body: .summary(page: 0, more: false, entries: descending))))
    }
}
