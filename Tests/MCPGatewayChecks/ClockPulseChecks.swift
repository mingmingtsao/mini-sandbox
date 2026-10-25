import Foundation
import SharedClockSupport
import SandboxHost
import SandboxContracts

/// One expired sample, then valid samples; never mutates the system clock.
/// Anchors are actual shared-now calls in HostMCPGateway/AuthorizationController:
/// propose = gateway live, eligibility, authority propose, gateway post-await;
/// approve = gateway pre-await, authority approve, gateway post-await;
/// deny = gateway pre-await, authority explicit-deny event, gateway post-await.
typealias PulseClock = SharedHostClock
func clockPulseChecks(_ port: UInt16, _ token: String) async throws {
    for (operation, positions) in [("propose", 4), ("approve", 3), ("deny", 3)] {
        for position in 1...positions {
            let name = "pulse-" + operation + "-" + String(position)
            try phase(name)
            let clock = PulseClock(); let id = UUID(), account = UUID()
            let audit = Audit(); let credentials = Credentials(token, audit)
            let connection = try HostMCPConnection.testOnlyLoopback(connectionID: id, accountID: account, port: port, provider: credentials)
            let gateway = try HostMCPGateway(connections: [connection], auditSink: audit, now: { clock.now() })
            let handle = try await gateway.install(grant: boundedGrant(id, at: clock.base))
            let pending = operation == "propose" ? nil : try await gateway.propose(handle: handle, connectionID: id, raw: control("initialize"))
            clock.arm(position)
            var errorLabel = "none"
            do {
                switch operation {
                case "propose": _ = try await gateway.propose(handle: handle, connectionID: id, raw: control("initialize"))
                case "approve": _ = try await gateway.hostApprove(handle: handle, proposal: pending!)
                default: try await gateway.hostDeny(handle: handle, proposal: pending!)
                }
            } catch let e as HostMCPGatewayError {
                try check(e == .revoked, "pulse unexpected gateway error")
                errorLabel = "revoked"
            } catch let e as AuthorizationError {
                try check(e == .grantExpired, "pulse unexpected authority error")
                errorLabel = "grant-expired"
            }
            // Read the latch before ANY new liveness operation can repair it.
            let latched = try await gateway.isRevoked(handle: handle)
            let (samples, fired) = clock.observation
            let auditExpired = audit.snapshot.contains { $0.time >= clock.base.addingTimeInterval(900) }
            var repaired = false
            if !latched {
                repaired = (try? await gateway.propose(handle: handle, connectionID: id, raw: control("initialize"))) != nil
            }
            output("CLOCK \(name) samples=\(samples) fired=\(fired) latched=\(latched) repaired=\(repaired) audit_expired=\(auditExpired) error=\(errorLabel) reads=\(credentials.count)")
            try check(fired, "pulse anchor not reached")
            try check(credentials.count == 0, "control pulse read credentials")
            try check(latched && !repaired, "pulse sampled expiry did not latch")
            // A durable accepted denial may return normally. The required
            // security effect is the immediate terminal latch and no revival.
            if operation != "deny" { try check(errorLabel != "none", "pulse operation returned success") }
            try report(name, hits: 0, reads: 0)
        }
    }
}
