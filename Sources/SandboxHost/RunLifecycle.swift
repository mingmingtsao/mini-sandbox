import Foundation

/// Immutable host observation. Never accept guest-supplied security timestamps.
public struct RunObservation: Sendable {
    public let wallTime: Date
    public let effectiveTime: Date
    public let sequence: UInt64
    public let generation: UInt64
    public let status: RunLifecycle.Status
}

/// Identity is the lifecycle reference plus its epoch and connection revision.
/// This is not a transferable execution permit: start/accept validate it again.
package struct RunEffectScope: Sendable {
    let generation: UInt64
    let connectionID: UUID?
    let connectionRevision: UInt64
    let runHandle: HostRunHandle?
    init(generation: UInt64, connectionID: UUID?, connectionRevision: UInt64, runHandle: HostRunHandle? = nil) {
        self.generation = generation; self.connectionID = connectionID
        self.connectionRevision = connectionRevision; self.runHandle = runHandle
    }
}

/// Closed set of known synchronous starts. Never accepts a delayed start closure.
enum RunPreparedEffect: Sendable {
    case model(ModelPreparedOperation)
    case mcp(MCPPreparedOperation)
    case businessVM(BusinessVMPreparedStart)
    func acquire() { switch self { case .model(let op): op.acquireForStart(); case .mcp(let op): op.acquireForStart(); case .businessVM(let op): op.acquireForStart() } }
    func release() { switch self { case .model(let op): op.releaseForStart(); case .mcp(let op): op.releaseForStart(); case .businessVM(let op): op.releaseForStart() } }
    func validateScope(_ scope: RunEffectScope, lifecycle: RunLifecycle) throws {
        switch self {
        case .model, .mcp:
            guard scope.connectionID != nil else { throw AuthorizationError.connectionNotGranted }
        case .businessVM(let operation):
            guard scope.connectionID == nil, scope.runHandle === operation.handle,
                  operation.handle.lifecycle === lifecycle, operation.generation == scope.generation else {
                throw AuthorizationError.wrongRun
            }
        }
    }
    func startLocked() throws {
        try Task.checkCancellation()
        switch self { case .model(let op): try op.startLocked(); case .mcp(let op): try op.startLocked(); case .businessVM(let op): try op.startLocked() }
    }
    func cancel() {
        switch self { case .model(let op): op.cancel(); case .mcp(let op): op.cancel(); case .businessVM(let op): op.cancel() }
    }
}

/// The one synchronous terminal, concrete-resume and owned-state acceptance fence.
/// Preparation, audit, cancellation and caller callbacks stay outside.
/// The closed concrete clock is sampled only after final effect ownership.
public final class RunLifecycle: @unchecked Sendable {
    public enum Status: String, Sendable { case active, expired, revoked, stopped, faulted }
    private let lock = NSLock()
    private let clock: RunClock
    private let deadline: Duration
    public let expiresAt: Date
    private var highWater: Date
    private var sequence: UInt64 = 0
    private var latestObservation: RunObservation?
    package var lastObservation: RunObservation? { lock.withLock { latestObservation } }
    package var registeredEffectCount: Int { lock.withLock { operations.count } }
    private var generation: UInt64
    private var status: Status = .active
    private var invalidConnections: Set<UUID> = []
    private var connectionRevisions: [UUID: UInt64] = [:]
    private var operations: [UUID: (RunEffectScope, RunPreparedEffect)] = [:]

