import Darwin
import Foundation
import SandboxHost

/// POSIX permission behavior on owned fixtures, not a TCC/NSOpenPanel verdict.
func workspaceSearchChecks(_ fixture: String) throws {
    let container = fixture + "/search-only"
    try mkdir(container)
    let ancestor = container + "/ancestor"
    let source = ancestor + "/selected"
    try mkdir(ancestor)
    try mkdir(source)
    try put(source + "/file", "selected content\n")
    defer { _ = chmod(ancestor, 0o700) }
    try check(chmod(ancestor, 0o300) == 0, "search/write-only ancestor fixture")
    let common = O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
    errno = 0
    let ordinary = open(ancestor, O_RDONLY | common)
    let readFailure = errno
    if ordinary >= 0 { close(ordinary) }
    try check(ordinary < 0 && readFailure == EACCES, "fixture really denies ancestor directory read")
    let searching = open(ancestor, O_SEARCH | common)
    try check(searching >= 0, "search-only descriptor opens")
    defer { close(searching) }
    var metadata = stat()
    var named = stat()
    try check(
        fstat(searching, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR && metadata.st_uid == geteuid()
            && metadata.st_mode & 0o777 == 0o300, "search fstat owner/type/mode")
    try check(fcntl(searching, F_GETFD) & FD_CLOEXEC != 0, "search descriptor close-on-exec")
    try check(fstatat(searching, "selected", &named, AT_SYMLINK_NOFOLLOW) == 0, "relative nofollow metadata")
    let selected = openat(searching, "selected", O_RDONLY | common)
    try check(selected >= 0, "selected tree still opens for reading")
    defer { close(selected) }
    try check(
        fstat(selected, &metadata) == 0 && metadata.st_dev == named.st_dev && metadata.st_ino == named.st_ino,
        "selected descriptor identity equals relative metadata")
    namedPass("search-only ancestor POSIX semantics and selected read identity")

    // The destination parent itself needs search/write, never directory listing.
    let store = try WorkspaceStore(newRoot: ancestor + "/managed")
    let snapshot = try store.importTree(from: source)
    try put(snapshot.workingDirectory + "/file", "reviewed content\n")
    let review = try store.review(snapshot.id)
    try store.exportReviewed(review, toNewDirectory: ancestor + "/export")
    try check(
        try contents(source + "/file") == "selected content\n"
            && contents(ancestor + "/export/file") == "reviewed content\n",
        "search-only import review export preserves original")
    var unchanged = stat()
    try check(
        fstat(searching, &unchanged) == 0 && unchanged.st_mode & 0o777 == 0o300,
        "product does not broaden ancestor permissions")
    namedPass("search-only ancestor supports real import review and exclusive export")

    let unreadable = ancestor + "/unreadable"
    try mkdir(unreadable)
    try put(unreadable + "/file", "private")
    defer { _ = chmod(unreadable, 0o700) }
    try check(chmod(unreadable, 0o100) == 0, "unreadable selected tree fixture")
    try expect(.io("open", EACCES)) { _ = try store.importTree(from: unreadable) }
    namedPass("final selected tree still requires directory read permission")

    let privateFile = ancestor + "/private-file"
    try mkdir(privateFile)
    try put(privateFile + "/file", "private")
    defer { _ = chmod(privateFile + "/file", 0o600) }
    try check(chmod(privateFile + "/file", 0o000) == 0, "unreadable file fixture")
    try expect(.io("open", EACCES)) { _ = try store.importTree(from: privateFile) }
    namedPass("selected file data still requires normal read permission")

    let noSearch = container + "/no-search"
    try mkdir(noSearch)
    try mkdir(noSearch + "/selected")
    defer { _ = chmod(noSearch, 0o700) }
    try check(chmod(noSearch, 0o400) == 0, "read-only no-search ancestor fixture")
    try expect(.io("open", EACCES)) { _ = try store.importTree(from: noSearch + "/selected") }
    namedPass("ancestor search permission denial remains enforced")

    try check(symlink(source, ancestor + "/link") == 0, "search-path symlink fixture")
    try expect(.rejected("unsupported file type or hard link")) { _ = try store.importTree(from: ancestor + "/link") }
    try expect(.rejected("unsupported file type or hard link")) {
        _ = try WorkspaceStore(newRoot: ancestor + "/link/managed")
    }
    namedPass("search-only traversal rejects final and intermediate symlinks")

    let moving = container + "/moving"
    try mkdir(moving)
    try mkdir(moving + "/selected")
    try put(moving + "/selected/file", "unchanged")
    var fired = false
    defer {
        _ = chmod(moving, 0o700)
        _ = chmod(moving + "-old", 0o700)
    }
    try check(chmod(moving, 0o100) == 0, "relocation search-only ancestor")
    let movingStore = try WorkspaceStore(
        newRoot: container + "/moving-store",
        didReadChunk: { _ in
            if !fired {
                fired = true
                try FileManager.default.moveItem(atPath: moving, toPath: moving + "-old")
                try mkdir(moving)
            }
        })
    try expect(.mutated) { _ = try movingStore.importTree(from: moving + "/selected") }
    try check(fired, "search-only ancestor relocated during actual content read")
    namedPass("search-only descriptor traversal retains namespace revalidation")
}
