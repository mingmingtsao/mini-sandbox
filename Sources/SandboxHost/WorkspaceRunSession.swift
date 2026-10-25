import Foundation
import SandboxContracts

/// Owns one imported host store/snapshot after the caller transfers exclusive
/// access to it. Product code gets this closed facade, never an unbound receiver,
/// raw file writer, transferable execution permit or guest-selected snapshot.
package final class WorkspaceRunSession: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let store: WorkspaceStore
    private let snapshot: WorkspaceSnapshot
    private let quota: WorkspaceGrantQuota
    private let task: TaskQuotaLedger
    private var runtimeID: UUID?
    private var flow: WorkspaceTransferFlow?
    private var adopted = false
    private var capturedReview: WorkspaceReview?
    package let handle: HostRunHandle
    package var snapshotID: UUID { snapshot.id.grantSnapshotID }

    private init(store: WorkspaceStore, snapshot: WorkspaceSnapshot, quota: WorkspaceGrantQuota, task: TaskQuotaLedger)
    {
        self.store = store
        self.snapshot = snapshot
        self.quota = quota
        self.task = task
        handle = quota.handle
    }
    package static func bind(
        store: WorkspaceStore, snapshot: WorkspaceSnapshot,
        authority: RunAuthorizationController, handle: HostRunHandle, grant: RunGrant,
        limits: WorkspaceTaskLimits
    ) throws -> WorkspaceRunSession {
        guard snapshot.id.grantSnapshotID == grant.workspaceSnapshotID else { throw WorkspaceError.foreignSnapshot }
        let quota = try WorkspaceGrantQuota.authenticatedForSession(authority: authority, handle: handle, grant: grant)
        try store.bindTransferQuota(quota, for: snapshot.id)
        let task = try store.createTransferTask(for: snapshot.id, limits: limits)
        return WorkspaceRunSession(store: store, snapshot: snapshot, quota: quota, task: task)
    }
    package func prepareTransfer(runtimeID: UUID) throws {
        try lock.withLock {
            guard self.runtimeID == nil, flow == nil, !adopted else { throw WorkspaceTransferError.rejected }
            let flow = try store.transferFlow(for: snapshot.id)
            self.runtimeID = runtimeID
            self.flow = flow
        }
    }
    /// Input bytes belong to the caller's verified VZ connection. Every received
    /// state/chunk is adopted through this task's own workflow + run fence. The
    /// returned outbound frame still requires the VM owner's final send fence.
    package func receive(_ bytes: Data) throws -> Data? {
        try lock.withLock {
            guard let flow, !adopted else { throw WorkspaceTransferError.rejected }
            return try flow.receive(bytes)
        }
    }
    package var transferCompleted: Bool { lock.withLock { flow?.completed == true } }
    package var messageBytes: Int { task.messageBytes }
    package func sealAndAdopt(after stopped: BusinessVMStopReport) throws -> WorkspaceReview {
        try lock.withLock {
            guard !adopted, let runtimeID, stopped.runtimeID == runtimeID,
                stopped.runID == handle.runID, stopped.epoch == handle.installedEpoch,
                stopped.actualStopped, stopped.callbacksSettled,
                let flow, flow.completed
            else { throw WorkspaceTransferError.rejected }
            let result = try flow.receiver.snapshot()
            _ = try store.acceptTransfer(result, for: snapshot.id)
            adopted = true
            let review = try store.review(snapshot.id)
            capturedReview = review
            flow.receiver.stop()
            self.flow = nil
            return review
        }
    }
    package func review() throws -> WorkspaceReview {
        try lock.withLock {
            guard adopted, let capturedReview else { throw WorkspaceTransferError.rejected }
            return capturedReview
        }
    }
    package func exportReviewed(_ review: WorkspaceReview, toNewDirectory destination: String) throws {
        try lock.withLock {
            guard adopted else { throw WorkspaceTransferError.rejected }
            try store.exportReviewed(review, toNewDirectory: destination)
        }
    }
    package func exportReviewedAfterStop(
        _ review: WorkspaceReview, toNewDirectory destination: String,
        actionCancellation: WorkspaceExportCancellation
    ) throws {
        try lock.withLock {
            guard adopted else { throw WorkspaceTransferError.rejected }
            try store.exportReviewedAfterStop(
                review, toNewDirectory: destination, actionCancellation: actionCancellation)
        }
    }
    /// The cancellation latch is independent of potentially long preparation or
    /// fsync work. Late settlement cannot restore it or release capacity twice.
    package func cancel() {
        handle.lifecycle.terminate(.stopped)
        task.cancel()
    }
    /// Call after the owned transfer callback/task has ended. This releases only
    /// the receiver's retained bytes, never committed or orphaned disk charges.
    package func discardTransfer() {
        lock.withLock {
            flow?.receiver.stop()
            flow = nil
        }
    }
}
