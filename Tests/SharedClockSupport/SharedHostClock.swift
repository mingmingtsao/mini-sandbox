import Foundation
import SandboxHost

/// Data-only fixture source shared with F03; pulses cannot run arbitrary code.
public final class SharedHostClock: @unchecked Sendable {
    public let base = Date(timeIntervalSince1970: 1_900_000_000)
    package let source = RunClock.manual(wall: Date(timeIntervalSince1970: 1_900_000_000), elapsed: .zero)
    public init() {}
    public func arm(_ position: Int) { source.arm(at: position, wall: base.addingTimeInterval(900)) }
    public func now() -> Date { source.now() }
    public func monotonic() -> Duration { source.elapsed }
    public func set(wall: TimeInterval, elapsed: Duration) { source.set(wall: base.addingTimeInterval(wall), elapsed: elapsed) }
    public var observation: (Int, Bool) { source.observation }
    public var observed: Bool { observation.1 }
}
