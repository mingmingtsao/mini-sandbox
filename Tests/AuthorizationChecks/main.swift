import Foundation
import SandboxContracts
import SandboxHost

final class RecordingSink: SynchronousAuditSink, @unchecked Sendable {
    private(set) var events: [SecurityEvent] = []
    var fail = false
    func append(_ event: SecurityEvent) throws {
        if fail { throw SinkError.failed }
        events.append(event)
    }
    enum SinkError: Error { case failed }
}

final class TestClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}

@main struct AuthorizationChecks {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("lifecycle and audit", testLifecycleAndAudit),
            ("binding and connection checks", testBindingAndConnectionChecks),
            ("concurrent consumption", testConcurrentConsume),
            ("audit failure revokes without dispatch", testAuditFailureRevokesWithoutDispatch),
            ("expiry and stop", testExpiryAndStop),
            ("JSONL audit sink", testJSONLAuditSink),
            ("connection revocation is terminal", testConnectionRevocationIsTerminal),
            ("connection versions cannot roll back", testConnectionVersionsCannotRollBack),
            ("host approval checks live connection", testHostApprovalChecksConnection),
            ("active pending limit recovers", testPendingLimitRecovery),
            ("denial history is bounded without lifetime cap", testDenialHistoryIsBounded),
            ("expiry releases capacity", testExpiryReleasesCapacity),
            ("completion history and issued tickets", testCompletionHistoryAndIssuedTickets),
            ("outstanding ticket backpressure recovers", testOutstandingTicketBackpressure),
            ("grant digest canonical reconstruction", testCanonicalGrantDigest),
            ("grant digest covers every field", testGrantDigestFieldCoverage),
            ("caller Data mutation preserves proposal bytes", testCallerDataMutation)
        ] + sharedExpiryPaths.map { path, position in
            ("shared expiry observation " + path, { try await testSharedExpiry(path: path, position: position) })
        }
        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("AuthorizationChecks: \(tests.count - failures) passed, \(failures) failed (\(tests.count) groups)")
        if failures > 0 { exit(1) }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message) }
    }

    static func expectError(_ operation: () async throws -> Void, _ expected: AuthorizationError, _ message: String) async throws {
        do {
            try await operation()
            throw CheckFailure("expected \(expected) for \(message)")
        } catch let error as AuthorizationError {
            guard error == expected else { throw CheckFailure("expected \(expected), got \(error) for \(message)") }
        }
    }

    static func makeGrant(runID: UUID, now: Date, connectionID: UUID, scope: ResourceScope, expiresIn: TimeInterval = 300) throws -> RunGrant {
        let connection = try ConnectionGrant(connectionID: connectionID, accountBindingVersion: 7, routeVersion: 11, scopes: [scope])
        return try RunGrant(runID: runID, epoch: 1, createdAt: now, expiresAt: now.addingTimeInterval(expiresIn), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "adapter-1", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [connection], explicitDenies: [], resourceLimits: try ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 1024, concurrentRequests: 1))
    }

    static func makeBinding(grant: RunGrant, connectionID: UUID, scope: ResourceScope, body: String = "{\"value\":1}") throws -> ActionBinding {
        try ActionBinding(runID: grant.runID, epoch: grant.epoch, grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: connectionID, operation: scope.operation, schemaDigest: String(repeating: "c", count: 64), resolvedResource: scope.resource, canonicalRequest: Data(body.utf8))
    }

    static func testLifecycleAndAudit() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(now)
        let sink = RecordingSink()
        let controller = RunAuthorizationController(auditSink: sink, now: clock.now)
        let runID = UUID(); let connectionID = UUID()
        let scope = try ResourceScope(service: "files", resource: "docs/1", operation: "read")
        let grant = try makeGrant(runID: runID, now: now, connectionID: connectionID, scope: scope)
        let handle = try await controller.install(grant: grant)
        let pending = try await controller.propose(handle: handle, binding: makeBinding(grant: grant, connectionID: connectionID, scope: scope), display: "read docs/1")
        try await controller.deny(handle: handle, actionID: pending.actionID)
        try await expectError({ _ = try await controller.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce) }, .actionDenied, "explicit deny")
        try require(sink.events.contains { $0.origin == .hostEnforcement && $0.decision == .deny }, "deny is host-origin")
        try await controller.recordGuestDiagnostic(runID: runID, operation: "read", resourceSummary: "docs/1", message: "guest says hello")
        try require(sink.events.contains { $0.origin == .guestDiagnostic }, "guest diagnostic recorded")
        try require(sink.events.filter { $0.origin == .guestDiagnostic }.allSatisfy { $0.decision == .observe }, "diagnostic is observe only")
    }

    static func testBindingAndConnectionChecks() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let sink = RecordingSink(); let controller = RunAuthorizationController(auditSink: sink, now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/2", operation: "write")
        let runA = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let runB = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let handleA = try await controller.install(grant: runA)
        let handleB = try await controller.install(grant: runB)
        let bindingA = try makeBinding(grant: runA, connectionID: runA.connections[0].connectionID, scope: scope)
        let bindingB = try makeBinding(grant: runB, connectionID: runB.connections[0].connectionID, scope: scope)
        try await expectError({ _ = try await controller.propose(handle: handleA, binding: bindingB, display: "wrong run") }, .wrongRun, "wrong handle/run")
        let wrongEpoch = try ActionBinding(runID: runA.runID, epoch: 2, grantDigest: bindingA.grantDigest, connectionID: bindingA.connectionID, operation: scope.operation, schemaDigest: bindingA.schemaDigest, resolvedResource: scope.resource, canonicalRequest: Data("{\"value\":1}".utf8))
        try await expectError({ _ = try await controller.propose(handle: handleA, binding: wrongEpoch, display: "wrong epoch") }, .wrongEpoch, "wrong epoch")
        let changed = try makeBinding(grant: runA, connectionID: runA.connections[0].connectionID, scope: scope, body: "{\"value\":2}")
        let changedPending = try await controller.propose(handle: handleA, binding: changed, display: "changed")
        let approved = try await controller.hostApprove(handle: handleA, actionID: changedPending.actionID, nonce: changedPending.nonce)
        let ticket = try await controller.consume(handle: handleA, approved: approved)
        try require(ticket.approvedRequest == Data("{\"value\":2}".utf8), "ticket contains exact approved bytes")
        try require(sink.events.contains { $0.actionID == changedPending.actionID && $0.reason == "dispatch-intent" && $0.decision == .allow }, "dispatch intent is audited")
        try await controller.stop(handle: handleA)
        try await controller.complete(handle: handleA, ticket: ticket, outcome: .completed)
        try await expectError({ try await controller.complete(handle: handleA, ticket: ticket, outcome: .failed) }, .completionAlreadyRecorded, "completion is one-shot")
        try await expectError({ _ = try await controller.propose(handle: handleB, binding: bindingA, display: "wrong handle") }, .wrongRun, "wrong handle")
        let pendingB = try await controller.propose(handle: handleB, binding: bindingB, display: "revoked")
        let approvedB = try await controller.hostApprove(handle: handleB, actionID: pendingB.actionID, nonce: pendingB.nonce)
        try await controller.revokeConnection(handle: handleB, connectionID: runB.connections[0].connectionID)
        try await expectError({ _ = try await controller.consume(handle: handleB, approved: approvedB) }, .connectionRevoked, "revoked connection")
    }

    static func testConcurrentConsume() async throws {
        let now = Date(timeIntervalSince1970: 3_000); let sink = RecordingSink()
        let controller = RunAuthorizationController(auditSink: sink, now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/3", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let handle = try await controller.install(grant: grant)
        let pending = try await controller.propose(handle: handle, binding: makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope), display: "read")
        let approved = try await controller.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { _ = try await controller.consume(handle: handle, approved: approved); return true }
                    catch { return false }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        try require(results.filter { $0 }.count == 1, "exactly one concurrent consumer wins")

    }

    static func testAuditFailureRevokesWithoutDispatch() async throws {
        let now = Date(timeIntervalSince1970: 4_000); let sink = RecordingSink()
        let controller = RunAuthorizationController(auditSink: sink, now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/4", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let handle = try await controller.install(grant: grant)
        let pending = try await controller.propose(handle: handle, binding: makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope), display: "read")
        let approved = try await controller.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce)
        sink.fail = true
        try await expectError({ _ = try await controller.consume(handle: handle, approved: approved) }, .auditFailed, "audit failure")
        sink.fail = false
        try await expectError({ _ = try await controller.consume(handle: handle, approved: approved) }, .runRevoked, "audit failure revokes run")
    }

    static func testExpiryAndStop() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5_000)); let sink = RecordingSink()
        let controller = RunAuthorizationController(auditSink: sink, now: clock.now)
        let scope = try ResourceScope(service: "files", resource: "docs/5", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: clock.value, connectionID: UUID(), scope: scope, expiresIn: 1_000)
        let handle = try await controller.install(grant: grant)
        let pending = try await controller.propose(handle: handle, binding: makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope), display: "read")
        clock.value = clock.value.addingTimeInterval(301)
        try await expectError({ _ = try await controller.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce) }, .actionExpired, "late approve")
        let stopClock = TestClock(Date(timeIntervalSince1970: 5_000))
        let stopController = RunAuthorizationController(auditSink: RecordingSink(), now: stopClock.now)
        let stopGrant = try makeGrant(runID: UUID(), now: stopClock.value, connectionID: UUID(), scope: scope)
        let stopHandle = try await stopController.install(grant: stopGrant)
        let pending2 = try await stopController.propose(handle: stopHandle, binding: makeBinding(grant: stopGrant, connectionID: stopGrant.connections[0].connectionID, scope: scope, body: "{\"value\":9}"), display: "read")
        try await stopController.stop(handle: stopHandle)
        try await expectError({ _ = try await stopController.hostApprove(handle: stopHandle, actionID: pending2.actionID, nonce: pending2.nonce) }, .runRevoked, "stop revokes before approve")
    }

    static func testJSONLAuditSink() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("authorization-\(UUID().uuidString).jsonl")
        let sink = try JSONLAuditSink(newFileAt: path)
        let controller = RunAuthorizationController(auditSink: sink, now: { Date(timeIntervalSince1970: 6_000) })
        try await controller.recordGuestDiagnostic(runID: UUID(), operation: "read", resourceSummary: "docs", message: "diagnostic")
        let data = try Data(contentsOf: path)
        try require(data.last == 10, "audit is JSONL")
        try require(!String(decoding: data, as: UTF8.self).contains("canonicalRequest"), "audit excludes canonical bytes")
        try FileManager.default.removeItem(at: path)
    }

    static func testConnectionRevocationIsTerminal() async throws {
        let now = Date(timeIntervalSince1970: 7_000)
        let sink = RecordingSink()
        let controller = RunAuthorizationController(auditSink: sink, now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/revocation", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let connectionID = grant.connections[0].connectionID
        let handle = try await controller.install(grant: grant)
        let pending = try await controller.propose(handle: handle, binding: makeBinding(grant: grant, connectionID: connectionID, scope: scope), display: "read")
        let approved = try await controller.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce)
        try await controller.revokeConnection(handle: handle, connectionID: connectionID)
        var updateError: AuthorizationError?
        do { try await controller.updateConnection(handle: handle, connectionID: connectionID, accountBindingVersion: 7, routeVersion: 11) }
        catch let error as AuthorizationError { updateError = error }
        // Assert the unsafe effect first, even if a buggy update silently succeeds.
        try await expectError({ _ = try await controller.consume(handle: handle, approved: approved) }, .connectionRevoked, "revoke then restore original versions never revives approval")
        try require(updateError == .connectionRevoked, "updates cannot undo revocation")
        try require(!sink.events.contains { $0.reason == "dispatch-intent" }, "revoked action never yields dispatch intent")
    }

    static func testConnectionVersionsCannotRollBack() async throws {
        for versions: (UInt64, UInt64) in [(8, 12), (8, 11), (7, 12)] {
            let now = Date(timeIntervalSince1970: 8_000)
            let controller = RunAuthorizationController(auditSink: RecordingSink(), now: { now })
            let scope = try ResourceScope(service: "files", resource: "docs/versions", operation: "read")
            let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
            let connectionID = grant.connections[0].connectionID
            let handle = try await controller.install(grant: grant)
            let binding = try makeBinding(grant: grant, connectionID: connectionID, scope: scope)
            let pending = try await controller.propose(handle: handle, binding: binding, display: "read")
            let approved = try await controller.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce)
            try await controller.updateConnection(handle: handle, connectionID: connectionID, accountBindingVersion: versions.0, routeVersion: versions.1)
            var rollbackError: AuthorizationError?
            do { try await controller.updateConnection(handle: handle, connectionID: connectionID, accountBindingVersion: 7, routeVersion: 11) }
            catch let error as AuthorizationError { rollbackError = error }
            try await expectError({ _ = try await controller.consume(handle: handle, approved: approved) }, .connectionVersionMismatch, "version rollback must not revive approval")
            try require(rollbackError == .connectionVersionMismatch, "version rollback is rejected")
            try await expectError({ _ = try await controller.propose(handle: handle, binding: binding, display: "stale grant") }, .connectionVersionMismatch, "old grant stays invalid")
        }
    }

    static func testHostApprovalChecksConnection() async throws {
        for change in 0..<3 {
            let now = Date(timeIntervalSince1970: 9_000)
            let controller = RunAuthorizationController(auditSink: RecordingSink(), now: { now })
            let scope = try ResourceScope(service: "files", resource: "docs/approve", operation: "read")
            let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
            let connectionID = grant.connections[0].connectionID
            let handle = try await controller.install(grant: grant)
            let pending = try await controller.propose(handle: handle, binding: makeBinding(grant: grant, connectionID: connectionID, scope: scope), display: "read")
            if change == 0 {
                try await controller.revokeConnection(handle: handle, connectionID: connectionID)
            } else {
                try await controller.updateConnection(handle: handle, connectionID: connectionID, accountBindingVersion: change == 1 ? 8 : 7, routeVersion: change == 2 ? 12 : 11)
            }
            try await expectError({ _ = try await controller.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce) }, change == 0 ? .connectionRevoked : .connectionVersionMismatch, "live connection checked at approval")
        }
    }

    static func testPendingLimitRecovery() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let controller = RunAuthorizationController(auditSink: RecordingSink(), now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/capacity", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let binding = try makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope)
        let handle = try await controller.install(grant: grant)
        var actions: [PendingAction] = []
        for _ in 0..<32 { actions.append(try await controller.propose(handle: handle, binding: binding, display: "read")) }
        let approved = try await controller.hostApprove(handle: handle, actionID: actions[0].actionID, nonce: actions[0].nonce)
        try await expectError({ _ = try await controller.propose(handle: handle, binding: binding, display: "33rd") }, .pendingLimit, "32 pending or approved actions reject 33rd")
        try await controller.deny(handle: handle, actionID: actions[1].actionID)
        _ = try await controller.propose(handle: handle, binding: binding, display: "replacement after deny")
        let ticket = try await controller.consume(handle: handle, approved: approved)
        try await controller.complete(handle: handle, ticket: ticket, outcome: .completed)
        _ = try await controller.propose(handle: handle, binding: binding, display: "replacement after completion")
        try await expectError({ _ = try await controller.propose(handle: handle, binding: binding, display: "33rd again") }, .pendingLimit, "active limit remains enforced after recovery")
    }

    static func testDenialHistoryIsBounded() async throws {
        let now = Date(timeIntervalSince1970: 11_000)
        let controller = RunAuthorizationController(auditSink: RecordingSink(), now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/deny-history", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let binding = try makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope)
        let handle = try await controller.install(grant: grant)
        var actions: [PendingAction] = []
        for _ in 0..<80 {
            let action = try await controller.propose(handle: handle, binding: binding, display: "deny")
            try await controller.deny(handle: handle, actionID: action.actionID)
            actions.append(action)
        }
        try await expectError({ _ = try await controller.hostApprove(handle: handle, actionID: actions[0].actionID, nonce: actions[0].nonce) }, .actionNotPending, "old tombstone evicted but approval still rejected")
        try await expectError({ _ = try await controller.hostApprove(handle: handle, actionID: actions[15].actionID, nonce: actions[15].nonce) }, .actionNotPending, "65th-most-recent denial is evicted")
        try await expectError({ _ = try await controller.hostApprove(handle: handle, actionID: actions[16].actionID, nonce: actions[16].nonce) }, .actionDenied, "64th-most-recent denial is retained")
        let recent = actions[79]
        try await expectError({ _ = try await controller.hostApprove(handle: handle, actionID: recent.actionID, nonce: recent.nonce) }, .actionDenied, "recent denied action retains precise error")
    }

    static func testExpiryReleasesCapacity() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 12_000))
        let controller = RunAuthorizationController(auditSink: RecordingSink(), now: clock.now)
        let scope = try ResourceScope(service: "files", resource: "docs/expiry-capacity", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: clock.value, connectionID: UUID(), scope: scope, expiresIn: 2_000)
        let binding = try makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope)
        let handle = try await controller.install(grant: grant)
        for _ in 0..<3 {
            var approved: ApprovedAction?
            for index in 0..<32 {
                let action = try await controller.propose(handle: handle, binding: binding, display: "expire")
                if index == 0 { approved = try await controller.hostApprove(handle: handle, actionID: action.actionID, nonce: action.nonce) }
            }
            clock.value = clock.value.addingTimeInterval(301)
            try await expectError({ _ = try await controller.consume(handle: handle, approved: approved!) }, .actionExpired, "approved action expires")
        }
        _ = try await controller.propose(handle: handle, binding: binding, display: "after expiry batches")
    }

    static func testCompletionHistoryAndIssuedTickets() async throws {
        let now = Date(timeIntervalSince1970: 13_000)
        let clock = TestClock(now)
        let sink = RecordingSink()
        let controller = RunAuthorizationController(auditSink: sink, now: clock.now)
        let scope = try ResourceScope(service: "files", resource: "docs/completion-history", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let binding = try makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope)
        let handle = try await controller.install(grant: grant)
        let original = try await controller.propose(handle: handle, binding: binding, display: "long-running")
        let originalApproval = try await controller.hostApprove(handle: handle, actionID: original.actionID, nonce: original.nonce)
        let originalTicket = try await controller.consume(handle: handle, approved: originalApproval)
        var approvals: [ApprovedAction] = []
        var tickets: [DispatchTicket] = []
        for _ in 0..<80 {
            let action = try await controller.propose(handle: handle, binding: binding, display: "complete")
            let approved = try await controller.hostApprove(handle: handle, actionID: action.actionID, nonce: action.nonce)
            let ticket = try await controller.consume(handle: handle, approved: approved)
            try await controller.complete(handle: handle, ticket: ticket, outcome: .unknown)
            approvals.append(approved)
            tickets.append(ticket)
        }
        try await expectError({ _ = try await controller.consume(handle: handle, approved: approvals[0]) }, .ticketInvalid, "evicted consumed action cannot replay")
        try await expectError({ try await controller.complete(handle: handle, ticket: tickets[0], outcome: .completed) }, .ticketInvalid, "evicted completion cannot replay")
        try await expectError({ _ = try await controller.consume(handle: handle, approved: approvals[15]) }, .ticketInvalid, "65th-most-recent consumption is evicted")
        try await expectError({ _ = try await controller.consume(handle: handle, approved: approvals[16]) }, .ticketAlreadyConsumed, "64th-most-recent consumption is retained")
        try await expectError({ try await controller.complete(handle: handle, ticket: tickets[15], outcome: .completed) }, .ticketInvalid, "65th-most-recent completion is evicted")
        try await expectError({ try await controller.complete(handle: handle, ticket: tickets[16], outcome: .completed) }, .completionAlreadyRecorded, "64th-most-recent completion is retained")
        try await expectError({ _ = try await controller.consume(handle: handle, approved: approvals[79]) }, .ticketAlreadyConsumed, "recent consumption is one-shot")
        try await expectError({ try await controller.complete(handle: handle, ticket: tickets[79], outcome: .failed) }, .completionAlreadyRecorded, "recent completion is one-shot")
        let blockedAction = try await controller.propose(handle: handle, binding: binding, display: "stop before consume")
        let blockedApproval = try await controller.hostApprove(handle: handle, actionID: blockedAction.actionID, nonce: blockedAction.nonce)
        try await controller.stop(handle: handle)
        try await expectError({ _ = try await controller.consume(handle: handle, approved: blockedApproval) }, .runRevoked, "stop prevents new tickets")
        clock.value = grant.expiresAt
        try await controller.complete(handle: handle, ticket: originalTicket, outcome: .completed)
        try await expectError({ try await controller.complete(handle: handle, ticket: originalTicket, outcome: .unknown) }, .completionAlreadyRecorded, "issued ticket survives history churn and stop exactly once")
        try require(sink.events.filter { $0.reason == "dispatch-intent" }.count == 81, "no replay or auto retry dispatch intent")
        try require(sink.events.filter { $0.reason == "dispatch-completion" }.count == 81, "one completion per issued ticket")
    }

    static func testOutstandingTicketBackpressure() async throws {
        let now = Date(timeIntervalSince1970: 14_000)
        let controller = RunAuthorizationController(auditSink: RecordingSink(), now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/in-flight", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let binding = try makeBinding(grant: grant, connectionID: grant.connections[0].connectionID, scope: scope)
        let handle = try await controller.install(grant: grant)
        var tickets: [DispatchTicket] = []
        for _ in 0..<32 {
            let action = try await controller.propose(handle: handle, binding: binding, display: "in-flight")
            let approved = try await controller.hostApprove(handle: handle, actionID: action.actionID, nonce: action.nonce)
            tickets.append(try await controller.consume(handle: handle, approved: approved))
        }
        let waiting = try await controller.propose(handle: handle, binding: binding, display: "waiting")
        let waitingApproval = try await controller.hostApprove(handle: handle, actionID: waiting.actionID, nonce: waiting.nonce)
        try await expectError({ _ = try await controller.consume(handle: handle, approved: waitingApproval) }, .pendingLimit, "outstanding dispatch records are bounded")
        try await controller.complete(handle: handle, ticket: tickets[0], outcome: .completed)
        let lastTicket = try await controller.consume(handle: handle, approved: waitingApproval)
        try await controller.stop(handle: handle)
        for ticket in tickets.dropFirst() { try await controller.complete(handle: handle, ticket: ticket, outcome: .unknown) }
        try await controller.complete(handle: handle, ticket: lastTicket, outcome: .failed)
    }

    static func complexGrant() throws -> RunGrant {
        let scopes = try [
            ResourceScope(service: "files", resource: "docs/1", operation: "read"),
            ResourceScope(service: "files", resource: "docs/1", operation: "write"),
            ResourceScope(service: "files", resource: "docs/2", operation: "read"),
            ResourceScope(service: "archive", resource: "docs/1", operation: "read")
        ]
        return try RunGrant(runID: UUID(), epoch: 1, createdAt: Date(timeIntervalSince1970: 15_000), expiresAt: Date(timeIntervalSince1970: 16_000), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "adapter-1", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [
            ConnectionGrant(connectionID: UUID(), accountBindingVersion: 7, routeVersion: 11, scopes: Set(scopes)),
            ConnectionGrant(connectionID: UUID(), accountBindingVersion: 8, routeVersion: 12, scopes: Set(scopes))
        ], explicitDenies: Set(scopes), resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 1024, concurrentRequests: 1))
    }

    static func testCanonicalGrantDigest() async throws {
        let grant = try complexGrant()
        let expected = RunAuthorizationController.grantDigest(for: grant)
        try require(expected.count == 64, "SHA256 digest has expected length")
        for index in 0..<24 {
            let connections = try grant.connections.map {
                try ConnectionGrant(connectionID: $0.connectionID, accountBindingVersion: $0.accountBindingVersion, routeVersion: $0.routeVersion, scopes: Set(Array($0.scopes).reversed()))
            }
            let reconstructed = try RunGrant(runID: grant.runID, epoch: grant.epoch, createdAt: grant.createdAt, expiresAt: grant.expiresAt, workloadImageDigest: grant.workloadImageDigest, agentAdapterVersion: grant.agentAdapterVersion, workspaceSnapshotID: grant.workspaceSnapshotID, policyDigest: grant.policyDigest, approvalSnapshotID: grant.approvalSnapshotID, connections: index.isMultiple(of: 2) ? connections : Array(connections.reversed()), explicitDenies: Set(Array(grant.explicitDenies).reversed()), resourceLimits: grant.resourceLimits)
            try require(RunAuthorizationController.grantDigest(for: reconstructed) == expected, "equivalent multi-element sets and connection order have same digest")
            let roundTrip = try JSONDecoder().decode(RunGrant.self, from: JSONEncoder().encode(reconstructed))
            try require(RunAuthorizationController.grantDigest(for: roundTrip) == expected, "round trip has same canonical digest")
        }
    }

    static func testGrantDigestFieldCoverage() async throws {
        let grant = try complexGrant()
        let expected = RunAuthorizationController.grantDigest(for: grant)
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)) as! [String: Any]
        let topLevel: [(String, Any)] = [
            ("runID", UUID().uuidString), ("epoch", 2),
            ("createdAt", grant.createdAt.timeIntervalSinceReferenceDate + 1),
            ("expiresAt", grant.expiresAt.timeIntervalSinceReferenceDate + 1),
            ("workloadImageDigest", String(repeating: "d", count: 64)),
            ("agentAdapterVersion", "adapter-2"), ("workspaceSnapshotID", UUID().uuidString),
            ("policyDigest", String(repeating: "e", count: 64)), ("approvalSnapshotID", UUID().uuidString)
        ]
        func assertDifferent(_ object: [String: Any], _ field: String) throws {
            let changed = try JSONDecoder().decode(RunGrant.self, from: JSONSerialization.data(withJSONObject: object))
            try require(RunAuthorizationController.grantDigest(for: changed) != expected, "digest covers \(field)")
        }
        for (key, value) in topLevel {
            var changed = base; changed[key] = value
            try assertDifferent(changed, key)
        }
        for key in ["cpuCount", "memoryBytes", "diskBytes", "messageBytes", "concurrentRequests"] {
            var changed = base
            var limits = changed["resourceLimits"] as! [String: Any]
            limits[key] = key == "messageBytes" ? 2048 : 2
            changed["resourceLimits"] = limits
            try assertDifferent(changed, "resourceLimits.\(key)")
        }
        for (key, value) in [("connectionID", UUID().uuidString as Any), ("accountBindingVersion", 99 as Any), ("routeVersion", 99 as Any)] {
            var changed = base
            var connections = changed["connections"] as! [[String: Any]]
            connections[0][key] = value
            changed["connections"] = connections
            try assertDifferent(changed, "connections.\(key)")
        }
        for field in ["service", "resource", "operation"] {
            for isDeny in [false, true] {
                var changed = base
                if isDeny {
                    var denies = changed["explicitDenies"] as! [[String: Any]]
                    denies[0][field] = "changed"
                    changed["explicitDenies"] = denies
                } else {
                    var connections = changed["connections"] as! [[String: Any]]
                    var scopes = connections[0]["scopes"] as! [[String: Any]]
                    scopes[0][field] = "changed"
                    connections[0]["scopes"] = scopes
                    changed["connections"] = connections
                }
                try assertDifferent(changed, "\(isDeny ? "explicitDenies" : "scopes").\(field)")
            }
        }
    }

    static func testCallerDataMutation() async throws {
        let now = Date(timeIntervalSince1970: 17_000)
        let controller = RunAuthorizationController(auditSink: RecordingSink(), now: { now })
        let scope = try ResourceScope(service: "files", resource: "docs/original-bytes", operation: "write")
        let grant = try makeGrant(runID: UUID(), now: now, connectionID: UUID(), scope: scope)
        let original = Data("{\"value\":1}".utf8)
        var callerData = original
        let binding = try ActionBinding(runID: grant.runID, epoch: grant.epoch, grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: grant.connections[0].connectionID, operation: scope.operation, schemaDigest: String(repeating: "c", count: 64), resolvedResource: scope.resource, canonicalRequest: callerData)
        let handle = try await controller.install(grant: grant)
        let action = try await controller.propose(handle: handle, binding: binding, display: "write original")
        callerData.replaceSubrange(0..<callerData.count, with: Data("{\"value\":9}".utf8))
        try require(callerData != original, "caller actually mutated Data after proposal")
        let approved = try await controller.hostApprove(handle: handle, actionID: action.actionID, nonce: action.nonce)
        let ticket = try await controller.consume(handle: handle, approved: approved)
        try require(ticket.approvedRequest == original, "ticket carries original proposed bytes, not caller mutation")
    }

    enum CheckFailure: Error { case message(String); init(_ message: String) { self = .message(message) } }
}

