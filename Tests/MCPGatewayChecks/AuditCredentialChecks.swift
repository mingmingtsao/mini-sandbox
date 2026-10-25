import Foundation
import SandboxHost

func credentialGateChecks(_ port: UInt16, _ token: String) async throws {
    for kind in ["credential-binding", "credential-provider"] {
        let c = try await make(port, token)
        try await discover(c, name: kind + "-discovery")
        try phase(kind)
        let approval = try await c.approve(call("A"), source: "credential-gate")
        c.credentials.inject(kind == "credential-binding" ? .bindingMismatch : .failure)
        try await denied(.notStarted) { _ = try await c.execute(approval) }
        try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(approval) }
        let events = c.audit.snapshot.suffix(2)
        try check(events.map(\.reason) == ["dispatch-intent", "dispatch-completion"] && events.last?.outcome == .failed, "credential failure pre-start audit")
        try report(kind, hits: 0, reads: 1)
    }
}

final class ReturnObservation: @unchecked Sendable {
    private let lock = NSLock(); private var returned = false
    func mark() { lock.withLock { returned = true } }
    var value: Bool { lock.withLock { returned } }
}

func diskAuditChecks(_ port: UInt16, _ token: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-audit-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    for kind in ["disk-completed", "disk-reflection", "disk-intent-failure", "disk-completion-failure"] {
        let file = directory.appendingPathComponent(kind + ".jsonl")
        let audit = try Audit(diskAt: file)
        let c = try await make(port, token, audit: audit)
        try await discover(c, name: kind + "-discovery")
        try check(try audit.readDisk().count == 6 && audit.diskReadbacks == 6, "three durable discovery audit pairs")
        try check(c.credentials.diskIntentReadbacks == 3, "disk intents precede discovery credentials")
        try phase(kind)
        let approval = try await c.approve(call("A"), source: "disk-audit")
        if kind == "disk-completed" {
            let observation = ReturnObservation()
            let barrier = Barrier("dispatch-completion")
            audit.barrier = barrier
            let execution = Task {
                let result = try await c.execute(approval)
                observation.mark()
                return result
            }
            do {
                try await barrier.reached()
                let last = try audit.readDisk().last
                try check(last?.reason == "dispatch-completion" && last?.outcome == "completed", "completed disk readback before release")
                try check(!observation.value, "no completion returned while audit append blocked")
            } catch {
                barrier.semaphore.signal()
                _ = try? await execution.value
                throw error
            }
            barrier.semaphore.signal()
            let result = try await execution.value
            try check(observation.value && result.text == "changed", "audited disk result returned")
            try check(try MCPModelHandoff.toolResult(result, matching: "disk-audit") == .toolResult(toolUseID: "disk-audit", content: "changed", isError: false), "disk gated successful handoff")
            try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(approval) }
        } else if kind == "disk-reflection" {
            try await denied(.outcomeUnknown) { _ = try await c.execute(approval) }
            try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(approval) }
            let events = Array(try audit.readDisk().dropFirst(6))
            try check(events.count == 2 && events.last?.outcome == "unknown", "reflection durable unknown not success")
        } else {
            // Fail the selected append at the synchronous sink boundary; all
            // preceding events use the real JSONLAuditSink, not an in-memory fake.
            audit.fail = kind == "disk-intent-failure" ? "dispatch-intent" : "dispatch-completion"
            try await denied(HostMCPGatewayError.auditFailed) { _ = try await c.execute(approval) }
            try check(try await c.gateway.isRevoked(handle: c.handle), "disk audit failure revokes")
            try await denied(.revoked) { _ = try await c.execute(approval) }
            let after = Array(try audit.readDisk().dropFirst(6))
            try check(after.count == (kind == "disk-intent-failure" ? 0 : 1), "failed audit append not persisted")
            try check(!after.contains { $0.reason == "dispatch-completion" }, "failed audit cannot release completed result")
        }
        let expectedReads = kind == "disk-intent-failure" ? 0 : 1
        try check(c.credentials.diskIntentReadbacks == 3 + expectedReads, "each credential read follows disk intent")
        let persisted = try audit.readDisk()
        try check(audit.diskReadbacks == persisted.count, "every successful append read back")
        // Boolean assertion only. Do not save or print a token or response body.
        try check(!String(decoding: Data(contentsOf: file), as: UTF8.self).contains(token), "audit excludes active credential")
        try report(kind, hits: expectedReads, reads: expectedReads)
    }
}