    init(expiresAt: Date, epoch: UInt64, installedAt: Date, clock: RunClock, installedElapsed: Duration? = nil) {
        self.expiresAt = expiresAt; self.generation = epoch
        self.highWater = installedAt; self.clock = clock
        self.deadline = (installedElapsed ?? clock.elapsed) + .seconds(max(0, expiresAt.timeIntervalSince(installedAt)))
    }
    private func reduce(_ sampledWall: Date, _ sampledMono: Duration) -> RunObservation {
        highWater = max(highWater, sampledWall)
        if status == .active && (highWater >= expiresAt || sampledMono >= deadline) {
            status = .expired; generation &+= 1
        }
        sequence &+= 1
        let observation = RunObservation(wallTime: sampledWall, effectiveTime: highWater,
                              sequence: sequence, generation: generation, status: status)
        latestObservation = observation
        return observation
    }
    private func drainTerminal() -> [RunPreparedEffect] {
        guard status != .active else { return [] }
        let drained = operations.values.map { $0.1 }; operations.removeAll()
        return drained
    }
    public func observeAndReduce(reason: String) -> RunObservation {
        let (observation, cancelled) = lock.withLock {
            let sample = clock.sample()
            let observation = reduce(sample.wall, sample.elapsed)
            return (observation, drainTerminal())
        }
        cancelled.forEach { $0.cancel() }
        return observation
    }
    public var currentStatus: Status { lock.withLock { status } }
    public var currentGeneration: UInt64 { lock.withLock { generation } }
    public func terminate(_ terminal: Status) {
        precondition(terminal != .active)
        let cancelled = lock.withLock {
            if status == .active { status = terminal; generation &+= 1 }
            return drainTerminal()
        }
        cancelled.forEach { $0.cancel() }
    }
    public func invalidateConnection(_ id: UUID) {
        let cancelled = lock.withLock {
            invalidConnections.insert(id)
            return retireConnection(id)
        }
        cancelled.forEach { $0.cancel() }
    }
    /// Catalog changes stale only this connection's effects, not sibling runs/actions.
    func advanceConnection(_ id: UUID) {
        let cancelled = lock.withLock {
            connectionRevisions[id, default: 0] &+= 1
            return retireConnection(id)
        }
        cancelled.forEach { $0.cancel() }
    }
    private func retireConnection(_ id: UUID) -> [RunPreparedEffect] {
        let selected = operations.filter { $0.value.0.connectionID == id }
        for key in selected.keys { operations.removeValue(forKey: key) }
        return selected.values.map { $0.1 }
    }
    public func permitsConnection(_ id: UUID) -> Bool {
        lock.withLock { status == .active && !invalidConnections.contains(id) }
    }
    package func effectScope(connectionID: UUID) -> RunEffectScope {
        lock.withLock { RunEffectScope(generation: generation, connectionID: connectionID,
                                      connectionRevision: connectionRevisions[connectionID, default: 0]) }
    }
    /// Immutable run provenance for the closed VM/task consumers. Not a permit:
    /// each start/write validates the actual owner again after taking its locks.
    package func runScope(for handle: HostRunHandle, epoch: UInt64) throws -> RunEffectScope {
        guard handle.lifecycle === self, handle.installedEpoch == epoch else { throw AuthorizationError.wrongRun }
        return RunEffectScope(generation: epoch, connectionID: nil, connectionRevision: 0, runHandle: handle)
    }
    private func validate(_ scope: RunEffectScope) throws {
        guard status == .active, generation == scope.generation else { throw AuthorizationError.runRevoked }
        if let connectionID = scope.connectionID {
            guard !invalidConnections.contains(connectionID),
                  connectionRevisions[connectionID, default: 0] == scope.connectionRevision else { throw AuthorizationError.connectionRevoked }
        } else {
            guard let handle = scope.runHandle, handle.lifecycle === self,
                  handle.installedEpoch == scope.generation else { throw AuthorizationError.wrongRun }
        }
    }
    /// The only gateway start entry: validation, registration and actual resume
    /// share the mutex with terminal/connection invalidation, with no await or Task.
    func start(_ effect: RunPreparedEffect, id: UUID, scope: RunEffectScope, notBefore: Date, startDeadline: Date) throws {
        var cancelled: [RunPreparedEffect] = []
        effect.acquire()
        defer { effect.release(); cancelled.forEach { $0.cancel() } }
        try lock.withLock {
            let sample = clock.sample()
            let observation = reduce(sample.wall, sample.elapsed)
            cancelled = drainTerminal()
            try validate(scope)
            guard observation.wallTime >= notBefore else { throw AuthorizationError.grantNotYetValid }
            guard observation.effectiveTime < startDeadline else { throw AuthorizationError.actionExpired }
            guard operations[id] == nil else { throw AuthorizationError.ticketAlreadyConsumed }
            try effect.validateScope(scope, lifecycle: self)
            try effect.startLocked()
            operations[id] = (scope, effect)
        }
    }
    func finishEffect(_ id: UUID) {
        let removed = lock.withLock { operations.removeValue(forKey: id) }
        removed?.1.cancel() // never deinit/cancel unknown cleanup under the lifecycle lock
    }
    func acceptOutput(_ output: ControlledRunOutput) throws -> Bool {
        var cancelled: [RunPreparedEffect] = []
        let owned = output.acquireForAcceptance()
        defer {
            if owned { output.releaseForAcceptance() }
            cancelled.forEach { $0.cancel() }
        }
        if owned { try output.prepareAcceptanceLocked() }
        return try lock.withLock {
            let sample = clock.sample()
            _ = reduce(sample.wall, sample.elapsed)
            cancelled = drainTerminal()
            guard output.lifecycle === self else { throw AuthorizationError.wrongRun }
            try validate(output.scope)
            // Known bounded in-memory mutation. No user callback or transferable ticket.
            guard owned else { return false }
            return try output.acceptLocked()
        }
    }
    func acceptVMFrame(_ output: BusinessVMFrameOutput) throws -> Bool {
        var cancelled: [RunPreparedEffect] = []
        let owned = output.acquireForAcceptance()
        defer {
            if owned { output.releaseForAcceptance() }
            cancelled.forEach { $0.cancel() }
        }
        if owned { try output.prepareAcceptanceLocked() }
        return try lock.withLock {
            let sample = clock.sample()
            _ = reduce(sample.wall, sample.elapsed)
            cancelled = drainTerminal()
            guard output.lifecycle === self, output.handle.lifecycle === self,
                  output.handle.installedEpoch == output.generation,
                  output.scope.generation == output.generation else { throw AuthorizationError.wrongRun }
            if output.scope.connectionID == nil {
                guard output.scope.runHandle === output.handle else { throw AuthorizationError.wrongRun }
            }
            try validate(output.scope)
            try Task.checkCancellation()
            guard owned else { return false }
            return try output.acceptLocked()
        }
    }

}
