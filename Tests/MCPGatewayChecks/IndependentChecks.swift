import Foundation
import SandboxContracts
import SandboxHost

func fixtureGate(_ command: String) throws {
    output("GATE " + command)
    try check(readLine() == "go", "bounded fixture gate acknowledgement")
}
final class MatrixClock: @unchecked Sendable {
    let base = Date(timeIntervalSince1970: 1_900_000_000)
    let source = RunClock.manual(wall: Date(timeIntervalSince1970: 1_900_000_000))
    func now() -> Date { source.now() }
    func set(_ value: TimeInterval) { source.set(wall: base.addingTimeInterval(value)) }
}
func matrixGrant(_ id: UUID, at date: Date, concurrent: Int = 2, account: UInt64 = 1, route: UInt64 = 1) throws
    -> RunGrant
{
    let original = try boundedGrant(id, at: date, concurrent: concurrent)
    return try RunGrant(
        runID: UUID(), epoch: 1, createdAt: original.createdAt, expiresAt: original.expiresAt,
        workloadImageDigest: original.workloadImageDigest, agentAdapterVersion: original.agentAdapterVersion,
        workspaceSnapshotID: original.workspaceSnapshotID, policyDigest: original.policyDigest,
        approvalSnapshotID: original.approvalSnapshotID,
        connections: [
            ConnectionGrant(
                connectionID: id, accountBindingVersion: account, routeVersion: route,
                scopes: original.connections[0].scopes)
        ], explicitDenies: [], resourceLimits: original.resourceLimits)
}
func matrixContext(_ port: UInt16, _ token: String, concurrent: Int = 2, clock: MatrixClock = MatrixClock())
    async throws -> Context
{
    let id = UUID()
    let account = UUID()
    let audit = Audit()
    let credentials = Credentials(token, audit)
    let connection = try HostMCPConnection.testOnlyLoopback(
        connectionID: id, accountID: account, port: port, provider: credentials)
    let gateway = try HostMCPGateway(connections: [connection], auditSink: audit, clock: clock.source)
    let handle = try await gateway.install(grant: matrixGrant(id, at: clock.base, concurrent: concurrent))
    return Context(
        gateway: gateway, handle: handle, id: id, account: account, audit: audit, credentials: credentials, port: port)
}
func independentChecks(_ port: UInt16, _ token: String) async throws {
    for (label, grantCap, cap) in [("grant1", 1, 1), ("cap2", 8, 2)] {
        let c = try await matrixContext(port, token, concurrent: grantCap)
        try await discover(c, name: "saturation-" + label + "-discovery")
        for ending in ["release", "failed", "cancelled"] {
            let name = "saturation-" + label + "-" + ending
            try phase(name)
            var approvals: [HostMCPApproval] = []
            for _ in 0...cap { approvals.append(try await c.approve(call("A"))) }
            // Start in acknowledged ingress order, not Task scheduling/FIFO order.
            var operations: [Task<MCPCompletion, Error>] = []
            for index in 0..<cap {
                let approval = approvals[index]
                operations.append(Task { try await c.execute(approval) })
                try fixtureGate("wait \(index + 1)")
            }
            let extra = approvals[cap]
            let before = c.credentials.count
            let events = c.audit.snapshot.count
            try await denied(.busy) { _ = try await c.execute(extra) }
            try check(
                c.credentials.count == before && c.audit.snapshot.count == events, "busy consumed or prepared approval")
            try fixtureGate("busy \(cap)")
            let first = operations[0]
            if ending == "cancelled" { first.cancel() }
            try fixtureGate("release 1")
            if ending == "release" {
                _ = try await first.value
            } else {
                try await denied(.outcomeUnknown) { _ = try await first.value }
            }
            // The exact busy approval succeeds while the other cap-2 request is held.
            _ = try await c.execute(extra)
            try fixtureGate("release all")
            for operation in operations.dropFirst() { _ = try await operation.value }
            try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(extra) }
            try report(name, hits: cap + 1, reads: cap + 1)
        }
    }
    for position in ["intent", "credential"] {
        let clock = MatrixClock()
        let c = try await matrixContext(port, token, clock: clock)
        try await discover(c, name: "action-" + position + "-discovery")
        let name = "action-" + position
        try phase(name)
        let approval = try await c.approve(call("A"))
        if position == "intent" {
            c.audit.afterAppend = { event in if event.reason == "dispatch-intent" { clock.set(300) } }
        } else {
            c.credentials.afterRead = { clock.set(300) }
        }
        let before = c.credentials.count
        try await denied(.notStarted) { _ = try await c.execute(approval) }
        try check(c.credentials.count - before == (position == "intent" ? 0 : 1), "action expiry read boundary")
        try check(try await !c.gateway.isRevoked(handle: c.handle), "action expiry must be nonterminal")
        try check(c.audit.snapshot.last?.outcome == .failed, "prestart expiry audit failed")
        try fixtureGate("zero 0")
        c.audit.afterAppend = nil
        c.credentials.afterRead = nil
        try report(name, hits: 0, reads: position == "intent" ? 0 : 1)
        try phase(name + "-recovery")
        _ = try await c.send(call("A"))
        try report(name + "-recovery", hits: 1, reads: 1)
    }
    for operation in ["propose", "approve", "execute"] {
        let clock = MatrixClock()
        let c = try await matrixContext(port, token, clock: clock)
        let name = "not-yet-valid-" + operation
        try phase(name)
        let proposal = try await c.proposal(control("initialize"))
        let approval =
            operation == "execute" ? try await c.gateway.hostApprove(handle: c.handle, proposal: proposal) : nil
        clock.set(-2)
        try await denied(AuthorizationError.grantNotYetValid) {
            switch operation {
            case "propose": _ = try await c.proposal(control("initialize"))
            case "approve": _ = try await c.gateway.hostApprove(handle: c.handle, proposal: proposal)
            default: _ = try await c.execute(approval!)
            }
        }
        try check(try await !c.gateway.isRevoked(handle: c.handle), "not-yet-valid is nonterminal")
        clock.set(0)
        _ = try await c.approve(control("initialize"))
        try report(name, hits: 0, reads: 0)
    }
    try await staleCatalogChecks(port, token)
    try await negativeModelChecks(port, token)
}
func staleCatalogChecks(_ port: UInt16, _ token: String) async throws {
    for transition in ["invalidate", "account", "route", "stop"] {
        let clock = MatrixClock()
        let c = try await matrixContext(port, token, clock: clock)
        let name = "stale-" + transition
        try await discover(c, name: name + "-discovery")
        try phase(name)
        let old = try await c.approve(call("A"))
        let a = try await c.approve(control("tools/list"))
        let b = try await c.approve(control("tools/list"))
        let first = Task { try await c.execute(a) }
        try fixtureGate("wait 1")
        let second = Task { try await c.execute(b) }
        try fixtureGate("wait 2")
        switch transition {
        case "invalidate": try await c.gateway.invalidateCatalog(connectionID: c.id)
        case "stop": try await c.gateway.stop(handle: c.handle)
        default:
            let updated = try HostMCPConnection.testOnlyLoopback(
                connectionID: c.id, accountID: transition == "account" ? UUID() : c.account,
                accountBindingVersion: transition == "account" ? 2 : 1, routeVersion: transition == "route" ? 2 : 1,
                port: port, provider: c.credentials)
            try await c.gateway.updateConnection(updated)
        }
        if transition == "stop" {
            try check(try await c.gateway.isRevoked(handle: c.handle), "STOP immediate latch")
        } else {
            try check(try await c.gateway.discovery(connectionID: c.id) == .unknown, "transition immediate unknown")
        }
        let expected: HostMCPGatewayError = ["account", "route"].contains(transition) ? .invalidConnection : .revoked
        try await denied(expected) { _ = try await c.execute(old) }
        try fixtureGate("release all")
        try await denied(.outcomeUnknown) { _ = try await first.value }
        try await denied(.outcomeUnknown) { _ = try await second.value }
        try check(try await c.gateway.discovery(connectionID: c.id) == .unknown, "stale completion restored authority")
        try await denied(expected) { _ = try await c.execute(old) }
        try report(name, hits: 2, reads: 2)
        try phase(name + "-recovery")
        var recovery = c
        if transition != "invalidate" {
            let handle = try await c.gateway.install(
                grant: matrixGrant(
                    c.id, at: clock.base, account: transition == "account" ? 2 : 1, route: transition == "route" ? 2 : 1
                ))
            recovery = Context(
                gateway: c.gateway, handle: handle, id: c.id, account: c.account, audit: c.audit,
                credentials: c.credentials, port: port)
        }
        if ["account", "route"].contains(transition) {
            _ = try await recovery.send(control("initialize"))
            _ = try await recovery.send(control("notifications/initialized"))
        }
        _ = try await recovery.send(control("tools/list"))
        try check(try await recovery.gateway.discovery(connectionID: c.id) == .knownReady, "explicit rediscovery")
        _ = try await recovery.send(call("A"))
        try report(
            name + "-recovery", hits: ["account", "route"].contains(transition) ? 4 : 2,
            reads: ["account", "route"].contains(transition) ? 4 : 2)
    }
}
