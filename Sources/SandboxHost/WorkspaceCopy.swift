import Foundation
import CryptoKit
import Darwin

public enum WorkspaceError: Error, Equatable {
    case rejected(String)
    case blockedPlatform(String)
    case io(String, Int32)
    case mutated
    case cancelled
    case foreignSnapshot
    case staleReview
    /// Rename succeeded; publication may have occurred despite verification failure.
    case committedUnverified(String)
}

public struct WorkspaceLimits {
    public var entries: Int = 1_000
    public var fileBytes: Int = 4 * 1_024 * 1_024
    public var totalBytes: Int = 16 * 1_024 * 1_024
    public var depth: Int = 16
    public var pathBytes: Int = 1_024
    public var previewBytes: Int = 4_096
    public init() {}
}

/// Opaque, process-local handle; not a guest capability or a persisted authorization.
public struct WorkspaceSnapshotID: Hashable { fileprivate let value = UUID() }
public struct WorkspaceSnapshot {
    public let id: WorkspaceSnapshotID
    public let workingDirectory: String
    public let manifest: [WorkspaceManifestEntry]
    public let exclusions: [String]
}
public struct WorkspaceManifestEntry: Equatable {
    public let path: String
    public let directory: Bool
    public let bytes: Int
    public let sha256: String?
}
public enum WorkspacePreview: Equatable {
    case text(String)
    case noPreview(String)
}
public struct WorkspaceChange {
    public enum Kind: String { case add, change, delete }
    public let path: String
    public let kind: Kind
    public let before: WorkspacePreview?
    public let after: WorkspacePreview?
}
public struct WorkspaceReview {
    public let changes: [WorkspaceChange]
    public let manifest: [WorkspaceManifestEntry]
    public let exclusions: [String]
    fileprivate let owner: UUID
    fileprivate let snapshot: WorkspaceSnapshotID
    fileprivate let tree: WorkspaceTree
}

private final class WorkspaceFD {
    let value: Int32
    init(_ value: Int32) throws {
        guard value >= 0 else { throw WorkspaceError.io("open", errno) }
        self.value = value
    }
    deinit { close(value) }
}
private struct WorkspaceIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ s: stat) { device = s.st_dev; inode = s.st_ino }
}
private struct WorkspaceStamp: Equatable {
    let identity: WorkspaceIdentity
    let size: off_t
    let links: nlink_t
    let mode: mode_t
    let mt: Int; let mn: Int; let ct: Int; let cn: Int
    init(_ s: stat) {
        identity = WorkspaceIdentity(s); size = s.st_size; links = s.st_nlink; mode = s.st_mode
        mt = s.st_mtimespec.tv_sec; mn = s.st_mtimespec.tv_nsec
        ct = s.st_ctimespec.tv_sec; cn = s.st_ctimespec.tv_nsec
    }
}
private struct WorkspaceNode: Equatable {
    let data: Data? // nil represents an empty or nonempty directory
    var digest: String? { data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
}
fileprivate struct WorkspaceTree: Equatable {
    fileprivate var nodes: [String: WorkspaceNode] = [:]
    var exclusions: [String] = []
    var manifest: [WorkspaceManifestEntry] {
        nodes.keys.sorted().map { path in
            let node = nodes[path]!
            return WorkspaceManifestEntry(path: path, directory: node.data == nil,
                                          bytes: node.data?.count ?? 0, sha256: node.digest)
        }
    }
}
private struct WorkspaceRecord {
    let baseline: WorkspaceTree
    let source: WorkspaceFD
    let sourcePath: String
    let work: WorkspaceFD
}

/// Synchronous trusted-host-only API. Serialize access; no guest JSON entry point.
/// Baseline truth stays private in memory and is also stored read-only on disk.
public final class WorkspaceStore {
    private let root: WorkspaceFD
    private let rootPath: String
    private let limits: WorkspaceLimits
    private let owner = UUID()
    private var records: [WorkspaceSnapshotID: WorkspaceRecord] = [:]
    private let cancelled: () -> Bool
    // Host instrumentation also permits deterministic mutation checks with real files.
    private let didReadChunk: ((String) throws -> Void)?

