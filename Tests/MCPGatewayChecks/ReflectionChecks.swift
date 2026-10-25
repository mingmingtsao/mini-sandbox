import Foundation
import SandboxHost

/// Synthetic active credential comes only from the authenticated loopback response.
/// Never print or persist the completion, response, token, or caught error payload.
func reflectionChecks(_ c: Context) async throws {
    var allRejected = true
    for kind in ["reflection-plain", "reflection-authorization", "reflection-escaped", "reflection-split"] {
        try phase(kind)
        let before = c.credentials.count
        let eventCount = c.audit.snapshot.count
        let approval = try await c.approve(call("A"), source: "reflection-regression")
        var returned = false; var handedOff = false; var unknown = false
        do {
            let result = try await c.execute(approval)
            returned = true
            _ = try MCPModelHandoff.toolResult(result, matching: "reflection-regression")
            handedOff = true
        } catch let error as HostMCPGatewayError { unknown = error == .outcomeUnknown }
        catch { throw Failure(message: "reflection unexpected error type") }
        try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await c.execute(approval) }
        let events = Array(c.audit.snapshot.dropFirst(eventCount))
        let auditUnknown = events.count == 2 && events.last?.reason == "dispatch-completion" && events.last?.outcome == .unknown
        try check(c.credentials.count - before == 1, "reflection exactly one credential read, no retry/replay")
        output("REFLECTION \(kind) completion_blocked=\(!returned) handoff_blocked=\(!handedOff) unknown=\(unknown) audit_unknown=\(auditUnknown)")
        allRejected = allRejected && !returned && !handedOff && unknown && auditUnknown
        try report(kind, hits: 1, reads: 1)
    }
    for kind in ["reflection-ordinary", "reflection-unrelated-bearer"] {
        try phase(kind)
        let before = c.credentials.count
        let result = try await c.execute(c.approve(call("A"), source: "reflection-control"))
        let expected = kind == "reflection-ordinary" ? "ordinary non-reflecting content" : "Bearer unrelated-public-word"
        try check(result.text == expected, "non-reflecting content preserved")
        try check(try MCPModelHandoff.toolResult(result, matching: "reflection-control") == .toolResult(toolUseID: "reflection-control", content: expected, isError: false), "positive handoff preserved")
        try check(c.audit.snapshot.last?.outcome == .completed, "positive audit completed")
        try check(c.credentials.count - before == 1, "positive exactly one credential read")
        try report(kind, hits: 1, reads: 1)
    }
    try check(allRejected, "credential reflection crossed completion/handoff boundary")
}
