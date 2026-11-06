import Foundation

// A bounded JSON reader for the report profile. It preserves scalar sequences,
// rejects duplicate decoded keys, and accepts only null, strings and integers.
indirect enum ReportJSON {
    case object([(String, ReportJSON)])
    case array([ReportJSON])
    case string(String)
    case integer(Int64)
    case null

    var object: [(String, ReportJSON)]? {
        if case let .object(value) = self { return value }
        return nil
    }
    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }
    var integer: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }
    subscript(key: String) -> ReportJSON? {
        object?.first { Array($0.0.utf8) == Array(key.utf8) }?.1
    }
    func hasFields(_ fields: [String]) -> Bool {
        guard let object, object.count == fields.count else { return false }
        return fields.allSatisfy { self[$0] != nil }
    }

    func canonical() -> String {
        switch self {
        case .null: return "null"
        case .integer(let value): return String(value)
        case .string(let value): return Self.quote(value)
        case .array(let values): return "[" + values.map { $0.canonical() }.joined(separator: ",") + "]"
        case .object(let members):
            return "{" + members.sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }
                .map { Self.quote($0.0) + ":" + $0.1.canonical() }.joined(separator: ",") + "}"
        }
    }
    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 0...31: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

struct StrictReportJSONParser {
    private enum Invalid: Error { case input }
    private let bytes: [UInt8]
    private var index = 0
    init(_ input: Data) throws {
        guard input.count <= 8192, !input.starts(with: [0xef, 0xbb, 0xbf]),
              String(data: input, encoding: .utf8) != nil else { throw Invalid.input }
        bytes = Array(input)
    }
    mutating func parse() throws -> ReportJSON {
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw Invalid.input }
        return result
    }
    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
    private mutating func value(depth: Int) throws -> ReportJSON {
        whitespace()
        guard index < bytes.count else { throw Invalid.input }
        switch bytes[index] {
        case 123:
            guard depth < 8 else { throw Invalid.input }
            index += 1
            var members: [(String, ReportJSON)] = []
            if consume(125) { return .object(members) }
            repeat {
                whitespace()
                let key = try string()
                guard !members.contains(where: { Array($0.0.utf8) == Array(key.utf8) }), consume(58) else { throw Invalid.input }
                members.append((key, try value(depth: depth + 1)))
                if consume(125) { return .object(members) }
            } while consume(44)
            throw Invalid.input
        case 91:
            guard depth < 8 else { throw Invalid.input }
            index += 1
            var values: [ReportJSON] = []
            if consume(93) { return .array(values) }
            repeat {
                values.append(try value(depth: depth + 1))
                if consume(93) { return .array(values) }
            } while consume(44)
            throw Invalid.input
        case 34: return .string(try string())
        case 110:
            guard index + 4 <= bytes.count, Array(bytes[index..<index + 4]) == Array("null".utf8) else { throw Invalid.input }
            index += 4
            return .null
        case 45, 48...57:
            let start = index
            if bytes[index] == 45 { index += 1 }
            guard index < bytes.count else { throw Invalid.input }
            if bytes[index] == 48 { index += 1 }
            else {
                guard (49...57).contains(bytes[index]) else { throw Invalid.input }
                repeat { index += 1 } while index < bytes.count && (48...57).contains(bytes[index])
            }
            guard let number = Int64(String(decoding: bytes[start..<index], as: UTF8.self)),
                  (-9_007_199_254_740_991...9_007_199_254_740_991).contains(number) else { throw Invalid.input }
            return .integer(number)
        default: throw Invalid.input
        }
    }
    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw Invalid.input }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 34 {
                let token = Data(bytes[start..<index])
                guard let decoded = try JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? String else { throw Invalid.input }
                return decoded
            }
            if byte < 32 { throw Invalid.input }
        }
        throw Invalid.input
    }
}
