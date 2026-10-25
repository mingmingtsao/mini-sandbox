import Foundation

@testable import SandboxHost

// R3 barriers own application mutexes, never block a clock provider.
final class R3Result: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: Result<Bool, Error>?
    func run(_ output: ControlledRunOutput) {
        entered.signal()
        let r = Result { try output.acceptNext() }
        lock.withLock { result = r }
        done.signal()
    }
}
func r3Mutex(_ value: Any) throws -> NSLock {
    guard let lock = Mirror(reflecting: value).children.first(where: { $0.label == "lock" })?.value as? NSLock else {
        throw Failure(message: "fixture mutex missing")
    }
    return lock
}
func r3FinalEffectChecks() throws {
    let clock = Clock()
    let authority = lifecycle(clock)
    let pair = try NativeSocketPair()
    let output = try ControlledRunOutput(
        lifecycle: authority, scope: authority.effectScope(connectionID: UUID()),
        takingAcceptedSocket: pair.takeWriter(), streaming: false)
    try output.enqueue(
        .modelCompletion(
            ModelCompletion(
                blocks: [.text("timing fixture")],
                metadata: ModelMetadata(
                    messageID: "msg_independent", model: "fixture",
                    usage: try ModelUsage(wire: .object(["input_tokens": .integer(1), "output_tokens": .integer(2)])),
                    stopReason: "end_turn"))))
    let mutex = try r3Mutex(authority)
    let attempt = R3Result()
    mutex.lock()
    DispatchQueue.global().async { attempt.run(output) }
    let entered = attempt.entered.wait(timeout: .now() + 2) == .success
    let blocked = attempt.done.wait(timeout: .now() + 0.1) == .timedOut
    clock.advance(600)
    mutex.unlock()
    try check(attempt.done.wait(timeout: .now() + 3) == .success, "R3 lifecycle wait timed out")
    let bytes = try pair.readAvailable()
    let accepted = output.nativeProgress!.committedBytes
    print(
        "OBS R3-A-D-E lifecycle_wait=true exact_expiry=true peer_bytes=\(bytes.count) committed=\(accepted) write_calls=\(output.nativeProgress!.writeCalls) final_wall=\(authority.lastObservation!.wallTime.timeIntervalSince1970) deadline=\(authority.expiresAt.timeIntervalSince1970) sequence=\(authority.lastObservation!.sequence) status=\(authority.currentStatus.rawValue)"
    )
    try check(
        entered && blocked && bytes.isEmpty && accepted == 0 && authority.currentStatus == .expired,
        "R3 stale-time native write after lifecycle wait")
    print("PASS r3-lifecycle-wait-exact-expiry")
}
