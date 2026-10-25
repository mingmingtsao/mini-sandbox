import Foundation

/// Deliberately bounded JSON domain: exact safe integers only, no floating-point,
/// decimal, exponent, negative zero, NaN or infinity. No schema evaluation/fetch.
package indirect enum ModelJSON: Equatable, Sendable, Codable {
    case object([String: ModelJSON])
    case array([ModelJSON])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null
    package static let maxBytes = 65_536
    package static let maxDepth = 32
    package static let maxNodes = 8_192
    package static let maxInteger: Int64 = 9_007_199_254_740_991

    package static func parse(_ data: Data, maxBytes: Int = ModelJSON.maxBytes) throws -> ModelJSON {
        guard data.count <= maxBytes else { throw ModelTransportError.invalidResponse }
        var parser = RawJSON(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count else { throw ModelTransportError.invalidResponse }
        return result
    }
    package func validated() throws -> ModelJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        return try Self.parse(bytes)
    }
    package var object: [String: ModelJSON]? { if case .object(let value) = self { value } else { nil } }
    package var array: [ModelJSON]? { if case .array(let value) = self { value } else { nil } }
    package var string: String? { if case .string(let value) = self { value } else { nil } }
    package var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    package subscript(_ key: String) -> ModelJSON? { object?[key] }
    package init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Int64.self), (-Self.maxInteger...Self.maxInteger).contains(n) {
            self = .integer(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([ModelJSON].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: ModelJSON].self) {
            self = .object(o)
        } else {
            throw ModelTransportError.invalidResponse
        }
    }
    package func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .integer(let n):
            guard (-Self.maxInteger...Self.maxInteger).contains(n) else { throw ModelTransportError.invalidResponse }
            try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

/// Raw grammar validation precedes any Foundation object decoding. Escaped keys
/// are decoded here so e.g. "id" and "\\u0069d" cannot evade duplicate detection.
private struct RawJSON {
    let bytes: [UInt8]
    var index = 0
    var nodes = 0
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) -> Bool {
        if index < bytes.count && bytes[index] == byte {
            index += 1
            return true
        }
        return false
    }
    mutating func require(_ byte: UInt8) throws { guard take(byte) else { throw ModelTransportError.invalidResponse } }
    mutating func value(depth: Int) throws -> ModelJSON {
        space()
        nodes += 1
        guard depth <= ModelJSON.maxDepth, nodes <= ModelJSON.maxNodes, index < bytes.count else {
            throw ModelTransportError.invalidResponse
        }
        switch bytes[index] {
        case 123:
            index += 1
            space()
            var o: [String: ModelJSON] = [:]
            if take(125) { return .object(o) }
            repeat {
                space()
                let k = try string()
                guard o[k] == nil else { throw ModelTransportError.invalidResponse }
                space()
                try require(58)
                o[k] = try value(depth: depth + 1)
                space()
                if take(125) { return .object(o) }
                try require(44)
            } while true
        case 91:
            index += 1
            space()
            var a: [ModelJSON] = []
            if take(93) { return .array(a) }
            repeat {
                a.append(try value(depth: depth + 1))
                space()
                if take(93) { return .array(a) }
                try require(44)
            } while true
        case 34: return .string(try string())
        case 116:
            try literal("true")
            return .bool(true)
        case 102:
            try literal("false")
            return .bool(false)
        case 110:
            try literal("null")
            return .null
        default:
            let start = index
            let negative = take(45)
            guard index < bytes.count else { throw ModelTransportError.invalidResponse }
            if take(48) {
                guard !negative else { throw ModelTransportError.invalidResponse }
            } else {
                guard (49...57).contains(bytes[index]) else { throw ModelTransportError.invalidResponse }
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            }
            guard let s = String(bytes: bytes[start..<index], encoding: .utf8), let n = Int64(s),
                (-ModelJSON.maxInteger...ModelJSON.maxInteger).contains(n)
            else { throw ModelTransportError.invalidResponse }
            // A delimiter is required; decimals/exponents/leading zero are rejected.
            guard index == bytes.count || [9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) else {
                throw ModelTransportError.invalidResponse
            }
            return .integer(n)
        }
    }
    mutating func literal(_ s: String) throws {
        for b in s.utf8 { try require(b) }
    }
    mutating func hex() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw ModelTransportError.invalidResponse }
            let b = bytes[index]
            index += 1
            let n: UInt32
            switch b {
            case 48...57: n = UInt32(b - 48)
            case 65...70: n = UInt32(b - 55)
            case 97...102: n = UInt32(b - 87)
            default: throw ModelTransportError.invalidResponse
            }
            result = result * 16 + n
        }
        return result
    }
    mutating func string() throws -> String {
        try require(34)
        var output = [UInt8]()
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            if b == 34 {
                guard let s = String(bytes: output, encoding: .utf8) else { throw ModelTransportError.invalidResponse }
                return s
            }
            guard b >= 32 else { throw ModelTransportError.invalidResponse }
            if b != 92 {
                output.append(b)
            } else {
                guard index < bytes.count else { throw ModelTransportError.invalidResponse }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case 34, 47, 92: output.append(escaped)
                case 98: output.append(8)
                case 102: output.append(12)
                case 110: output.append(10)
                case 114: output.append(13)
                case 116: output.append(9)
                case 117:
                    var scalar = try hex()
                    if (0xD800...0xDBFF).contains(scalar) {
                        try require(92)
                        try require(117)
                        let low = try hex()
                        guard (0xDC00...0xDFFF).contains(low) else { throw ModelTransportError.invalidResponse }
                        scalar = 0x10000 + (scalar - 0xD800) * 1024 + low - 0xDC00
                    }
                    guard let u = UnicodeScalar(scalar) else { throw ModelTransportError.invalidResponse }
                    output.append(contentsOf: String(u).utf8)
                default: throw ModelTransportError.invalidResponse
                }
            }
            guard output.count <= ModelJSON.maxBytes else { throw ModelTransportError.invalidResponse }
        }
        throw ModelTransportError.invalidResponse
    }
}
