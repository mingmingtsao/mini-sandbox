import Darwin
import Foundation
import SandboxContracts

@testable import SandboxHost

private struct WorkspaceEffectAudit: SynchronousAuditSink { func append(_ event: SecurityEvent) throws {} }
private final class WorkspaceEffectFixture: @unchecked Sendable {
    let root: String, store: WorkspaceStore, snapshot: WorkspaceSnapshot, quota: WorkspaceGrantQuota
    let task: TaskQuotaLedger, clock: RunClock
    init(
        root: String, store: WorkspaceStore, snapshot: WorkspaceSnapshot, quota: WorkspaceGrantQuota,
        task: TaskQuotaLedger, clock: RunClock
    ) {
        self.root = root
        self.store = store
        self.snapshot = snapshot
        self.quota = quota
        self.task = task
        self.clock = clock
    }
    func trip(_ mode: String) {
        if mode == "stop" {
            quota.handle.lifecycle.terminate(.stopped)
        } else if mode == "cancel" {
            task.cancel()
        } else if mode == "monotonic" {
            clock.set(wall: clock.wall, elapsed: .seconds(600))
        } else {
            clock.advance(600)
        }
    }
    func frozen() throws -> FrozenWorkspaceTransfer {
        let flow = try store.transferFlow(for: snapshot.id)
        for bytes in try WorkspaceTransferWire.messages(["a": Data(repeating: 42, count: 8192)]) {
            try flow.receiver.receive(bytes)
        }
        return try flow.receiver.snapshot()
    }
    var quarantines: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root).filter { $0.hasPrefix("quarantine-") }) ?? []
    }
}
private func deniedWorkspaceEffect(_ operation: () throws -> Void) throws {
    var denied = false
    do { try operation() } catch AuthorizationError.runRevoked { denied = true } catch WorkspaceError.cancelled {
        denied = true
    } catch WorkspaceTransferError.rejected { denied = true }
    try check(denied, "workspace concrete effect unexpectedly accepted")
}
private final class WorkspaceEffectWorker: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var failed = false, timedOut = false
    let transfer: FrozenWorkspaceTransfer
    init(transfer: FrozenWorkspaceTransfer) { self.transfer = transfer }
    func holdAcrossDeadline(_ mutex: NSLock, clock: RunClock) -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        proceed.signal()
        let blocked = done.wait(timeout: .now() + 0.05) == .timedOut
        clock.advance(600)
        return blocked
    }
    func barrier() {
        ready.signal()
        if proceed.wait(timeout: .now() + 5) != .success { lock.withLock { timedOut = true } }
    }
    func record(_ value: Bool) {
        lock.withLock { failed = value }
        done.signal()
    }
}
private func workspaceMutex(_ value: Any, name: String) throws -> NSLock {
    guard let lock = Mirror(reflecting: value).children.first(where: { $0.label == name })?.value as? NSLock else {
        throw NSError(domain: "missing concrete mutex fixture", code: 1)
    }
    return lock
}

