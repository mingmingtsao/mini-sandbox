import Darwin
import Foundation
import SandboxHost

final class CheckMetrics: @unchecked Sendable {
    static let shared = CheckMetrics()
    var assertions = 0
    var groups = 0
}
func namedPass(_ name: String) {
    CheckMetrics.shared.groups += 1
    print("PASS \(name)")
}
struct CheckFailure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    CheckMetrics.shared.assertions += 1
    if try !condition() { throw CheckFailure(message: message) }
}
func put(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
func mkdir(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
}
func contents(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

func xattrs(_ path: String) throws -> Set<String> {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    try check(fd >= 0, "metadata descriptor")
    defer { close(fd) }
    let n = flistxattr(fd, nil, 0, 0)
    try check(n >= 0, "metadata names")
    var bytes = [CChar](repeating: 0, count: max(n, 1))
    try check(flistxattr(fd, &bytes, n, 0) == n, "metadata names stable")
    return Set(
        bytes.prefix(n).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) })
}
func aclText(_ path: String) throws -> String {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    try check(fd >= 0, "ACL descriptor")
    defer { close(fd) }
    guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
        try check(errno == ENOENT, "ACL fetch error")
        return ""
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard let text = acl_to_text(acl, nil) else { throw CheckFailure(message: "ACL text") }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text)
}
func fixtureACL(_ path: String, _ entry: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/chmod")
    p.arguments = ["+a", entry, path]
    try p.run()
    p.waitUntilExit()
    try check(p.terminationStatus == 0, "synthetic ACL setup")
}
func run() throws {
    if CommandLine.arguments.contains("--self-check-failure") { try check(false, "intentional harness failure") }
    guard let scratch = ProcessInfo.processInfo.environment["TMPDIR"] else {
        throw CheckFailure(message: "TMPDIR required")
    }
    let base = scratch.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let fixture = "/" + base + "/workspace-checks-" + UUID().uuidString
    try mkdir(fixture)
    if CommandLine.arguments.contains("--search-only") {
        try workspaceSearchChecks(fixture)
        return
    }
    let source = fixture + "/source"
    try mkdir(source)
    try put(source + "/hello.txt", "before\n")
    try put(source + "/delete.txt", "deleted\n")
    try expect(.io("exclusive mkdir", EEXIST)) { _ = try WorkspaceStore(newRoot: source) }
    try expect(.rejected("path component")) { _ = try WorkspaceStore(newRoot: fixture + "/source/../escape") }
    try check(symlink(source, fixture + "/alias") == 0, "fixture symlink")
    try expect(.rejected("unsupported file type or hard link")) {
        _ = try WorkspaceStore(newRoot: fixture + "/alias/new")
    }
    try check(try contents(source + "/hello.txt") == "before\n", "preflight preserves original")
    do {
        _ = try WorkspaceStore(newRoot: fixture + "/e\u{301}")
        throw CheckFailure(message: "decomposed root name accepted")
    } catch WorkspaceError.rejected("path component") {}
    try check(!FileManager.default.fileExists(atPath: fixture + "/e\u{301}"), "normalization rejected before creation")
    namedPass("preflight: existing root, traversal, symlink ancestor, original preservation, NFC")
    print("Synthetic fixtures: \(fixture)")

    let canary = "source-only"
    try check(
        canary.withCString {
            setxattr(source + "/hello.txt", "org.mini-sandbox.test-source-only", $0, canary.utf8.count, 0, 0)
        } == 0, "source xattr fixture")
    try fixtureACL(source + "/hello.txt", "everyone allow read")
    let sourceACL = try aclText(source + "/hello.txt")
    let sourceAttrs = try xattrs(source + "/hello.txt")
    let freshAttrs = try xattrs(fixture)
    let store = try WorkspaceStore(newRoot: fixture + "/managed")
    let snapshot = try store.importTree(from: source)
    try check(
        snapshot.manifest.count == 2 && snapshot.manifest.allSatisfy { $0.sha256?.count == 64 }, "full SHA manifest")
    try put(snapshot.workingDirectory + "/hello.txt", "after\n")
    try FileManager.default.removeItem(atPath: snapshot.workingDirectory + "/delete.txt")
    try put(snapshot.workingDirectory + "/added.txt", "added\n")
    let review = try store.review(snapshot.id)
    try check(Set(review.changes.map { $0.kind.rawValue }) == Set(["add", "change", "delete"]), "complete delta")
    try check(review.changes.first(where: { $0.path == "hello.txt" })?.after == .text("after\n"), "text preview")
    try store.exportReviewed(review, toNewDirectory: fixture + "/export")
    try check(try contents(source + "/hello.txt") == "before\n", "original untouched")
    try check(try contents(fixture + "/export/hello.txt") == "after\n", "reviewed export")
    try check(try store.originalChanges(snapshot.id).isEmpty, "original separate")
    try check(try aclText(source + "/hello.txt") == sourceACL, "source ACL unchanged")
    try check(try xattrs(source + "/hello.txt") == sourceAttrs, "source xattr unchanged")
    var canaryBytes = [UInt8](repeating: 0, count: 32)
    let canaryCount = getxattr(
        source + "/hello.txt", "org.mini-sandbox.test-source-only", &canaryBytes, canaryBytes.count, 0, 0)
    try check(
        canaryCount == canary.utf8.count && String(decoding: canaryBytes.prefix(canaryCount), as: UTF8.self) == canary,
        "source xattr value unchanged")
    for path in [
        fixture + "/managed", snapshot.workingDirectory, snapshot.workingDirectory + "/hello.txt", fixture + "/export",
        fixture + "/export/hello.txt",
    ] {
        let attrs = try xattrs(path)
        try check(attrs.isSubset(of: ["com.apple.provenance"]), "no source metadata propagated")
        if freshAttrs.contains("com.apple.provenance") {
            try check(attrs.contains("com.apple.provenance"), "new-node provenance retained")
        }
        let text = try aclText(path)
        try check(!text.contains("allow") && !text.contains("deny"), "new-node empty ACL")
        var s = stat()
        try check(lstat(path, &s) == 0, "new-node stat")
        try check(
            s.st_uid == geteuid() && s.st_mode & 0o777 == (s.st_mode & S_IFMT == S_IFDIR ? 0o700 : 0o600),
            "new-node owner/mode")
    }
    namedPass("vertical import -> edit/diff -> new export; metadata canaries and provenance")

    try put(source + "/hello.txt", "host change\n")
    try check(try store.originalChanges(snapshot.id).count == 1, "original changes detected separately")
    try check(
        try store.review(snapshot.id).changes.first(where: { $0.path == "hello.txt" })?.before == .text("before\n"),
        "private baseline unchanged")
    try expect(.rejected("destination exists or is inaccessible")) {
        try store.exportReviewed(review, toNewDirectory: fixture + "/export")
    }
    try expect(.rejected("source destination")) { try store.exportReviewed(review, toNewDirectory: source) }
    try expect(.rejected("source destination")) { try store.exportReviewed(review, toNewDirectory: source + "/nested") }
    try expect(.rejected("managed destination")) {
        try store.exportReviewed(review, toNewDirectory: snapshot.workingDirectory + "/nested")
    }
    try expect(.rejected("unsupported file type or hard link")) {
        try store.exportReviewed(review, toNewDirectory: fixture + "/alias/nested")
    }
    try expect(.rejected("path component")) {
        try store.exportReviewed(review, toNewDirectory: fixture + "/source/../outside")
    }
    let foreign = try WorkspaceStore(newRoot: fixture + "/foreign")
    try expect(.foreignSnapshot) { _ = try foreign.review(snapshot.id) }
    try expect(.foreignSnapshot) { try foreign.exportReviewed(review, toNewDirectory: fixture + "/foreign-export") }
    try put(snapshot.workingDirectory + "/added.txt", "late edit")
    try expect(.staleReview) { try store.exportReviewed(review, toNewDirectory: fixture + "/stale") }
    try check(!FileManager.default.fileExists(atPath: fixture + "/stale"), "stale review not exported")
    namedPass("original changes, destinations, foreign handle, stale review")

    let negative = fixture + "/negative"
    try mkdir(negative)
    try check(symlink(source + "/hello.txt", negative + "/link") == 0, "link fixture")
    try expect(.rejected("unsupported file type or hard link")) { _ = try store.importTree(from: negative) }
    try FileManager.default.removeItem(atPath: negative + "/link")
    try check(link(source + "/hello.txt", negative + "/hardlink") == 0, "hardlink fixture")
    try expect(.rejected("unsupported file type or hard link")) { _ = try store.importTree(from: negative) }
    try FileManager.default.removeItem(atPath: negative + "/hardlink")
    try check(mkfifo(negative + "/pipe", 0o600) == 0, "FIFO fixture")
    alarm(3)
    try expect(.rejected("unsupported file type or hard link")) { _ = try store.importTree(from: negative) }
    alarm(0)
    try FileManager.default.removeItem(atPath: negative + "/pipe")
    var small = WorkspaceLimits()
    small.fileBytes = 3
    let limited = try WorkspaceStore(newRoot: fixture + "/limited", limits: small)
    try expect(.rejected("byte limit")) { _ = try limited.importTree(from: source) }
    var stopped = false
    let cancellable = try WorkspaceStore(newRoot: fixture + "/cancel", cancelled: { stopped })
    stopped = true
    try expect(.cancelled) { _ = try cancellable.importTree(from: source) }
    namedPass("links, hardlinks, nonblocking FIFO, byte limit, cancellation")

    let changed = fixture + "/changed"
    try mkdir(changed)
    try put(changed + "/file", "initial")
    var changedOnce = false
    let mutating = try WorkspaceStore(
        newRoot: fixture + "/mutating",
        didReadChunk: { _ in
            if !changedOnce {
                changedOnce = true
                try put(changed + "/file", "replacement")
            }
        })
    try expect(.mutated) { _ = try mutating.importTree(from: changed) }
    var replacedOnce = false
    let replacing = try WorkspaceStore(
        newRoot: fixture + "/replacing",
        didReadChunk: { _ in
            if !replacedOnce {
                replacedOnce = true
                try FileManager.default.removeItem(atPath: changed + "/file")
                try check(symlink(source + "/hello.txt", changed + "/file") == 0, "replace fixture")
            }
        })
    try expect(.mutated) { _ = try replacing.importTree(from: changed) }
    namedPass("deterministic mid-read mutation/replacement")
    try additionalChecks(fixture, source)
    try workspaceSearchChecks(fixture)
}

do {
    try run()
    print("TOTAL: \(CheckMetrics.shared.groups) named groups, \(CheckMetrics.shared.assertions) assertions, 0 failures")
} catch let error as WorkspaceError {
    if case .blockedPlatform(let reason) = error {
        print("BLOCKED: \(reason)")
        print("NOT_RUN: remaining checks after platform policy failure")
        exit(78)
    }
    print("FAIL: \(error)")
    exit(1)
} catch {
    print("FAIL: \(error)")
    exit(1)
}