    public init(newRoot: String, limits: WorkspaceLimits = WorkspaceLimits(),
                cancelled: @escaping () -> Bool = { false },
                didReadChunk: ((String) throws -> Void)? = nil) throws {
        guard limits.entries > 0, limits.entries <= 10_000,
              limits.fileBytes > 0, limits.fileBytes <= 64 * 1_024 * 1_024,
              limits.totalBytes > 0, limits.totalBytes <= 128 * 1_024 * 1_024,
              limits.depth > 0, limits.depth <= 64, limits.pathBytes > 0,
              limits.pathBytes <= 4_096, limits.previewBytes >= 0,
              limits.previewBytes <= 65_536 else { throw WorkspaceError.rejected("limits") }
        self.limits = limits; self.cancelled = cancelled; self.didReadChunk = didReadChunk
        let (parent, name) = try Self.parent(newRoot)
        root = try Self.makeDirectory(parent, name)
        rootPath = newRoot
        try Self.verifyPath(newRoot, root)
    }

    public func importTree(from sourcePath: String) throws -> WorkspaceSnapshot {
        try checkpoint()
        try validateBindings()
        let source = try Self.openDirectory(sourcePath)
        try Self.disjoint(source, root)
        let tree = try stableScan(source)
        try validateBindings()
        try Self.verifyPath(sourcePath, source)
        let id = WorkspaceSnapshotID()
        let name = id.value.uuidString
        let area = try Self.makeDirectory(root, name)
        let baseline = try Self.makeDirectory(area, "baseline")
        let work = try Self.makeDirectory(area, "working")
        let validate = {
            try self.validateBindings()
            try Self.verifyPath(sourcePath, source)
            try Self.verifyNamed(self.root, name, area)
            try Self.verifyNamed(area, "baseline", baseline)
            try Self.verifyNamed(area, "working", work)
        }
        try materialize(tree, into: baseline, readOnly: true, validate: validate)
        try materialize(tree, into: work, readOnly: false, validate: validate)
        guard try stableScan(source) == tree else { throw WorkspaceError.mutated }
        try validate()
        records[id] = WorkspaceRecord(baseline: tree, source: source, sourcePath: sourcePath, work: work)
        return WorkspaceSnapshot(id: id, workingDirectory: rootPath + "/" + name + "/working",
                                 manifest: tree.manifest, exclusions: tree.exclusions)
    }

    public func review(_ id: WorkspaceSnapshotID) throws -> WorkspaceReview {
        guard let record = records[id] else { throw WorkspaceError.foreignSnapshot }
        try validateBindings()
        let current = try stableScan(record.work)
        try validateBindings()
        return WorkspaceReview(changes: changes(record.baseline, current), manifest: current.manifest,
                               exclusions: current.exclusions, owner: owner, snapshot: id, tree: current)
    }

    public func originalChanges(_ id: WorkspaceSnapshotID) throws -> [WorkspaceChange] {
        guard let record = records[id] else { throw WorkspaceError.foreignSnapshot }
        try Self.verifyPath(record.sourcePath, record.source)
        let current = try stableScan(record.source)
        try Self.verifyPath(record.sourcePath, record.source)
        return changes(record.baseline, current)
    }

