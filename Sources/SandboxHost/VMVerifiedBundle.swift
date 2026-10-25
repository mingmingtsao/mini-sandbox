import CryptoKit
import Darwin
import Foundation

public struct VMVerifiedBundle: Sendable {
    public let kernel: URL
    public let initramfs: URL
    public let workloadDigest: String
    public let kernelRelease: String
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let kernelFile: String
        let kernelSHA256: String
        let initramfsFile: String
        let initramfsSHA256: String
        let probeSHA256: String
        let protocolVersion: Int
        let workloadSHA256: String
        let kernelRelease: String
    }
    public init(directory: URL) throws {
        let root = directory.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else { throw VMProtocolError.length }
        func read(_ name: String, maximum: Int) throws -> Data {
            let fd = open(root.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size > 0,
                info.st_size <= maximum
            else { throw VMProtocolError.length }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n == 0 { break }
                guard n > 0, data.count + n <= maximum else { throw VMProtocolError.length }
                data.append(contentsOf: buffer.prefix(n))
            }
            return data
        }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let m = try JSONDecoder().decode(Manifest.self, from: read("bundle.json", maximum: 16384))
        guard m.schemaVersion == 1, m.protocolVersion == 1, m.kernelFile == "Image",
            m.initramfsFile == "initramfs.cpio.gz"
        else { throw VMProtocolError.version }
        for hash in [m.kernelSHA256, m.initramfsSHA256, m.probeSHA256, m.workloadSHA256] {
            guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw VMProtocolError.length
            }
        }
        guard digest(try read("Image", maximum: 134_217_728)) == m.kernelSHA256,
            digest(try read("initramfs.cpio.gz", maximum: 134_217_728)) == m.initramfsSHA256
        else { throw VMProtocolError.uuid }
        let canonical = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1, "protocolVersion": 1, "kernelSHA256": m.kernelSHA256,
                "initramfsSHA256": m.initramfsSHA256,
            ], options: [.sortedKeys, .withoutEscapingSlashes])
        guard digest(canonical) == m.workloadSHA256 else { throw VMProtocolError.uuid }
        kernel = root.appendingPathComponent("Image")
        initramfs = root.appendingPathComponent("initramfs.cpio.gz")
        workloadDigest = m.workloadSHA256
        kernelRelease = m.kernelRelease
    }
}
