import Foundation
import Darwin

/// Installed host provenance, never an execution permit. The quota registry
/// binds one actual handle/snapshot to one store and workflow generation.
final class WorkspaceRunBinding: @unchecked Sendable {
    let handle: HostRunHandle
    let epoch: UInt64
    let notBefore: Date
    let snapshot: WorkspaceSnapshotID
    let storeOwner: UUID
    let workflowOwner: UUID
    let workflowGeneration: UInt64
    init(handle: HostRunHandle, notBefore: Date, snapshot: WorkspaceSnapshotID, storeOwner: UUID,
         workflow: WorkspaceWorkflowBinding) {
        self.handle = handle; epoch = handle.installedEpoch; self.notBefore = notBefore; self.snapshot = snapshot
        self.storeOwner = storeOwner; workflowOwner = workflow.owner
        workflowGeneration = workflow.generation
    }
    func matches(_ binding: WorkspaceWorkflowBinding) -> Bool {
        binding.run === self && binding.owner == workflowOwner && binding.generation == workflowGeneration
    }
}

/// Closed, synchronous concrete effects. Preparation/path checks/hashing and
/// accounting are outside the lifecycle fence. No user closure or reusable token
/// can be inserted here. Every retry enters this same owner → workflow → run order.
enum WorkspacePreparedEffect {
    case receive(WorkspaceTransferReceiver, Data)
    case snapshot(WorkspaceTransferReceiver)
    case create(WorkspaceStore, WorkspaceWorkflowBinding, WorkspaceFD, String, directory: Bool)
    case write(WorkspaceStore, WorkspaceWorkflowBinding, WorkspaceFD, UnsafeRawPointer, Int)
    case adopt(WorkspacePreparedAdoption)
    case publish(WorkspaceStore, WorkspaceWorkflowBinding, WorkspaceFD, String, String, String, String)
    case validate(WorkspaceWorkflowBinding)

    enum Result {
        case none
        case syscall(Int, Int32)
        case snapshot(FrozenWorkspaceTransfer)
    }
    var workflow: WorkspaceWorkflowBinding {
        switch self {
        case .receive(let receiver, _), .snapshot(let receiver): return receiver.effectWorkflow
        case .create(_, let binding, _, _, _), .write(_, let binding, _, _, _),
             .publish(_, let binding, _, _, _, _, _), .validate(let binding): return binding
        case .adopt(let adoption): return adoption.workflow
        }
    }
    func acquire() {
        switch self {
        case .receive(let receiver, _), .snapshot(let receiver): receiver.acquireEffect()
        case .create(let store, _, _, _, _), .write(let store, _, _, _, _),
             .publish(let store, _, _, _, _, _, _): store.acquireEffect()
        case .adopt(let adoption): adoption.acquire()
        case .validate: break
        }
    }
    func prepare() throws {
        switch self {
        case .receive(let receiver, let bytes): try receiver.prepareEffectLocked(bytes)
        case .snapshot(let receiver): try receiver.prepareSnapshotLocked()
        case .create(_, _, _, let name, _): try WorkspaceStore.component(name)
        case .write(_, _, _, _, let count): guard (1...4096).contains(count) else { throw WorkspaceTransferError.rejected }
        case .adopt(let adoption): try adoption.prepare()
        case .publish(_, _, _, let stage, let name, let reviewed, let actual):
            try WorkspaceStore.component(stage); try WorkspaceStore.component(name)
            guard reviewed == actual else { throw WorkspaceError.staleReview }
        case .validate: break
        }
    }
    func validateOwner() throws {
        switch self {
        case .receive(let receiver, _), .snapshot(let receiver): try receiver.validateEffectLocked()
        case .create(let store, let binding, _, _, _), .write(let store, let binding, _, _, _),
             .publish(let store, let binding, _, _, _, _, _): try store.validateEffectLocked(binding)
        case .adopt(let adoption): try adoption.validateOwner()
        case .validate: break
        }
    }
    func commitLocked() throws -> Result {
        switch self {
        case .receive(let receiver, _): try receiver.commitEffectLocked(); return .none
        case .snapshot(let receiver): return .snapshot(try receiver.snapshotEffectLocked())
        case .create(_, _, let parent, let name, let directory):
            let result: Int32
            if directory { result = mkdirat(parent.value, name, 0o700) }
            else { result = openat(parent.value, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600) }
            return .syscall(Int(result), result < 0 ? errno : 0)
        case .write(_, _, let file, let bytes, let count):
            let result = Darwin.write(file.value, bytes, count)
            return .syscall(result, result < 0 ? errno : 0)
        case .adopt(let adoption): try adoption.commitLocked(); return .none
        case .publish(_, _, let parent, let stage, let name, _, _):
            guard renameatx_np(parent.value, stage, parent.value, name, UInt32(RENAME_EXCL)) == 0 else {
                throw WorkspaceError.io("exclusive export rename", errno)
            }
            return .none
        case .validate: return .none
        }
    }
    func settle() {
        if case .receive(let receiver, _) = self { receiver.settleEffectLocked() }
    }
    func release() {
        switch self {
        case .receive(let receiver, _), .snapshot(let receiver): receiver.releaseEffect()
        case .create(let store, _, _, _, _), .write(let store, _, _, _, _),
             .publish(let store, _, _, _, _, _, _): store.releaseEffect()
        case .adopt(let adoption): adoption.release()
        case .validate: break
        }
    }
    @discardableResult func perform() throws -> Result {
        if let run = workflow.run { return try run.handle.lifecycle.acceptWorkspaceEffect(self) }
        // Unbound import/diagnostic actions and explicitly NEW post-Stop exports
        // use only their own host-action cancellation, never resurrect a run.
        acquire(); defer { release() }
        try prepare()
        workflow.gate.acquireEffect(); defer { workflow.gate.releaseEffect() }
        try workflow.gate.validateLocked(workflow)
        try validateOwner()
        try Task.checkCancellation()
        let result = try commitLocked()
        settle()
        return result
    }
}