@MainActor func workspaceLifecycleChecks(root: String, pass: (String) -> Void) async throws {
    let source = root + "/effect-empty-source"
    try check(mkdir(source, 0o700) == 0, "effect source")
    func make(_ name: String) async throws -> WorkspaceEffectFixture {
        let path = root + "/effect-" + name
        let store = try WorkspaceStore(newRoot: path)
        let snapshot = try store.importTree(from: source)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = RunClock.manual(wall: now, elapsed: .zero)
        let authority = RunAuthorizationController(auditSink: WorkspaceEffectAudit(), clock: clock)
        let grant = try RunGrant(
            runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(600),
            workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "workspace-effect-fixture",
            workspaceSnapshotID: snapshot.id.grantSnapshotID, policyDigest: String(repeating: "b", count: 64),
            approvalSnapshotID: UUID(),
            connections: [], explicitDenies: [],
            resourceLimits: ResourceLimits(
                cpuCount: 1, memoryBytes: 65536, diskBytes: 65536, messageBytes: 16384, concurrentRequests: 2))
        let handle = try await authority.install(grant: grant)
        let quota = try await WorkspaceGrantQuota.authenticated(authority: authority, handle: handle, grant: grant)
        try store.bindTransferQuota(quota, for: snapshot.id)
        let task = try store.createTransferTask(
            for: snapshot.id,
            limits: WorkspaceTaskLimits(retainedPayloadBytes: 65536, diskBytes: 65536, cumulativeInputBytes: 65536))
        return WorkspaceEffectFixture(
            root: path, store: store, snapshot: snapshot, quota: quota, task: task, clock: clock)
    }
    for mode in ["stop", "expiry", "monotonic", "cancel"] {
        let f = try await make("receive-" + mode)
        let flow = try f.store.transferFlow(for: f.snapshot.id)
        let messages = try WorkspaceTransferWire.messages(["a": Data(repeating: 42, count: 8192)])
        try flow.receiver.receive(messages[0])
        try flow.receiver.receive(messages[1])
        flow.receiver.beforeInputEffect = { f.trip(mode) }
        try deniedWorkspaceEffect { try flow.receiver.receive(messages[2]) }
        try check(
            flow.receiver.acceptedBytes == 0 && !flow.completed && flow.receiver.poisoned,
            "revoked receiver adopted chunk or completion")
        try check(
            f.task.memory.metrics.used == 0 && f.task.memory.metrics.reserved == 0
                && f.task.memory.metrics.accepted == 0,
            "revoked prepared receiver bytes not released exactly")
        print("MEASURE workspace-receive-\(mode) accepted=0 reserved=0 complete=false")
        pass("S01 receiver final gate " + mode)
    }
    for stage in ["write", "partial", "adopt"] {
        for mode in ["stop", "expiry", "cancel"] {
            let f = try await make(stage + "-" + mode)
            let frozen = try f.frozen()
            if stage == "write" { f.store.beforeTransferWrite = { f.trip(mode) } }
            if stage == "partial" { f.store.didWriteTransferChunk = { _ in f.trip(mode) } }
            if stage == "adopt" { f.store.beforeTransferAdoption = { f.trip(mode) } }
            try deniedWorkspaceEffect { _ = try f.store.acceptTransfer(frozen, for: f.snapshot.id) }
            let expected = stage == "write" ? 0 : stage == "partial" ? 4096 : 8192
            let metrics = f.task.disk.metrics
            try check(
                metrics.accepted == expected && metrics.used == 0 && metrics.reserved == 0 && metrics.committed == 0,
                "revoked write/adoption actual accounting")
            try check(
                f.quarantines.isEmpty
                    && (try FileManager.default.contentsOfDirectory(atPath: f.snapshot.workingDirectory)).isEmpty,
                "rejected adoption changed actual working tree")
            if mode == "expiry" {
                f.clock.advance(-600)
                try deniedWorkspaceEffect { _ = try f.store.acceptTransfer(frozen, for: f.snapshot.id) }
                try check(f.quota.handle.lifecycle.currentStatus == .expired, "wall rollback revived expired workspace")
            }
            print("MEASURE workspace-\(stage)-\(mode) actual_written=\(metrics.accepted) committed=0 quarantine=0")
            pass("S01 " + stage + " final gate " + mode)
        }
    }
    for mode in ["stop", "expiry", "cancel"] {
        for first in [false, true] {
            let f = try await make("rename-" + mode + "-" + String(first))
            let frozen = try f.frozen()
            _ = try f.store.acceptTransfer(frozen, for: f.snapshot.id)
            let review = try f.store.review(f.snapshot.id)
            let destination = root + "/effect-publish-" + UUID().uuidString
            f.store.exportBoundary = { boundary in
                if boundary == (first ? .afterRename : .beforeRename) { f.trip(mode) }
            }
            if first {
                try f.store.exportReviewed(review, toNewDirectory: destination)
            } else {
                try deniedWorkspaceEffect { try f.store.exportReviewed(review, toNewDirectory: destination) }
            }
            let m = f.task.disk.metrics
            try check(
                FileManager.default.fileExists(atPath: destination) == first && m.committed == (first ? 16384 : 8192),
                "rename/terminal ordering mismatched real publication")
            try check(m.used == 0 && m.reserved == 0, "rename temporary accounting not settled")
            f.store.exportBoundary = nil
            if mode != "cancel" {
                try deniedWorkspaceEffect { try f.store.exportReviewed(review, toNewDirectory: destination + "-old") }
                try f.store.exportReviewedAfterStop(
                    review, toNewDirectory: destination + "-new-action",
                    actionCancellation: WorkspaceExportCancellation())
                try check(
                    try Data(contentsOf: URL(fileURLWithPath: destination + "-new-action/a")) == frozen.files["a"],
                    "fresh host action lost immutable bytes")
                try deniedWorkspaceEffect { _ = try f.store.transferFlow(for: f.snapshot.id) }
            }
            print("MEASURE workspace-rename-\(mode) commit_first=\(first) published=\(first) committed=\(m.committed)")
            pass("S01 rename ordering " + mode + " " + String(first))
        }
    }
    // Deliberately hold real app mutexes across the exact deadline. The test
    // never blocks a clock provider or injects a callback under the final fence.
    for owner in ["lifecycle", "workflow"] {
        let f = try await make("lock-" + owner)
        let frozen = try f.frozen()
        let worker = WorkspaceEffectWorker(transfer: frozen)
        f.store.beforeTransferWrite = { worker.barrier() }
        DispatchQueue.global().async {
            do {
                _ = try f.store.acceptTransfer(worker.transfer, for: f.snapshot.id)
                worker.record(false)
            } catch AuthorizationError.runRevoked { worker.record(true) } catch { worker.record(false) }
        }
        try check(worker.ready.wait(timeout: .now() + 5) == .success, "writer preparation barrier")
        let mutex = try workspaceMutex(
            owner == "lifecycle" ? f.quota.handle.lifecycle as Any : f.task.workflow.gate as Any, name: "lock")
        let blocked = worker.holdAcrossDeadline(mutex, clock: f.clock)
        try check(worker.done.wait(timeout: .now() + 5) == .success, "writer wait settled")
        try check(
            worker.lock.withLock { worker.failed && !worker.timedOut } && blocked, "actual owner contention missing")
        try check(
            f.task.disk.metrics.accepted == 0 && f.quarantines.isEmpty
                && f.quota.handle.lifecycle.currentStatus == .expired,
            "lock wait reused stale file permission")
        print("MEASURE workspace-lock-\(owner) exact_expiry=true actual_written=0 quarantine=0")
        pass("S01 concrete writer waits across deadline " + owner)
    }
}
