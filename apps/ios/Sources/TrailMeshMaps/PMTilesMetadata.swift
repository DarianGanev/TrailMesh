import Foundation
import CMapZlib

/// The native PMTiles reader preserves a metadata `tiles` array. Check the
/// archive before loading so it cannot redirect a local style to remote tiles.
public enum PMTilesMetadata {
    public static func validate(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let header = try handle.read(upToCount: 127) ?? Data()
        guard header.count == 127, Array(header.prefix(8)) == Array("PMTiles".utf8) + [3], [1, 2].contains(header[97]), [1, 2].contains(header[98]) else { throw MapFailure.corrupt }
        func uint64(_ offset: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(header[offset + $1]) << (8 * $1) } }
        let offset = uint64(24), length = uint64(32)
        let size = try handle.seekToEnd()
        guard offset >= 127, length > 0, length <= 1024 * 1024, offset <= size, length <= size - offset else { throw MapFailure.corrupt }
        try handle.seek(toOffset: offset)
        guard let encoded = try handle.read(upToCount: Int(length)), encoded.count == Int(length) else { throw MapFailure.corrupt }
        let data = header[97] == 2 ? try gunzip(encoded) : encoded
        guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any], metadata["tiles"] == nil else { throw MapFailure.corrupt }
    }
    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw MapFailure.corrupt }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 1024 * 1024 + 1)
        let result: Int32 = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out <= 1024 * 1024, stream.avail_in == 0 else { throw MapFailure.corrupt }
        return Data(output.prefix(Int(stream.total_out)))
    }
}
