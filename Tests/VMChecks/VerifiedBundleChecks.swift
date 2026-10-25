import Foundation
import CryptoKit
import Darwin
import SandboxHost

@MainActor func verifiedBundleChecks() {
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func fixture(_ body: (URL, inout [String: Any]) throws -> Bool) throws -> Bool {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("bundle-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let kernel = Data("synthetic kernel".utf8), ramdisk = Data("synthetic ramdisk".utf8)
        try kernel.write(to: root.appendingPathComponent("Image")); try ramdisk.write(to: root.appendingPathComponent("initramfs.cpio.gz"))
        let canonical: [String: Any] = ["schemaVersion": 1, "protocolVersion": 1, "kernelSHA256": digest(kernel), "initramfsSHA256": digest(ramdisk)]
        var manifest = canonical
        manifest.merge(["kernelFile": "Image", "initramfsFile": "initramfs.cpio.gz", "probeSHA256": String(repeating: "a", count: 64), "workloadSHA256": digest(try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys, .withoutEscapingSlashes])), "kernelRelease": "synthetic-test"], uniquingKeysWith: { _, new in new })
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("bundle.json"))
        return try body(root, &manifest)
    }
    func rejected(_ root: URL) -> Bool { do { _ = try VMVerifiedBundle(directory: root); return false } catch { return true } }
    check("verified bundle exact files and canonical workload digest") {
        try fixture { root, manifest in
            let bundle = try VMVerifiedBundle(directory: root)
            return bundle.kernel == root.appendingPathComponent("Image") && bundle.initramfs == root.appendingPathComponent("initramfs.cpio.gz") && bundle.workloadDigest == manifest["workloadSHA256"] as? String && bundle.kernelRelease == "synthetic-test"
        }
    }
    for (key, value) in [("schemaVersion", 2 as Any), ("protocolVersion", 2), ("kernelFile", "../Image"), ("initramfsFile", "other"), ("kernelSHA256", "bad"), ("probeSHA256", String(repeating: "A", count: 64)), ("kernelSHA256", String(repeating: "0", count: 64)), ("initramfsSHA256", String(repeating: "0", count: 64)), ("workloadSHA256", String(repeating: "0", count: 64))] {
        check("verified bundle rejects \(key)=\(value)") {
            try fixture { root, manifest in
                manifest[key] = value
                try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("bundle.json"))
                return rejected(root)
            }
        }
    }
    for kind in ["missing", "empty", "symlink", "hardlink", "fifo", "oversized"] {
        check("verified bundle rejects \(kind) before reading content") {
            try fixture { root, _ in
                let image = root.appendingPathComponent("Image").path
                try FileManager.default.removeItem(atPath: image)
                switch kind {
                case "empty": try Data().write(to: URL(fileURLWithPath: image))
                case "symlink": try FileManager.default.createSymbolicLink(atPath: image, withDestinationPath: root.appendingPathComponent("initramfs.cpio.gz").path)
                case "hardlink": guard link(root.appendingPathComponent("initramfs.cpio.gz").path, image) == 0 else { return false }
                case "fifo": guard mkfifo(image, 0o600) == 0 else { return false }
                case "oversized":
                    guard FileManager.default.createFile(atPath: image, contents: nil) else { return false }
                    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: image)); defer { try? file.close() }
                    try file.truncate(atOffset: 134217729)
                default: break
                }
                return rejected(root)
            }
        }
    }
    check("verified bundle rejects symlinked root") {
        try fixture { root, _ in
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            return rejected(alias)
        }
    }
}
