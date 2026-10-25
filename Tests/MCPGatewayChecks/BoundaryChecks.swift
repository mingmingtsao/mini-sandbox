import Foundation
import SandboxHost
import SandboxContracts

// Coverage-only tests against the existing implementation. ModelJSON permits
// 65536 bytes per individual string, so each 32768-byte text control is valid
// before the assembled-output check; JSON whitespace pads transport controls.
func boundedGrant(_ id: UUID, at date: Date, bytes: Int = 65536, concurrent: Int = 2) throws -> RunGrant {
    let scopes = Set(try ["initialize", "notifications/initialized", "tools/list"].map { try ResourceScope(service: "mcp", resource: "control", operation: $0) } + [ResourceScope(service: "mcp", resource: "A", operation: "read")])
    return try RunGrant(runID: UUID(), epoch: 1, createdAt: date.addingTimeInterval(-1), expiresAt: date.addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "fixture", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: scopes)], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: bytes, concurrentRequests: concurrent))
}
func boundedContext(_ port: UInt16, _ token: String, bytes: Int) async throws -> Context {
    let id = UUID(), account = UUID(); let audit = Audit(); let credentials = Credentials(token, audit)
    let connection = try HostMCPConnection.testOnlyLoopback(connectionID: id, accountID: account, port: port, provider: credentials)
    let gateway = try HostMCPGateway(connections: [connection], auditSink: audit)
    let handle = try await gateway.install(grant: boundedGrant(id, at: Date(), bytes: bytes))
    return Context(gateway: gateway, handle: handle, id: id, account: account, audit: audit, credentials: credentials, port: port)
}
func responseBoundaryChecks(_ port: UInt16, _ token: String) async throws {
    for cap in ["grant", "hard"] {
        let c = try await boundedContext(port, token, bytes: cap == "grant" ? 4096 : 131072)
        try await discover(c, name: "limit-" + cap + "-discovery")
        for framing in ["declared", "unknown", "chunked"] {
            for edge in ["exact", "over"] {
                let name = "limit-" + cap + "-" + framing + "-" + edge
                try phase(name)
                let approval = try await c.approve(call("A"))
                if edge == "exact" {
                    let result = try await c.execute(approval)
                    try check(result.text == "boundary-control", "padded valid JSON at effective byte cap unchanged")
                    try check(c.audit.snapshot.last?.outcome == .completed, "at-cap completed audit")
                } else {
                    try await denied(.outcomeUnknown) { _ = try await c.execute(approval) }
                    try check(c.audit.snapshot.last?.outcome == .unknown, "oversized started response unknown")
                }
                try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(approval) }
                try report(name, hits: 1, reads: 1)
            }
        }
    }
    let c = try await boundedContext(port, token, bytes: 65536)
    try await discover(c, name: "text-limit-discovery")
    for shape in ["single", "split"] {
        for edge in ["exact", "over"] {
            let name = "text-limit-" + shape + "-" + edge
            try phase(name)
            let approval = try await c.approve(call("A"))
            if edge == "exact" {
                let result = try await c.execute(approval)
                try check(result.text == String(repeating: "é", count: 16384) && result.text.utf8.count == 32768, "UTF8 assembled text boundary unchanged")
            } else {
                try await denied(.outcomeUnknown) { _ = try await c.execute(approval) }
                try check(c.audit.snapshot.last?.outcome == .unknown, "assembled text overflow unknown")
            }
            try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(approval) }
            try report(name, hits: 1, reads: 1)
        }
    }
}
