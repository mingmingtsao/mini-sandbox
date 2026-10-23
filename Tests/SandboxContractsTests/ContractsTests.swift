import Foundation
import SandboxContracts

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func check(_ value: @autoclosure () throws -> Bool, _ message: String = "assertion failed") throws {
    if try !value() { throw CheckFailure(description: message) }
}
func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw CheckFailure(description: "expected rejection")
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
func grant(denies: Set<ResourceScope> = [], expiration: Date? = nil) throws -> RunGrant {
    let scope = try ResourceScope(service: "model", resource: "primary", operation: "completion")
    return try RunGrant(
        runID: UUID(), epoch: 1, createdAt: now, expiresAt: expiration ?? now.addingTimeInterval(60),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "test/1",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64),
        approvalSnapshotID: UUID(), connections: [try ConnectionGrant(connectionID: UUID(), accountBindingVersion: 1, routeVersion: 1, scopes: [scope])],
        explicitDenies: denies, resourceLimits: try ResourceLimits(cpuCount: 2, memoryBytes: 512 * 1024 * 1024, diskBytes: 1024 * 1024 * 1024, messageBytes: 65_536, concurrentRequests: 2))
}
func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
        throw CheckFailure(description: "expected JSON object")
    }
    return object
}
let tests: [(String, () throws -> Void)] = [
    ("invalid expiry and zero epoch rejected", {
        try rejects { _ = try grant(expiration: now) }
        var data = try object(grant()); data["epoch"] = 0
        try rejects { _ = try JSONDecoder().decode(RunGrant.self, from: JSONSerialization.data(withJSONObject: data)) }
    }),
    ("explicit deny overrides granted resource", {
        let scope = try ResourceScope(service: "model", resource: "primary", operation: "completion")
        let g = try grant(denies: [scope])
        try check(g.decision(for: scope, connectionID: g.connections[0].connectionID, at: now) == .denied(.explicitDeny))
        try check(g.decision(for: scope, connectionID: g.connections[0].connectionID, at: g.expiresAt) == .denied(.explicitDeny), "explicit deny must precede expiration")
        try check(g.decision(for: scope, connectionID: g.connections[0].connectionID, at: now.addingTimeInterval(-1)) == .denied(.explicitDeny), "explicit deny must precede not-yet-valid")
    }),
    ("unknown connection, resource and expired grant denied", {
        let g = try grant()
        let scope = try ResourceScope(service: "model", resource: "primary", operation: "completion")
        try check(g.decision(for: scope, connectionID: UUID(), at: now) == .denied(.connectionNotGranted))
        let other = try ResourceScope(service: "model", resource: "another", operation: "completion")
        try check(g.decision(for: other, connectionID: g.connections[0].connectionID, at: now) == .denied(.resourceNotGranted))
        try check(g.decision(for: scope, connectionID: g.connections[0].connectionID, at: g.expiresAt) == .denied(.expired))
        try check(g.decision(for: scope, connectionID: g.connections[0].connectionID, at: now.addingTimeInterval(-1)) == .denied(.notYetValid))
        try check(g.decision(for: scope, connectionID: g.connections[0].connectionID, at: now) == .allowed)
    }),
    ("limits and wildcard resources rejected", {
        try rejects { _ = try ResourceLimits(cpuCount: 0, memoryBytes: 1, diskBytes: 1, messageBytes: 1, concurrentRequests: 1) }
        try rejects { _ = try ResourceLimits(cpuCount: 2, memoryBytes: 1, diskBytes: 1, messageBytes: 0, concurrentRequests: 1) }
        try rejects { _ = try ResourceScope(service: "model", resource: "*", operation: "completion") }
        try rejects { _ = try ResourceScope(service: "", resource: "primary", operation: "completion") }
    }),
    ("validated decode and round trip", {
        let g = try grant()
        try check(try JSONDecoder().decode(RunGrant.self, from: JSONEncoder().encode(g)) == g)
        var data = try object(g); data["policyDigest"] = "not-a-digest"
        try rejects { _ = try JSONDecoder().decode(RunGrant.self, from: JSONSerialization.data(withJSONObject: data)) }
    }),
    ("pending action binds bytes, run, epoch and nonce with expiration", {
        let g = try grant()
        let binding = try ActionBinding(runID: g.runID, epoch: g.epoch, grantDigest: String(repeating: "c", count: 64), connectionID: g.connections[0].connectionID, operation: "create", schemaDigest: String(repeating: "d", count: 64), resolvedResource: "repo/example", canonicalRequest: Data("{\"title\":\"A\"}".utf8))
        let action = try PendingAction(binding: binding, safeDisplaySnapshot: "Create A in repo/example", createdAt: now, expiresAt: now.addingTimeInterval(30))
        try check(action.matches(binding: binding, nonce: action.nonce, at: now))
        try check(!action.matches(binding: binding, nonce: UUID(), at: now))
        try check(!action.matches(binding: binding, nonce: action.nonce, at: action.expiresAt))
        let changed = try ActionBinding(runID: g.runID, epoch: g.epoch + 1, grantDigest: binding.grantDigest, connectionID: binding.connectionID, operation: binding.operation, schemaDigest: binding.schemaDigest, resolvedResource: binding.resolvedResource, canonicalRequest: binding.canonicalRequest)
        try check(!action.matches(binding: changed, nonce: action.nonce, at: now))
        let changedBytes = try ActionBinding(runID: g.runID, epoch: g.epoch, grantDigest: binding.grantDigest, connectionID: binding.connectionID, operation: binding.operation, schemaDigest: binding.schemaDigest, resolvedResource: binding.resolvedResource, canonicalRequest: Data("{\"title\":\"B\"}".utf8))
        try check(!action.matches(binding: changedBytes, nonce: action.nonce, at: now))
        try check(changedBytes.canonicalParametersDigest != binding.canonicalParametersDigest)
        try rejects { _ = try ActionBinding(runID: g.runID, epoch: 1, grantDigest: binding.grantDigest, connectionID: binding.connectionID, operation: "create", schemaDigest: binding.schemaDigest, resolvedResource: "repo/example", canonicalRequest: Data(repeating: 65, count: 65_537)) }
    }),
    ("duplicate connections rejected on decoding", {
        let g = try grant()
        var data = try object(g)
        let connection = try object(g.connections[0])
        data["connections"] = [connection, connection]
        try rejects { _ = try JSONDecoder().decode(RunGrant.self, from: JSONSerialization.data(withJSONObject: data)) }
    })
]
var failures = 0
for (name, test) in tests {
    do { try test(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("\(tests.count - failures)/\(tests.count) contract checks passed")
exit(failures == 0 ? 0 : 1)