    /// Explicit host action only. No overwrite/backwrite option exists.
    public func exportReviewed(_ review: WorkspaceReview, toNewDirectory destination: String) throws {
        guard review.owner == owner, let record = records[review.snapshot] else { throw WorkspaceError.foreignSnapshot }
        try checkpoint()
        _ = try Self.pathParts(destination)
        for record in records.values {
            if destination == record.sourcePath || destination.hasPrefix(record.sourcePath + "/") {
                throw WorkspaceError.rejected("source destination")
            }
        }
        try validateBindings()
        let (parent, name) = try Self.parent(destination)
        try permittedDestination(parent)
        var existing = stat()
        if fstatat(parent.value, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
            throw WorkspaceError.rejected("destination exists or is inaccessible")
        }
        let exportTree = try stableScan(record.work)
        guard exportTree.exclusions.isEmpty, review.tree.exclusions.isEmpty else {
            throw WorkspaceError.rejected("excluded working entries require selection")
        }
        guard exportTree == review.tree else { throw WorkspaceError.staleReview }
        try validateBindings()
        guard try Self.identity(parent) == Self.identity(Self.parent(destination).0) else { throw WorkspaceError.mutated }
        let stageName = ".workspace-stage-" + UUID().uuidString
        let stage = try Self.makeDirectory(parent, stageName)
        // Failures leave this exclusively-created private staging directory for host inspection.
        // Never recursively delete a path that could have been replaced by an unknown object.
        let validate = {
            try self.validateBindings()
            guard try Self.identity(parent) == Self.identity(Self.parent(destination).0) else { throw WorkspaceError.mutated }
            try self.permittedDestination(parent)
            try Self.verifyNamed(parent, stageName, stage)
        }
        try materialize(review.tree, into: stage, readOnly: false, validate: validate)
        let stagedTree = try stableScan(stage)
        let latestWork = try stableScan(record.work)
        guard latestWork.exclusions.isEmpty else { throw WorkspaceError.rejected("excluded working entries require selection") }
        guard stagedTree == review.tree, latestWork == review.tree else { throw WorkspaceError.staleReview }
        try checkpoint()
        try validate()
        try permittedDestination(parent)
        let parentNow = try Self.parent(destination).0
        guard try Self.identity(parent) == Self.identity(parentNow) else { throw WorkspaceError.mutated }
        try Self.verifyNamed(parent, stageName, stage)
        guard renameatx_np(parent.value, stageName, parent.value, name, UInt32(RENAME_EXCL)) == 0 else {
            throw WorkspaceError.io("exclusive export rename", errno)
        }
        do {
            try Self.verifyNamed(parent, name, stage)
            guard fsync(parent.value) == 0 else { throw WorkspaceError.io("export directory sync", errno) }
        } catch { throw WorkspaceError.committedUnverified(String(describing: error)) }
    }

