import Foundation
import SandboxContracts
import CryptoKit

/// Queue-confined diagnostic protocol with an immutable no-external-connections grant.
/// Production owner is the actual VZVirtioSocketDevice, retained for this VM's lifetime.
public final class VMDiagnosticSession {
    public let lifecycle: RunLifecycle
    private let owner: AnyObject
    public let runID: UUID
    public let epoch: UInt64
    private let workloadDigest: String
    public let grant: RunGrant
    private let grantDigest: String
    private let sink: any SynchronousAuditSink
    private let frameBudget: Int
    private var frames = 0
    private var deadline: TimeInterval?
    private var diagnosticBytes = 0
    public var revoked: Bool { lifecycle.currentStatus != .active }
    public private(set) var rejections: Set<VMProtocolError> = []
    public private(set) var positiveReplies = 0
    public init(owner: AnyObject, runID: UUID, epoch: UInt64, workloadDigest: String, sink: any SynchronousAuditSink, frameBudget: Int = 64, authorityHandle: HostRunHandle? = nil, installedGrant: RunGrant? = nil) throws {
        let clock = RunClock.system(), installed = clock.sample()
        let created = installed.wall
        let policy = Data("diagnostic-v1;cpu=2;memory=536870912;network=0;shares=0;disks=0;port=4050;frames=64;deadline=60".utf8)
        let policyDigest = SHA256.hash(data: policy).map { String(format: "%02x", $0) }.joined()
        // Host-created identifiers refer to this explicit CLI diagnostic request, not model approval.
        // diskBytes is the contract's positive nominal ceiling; no disk device is attached.
        let diagnosticGrant = try RunGrant(runID: runID, epoch: epoch, createdAt: created, expiresAt: created.addingTimeInterval(60), workloadImageDigest: workloadDigest, agentAdapterVersion: "diagnostic-v1", workspaceSnapshotID: UUID(), policyDigest: policyDigest, approvalSnapshotID: UUID(), connections: [], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 2, memoryBytes: 536870912, diskBytes: 1, messageBytes: 4096, concurrentRequests: 1))
        if let installedGrant, let authorityHandle {
            guard authorityHandle.runID == runID,
                  authorityHandle.grantDigest == RunAuthorizationController.grantDigest(for: installedGrant),
                  installedGrant.runID == runID, installedGrant.epoch == epoch,
                  installedGrant.workloadImageDigest == workloadDigest else { throw VMProtocolError.crossContext }
            grant = installedGrant; lifecycle = authorityHandle.lifecycle
        } else {
            guard installedGrant == nil && authorityHandle == nil else { throw VMProtocolError.crossContext }
            grant = diagnosticGrant
            lifecycle = RunLifecycle(expiresAt: grant.expiresAt, epoch: epoch, installedAt: created, clock: clock, installedElapsed: installed.elapsed)
        }
        grantDigest = RunAuthorizationController.grantDigest(for: grant)
        self.owner = owner; self.runID = runID; self.epoch = epoch; self.workloadDigest = workloadDigest; self.sink = sink; self.frameBudget = min(64, max(1, frameBudget))
    }
    func event(_ operation: String, reason: String, origin: EventOrigin = .hostEnforcement, decision: EventDecision = .observe, outcome: DispatchOutcome = .notDispatched) throws {
        let observation = lifecycle.observeAndReduce(reason: operation)
        do {
            try sink.append(SecurityEvent(eventID: UUID(), hostSequence: observation.sequence, runID: runID, actionID: nil, time: observation.effectiveTime, origin: origin, operation: operation, resourceSummary: "diagnostic VM; workload=\(workloadDigest)", decision: decision, reason: reason, grantDigest: grantDigest, outcome: outcome))
        } catch { lifecycle.terminate(.faulted); revoke(); throw VMProtocolError.auditFailed }
    }
    public func reject(_ error: VMProtocolError) throws {
        try event("vm.protocol.reject", reason: error.rawValue, decision: .deny)
        rejections.insert(error)
    }
    private func deny(_ error: VMProtocolError) throws -> Never { try reject(error); throw error }
    public func open(owner candidate: AnyObject, now: TimeInterval) throws {
        guard lifecycle.observeAndReduce(reason: "vm-access").status == .active else { try deny(.stopped) }
        guard candidate === owner else { try deny(.crossContext) }
        guard frames < frameBudget else { revoke(); try deny(.budget) }
        frames += 1
        guard deadline == nil else { try deny(.busy) }
        deadline = now + 5
    }
    public func reply(to frame: VMFrame, owner candidate: AnyObject, now: TimeInterval) throws -> VMFrame {
        guard lifecycle.observeAndReduce(reason: "vm-access").status == .active else { try deny(.stopped) }
        guard candidate === owner else { try deny(.crossContext) }
        guard let deadline, now < deadline else { try deny(.timeout) }
        guard frame.type == 1 else { try deny(.type) }
        guard frame.runID == runID else { try deny(.uuid) }
        guard frame.epoch == epoch, frame.epoch > 0 else { try deny(.epoch) }
        try event("vm.protocol.ping", reason: "validated device-bound ping", decision: .allow)
        guard lifecycle.observeAndReduce(reason: "vm-reply-after-audit").status == .active else { throw VMProtocolError.stopped }
        return VMFrame(type: 2, runID: runID, epoch: epoch, nonce: frame.nonce)
    }
    public func replyWritten() throws { try event("vm.protocol.pong", reason: "complete pong written to VZ socket", decision: .allow, outcome: .completed); positiveReplies += 1 }
    public func close() { deadline = nil }
    public func revoke() { lifecycle.terminate(.stopped); deadline = nil }
    public func guestDiagnostic(_ data: Data) throws {
        guard diagnosticBytes < 65536 else { return }
        let bounded = data.prefix(min(240, 65536 - diagnosticBytes))
        diagnosticBytes += bounded.count
        // Base64 avoids terminal controls, misleading line breaks and invalid text.
        try event("vm.console", reason: "base64:" + Data(bounded).base64EncodedString(), origin: .guestDiagnostic)
    }
}
