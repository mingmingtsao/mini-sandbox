import Foundation

public enum VMProtocolError: String, Error, Sendable {
    case oversized, length, version, type, truncated, extraBytes, uuid, epoch, crossContext, stopped, busy, budget,
        timeout, auditFailed
}
public struct VMFrame: Equatable, Sendable {
    public let type: UInt8
    public let runID: UUID
    public let epoch: UInt64
    public let nonce: UInt64
    public init(type: UInt8 = 1, runID: UUID, epoch: UInt64, nonce: UInt64) {
        self.type = type
        self.runID = runID
        self.epoch = epoch
        self.nonce = nonce
    }
    public func encoded() -> Data {
        var bytes: [UInt8] = [0, 0, 0, 34, 1, type]
        var uuid = runID.uuid
        withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
        for value in [epoch, nonce] {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        return Data(bytes)
    }
}

/// Incremental fixed-size parser. No length-derived allocation or unaligned loads.
public struct VMFrameParser {
    private var bytes: [UInt8] = []
    private var done = false
    private var poisoned = false
    public init() {}
    public var bufferedBytes: Int { bytes.count }
    public mutating func feed(_ data: Data) throws -> VMFrame? {
        guard !done, !poisoned else { throw VMProtocolError.extraBytes }
        poisoned = true
        for byte in data {
            guard bytes.count < 38 else { throw VMProtocolError.extraBytes }
            bytes.append(byte)
            if bytes.count == 4 {
                let size = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size <= 4096 else { throw VMProtocolError.oversized }
                guard size == 34 else { throw VMProtocolError.length }
            }
        }
        guard bytes.count == 38 else {
            poisoned = false
            return nil
        }
        guard bytes[4] == 1 else { throw VMProtocolError.version }
        guard bytes[5] == 1 else { throw VMProtocolError.type }
        let b = Array(bytes[6..<22])
        let id = UUID(
            uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        )
        func number(_ offset: Int) -> UInt64 { bytes[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) } }
        done = true
        return VMFrame(runID: id, epoch: number(22), nonce: number(30))
    }
    public func finish() throws { guard done else { throw VMProtocolError.truncated } }
}
