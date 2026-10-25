import CryptoKit
import Darwin
import Foundation

/// Validated, explicitly selected runtime resources. The application does not
/// discover developer caches or inherit a PATH. Keep this owned resource tree
/// non-mutating until VZ has stopped; VZ reopens paths after this validation.
package struct BusinessRuntimeBundle: Sendable {
    package static let profile = "claude-business-runtime-v1"
    package static let vendorSHA256 = "028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332"
    package static let vendorDiskSHA256 = "c4e512ea944c420c80285b4c4bd817098d9845ac6aa6e423bbbb58b8d3a9bf43"
    package let kernel: URL
    package let initramfs: URL
    package let vendorDisk: URL
    package let imageSHA256: String
    package let profileSHA256: String

    package init(directory: URL, vendorDisk: URL) throws {
        try Self.checkDirectory(directory)
        try Self.checkDirectory(vendorDisk.deletingLastPathComponent())
        let manifest = try Self.read(directory.appendingPathComponent("business.json"), maximum: 16_384)
        guard let object = try RuntimeJSON.parse(manifest).object,
            Set(object.keys) == [
                "schema", "profile", "kernelSHA256", "initramfsSHA256", "launchSHA256", "vendorSHA256",
                "vendorDiskSHA256", "vendorReadOnly",
            ],
            object["schema"] == .integer(1), object["profile"] == .string(Self.profile),
            object["vendorSHA256"] == .string(Self.vendorSHA256),
            object["vendorDiskSHA256"] == .string(Self.vendorDiskSHA256),
            object["vendorReadOnly"] == .bool(true),
            object["kernelSHA256"] == .string("256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e"),
            let imageSHA = object["initramfsSHA256"]?.string,
            let profileSHA = object["launchSHA256"]?.string,
            Self.isDigest(imageSHA), Self.isDigest(profileSHA)
        else { throw BusinessVMError.invalidProfile }
        kernel = directory.appendingPathComponent("Image")
        initramfs = directory.appendingPathComponent("runtime.cpio.gz")
        guard
            try Self.fileDigest(kernel, maximum: 64 * 1024 * 1024)
                == "256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e",
            try Self.fileDigest(initramfs, maximum: 128 * 1024 * 1024) == imageSHA,
            try Self.fileDigest(vendorDisk, maximum: 285_493_248, exact: 285_493_248, immutable: true)
                == Self.vendorDiskSHA256
        else { throw BusinessVMError.invalidResource }
        self.vendorDisk = vendorDisk
        imageSHA256 = imageSHA
        profileSHA256 = profileSHA
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func checkDirectory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.standardizedFileURL.path == url.path,
            url.resolvingSymlinksInPath().path == url.path
        else { throw BusinessVMError.invalidResource }
        var current = url
        var leaf = true
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0
            else { throw BusinessVMError.invalidResource }
            if leaf {
                guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw BusinessVMError.invalidResource }
                leaf = false
            }
            if current.path == "/" { return }
            current.deleteLastPathComponent()
        }
    }
    private static func openRegular(_ url: URL, maximum: Int, exact: Int?, immutable: Bool) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BusinessVMError.invalidResource }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_uid == getuid(), info.st_mode & (immutable ? 0o222 : 0o022) == 0,
            info.st_size > 0, info.st_size <= maximum, exact == nil || info.st_size == exact!
        else {
            Darwin.close(descriptor)
            throw BusinessVMError.invalidResource
        }
        return descriptor
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let fd = try openRegular(url, maximum: maximum, exact: nil, immutable: false)
        defer { Darwin.close(fd) }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { return result }
            guard count > 0, count <= maximum - result.count else { throw BusinessVMError.invalidResource }
            result.append(contentsOf: bytes.prefix(count))
        }
    }
    static func fileDigest(_ url: URL, maximum: Int, exact: Int? = nil, immutable: Bool = false) throws -> String {
        let fd = try openRegular(url, maximum: maximum, exact: exact, immutable: immutable)
        defer { Darwin.close(fd) }
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var total = 0
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0, count <= maximum - total else { throw BusinessVMError.invalidResource }
            total += count
            hash.update(data: Data(bytes.prefix(count)))
        }
        guard exact == nil || total == exact else { throw BusinessVMError.invalidResource }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
