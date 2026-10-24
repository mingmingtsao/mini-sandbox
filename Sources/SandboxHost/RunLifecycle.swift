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
    let connectionID: UUID
    let connectionRevision: UInt64
}

/// Closed set of known synchronous starts. Never accepts a delayed start closure.
enum RunPreparedEffect: Sendable {
    case model(ModelPreparedOperation)
    case mcp(MCPPreparedOperation)
    func start() throws {
        try Task.checkCancellation()
        switch self { case .model(let op): try op.start(); case .mcp(let op): try op.start() }
    }
    func cancel() {
        switch self { case .model(let op): op.cancel(); case .mcp(let op): op.cancel() }
    }
}

/// The one synchronous terminal, concrete-resume and owned-state acceptance fence.
/// Preparation, clock providers, audit, cancellation and caller callbacks stay outside.
public final class RunLifecycle: @unchecked Sendable {
    public enum Status: String, Sendable { case active, expired, revoked, stopped, faulted }
    private let lock = NSLock()
    private let wall: @Sendable () -> Date
    private let monotonic: @Sendable () -> Duration
    private let deadline: Duration
    public let expiresAt: Date
    private var highWater: Date
    private var sequence: UInt64 = 0
    private var generation: UInt64
    private var status: Status = .active
    private var invalidConnections: Set<UUID> = []
    private var connectionRevisions: [UUID: UInt64] = [:]
    private var operations: [UUID: (RunEffectScope, RunPreparedEffect)] = [:]

    init(expiresAt: Date, epoch: UInt64, installedAt: Date,
         wall: @escaping @Sendable () -> Date, monotonic: @escaping @Sendable () -> Duration) {
        self.expiresAt = expiresAt; self.generation = epoch
        self.highWater = installedAt; self.wall = wall; self.monotonic = monotonic
        self.deadline = monotonic() + .seconds(max(0, expiresAt.timeIntervalSince(installedAt)))
    }
    private func reduce(_ sampledWall: Date, _ sampledMono: Duration) -> RunObservation {
        highWater = max(highWater, sampledWall)
        if status == .active && (highWater >= expiresAt || sampledMono >= deadline) {
            status = .expired; generation &+= 1
        }
        sequence &+= 1
        return RunObservation(wallTime: sampledWall, effectiveTime: highWater,
                              sequence: sequence, generation: generation, status: status)
    }
    private func drainTerminal() -> [RunPreparedEffect] {
        guard status != .active else { return [] }
        let drained = operations.values.map { $0.1 }; operations.removeAll()
        return drained
    }
    public func observeAndReduce(reason: String) -> RunObservation {
        let sampledWall = wall(), sampledMono = monotonic()
        let (observation, cancelled) = lock.withLock {
            let observation = reduce(sampledWall, sampledMono)
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
    private func validate(_ scope: RunEffectScope) throws {
        guard status == .active, generation == scope.generation else { throw AuthorizationError.runRevoked }
        guard !invalidConnections.contains(scope.connectionID),
              connectionRevisions[scope.connectionID, default: 0] == scope.connectionRevision else { throw AuthorizationError.connectionRevoked }
    }
    /// The only gateway start entry: validation, registration and actual resume
    /// share the mutex with terminal/connection invalidation, with no await or Task.
    func start(_ effect: RunPreparedEffect, id: UUID, scope: RunEffectScope, notBefore: Date, startDeadline: Date) throws {
        let sampledWall = wall(), sampledMono = monotonic()
        var cancelled: [RunPreparedEffect] = []
        defer { cancelled.forEach { $0.cancel() } }
        try lock.withLock {
            let observation = reduce(sampledWall, sampledMono)
            cancelled = drainTerminal()
            try validate(scope)
            guard observation.wallTime >= notBefore else { throw AuthorizationError.grantNotYetValid }
            guard observation.effectiveTime < startDeadline else { throw AuthorizationError.actionExpired }
            guard operations[id] == nil else { throw AuthorizationError.ticketAlreadyConsumed }
            try effect.start()
            operations[id] = (scope, effect)
        }
    }
    func finishEffect(_ id: UUID) {
        let removed = lock.withLock { operations.removeValue(forKey: id) }
        removed?.1.cancel() // never deinit/cancel unknown cleanup under the lifecycle lock
    }
    func acceptOutput(_ output: ControlledRunOutput) throws -> Bool {
        let sampledWall = wall(), sampledMono = monotonic()
        var cancelled: [RunPreparedEffect] = []
        defer { cancelled.forEach { $0.cancel() } }
        return try lock.withLock {
            _ = reduce(sampledWall, sampledMono)
            cancelled = drainTerminal()
            guard output.lifecycle === self else { throw AuthorizationError.wrongRun }
            try validate(output.scope)
            // Known bounded in-memory mutation. No user callback or transferable ticket.
            return try output.acceptOne()
        }
    }
}
