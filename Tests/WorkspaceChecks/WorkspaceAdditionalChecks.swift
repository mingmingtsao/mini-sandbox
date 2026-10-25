import Darwin
import Foundation

@testable import SandboxHost

func expect(_ expected: WorkspaceError, _ operation: () throws -> Void) throws {
    do { try operation() } catch let error as WorkspaceError {
        try check(error == expected, "expected \(expected), got \(error)")
        return
    }
    throw CheckFailure(message: "expected \(expected), operation succeeded")
}
func additionalChecks(_ fixture: String, _ source: String) throws {
    var passed = 0
    var failed = 0
    func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            namedPass(name)
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }
    for mode: mode_t in [0o770, 0o707] {
        test("untrusted ancestor mode \(mode)") {
            let p = fixture + "/unsafe-\(mode)"
            try mkdir(p)
            try check(chmod(p, mode) == 0, "fixture mode")
            try expect(.rejected("unsafe ancestor permissions")) { _ = try WorkspaceStore(newRoot: p + "/new") }
            try check(!FileManager.default.fileExists(atPath: p + "/new"), "reject before mkdir")
        }
    }
    test("ALLOW ancestor refused") {
        let p = fixture + "/allow"
        try mkdir(p)
        try fixtureACL(p, "everyone allow read")
        try expect(.rejected("unsafe ACL")) { _ = try WorkspaceStore(newRoot: p + "/new") }
        try check(!FileManager.default.fileExists(atPath: p + "/new"), "ACL rejected before mkdir")
    }
    test("DENY-only ancestor permitted unchanged") {
        let p = fixture + "/deny"
        try mkdir(p)
        try fixtureACL(p, "everyone deny delete")
        defer {
            if let empty = acl_init(0) {
                _ = acl_set_file(p, ACL_TYPE_EXTENDED, empty)
                acl_free(UnsafeMutableRawPointer(empty))
            }
        }
        let before = try aclText(p)
        _ = try WorkspaceStore(newRoot: p + "/new")
        try check(try aclText(p) == before, "ancestor ACL untouched")
    }
    test("recorded original pathname remains forbidden after replacement") {
        let p = fixture + "/original-replaced"
        try mkdir(p)
        try put(p + "/f", "original")
        let store = try WorkspaceStore(newRoot: fixture + "/replacement-store")
        let snapshot = try store.importTree(from: p)
        let review = try store.review(snapshot.id)
        try FileManager.default.moveItem(atPath: p, toPath: p + "-old")
        try mkdir(p)
        try expect(.rejected("source destination")) { try store.exportReviewed(review, toNewDirectory: p + "/out") }
        try expect(.mutated) { try store.exportReviewed(review, toNewDirectory: fixture + "/replacement-out") }
    }
    for target in ["managed", "working", "export-parent"] {
        test("observed namespace substitution \(target)") {
            let p = fixture + "/namespace-" + target
            try mkdir(p)
            let managed = p + "/managed"
            let exportParent = p + "/out"
            try mkdir(exportParent)
            var armed = false
            var fired = false
            var working = ""
            let store = try WorkspaceStore(
                newRoot: managed,
                didReadChunk: { _ in
                    if armed && !fired {
                        fired = true
                        let path = target == "managed" ? managed : (target == "working" ? working : exportParent)
                        try FileManager.default.moveItem(atPath: path, toPath: path + "-moved")
                        try mkdir(path)
                    }
                })
            let snapshot = try store.importTree(from: source)
            working = snapshot.workingDirectory
            let review = try store.review(snapshot.id)
            armed = true
            try expect(.mutated) { try store.exportReviewed(review, toNewDirectory: exportParent + "/final") }
            try check(
                fired && !FileManager.default.fileExists(atPath: exportParent + "/final"),
                "substitution observed, no commit")
            try check(
                !FileManager.default.fileExists(atPath: exportParent + "-moved/final"),
                "relocated destination not committed")
        }
    }
    test("new excluded working entry has explicit export error") {
        let store = try WorkspaceStore(newRoot: fixture + "/excluded-store")
        let s = try store.importTree(from: source)
        try put(s.workingDirectory + "/.env", "synthetic secret")
        let review = try store.review(s.id)
        try check(review.exclusions == [".env"], "excluded name reported")
        try expect(.rejected("excluded working entries require selection")) {
            try store.exportReviewed(review, toNewDirectory: fixture + "/excluded-out")
        }
        try check(!FileManager.default.fileExists(atPath: fixture + "/excluded-out"), "excluded tree not committed")
    }
    for collision in [false, true] {
        test(
            collision
                ? "concurrent destination creation preserved"
                : "cancellation during export retains no final destination"
        ) {
            let p = fixture + (collision ? "/collision" : "/export-cancel")
            try mkdir(p)
            var armed = false
            var stopped = false
            var fired = false
            let destination = p + "/final"
            let store = try WorkspaceStore(
                newRoot: p + "/managed", cancelled: { stopped },
                didReadChunk: { _ in
                    if try armed && !fired
                        && FileManager.default.contentsOfDirectory(atPath: p).contains(where: {
                            $0.hasPrefix(".workspace-stage-")
                        })
                    {
                        fired = true
                        if collision {
                            try mkdir(destination)
                            try put(destination + "/foreign", "must survive")
                        } else {
                            stopped = true
                        }
                    }
                })
            let s = try store.importTree(from: source)
            let review = try store.review(s.id)
            armed = true
            try expect(collision ? .io("exclusive export rename", EEXIST) : .cancelled) {
                try store.exportReviewed(review, toNewDirectory: destination)
            }
            try check(fired, "failure injected after staging began")
            if collision {
                try check(try contents(destination + "/foreign") == "must survive", "unknown collision untouched")
            } else {
                try check(!FileManager.default.fileExists(atPath: destination), "cancel never committed")
            }
        }
    }
    test("filesystem socket rejected before content open") {
        let p = fixture + "/socket-source"
        try mkdir(p)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        try check(socketFD >= 0, "socket fixture")
        defer { close(socketFD) }
        let old = FileManager.default.currentDirectoryPath
        try check(FileManager.default.changeCurrentDirectoryPath(p), "socket fixture cwd")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { ptr in
            _ = "sock".withCString { memcpy(ptr, $0, 5) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try check(FileManager.default.changeCurrentDirectoryPath(old), "restore cwd")
        try check(result == 0, "bind synthetic socket")
        let store = try WorkspaceStore(newRoot: fixture + "/socket-store")
        try expect(.rejected("unsupported file type or hard link")) { _ = try store.importTree(from: p) }
    }
    test("device branch via production stat classifier, no device created") {
        for type: mode_t in [S_IFCHR, S_IFBLK] {
            var s = stat()
            s.st_mode = type | 0o600
            s.st_nlink = 1
            try expect(.rejected("unsupported file type or hard link")) { try WorkspaceStore.checkNodeType(s) }
        }
        var regular = stat()
        regular.st_mode = S_IFREG | 0o600
        regular.st_nlink = 1
        try WorkspaceStore.checkNodeType(regular)
    }
    for bound in ["count", "depth", "path", "aggregate"] {
        test("bounded scan \(bound)") {
            let p = fixture + "/bound-" + bound
            try mkdir(p)
            var limits = WorkspaceLimits()
            let expected: String
            switch bound {
            case "count":
                limits.entries = 1
                try put(p + "/a", "a")
                try put(p + "/b", "b")
                expected = "entry limit"
            case "depth":
                limits.depth = 1
                try mkdir(p + "/a")
                try mkdir(p + "/a/b")
                expected = "depth limit"
            case "path":
                limits.pathBytes = 1
                try put(p + "/long", "a")
                expected = "path limit"
            default:
                limits.totalBytes = 5
                limits.fileBytes = 4
                try put(p + "/a", "aaa")
                try put(p + "/b", "bbb")
                expected = "byte limit"
            }
            let store = try WorkspaceStore(newRoot: p + "-managed", limits: limits)
            try expect(.rejected(expected)) { _ = try store.importTree(from: p) }
        }
    }
    test("new exclusion arriving during export has explicit error") {
        let p = fixture + "/late-exclusion"
        try mkdir(p)
        var armed = false
        var fired = false
        var work = ""
        let store = try WorkspaceStore(
            newRoot: p + "/managed",
            didReadChunk: { _ in
                if try armed && !fired
                    && FileManager.default.contentsOfDirectory(atPath: p).contains(where: {
                        $0.hasPrefix(".workspace-stage-")
                    })
                {
                    fired = true
                    try put(work + "/.env", "synthetic")
                }
            })
        let s = try store.importTree(from: source)
        work = s.workingDirectory
        let review = try store.review(s.id)
        armed = true
        try expect(.rejected("excluded working entries require selection")) {
            try store.exportReviewed(review, toNewDirectory: p + "/final")
        }
        try check(fired && !FileManager.default.fileExists(atPath: p + "/final"), "late exclusion never committed")
    }
    test("canonical collisions refused by filesystem and production name classifier") {
        let p = fixture + "/canonical"
        try mkdir(p)
        let fd = open(p + "/case", O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try check(fd >= 0, "first canonical fixture")
        close(fd)
        let other = open(p + "/CASE", O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if other >= 0 {
            close(other)
            let store = try WorkspaceStore(newRoot: p + "-managed")
            try expect(.rejected("canonical collision")) { _ = try store.importTree(from: p) }
        } else {
            try check(errno == EEXIST, "case-insensitive filesystem collision")
        }
        var names = Set<String>()
        try WorkspaceStore.registerName("case", in: &names)
        try expect(.rejected("canonical collision")) { try WorkspaceStore.registerName("CASE", in: &names) }
    }
    test("source exclusions never opened, included content exports") {
        let p = fixture + "/exclusions"
        try mkdir(p)
        try put(p + "/included", "safe")
        try check(mkfifo(p + "/.env", 0o000) == 0, "excluded FIFO")
        try mkdir(p + "/.git")
        try put(p + "/.git/hook", "do not inspect")
        try check(chmod(p + "/.git", 0o000) == 0, "excluded inaccessible directory")
        var reads: [String] = []
        let store = try WorkspaceStore(newRoot: p + "-managed", didReadChunk: { reads.append($0) })
        let s = try store.importTree(from: p)
        try check(s.exclusions == [".env", ".git"], "exclusions reported")
        try check(!reads.isEmpty && reads.allSatisfy { $0 == "included" }, "excluded content never read")
        try store.exportReviewed(store.review(s.id), toNewDirectory: p + "-out")
        try check(try contents(p + "-out/included") == "safe", "included export with source exclusions")
    }
    test("binary and oversized previews explicit, guest content never executed") {
        let p = fixture + "/previews"
        try mkdir(p)
        try put(p + "/text", "before")
        let store = try WorkspaceStore(newRoot: p + "-managed")
        let s = try store.importTree(from: p)
        try put(s.workingDirectory + "/text", "after")
        try Data([0, 255]).write(to: URL(fileURLWithPath: s.workingDirectory + "/binary"))
        try put(s.workingDirectory + "/big", String(repeating: "x", count: 4097))
        let marker = p + "/executed"
        let script = "#!/bin/sh\ntouch '" + marker + "'\n"
        try put(s.workingDirectory + "/guest.sh", script)
        try check(chmod(s.workingDirectory + "/guest.sh", 0o755) == 0, "guest executable fixture")
        let review = try store.review(s.id)
        try check(
            review.changes.first { $0.path == "binary" }?.after == .noPreview("binary or non-text UTF-8"),
            "binary label")
        try check(review.changes.first { $0.path == "big" }?.after == .noPreview("oversized"), "oversized label")
        try check(review.changes.first { $0.path == "text" }?.after == .text("after"), "text label")
        try store.exportReviewed(review, toNewDirectory: p + "-out")
        try check(!FileManager.default.fileExists(atPath: marker), "guest script never executed")
        try check(
            try contents(p + "-out/guest.sh") == script && contents(p + "/text") == "before",
            "data-only export and original preserved")
        var st = stat()
        try check(lstat(p + "-out/guest.sh", &st) == 0 && st.st_mode & 0o777 == 0o600, "execution bits stripped")
    }
    test("originalChanges revalidates ancestor namespace after scan") {
        let p = fixture + "/original-parent"
        try mkdir(p)
        try mkdir(p + "/source")
        try put(p + "/source/f", "unchanged")
        var armed = false
        var fired = false
        let store = try WorkspaceStore(
            newRoot: fixture + "/original-parent-store",
            didReadChunk: { _ in
                if armed && !fired {
                    fired = true
                    try FileManager.default.moveItem(atPath: p, toPath: p + "-moved")
                    try mkdir(p)
                }
            })
        let s = try store.importTree(from: p + "/source")
        armed = true
        try expect(.mutated) { _ = try store.originalChanges(s.id) }
        try check(fired, "ancestor relocation injected")
    }
    print("ADDITIONAL TOTAL: \(passed) passed, \(failed) failed")
    try check(failed == 0, "additional test failures")
}
