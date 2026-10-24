import Foundation
import SandboxHost

final class Barrier: @unchecked Sendable {
    let reason: String
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock(); var entered = false
    init(_ reason: String) { self.reason = reason }
    func wait() { lock.withLock { entered = true }; _ = semaphore.wait(timeout: .now() + 5) }
    func reached() async throws {
        for _ in 0..<1000 {
            if lock.withLock({ entered }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Failure(message: "audit barrier not reached")
    }
}
final class Clock: @unchecked Sendable {
    let lock = NSLock(); var value = Date()
    func now() -> Date { lock.withLock { value } }
    func expire() { lock.withLock { value = value.addingTimeInterval(300) } }
}
func lifecycleBarriers(_ port: UInt16, _ token: String) async throws {
    for kind in ["barrier-stop", "barrier-revoke", "barrier-cancel", "barrier-expiry", "completion-stop"] {
        let id = UUID(); let account = UUID(); let audit = Audit(); let credentials = Credentials(token, audit); let clock = Clock()
        let connection = try HostMCPConnection.testOnlyLoopback(connectionID: id, accountID: account, port: port, provider: credentials)
        let gateway = try HostMCPGateway(connections: [connection], auditSink: audit, now: { clock.now() })
        let handle = try await gateway.install(grant: grant(id))
        let c = Context(gateway: gateway, handle: handle, id: id, account: account, audit: audit, credentials: credentials, port: port)
        try await discover(c, name: kind + "-discovery")
        try phase(kind)
        let approval = try await c.approve(call("A")); let before = credentials.count
        let barrier = Barrier(kind == "completion-stop" ? "dispatch-completion" : "dispatch-intent")
        audit.barrier = barrier
        let execution = Task { try await c.execute(approval) }
        try await barrier.reached()
        var transition: Task<Void, Error>?
        switch kind {
        case "barrier-stop", "completion-stop":
            transition = Task { try await gateway.stop(handle: handle) }
            var revoked = false
            for _ in 0..<1000 { if try await gateway.isRevoked(handle: handle) { revoked = true; break }; try await Task.sleep(for: .milliseconds(1)) }
            try check(revoked, "STOP latches before authority await")
        case "barrier-revoke":
            transition = Task { try await gateway.revokeConnection(id) }
            var revoked = false
            for _ in 0..<1000 {
                do { _ = try await gateway.discovery(connectionID: id) }
                catch let error as HostMCPGatewayError {
                    try check(error == .invalidConnection, "typed connection revocation")
                    revoked = true; break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            try check(revoked, "connection revoke before await")
        case "barrier-cancel": execution.cancel()
        case "barrier-expiry": clock.expire()
        default: break
        }
        barrier.semaphore.signal()
        try await denied(kind == "completion-stop" ? HostMCPGatewayError.outcomeUnknown : .notStarted) { _ = try await execution.value }
        if let transition { try await transition.value }
        if kind == "barrier-expiry" { try check(try await gateway.isRevoked(handle: handle), "expiry terminal latch") }
        let expected = kind == "completion-stop" ? 1 : 0
        try check(credentials.count - before == expected, "barrier credential reads")
        try report(kind, hits: expected, reads: expected)
    }
}
