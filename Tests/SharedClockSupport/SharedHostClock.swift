import Foundation

/// One deterministic trusted-host clock used by F03, model and MCP checks.
public final class SharedHostClock: @unchecked Sendable {
    public let base = Date(timeIntervalSince1970: 1_900_000_000)
    private let lock = NSLock()
    private var wallOffset: TimeInterval = 0
    private var elapsed: Duration = .zero
    private var target = Int.max
    private var reads = 0
    private var fired = false
    public init() {}
    public func arm(_ position: Int) { lock.withLock { target = position; reads = 0; fired = false } }
    public func now() -> Date {
        lock.withLock {
            reads += 1
            if reads == target { fired = true; return base.addingTimeInterval(900) }
            return base.addingTimeInterval(wallOffset)
        }
    }
    public func monotonic() -> Duration { lock.withLock { elapsed } }
    public func set(wall: TimeInterval, elapsed: Duration) { lock.withLock { wallOffset = wall; self.elapsed = elapsed } }
    public var observation: (Int, Bool) { lock.withLock { (reads, fired) } }
    public var observed: Bool { observation.1 }
}
