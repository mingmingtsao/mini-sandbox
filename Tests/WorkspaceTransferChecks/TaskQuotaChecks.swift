import Darwin
import Foundation
import SandboxContracts

@testable import SandboxHost

private struct TaskAudit: SynchronousAuditSink { func append(_ event: SecurityEvent) throws {} }

@MainActor func taskQuotaChecks(root: String, pass: (String) -> Void) async throws {
    let authority = RunAuthorizationController(auditSink: TaskAudit())
    let cancelled = WorkspaceExportCancellation()
    let store = try WorkspaceStore(newRoot: root + "/r3-cancel", cancellation: cancelled)
    let snap = try store.importTree(from: root + "/lower-fileBytes/source")
    let quota = try await taskQuota(authority, snap.id)
    try store.bindTransferQuota(quota, for: snap.id)
    let flow = try store.transferFlow(for: snap.id)
    cancelled.cancel()
    var denied = false
    do {
        for message in try WorkspaceTransferWire.messages(["a": Data([1])]) { try flow.receiver.receive(message) }
    } catch WorkspaceTransferError.rejected { denied = true }
    try check(
        denied && flow.receiver.acceptedBytes == 0 && quota.memory.metrics.used == 0,
        "R3 cancelled workspace owner must deny already-created receiver before allocation")
    pass("R3 workflow cancellation binds already-created transfer")

    let cumulativeStore = try WorkspaceStore(newRoot: root + "/r3-cumulative")
    let cumulativeSnap = try cumulativeStore.importTree(from: root + "/lower-fileBytes/source")
    let cumulativeQuota = try await taskQuota(authority, cumulativeSnap.id)
    try cumulativeStore.bindTransferQuota(cumulativeQuota, for: cumulativeSnap.id)
    let caps = WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 8, cumulativeInputBytes: 3)
    let task = try cumulativeStore.createTransferTask(for: cumulativeSnap.id, limits: caps)
    try check(
        try cumulativeStore.createTransferTask(for: cumulativeSnap.id, limits: caps) === task,
        "host task creation is idempotent not reset")
    for amount in [2, 1] {
        let connection = try cumulativeStore.transferFlow(for: cumulativeSnap.id)
        for message in try WorkspaceTransferWire.messages(["a": Data(repeating: 1, count: amount)]) {
            try connection.receiver.receive(message)
        }
        connection.receiver.stop()
    }
    let reconnect = try cumulativeStore.transferFlow(for: cumulativeSnap.id)
    denied = false
    do {
        for message in try WorkspaceTransferWire.messages(["a": Data([1])]) { try reconnect.receiver.receive(message) }
    } catch WorkspaceTransferError.rejected { denied = true }
    try check(
        denied && reconnect.receiver.acceptedBytes == 0 && task.memory.metrics.accepted == 3
            && task.memory.metrics.used == 0 && task.memory.metrics.reserved == 0,
        "cumulative input cannot reset at reconnect")
    pass("R3 cumulative input spans connections reconnects and files")

    let diskStore = try WorkspaceStore(newRoot: root + "/r3-committed")
    let diskSnap = try diskStore.importTree(from: root + "/lower-fileBytes/source")
    let diskQuota = try await taskQuota(authority, diskSnap.id)
    try diskStore.bindTransferQuota(diskQuota, for: diskSnap.id)
    let diskTask = try diskStore.createTransferTask(
        for: diskSnap.id, limits: WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 4, cumulativeInputBytes: 10))
    let diskFlow = try diskStore.transferFlow(for: diskSnap.id)
    for message in try WorkspaceTransferWire.messages(["a": Data([1, 2])]) { try diskFlow.receiver.receive(message) }
    _ = try diskStore.acceptTransfer(diskFlow.receiver.snapshot(), for: diskSnap.id)
    print(
        "MEASURE R3 adopted current=\(diskTask.disk.metrics.used) committed=\(diskTask.disk.metrics.committed) written=\(diskTask.disk.metrics.accepted)"
    )
    fflush(stdout)
    try check(
        diskTask.disk.metrics.committed == 2 && diskTask.disk.metrics.used == 0 && diskTask.disk.metrics.reserved == 0,
        "R3 adopted disk remains committed charged not free headroom")
    let review = try diskStore.review(diskSnap.id)
    try diskStore.exportReviewed(review, toNewDirectory: root + "/r3-committed-export")
    try check(
        diskTask.disk.metrics.committed == 4 && diskTask.disk.metrics.accepted == 4
            && diskTask.disk.metrics.peakUsed == 4, "R3 committed plus staging peak remains within task")
    do {
        try diskStore.exportReviewed(review, toNewDirectory: root + "/r3-over-cap")
        throw NSError(domain: "committed capacity reset", code: 1)
    } catch WorkspaceTransferError.rejected {}
    try check(
        !FileManager.default.fileExists(atPath: root + "/r3-over-cap") && diskTask.disk.metrics.committed == 4,
        "prewrite rejects without releasing committed trees")
    pass("R3 committed disk survives adoption export and repeated transfer")

    let writeCancel = WorkspaceExportCancellation()
    let writeStore = try WorkspaceStore(newRoot: root + "/r3-prewrite", cancellation: writeCancel)
    let writeSnap = try writeStore.importTree(from: root + "/lower-fileBytes/source")
    let writeQuota = try await taskQuota(authority, writeSnap.id)
    try writeStore.bindTransferQuota(writeQuota, for: writeSnap.id)
    let writeTask = try writeStore.createTransferTask(
        for: writeSnap.id, limits: WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 4, cumulativeInputBytes: 4))
    let writeFlow = try writeStore.transferFlow(for: writeSnap.id)
    for message in try WorkspaceTransferWire.messages(["a": Data([1, 2])]) { try writeFlow.receiver.receive(message) }
    let writeFrozen = try writeFlow.receiver.snapshot()
    writeStore.beforeTransferWrite = { writeCancel.cancel() }
    do {
        _ = try writeStore.acceptTransfer(writeFrozen, for: writeSnap.id)
        throw NSError(domain: "cancelled write", code: 1)
    } catch WorkspaceError.cancelled {}
    print("MEASURE R3 prewriteCancelled actualWritten=\(writeTask.disk.metrics.accepted)")
    fflush(stdout)
    try check(
        writeTask.disk.metrics.accepted == 0 && writeTask.disk.metrics.used == 0
            && writeTask.disk.metrics.reserved == 0,
        "R3 cancellation after prewrite validation must prevent concrete write")
    pass("R3 cancellation linearizes at concrete bounded write")

    let reviewStore = try WorkspaceStore(newRoot: root + "/r3-review-owner")
    let reviewSnap = try reviewStore.importTree(from: root + "/lower-fileBytes/source")
    let oldReview = try reviewStore.review(reviewSnap.id)
    let reviewQuota = try await taskQuota(authority, reviewSnap.id)
    try reviewStore.bindTransferQuota(reviewQuota, for: reviewSnap.id)
    _ = try reviewStore.createTransferTask(
        for: reviewSnap.id, limits: WorkspaceTaskLimits(retainedPayloadBytes: 2, diskBytes: 8, cumulativeInputBytes: 4))
    var stale = false
    do {
        try reviewStore.exportReviewed(oldReview, toNewDirectory: root + "/r3-old-review-export")
    } catch WorkspaceError.staleReview { stale = true }
    try check(
        stale && !FileManager.default.fileExists(atPath: root + "/r3-old-review-export"),
        "R3 unbound pre-task review cannot authorize task publication")
    pass("R3 immutable review binds task owner and generation")
    let unownedFiles = ["a": Data([1])]
    let unowned = FrozenWorkspaceTransfer(
        files: unownedFiles, sha256: WorkspaceTransferWire.treeHash(unownedFiles), quota: reviewQuota)
    denied = false
    do { _ = try reviewStore.acceptTransfer(unowned, for: reviewSnap.id) } catch WorkspaceTransferError.rejected {
        denied = true
    }
    try check(
        denied && reviewQuota.task!.disk.metrics.accepted == 0,
        "R3 quota metadata alone cannot manufacture task-owned sealed result")
    pass("R3 frozen result retains exact task workflow provenance")
    try await taskBoundaryChecks(root: root, authority: authority, pass: pass)
}

@MainActor func taskQuota(_ authority: RunAuthorizationController, _ snapshot: WorkspaceSnapshotID) async throws
    -> WorkspaceGrantQuota
{
    let now = Date()
    let grant = try RunGrant(
        runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "task-quota-fixture",
        workspaceSnapshotID: snapshot.grantSnapshotID, policyDigest: String(repeating: "b", count: 64),
        approvalSnapshotID: UUID(), connections: [], explicitDenies: [],
        resourceLimits: ResourceLimits(
            cpuCount: 1, memoryBytes: 1_048_576, diskBytes: 1_048_576, messageBytes: 16384, concurrentRequests: 2))
    let handle = try await authority.install(grant: grant)
    return try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: grant)
}
