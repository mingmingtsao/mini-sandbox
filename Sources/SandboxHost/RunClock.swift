import Foundation

/// Closed host time source. Production has no injectable callback/provider.
/// Manual storage is package-only fixture support, never a guest capability.
public final class RunClock: @unchecked Sendable {
    struct Sample {
        let wall: Date
        let elapsed: Duration
    }
    private let origin = ContinuousClock.now
    private let fixture: Fixture?
    private final class Fixture: @unchecked Sendable {
        let lock = NSLock()
        var wall: Date
        var elapsed: Duration?
        var reads = 0
        var pulseAt: Int?
        var pulseWall: Date?
        var persistent = false
        var fired = false
        init(_ wall: Date, _ elapsed: Duration?) {
            self.wall = wall
            self.elapsed = elapsed
        }
    }
    private init(_ fixture: Fixture?) { self.fixture = fixture }
    public static func system() -> RunClock { RunClock(nil) }
    package static func manual(wall: Date, elapsed: Duration? = nil) -> RunClock {
        RunClock(Fixture(wall, elapsed))
    }
    func sample() -> Sample {
        if let fixture {
            return fixture.lock.withLock {
                fixture.reads += 1
                var wall = fixture.wall
                if let at = fixture.pulseAt, fixture.reads >= at, fixture.persistent || fixture.reads == at {
                    wall = fixture.pulseWall!
                    fixture.fired = true
                }
                return Sample(wall: wall, elapsed: fixture.elapsed ?? origin.duration(to: ContinuousClock.now))
            }
        }
        return Sample(wall: Date(), elapsed: origin.duration(to: ContinuousClock.now))
    }
    package func now() -> Date { sample().wall }
    package var wall: Date {
        guard let fixture else { return Date() }
        return fixture.lock.withLock { fixture.wall }
    }
    package var elapsed: Duration {
        guard let fixture else { return origin.duration(to: ContinuousClock.now) }
        return fixture.lock.withLock { fixture.elapsed ?? origin.duration(to: ContinuousClock.now) }
    }
    package func set(wall: Date, elapsed: Duration? = nil) {
        guard let fixture else { preconditionFailure("system clock is immutable") }
        fixture.lock.withLock {
            fixture.wall = wall
            if let elapsed { fixture.elapsed = elapsed }
        }
    }
    package func advance(_ seconds: TimeInterval) {
        guard let fixture else { preconditionFailure("system clock is immutable") }
        fixture.lock.withLock { fixture.wall = fixture.wall.addingTimeInterval(seconds) }
    }
    package func arm(at read: Int, wall: Date, persistent: Bool = false) {
        precondition(read > 0)
        guard let fixture else { preconditionFailure("system clock is immutable") }
        fixture.lock.withLock {
            fixture.reads = 0
            fixture.fired = false
            fixture.pulseAt = read
            fixture.pulseWall = wall
            fixture.persistent = persistent
        }
    }
    package func disarm() { fixture?.lock.withLock { fixture?.pulseAt = nil } }
    package var observation: (Int, Bool) {
        guard let fixture else { return (0, false) }
        return fixture.lock.withLock { (fixture.reads, fixture.fired) }
    }
}
