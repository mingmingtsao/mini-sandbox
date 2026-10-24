import Foundation

/// Immutable host observation. Never accept guest-supplied security timestamps.
public struct RunObservation: Sendable {
    public let wallTime: Date
    public let effectiveTime: Date
    public let sequence: UInt64
    public let generation: UInt64
    public let status: RunLifecycle.Status
}

/// The one synchronous terminal fence for an installed F03 run. No I/O, provider,
/// audit, cancellation or caller callback executes inside its mutex.
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

    init(expiresAt: Date, epoch: UInt64, installedAt: Date,
         wall: @escaping @Sendable () -> Date, monotonic: @escaping @Sendable () -> Duration) {
        self.expiresAt = expiresAt; self.generation = epoch
        self.highWater = installedAt; self.wall = wall; self.monotonic = monotonic
        // Fixed once, including time asleep (ContinuousClock in production).
        self.deadline = monotonic() + .seconds(max(0, expiresAt.timeIntervalSince(installedAt)))
    }
    public func observeAndReduce(reason: String) -> RunObservation {
        // Injectable trusted clock sources run outside the lifecycle lock.
        let sampledWall = wall(), sampledMono = monotonic()
        return lock.withLock {
            highWater = max(highWater, sampledWall)
            if status == .active && (highWater >= expiresAt || sampledMono >= deadline) {
                status = .expired; generation &+= 1
            }
            sequence &+= 1
            return RunObservation(wallTime: sampledWall, effectiveTime: highWater,
                                  sequence: sequence, generation: generation, status: status)
        }
    }
    public var currentStatus: Status { lock.withLock { status } }
    public var currentGeneration: UInt64 { lock.withLock { generation } }
    /// Terminal state invalidates every unsent permission through the generation
    /// fence, even while F03 is suspended in audit. Tickets remain bookkeeping.
    public func terminate(_ terminal: Status) {
        precondition(terminal != .active)
        lock.withLock {
            guard status == .active else { return }
            status = terminal; generation &+= 1
        }
    }
    public func invalidateConnection(_ id: UUID) { lock.withLock { _ = invalidConnections.insert(id) } }
    public func permitsConnection(_ id: UUID) -> Bool {
        lock.withLock { status == .active && !invalidConnections.contains(id) }
    }
}