    private func validateBindings() throws {
        try Self.verifyPath(rootPath, root)
        try Self.trustedAncestors(root)
        for (id, record) in records {
            try Self.verifyPath(record.sourcePath, record.source)
            try Self.verifyPath(rootPath + "/" + id.value.uuidString + "/working", record.work)
        }
    }
    private static func verifyPath(_ path: String, _ fd: WorkspaceFD) throws {
        do {
            let now = try openDirectory(path)
            guard try identity(now) == identity(fd) else { throw WorkspaceError.mutated }
        } catch { throw WorkspaceError.mutated }
    }
    private func permittedDestination(_ parent: WorkspaceFD) throws {
        try Self.trustedAncestors(parent)
        guard try !Self.isWithin(parent, root) else { throw WorkspaceError.rejected("managed destination") }
        for record in records.values {
            guard try !Self.isWithin(parent, record.source) else { throw WorkspaceError.rejected("source destination") }
        }
    }
    private func checkpoint() throws { if cancelled() { throw WorkspaceError.cancelled } }
    private static func status(_ fd: WorkspaceFD) throws -> stat {
        var s = stat()
        guard fstat(fd.value, &s) == 0 else { throw WorkspaceError.io("fstat", errno) }
        return s
    }
    private static func identity(_ fd: WorkspaceFD) throws -> WorkspaceIdentity { WorkspaceIdentity(try status(fd)) }
    private static func component(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              name.utf8.elementsEqual(name.precomposedStringWithCanonicalMapping.utf8) else { throw WorkspaceError.rejected("path component") }
    }
    private static func pathParts(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { throw WorkspaceError.rejected("absolute bounded path required") }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts { try component(part) }
        return parts
    }
    private static func openDirectory(_ path: String) throws -> WorkspaceFD {
        let parts = try pathParts(path)
        var fd = try WorkspaceFD(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW))
        for part in parts { fd = try child(fd, part, directory: true) }
        return fd
    }
    private static func parent(_ path: String) throws -> (WorkspaceFD, String) {
        var parts = try pathParts(path)
        let name = parts.removeLast()
        let fd: WorkspaceFD
        if parts.isEmpty { fd = try WorkspaceFD(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)) }
        else { fd = try openDirectory("/" + parts.joined(separator: "/")) }
        return (fd, name)
    }
    // Pure stat classifier; device coverage needs no host device creation.
    static func checkNodeType(_ s: stat, directory: Bool = false) throws {
        let type = s.st_mode & S_IFMT
        guard type == S_IFDIR || (!directory && type == S_IFREG && s.st_nlink == 1) else {
            throw WorkspaceError.rejected("unsupported file type or hard link")
        }
    }
    private static func child(_ parent: WorkspaceFD, _ name: String, directory: Bool = false) throws -> WorkspaceFD {
        var before = stat()
        guard fstatat(parent.value, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkspaceError.io("entry stat", errno) }
        try checkNodeType(before, directory: directory)
        let fd = try WorkspaceFD(openat(parent.value, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW | (directory ? O_DIRECTORY : 0)))
        let s = try status(fd)
        try checkNodeType(s, directory: directory)
        guard WorkspaceIdentity(before) == WorkspaceIdentity(s) else { throw WorkspaceError.mutated }
        try verifyNamed(parent, name, fd)
        return fd
    }
    private static func verifyNamed(_ parent: WorkspaceFD, _ name: String, _ fd: WorkspaceFD) throws {
        var s = stat()
        guard fstatat(parent.value, name, &s, AT_SYMLINK_NOFOLLOW) == 0,
              WorkspaceStamp(s) == WorkspaceStamp(try status(fd)) else { throw WorkspaceError.mutated }
    }
    private static func isWithin(_ child: WorkspaceFD, _ ancestor: WorkspaceFD) throws -> Bool {
        let target = try identity(ancestor)
        var current = child
        for _ in 0..<256 {
            let here = try identity(current)
            if here == target { return true }
            let up = try Self.child(current, "..", directory: true)
            if try identity(up) == here { return false }
            current = up
        }
        throw WorkspaceError.rejected("ancestry limit")
    }
    private static func disjoint(_ a: WorkspaceFD, _ b: WorkspaceFD) throws {
        if try isWithin(a, b) || isWithin(b, a) { throw WorkspaceError.rejected("overlapping roots") }
    }
    private static func checkACL(_ fd: WorkspaceFD, requireEmpty: Bool) throws {
        guard let acl = acl_get_fd_np(fd.value, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw WorkspaceError.io("read ACL", errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY
        while true {
            errno = 0
            let result = acl_get_entry(acl, Int32(which.rawValue), &entry)
            if result == -1 && errno == EINVAL { return } // Darwin end-of-list convention
            guard result == 0, let entry else { throw WorkspaceError.io("enumerate ACL", errno) }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw WorkspaceError.io("ACL tag", errno) }
            guard !requireEmpty, tag == ACL_EXTENDED_DENY else { throw WorkspaceError.rejected("unsafe ACL") }
            which = ACL_NEXT_ENTRY
        }
    }
    private static func sanitize(_ fd: WorkspaceFD, mode: mode_t) throws {
        guard let acl = acl_init(0) else { throw WorkspaceError.io("acl init", errno) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd(fd.value, acl) == 0, fchmod(fd.value, mode) == 0 else {
            throw WorkspaceError.io("sanitize permissions", errno)
        }
        // Only names are inspected on exclusively created nodes. Never read source
        // metadata values or remove OS markers. Unknown fresh-node metadata fails closed.
        let count = flistxattr(fd.value, nil, 0, 0)
        guard count >= 0, count <= 65_536 else { throw WorkspaceError.rejected("new-object xattr limit") }
        if count > 0 {
            var names = [CChar](repeating: 0, count: count)
            guard flistxattr(fd.value, &names, count, 0) == count else { throw WorkspaceError.mutated }
            var offset = 0
            while offset < count {
                let length = names[offset...].prefix(while: { $0 != 0 }).count
                guard length > 0, offset + length < count else { throw WorkspaceError.rejected("xattr names") }
                let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress!.advanced(by: offset)) }
                guard name == "com.apple.provenance" else { throw WorkspaceError.blockedPlatform("unexpected new-object xattr: " + name) }
                offset += length + 1
            }
        }
        let s = try status(fd)
        guard s.st_uid == geteuid(), s.st_mode & 0o7777 == mode else { throw WorkspaceError.rejected("new-object permissions") }
        try checkACL(fd, requireEmpty: true)
    }
    private static func trustedAncestors(_ start: WorkspaceFD) throws {
        var fd = start
        for _ in 0..<256 {
            let s = try status(fd)
            guard (s.st_uid == 0 || s.st_uid == geteuid()), s.st_mode & 0o022 == 0 else {
                throw WorkspaceError.rejected("unsafe ancestor permissions")
            }
            try checkACL(fd, requireEmpty: false)
            let up = try child(fd, "..", directory: true)
            if try identity(fd) == identity(up) { return }
            fd = up
        }
        throw WorkspaceError.rejected("ancestry limit")
    }
    private static func makeDirectory(_ parent: WorkspaceFD, _ name: String) throws -> WorkspaceFD {
        try trustedAncestors(parent)
        guard mkdirat(parent.value, name, 0o700) == 0 else { throw WorkspaceError.io("exclusive mkdir", errno) }
        let fd = try child(parent, name, directory: true)
        try sanitize(fd, mode: 0o700)
        return fd
    }
    private static func excluded(_ name: String) -> Bool {
        let s = name.lowercased()
        return [".git", ".ssh", ".aws", ".azure", ".gnupg", ".config", ".npmrc", ".netrc", ".pypirc", "credentials", "id_rsa", "id_ed25519"].contains(s)
            || s == ".env" || s.hasPrefix(".env.") || s.hasSuffix(".pem") || s.hasSuffix(".key") || s.hasSuffix(".p12")
    }
    static func registerName(_ name: String, in names: inout Set<String>) throws {
        let key = name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard names.insert(key).inserted else { throw WorkspaceError.rejected("canonical collision") }
    }
    private func stableScan(_ root: WorkspaceFD) throws -> WorkspaceTree {
        let first = try scan(root)
        let second = try scan(root)
        guard first.0 == second.0, first.1 == second.1 else { throw WorkspaceError.mutated }
        return first.0
    }
    private func scan(_ root: WorkspaceFD) throws -> (WorkspaceTree, [String: WorkspaceStamp]) {
        var result = WorkspaceTree()
        var stamps: [String: WorkspaceStamp] = [:]
        var count = 0
        var bytes = 0
        func visit(_ dir: WorkspaceFD, _ prefix: String, _ depth: Int) throws {
            try checkpoint()
            guard depth <= limits.depth else { throw WorkspaceError.rejected("depth limit") }
            let before = WorkspaceStamp(try Self.status(dir))
            stamps[prefix] = before
            let enumerationFD = openat(dir.value, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            guard enumerationFD >= 0 else { throw WorkspaceError.io("enumerate open", errno) }
            guard let stream = fdopendir(enumerationFD) else { close(enumerationFD); throw WorkspaceError.io("fdopendir", errno) }
            defer { closedir(stream) }
            var names: [String] = []
            var canonical = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw WorkspaceError.io("readdir", errno) }
                    break
                }
                let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
                }
                guard let name else { throw WorkspaceError.rejected("non UTF-8 name") }
                if name == "." || name == ".." { continue }
                count += 1
                guard count <= limits.entries else { throw WorkspaceError.rejected("entry limit") }
                try Self.component(name)
                try Self.registerName(name, in: &canonical)
                names.append(name)
            }
            for name in names.sorted() {
                try checkpoint()
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard path.utf8.count <= limits.pathBytes else { throw WorkspaceError.rejected("path limit") }
                if Self.excluded(name) { result.exclusions.append(path); continue }
                let fd = try Self.child(dir, name)
                let initial = try Self.status(fd)
                let stamp = WorkspaceStamp(initial)
                stamps[path] = stamp
                if initial.st_mode & S_IFMT == S_IFDIR {
                    result.nodes[path] = WorkspaceNode(data: nil)
                    try visit(fd, path, depth + 1)
                } else {
                    guard initial.st_size >= 0, initial.st_size <= limits.fileBytes,
                          initial.st_size <= limits.totalBytes - bytes else { throw WorkspaceError.rejected("byte limit") }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        try checkpoint()
                        let n = read(fd.value, &buffer, buffer.count)
                        if n < 0 { if errno == EINTR { continue }; throw WorkspaceError.io("read", errno) }
                        if n == 0 { break }
                        guard n <= limits.fileBytes - data.count, n <= limits.totalBytes - bytes else { throw WorkspaceError.rejected("byte limit") }
                        data.append(contentsOf: buffer.prefix(n)); bytes += n
                        try didReadChunk?(path)
                    }
                    guard data.count == initial.st_size else { throw WorkspaceError.mutated }
                    result.nodes[path] = WorkspaceNode(data: data)
                }
                guard stamp == WorkspaceStamp(try Self.status(fd)) else { throw WorkspaceError.mutated }
                try Self.verifyNamed(dir, name, fd)
            }
            guard before == WorkspaceStamp(try Self.status(dir)) else { throw WorkspaceError.mutated }
        }
        try visit(root, "", 0)
        result.exclusions.sort()
        return (result, stamps)
    }
    private func materialize(_ tree: WorkspaceTree, into root: WorkspaceFD, readOnly: Bool, validate: () throws -> Void) throws {
        var directories: [String: WorkspaceFD] = ["": root]
        for path in tree.nodes.keys.sorted() {
            try checkpoint()
            try validate()
            let parts = path.split(separator: "/").map(String.init)
            let parentPath = parts.dropLast().joined(separator: "/")
            guard let parent = directories[parentPath], let name = parts.last else { throw WorkspaceError.rejected("internal tree") }
            try Self.trustedAncestors(parent)
            if let data = tree.nodes[path]!.data {
                let fd = try WorkspaceFD(openat(parent.value, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600))
                let s = try Self.status(fd)
                guard s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1 else { throw WorkspaceError.rejected("created file type") }
                try Self.sanitize(fd, mode: 0o600)
                try data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        try checkpoint()
                        try validate()
                        let n = write(fd.value, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw WorkspaceError.io("write", errno) }
                        offset += n
                    }
                }
                guard fchmod(fd.value, readOnly ? 0o400 : 0o600) == 0, fsync(fd.value) == 0 else { throw WorkspaceError.io("file sync", errno) }
                try Self.verifyNamed(parent, name, fd)
            } else { directories[path] = try Self.makeDirectory(parent, name) }
        }
        for fd in directories.values {
            try validate()
            guard fchmod(fd.value, readOnly ? 0o500 : 0o700) == 0, fsync(fd.value) == 0 else { throw WorkspaceError.io("directory sync", errno) }
        }
    }
    private func preview(_ node: WorkspaceNode?) -> WorkspacePreview? {
        guard let node else { return nil }
        guard let data = node.data else { return .noPreview("directory") }
        guard data.count <= limits.previewBytes else { return .noPreview("oversized") }
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9,10,13].contains($0.value)) || $0.value == 127 }) else { return .noPreview("binary or non-text UTF-8") }
        return .text(text)
    }
    private func changes(_ before: WorkspaceTree, _ after: WorkspaceTree) -> [WorkspaceChange] {
        Set(before.nodes.keys).union(after.nodes.keys).sorted().compactMap { path in
            let a = before.nodes[path], b = after.nodes[path]
            guard a != b else { return nil }
            return WorkspaceChange(path: path, kind: a == nil ? .add : (b == nil ? .delete : .change),
                                   before: preview(a), after: preview(b))
        }
    }
}