/// Host-owned clock: one expiry observation followed immediately by rollback.
final class AuthorityPulseClock: @unchecked Sendable {
    let base = Date(timeIntervalSince1970: 1_900_000_000)
    private let lock = NSLock()
    private var target = 0
    private var reads = 0
    private var fired = false
    func arm(_ position: Int) { lock.withLock { target = position; reads = 0; fired = false } }
    func now() -> Date {
        lock.withLock {
            reads += 1
            if reads == target { fired = true; return base.addingTimeInterval(900) }
            return base
        }
    }
    var observed: Bool { lock.withLock { fired } }
}

extension AuthorizationChecks {
    static let sharedExpiryPaths: [(String, Int)] = [
        ("propose", 1), ("approve", 1), ("deny", 1), ("consume", 1),
        ("intent", 2), ("completion", 1), ("reject", 2), ("diagnostic", 1)
    ]
    static func testSharedExpiry(path: String, position: Int) async throws {
        let clock = AuthorityPulseClock(), sink = RecordingSink(), id = UUID()
        let scope = try ResourceScope(service: "files", resource: "docs/pulse", operation: "read")
        let grant = try makeGrant(runID: UUID(), now: clock.base, connectionID: id, scope: scope, expiresIn: 900)
        let authority = RunAuthorizationController(auditSink: sink, now: clock.now)
        let handle = try await authority.install(grant: grant)
        let binding = try makeBinding(grant: grant, connectionID: id, scope: scope)
        let a = try await authority.propose(handle: handle, binding: binding, display: "A")
        let b = try await authority.propose(handle: handle, binding: binding, display: "B")
        let approvedB = try await authority.hostApprove(handle: handle, actionID: b.actionID, nonce: b.nonce)
        var approvedA: ApprovedAction?
        var ticketA: DispatchTicket?
        if ["consume", "intent", "completion"].contains(path) {
            approvedA = try await authority.hostApprove(handle: handle, actionID: a.actionID, nonce: a.nonce)
        }
        if path == "completion" { ticketA = try await authority.consume(handle: handle, approved: approvedA!) }
        clock.arm(position)
        var observedError: AuthorizationError?
        do {
            switch path {
            case "propose": _ = try await authority.propose(handle: handle, binding: binding, display: "pulse")
            case "approve": _ = try await authority.hostApprove(handle: handle, actionID: a.actionID, nonce: a.nonce)
            case "deny": try await authority.deny(handle: handle, actionID: a.actionID)
            case "consume", "intent": ticketA = try await authority.consume(handle: handle, approved: approvedA!)
            case "completion": try await authority.complete(handle: handle, ticket: ticketA!, outcome: .unknown)
            case "reject":
                let wrong = try ActionBinding(runID: UUID(), epoch: grant.epoch, grantDigest: binding.grantDigest, connectionID: id, operation: scope.operation, schemaDigest: binding.schemaDigest, resolvedResource: scope.resource, canonicalRequest: binding.canonicalRequest)
                _ = try await authority.propose(handle: handle, binding: wrong, display: "reject")
            default: try await authority.recordGuestDiagnostic(runID: grant.runID, operation: "read", resourceSummary: "docs/pulse", message: "untrusted text is not authority")
            }
        } catch let error as AuthorizationError { observedError = error }
        let events = sink.events
        var bConsumed = false
        do { _ = try await authority.consume(handle: handle, approved: approvedB); bConsumed = true }
        catch let error as AuthorizationError { try require(error == .runRevoked || error == .grantExpired, "terminal rejection is truthful") }
        print("AUTH_PULSE path=\(path) fired=\(clock.observed) rollback_B_consumed=\(bConsumed) audit_failed=\(observedError == .auditFailed) network_attempted=false")
        try require(clock.observed, "real sample anchor reached")
        try require(observedError != .auditFailed, "expiry is not an audit failure")
        if path == "deny" { try require(events.filter { $0.reason == "explicit-deny" }.count == 1, "truthful denial persisted once; returning normally is allowed") }
        if path == "completion" {
            try require(events.filter { $0.reason == "dispatch-completion" && $0.outcome == .unknown }.count == 1, "truthful completion persists once")
            try await expectError({ try await authority.complete(handle: handle, ticket: ticketA!, outcome: .completed) }, .completionAlreadyRecorded, "expired completion remains one-shot")
        }
        if path == "diagnostic" { try require(events.last?.origin == .guestDiagnostic && events.last?.decision == .observe, "host timestamp does not upgrade guest origin") }
        try require(!bConsumed, "trusted \(path) expiry observation must revoke independently approved B despite rollback")
    }
}
