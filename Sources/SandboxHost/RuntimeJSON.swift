// Standalone runtime-local adaptation of Sources/SandboxHost/ModelJSON.swift.
// No model gateway or Package dependency; raw grammar is checked before Foundation.
import Foundation

/// Deliberately bounded JSON domain: exact safe integers only, no floating-point,
/// decimal, exponent, negative zero, NaN or infinity. No schema evaluation/fetch.
indirect enum RuntimeJSON: Equatable, Sendable, Codable {
    case object([String: RuntimeJSON]), array([RuntimeJSON]), string(String), integer(Int64), bool(Bool), null
    static let maxBytes = 16_384
    static let maxDepth = 8
    static let maxNodes = 128
    static let maxInteger: Int64 = 9_007_199_254_740_991

    static func parse(_ data: Data, maxBytes: Int = RuntimeJSON.maxBytes) throws -> RuntimeJSON {
        guard data.count <= maxBytes else { throw AgentRuntimeProbe.Failure.frame }
        var parser = RuntimeRawJSON(bytes: Array(data)); let result = try parser.value(depth: 0)
        parser.space(); guard parser.index == parser.bytes.count else { throw AgentRuntimeProbe.Failure.frame }
        return result
    }
    func validated() throws -> RuntimeJSON {
        let bytes = try JSONEncoder().encode(self)
        return try Self.parse(bytes)
    }
    var object: [String: RuntimeJSON]? { if case .object(let value) = self { value } else { nil } }
    var array: [RuntimeJSON]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    subscript(_ key: String) -> RuntimeJSON? { object?[key] }
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Int64.self), (-Self.maxInteger...Self.maxInteger).contains(n) { self = .integer(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([RuntimeJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: RuntimeJSON].self) { self = .object(o) }
        else { throw AgentRuntimeProbe.Failure.frame }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .integer(let n): guard (-Self.maxInteger...Self.maxInteger).contains(n) else { throw AgentRuntimeProbe.Failure.frame }; try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

/// Raw grammar validation precedes any Foundation object decoding. Escaped keys
/// are decoded here so e.g. "id" and "\\u0069d" cannot evade duplicate detection.
private struct RuntimeRawJSON {
    let bytes: [UInt8]
    var index = 0
    var nodes = 0
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { if index < bytes.count && bytes[index] == byte { index += 1; return true }; return false }
    mutating func require(_ byte: UInt8) throws { guard take(byte) else { throw AgentRuntimeProbe.Failure.frame } }
    mutating func value(depth: Int) throws -> RuntimeJSON {
        space(); nodes += 1
        guard depth <= RuntimeJSON.maxDepth, nodes <= RuntimeJSON.maxNodes, index < bytes.count else { throw AgentRuntimeProbe.Failure.frame }
        switch bytes[index] {
        case 123:
            index += 1; space(); var o: [String: RuntimeJSON] = [:]
            if take(125) { return .object(o) }
            repeat {
                space(); let k = try string(); guard o[k] == nil else { throw AgentRuntimeProbe.Failure.frame }
                space(); try require(58); o[k] = try value(depth: depth + 1); space()
                if take(125) { return .object(o) }; try require(44)
            } while true
        case 91:
            index += 1; space(); var a: [RuntimeJSON] = []
            if take(93) { return .array(a) }
            repeat {
                a.append(try value(depth: depth + 1)); space()
                if take(93) { return .array(a) }; try require(44)
            } while true
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        default:
            let start = index; let negative = take(45)
            guard index < bytes.count else { throw AgentRuntimeProbe.Failure.frame }
            if take(48) {
                guard !negative else { throw AgentRuntimeProbe.Failure.frame }
            } else {
                guard (49...57).contains(bytes[index]) else { throw AgentRuntimeProbe.Failure.frame }
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            }
            guard let s = String(bytes: bytes[start..<index], encoding: .utf8), let n = Int64(s),
                  (-RuntimeJSON.maxInteger...RuntimeJSON.maxInteger).contains(n) else { throw AgentRuntimeProbe.Failure.frame }
            // A delimiter is required; decimals/exponents/leading zero are rejected.
            guard index == bytes.count || [9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) else { throw AgentRuntimeProbe.Failure.frame }
            return .integer(n)
        }
    }
    mutating func literal(_ s: String) throws {
        for b in s.utf8 { try require(b) }
    }
    mutating func hex() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw AgentRuntimeProbe.Failure.frame }
            let b = bytes[index]; index += 1
            let n: UInt32
            switch b { case 48...57: n = UInt32(b - 48); case 65...70: n = UInt32(b - 55); case 97...102: n = UInt32(b - 87); default: throw AgentRuntimeProbe.Failure.frame }
            result = result * 16 + n
        }
        return result
    }
    mutating func string() throws -> String {
        try require(34); var output = [UInt8]()
        while index < bytes.count {
            let b = bytes[index]; index += 1
            if b == 34 {
                guard let s = String(bytes: output, encoding: .utf8) else { throw AgentRuntimeProbe.Failure.frame }
                return s
            }
            guard b >= 32 else { throw AgentRuntimeProbe.Failure.frame }
            if b != 92 { output.append(b) } else {
                guard index < bytes.count else { throw AgentRuntimeProbe.Failure.frame }
                let escaped = bytes[index]; index += 1
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
                        try require(92); try require(117); let low = try hex()
                        guard (0xDC00...0xDFFF).contains(low) else { throw AgentRuntimeProbe.Failure.frame }
                        scalar = 0x10000 + (scalar - 0xD800) * 1024 + low - 0xDC00
                    }
                    guard let u = UnicodeScalar(scalar) else { throw AgentRuntimeProbe.Failure.frame }
                    output.append(contentsOf: String(u).utf8)
                default: throw AgentRuntimeProbe.Failure.frame
                }
            }
            guard output.count <= RuntimeJSON.maxBytes else { throw AgentRuntimeProbe.Failure.frame }
        }
        throw AgentRuntimeProbe.Failure.frame
    }
}

func validateRuntimeFrame(_ data: Data) throws {
    guard let f = try RuntimeJSON.parse(data).object,
          f["v"] == .integer(1), let id=f["id"]?.integer, id>=0,
          let kind=f["type"]?.string else { throw AgentRuntimeProbe.Failure.frame }
    let keys=Set(f.keys)
    switch kind {
    case "hello":
        guard keys == ["v","type","id","fresh","interfaces","kernel","workdir"],
              f["fresh"] == .bool(true), f["interfaces"] == .array([.string("lo")]),
              let kernel=f["kernel"]?.string, !kernel.isEmpty, kernel.utf8.count<=256,
              f["workdir"] == .string("/work/project") else {throw AgentRuntimeProbe.Failure.frame}
    case "stdout","stderr":
        guard keys == ["v","type","id","data","sha256"], f["data"]?.string != nil,
              let hash=f["sha256"]?.string, hash.utf8.count==64,
              hash.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {throw AgentRuntimeProbe.Failure.frame}
    case "exit":
        guard keys == ["v","type","id","code","cancelled"], let code=f["code"]?.integer,
              (-255...255).contains(code), case .bool = f["cancelled"] else {throw AgentRuntimeProbe.Failure.frame}
    default: throw AgentRuntimeProbe.Failure.frame
    }
}
