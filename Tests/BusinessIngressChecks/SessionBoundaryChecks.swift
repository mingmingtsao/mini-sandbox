import Darwin
import Foundation
import SandboxContracts

@testable import SandboxHost

private func refuses(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch is WorkspaceTransferError { return } catch is WorkspaceError {
        return
    } catch is AuthorizationError { return }
    throw CheckFailure.failed(label)
}

func workspaceSessionBoundaryChecks() async throws {
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("session-boundaries-" + UUID().uuidString)
    try FileManager.default.createDirectory(
        at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard let canonical = realpath(temporary.path, nil) else { throw CheckFailure.failed("canonical test root") }
    let root = URL(fileURLWithPath: String(cString: canonical))
    free(canonical)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(
        at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let original = Data("host original\n".utf8)
    try original.write(to: source.appendingPathComponent("a.txt"))
    for mode in ["complete", "cancel", "discard", "foreign"] {
        let store = try WorkspaceStore(newRoot: root.appendingPathComponent(mode).path)
        let snapshot = try store.importTree(from: source.path)
        let authority = RunAuthorizationController(auditSink: Audit())
        let now = Date()
        let grant = try RunGrant(
            runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
            workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "session-boundary-check",
            workspaceSnapshotID: mode == "foreign" ? UUID() : snapshot.id.grantSnapshotID,
            policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [],
            explicitDenies: [],
            resourceLimits: ResourceLimits(
                cpuCount: 1, memoryBytes: 65_536, diskBytes: 65_536, messageBytes: 16_384, concurrentRequests: 1))
        let handle = try await authority.install(grant: grant)
        let limits = WorkspaceTaskLimits(retainedPayloadBytes: 65_536, diskBytes: 65_536, cumulativeInputBytes: 65_536)
        if mode == "foreign" {
            try refuses("foreign snapshot bound") {
                _ = try WorkspaceRunSession.bind(
                    store: store, snapshot: snapshot, authority: authority, handle: handle, grant: grant, limits: limits
                )
            }
            continue
        }
        let session = try WorkspaceRunSession.bind(
            store: store, snapshot: snapshot, authority: authority, handle: handle, grant: grant, limits: limits)
        try check(
            session.snapshotID == snapshot.id.grantSnapshotID && session.messageBytes == 16_384
                && !session.transferCompleted, "bound session identity and quota")
        let ready = Data(#"{"v":1,"type":"ready"}"#.utf8)
        try refuses("receive before preparation") { _ = try session.receive(ready) }
        try refuses("review before actual VM stop") { _ = try session.review() }
        try session.prepareTransfer(runtimeID: UUID())
        try refuses("duplicate transfer preparation") { try session.prepareTransfer(runtimeID: UUID()) }
        if mode == "cancel" || mode == "discard" {
            if mode == "cancel" {
                session.cancel()
                session.cancel()
            } else {
                session.discardTransfer()
                session.discardTransfer()
            }
            try refuses("terminated session accepted bytes") { _ = try session.receive(ready) }
            try check(!session.transferCompleted, "termination manufactured completion")
            session.discardTransfer()
            continue
        }
        let outbound = try WorkspaceTransferWire.messages(["a.txt": original])
        var next = try session.receive(ready)
        for (index, expected) in outbound.enumerated() {
            try check(next == expected, "actual imported bytes and transfer sequence")
            let ack = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "ack", "seq": index])
            next = try session.receive(ack)
        }
        try check(next == nil && !session.transferCompleted, "import acknowledgements are not export completion")
        for frame in try WorkspaceTransferWire.messages(["a.txt": Data("guest result\n".utf8)]) {
            try check(try session.receive(frame) == nil, "result unexpectedly produced outbound data")
        }
        try check(session.transferCompleted, "validated guest transfer did not complete")
        try refuses("complete transfer still requires actual stopped VM") { _ = try session.review() }
        let review = try store.review(snapshot.id)
        let destination = root.appendingPathComponent("must-not-export")
        try refuses("unadopted export") { try session.exportReviewed(review, toNewDirectory: destination.path) }
        try refuses("unadopted fresh action export") {
            try session.exportReviewedAfterStop(
                review, toNewDirectory: destination.path, actionCancellation: WorkspaceExportCancellation())
        }
        try check(!FileManager.default.fileExists(atPath: destination.path), "unadopted result published")
        try check(try Data(contentsOf: source.appendingPathComponent("a.txt")) == original, "source tree changed")
        session.cancel()
        session.discardTransfer()
        try check(!session.transferCompleted, "discard retained completed receiver")
    }
    print("PASS workspace session ownership, transfer handshake, cancellation and real-stop adoption gate")
}

func displayBoundaryChecks(handle: HostRunHandle) throws {
    let runtime = UUID()
    let scope = try handle.lifecycle.runScope(for: handle, epoch: handle.installedEpoch)
    func output() -> BusinessDisplayOutput {
        BusinessDisplayOutput(lifecycle: handle.lifecycle, scope: scope, runtimeID: runtime)
    }
    func invalid(_ operation: () throws -> Void) throws {
        do { try operation() } catch NativeResponseError.invalidEvent { return }
        throw CheckFailure.failed("invalid display event accepted")
    }
    func limited(_ operation: () throws -> Void) throws {
        do { try operation() } catch NativeResponseError.limitExceeded { return }
        throw CheckFailure.failed("display capacity enlarged")
    }
    let bounded = output()
    try check(try !bounded.acceptNext(), "empty output accepted event")
    try invalid { try bounded.enqueue(channel: "control", bytes: Data([65]), runtimeID: runtime) }
    try invalid { try bounded.enqueue(channel: "stdout", bytes: Data(), runtimeID: runtime) }
    try invalid {
        try bounded.enqueue(
            channel: "stdout", bytes: Data(repeating: 65, count: BusinessDisplayOutput.maxChunkBytes + 1),
            runtimeID: runtime)
    }
    for _ in 0..<64 { try bounded.enqueue(channel: "stdout", bytes: Data([65]), runtimeID: runtime) }
    try limited { try bounded.enqueue(channel: "stderr", bytes: Data([66]), runtimeID: runtime) }
    try check(
        bounded.snapshot.queuedEvents == 64 && bounded.snapshot.acceptedBytes == 0, "queue budget failure adopted data")
    bounded.cancel()
    bounded.cancel()
    do {
        _ = try bounded.acceptNext()
        throw CheckFailure.failed("cancelled display accepted")
    } catch is CancellationError {}
    do {
        try bounded.enqueue(channel: "stderr", bytes: Data([66]), runtimeID: runtime)
        throw CheckFailure.failed("cancelled display enqueued")
    } catch is CancellationError {}
    try check(bounded.snapshot.queuedEvents == 0, "cancel retained queued data")
    let total = output()
    for _ in 0..<(BusinessDisplayOutput.maxBytes / BusinessDisplayOutput.maxChunkBytes) {
        try total.enqueue(
            channel: "stderr", bytes: Data(repeating: 66, count: BusinessDisplayOutput.maxChunkBytes),
            runtimeID: runtime)
        try check(try total.acceptNext(), "bounded stderr adoption")
    }
    try limited { try total.enqueue(channel: "stdout", bytes: Data([65]), runtimeID: runtime) }
    try check(
        total.snapshot.acceptedBytes == BusinessDisplayOutput.maxBytes
            && total.snapshot.stderr.utf8.count == BusinessDisplayOutput.maxBytes && total.snapshot.stdout.isEmpty,
        "consumption refunded cumulative output budget")
    let unicode = output()
    for bytes in [Data([0xe4]), Data([0xb8, 0xad]), Data([0, 10, 13, 9, 127])] {
        try unicode.enqueue(channel: "stdout", bytes: bytes, runtimeID: runtime)
        try check(try unicode.acceptNext(), "UTF8 stream adoption")
    }
    try check(
        unicode.snapshot.stdout == "中\\u{00}\n\r\t\\u{7f}" && unicode.snapshot.acceptedEvents == 3,
        "split UTF8 or control display semantics changed")
    print("PASS display queue, cumulative bytes, cancellation, stderr and split UTF8 bounds")
}
