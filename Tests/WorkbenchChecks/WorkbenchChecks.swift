import Foundation
import Darwin
import SandboxContracts
import SandboxHost
import SandboxWorkbench

@main struct WorkbenchChecks {
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--composition-native-close-only") {
                try await CompositionNativeCloseChecks.run()
                return
            }
            if CommandLine.arguments.contains("--composition-diagnostic-only") {
                try await CompositionDiagnosticChecks.run()
                return
            }
            if CommandLine.arguments.contains("--composition-mcp") {
                try await CompositionMCPChecks.run()
                return
            }
            if CommandLine.arguments.contains("--composition-bounds-only") {
                try await CompositionBoundsChecks.run()
                return
            }
            if CommandLine.arguments.contains("--composition-close-only") {
                try await CompositionCloseChecks.run()
                return
            }
            if CommandLine.arguments.contains("--connection-settings-only") {
                try await ConnectionSettingsChecks.run()
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let model = WorkbenchModel(newAuditFileAt: url)
            try require(model.grants.isEmpty && model.pending.isEmpty && model.approvedActions.isEmpty, "initial state must be empty")
            try require(model.authorityAvailable, "real audit startup succeeds")
            let scope = try ResourceScope(service: "files", resource: "docs/1", operation: "write")
            let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1), expiresAt: Date().addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "test", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: UUID(), accountBindingVersion: 1, routeVersion: 1, scopes: [scope])], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 1024, concurrentRequests: 1))
            try await model.installTrustedGrant(grant)
            let binding = try ActionBinding(runID: grant.runID, epoch: 1, grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: grant.connections[0].connectionID, operation: "write", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "docs/1", canonicalRequest: Data("{\"value\":1}".utf8))
            let pending = try await model.proposeTrustedAction(binding: binding, display: "Write docs/1")
            try require(model.grants == [grant] && model.pending == [pending], "real grant and pending snapshots")
            try require(model.approvedActions.isEmpty, "presentation cannot authorize")
            try await model.deny(pending)
            do { _ = try await model.approveOnce(pending); throw Failure(message: "denied action approved") } catch is AuthorizationError {}
            let next = try await model.proposeTrustedAction(binding: binding, display: "Write exact bytes")
            let approved = try await model.approveOnce(next)
            try require(model.approvedActions[approved.actionID] != nil, "real approval retained")
            let beforeStaleDeny = model.activity
            do { try await model.deny(next); throw Failure(message: "approved action deny reported success") }
            catch let error as AuthorizationError { try require(error == .actionNotPending, "approved action is not pending, not revoked") }
            await model.dismiss(next)
            try require(model.approvedActions[approved.actionID] != nil, "stale deny/dismiss retains real approved capability")
            try require(model.activity == beforeStaleDeny, "stale approved denial adds no fabricated audit")
            try require(!model.activity.contains { $0.reason == "dispatch-intent" }, "UI never auto-consumes")
            let ticket = try await model.consumeForTrustedHost(runID: grant.runID, approved: approved)
            try require(ticket.approvedRequest == binding.canonicalRequest, "exact immutable binding")
            let dismiss = try await model.proposeTrustedAction(binding: binding, display: "Dismiss")
            await model.dismiss(dismiss)
            do { _ = try await model.approveOnce(dismiss); throw Failure(message: "dismiss approved") } catch is AuthorizationError {}
            let count = model.trustedDenialCount
            try await model.recordGuestDiagnostic(runID: grant.runID, operation: "write", resource: "docs/1", message: "deny: guest claim")
            try require(model.trustedDenialCount == count && model.activity.last?.origin == .guestDiagnostic, "guest is not trusted denial")
            let late = try await model.proposeTrustedAction(binding: binding, display: "Late")
            try await model.stop(runID: grant.runID)
            do { _ = try await model.approveOnce(late); throw Failure(message: "stop approved") } catch is AuthorizationError {}
            try require(model.pending.isEmpty && model.approvedActions.isEmpty, "stop clears live authority snapshots")
            let closed = await model.close()
            try require(closed && model.isClosed, "close awaits revocation")
            let broken = WorkbenchModel(newAuditFileAt: url)
            try require(!broken.authorityAvailable && broken.errorMessage != nil, "existing audit path fails closed")
            do { try await broken.installTrustedGrant(grant); throw Failure(message: "failed audit installed") } catch is AuthorizationError {}
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            try require(lines.count == model.activity.count + 1, "cache only contains persisted events plus startup record")
            for scenario in ["expiry", "timeout", "connection", "close", "approved-expiry"] {
                let clock = Clock(grant.createdAt.addingTimeInterval(1))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID()).jsonl")
                defer { try? FileManager.default.removeItem(at: path) }
                let subject = WorkbenchModel(newAuditFileAt: path, clock: clock.source)
                try await subject.installTrustedGrant(grant)
                let action = try await subject.proposeTrustedAction(binding: binding, display: "<b>literal native text</b>")
                let view = WorkbenchView(model: subject)
                _ = view.body
                try require(subject.approvedActions.isEmpty, "rendering creates no authority")
                switch scenario {
                case "expiry": clock.advance(301)
                case "timeout": clock.advance(301); await subject.expirePending()
                case "approved-expiry":
                    let realApproval = try await subject.approveOnce(action)
                    clock.advance(301)
                    do { _ = try await subject.consumeForTrustedHost(runID: grant.runID, approved: realApproval); throw Failure(message: "expired capability consumed") } catch is AuthorizationError { checks += 1 }
                case "connection": try await subject.revokeConnection(runID: grant.runID, connectionID: binding.connectionID)
                default:
                    let realApproval = try await subject.approveOnce(action)
                    let result = await subject.close()
                    try require(result && subject.isClosed, "close returned only after revocation")
                    do { _ = try await subject.consumeForTrustedHost(runID: grant.runID, approved: realApproval); throw Failure(message: "closed capability consumed") } catch is AuthorizationError { checks += 1 }
                }
                do { _ = try await subject.approveOnce(action); throw Failure(message: "late approval: \(scenario)") } catch is AuthorizationError { checks += 1 }
                try require(subject.pending.isEmpty && subject.approvedActions.isEmpty, "late UI snapshot cleared: \(scenario)")
            }
            for reconciliation in ["timeout", "dismiss", "deny"] {
                let clock = Clock(grant.createdAt.addingTimeInterval(1))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID()).jsonl")
                defer { try? FileManager.default.removeItem(at: path) }
                let subject = WorkbenchModel(newAuditFileAt: path, clock: clock.source)
                try await subject.installTrustedGrant(grant)
                let a = try await subject.proposeTrustedAction(binding: binding, display: "A expires before B")
                clock.advance(301)
                let b = try await subject.proposeTrustedAction(binding: binding, display: "B remains pending")
                try require(subject.pending == [a, b] && clock.now() < grant.expiresAt, "controller cleanup leaves stale A snapshot with live B")
                let events = subject.activity
                switch reconciliation {
                case "timeout": await subject.expirePending()
                case "dismiss": await subject.dismiss(a)
                default:
                    do { try await subject.deny(a); throw Failure(message: "retired deny reported success") }
                    catch let error as AuthorizationError { try require(error == .actionNotPending, "direct deny preserves semantic failure") }
                }
                try require(subject.pending == [b], "already-retired A removed before late approval: \(reconciliation)")
                try require(subject.activity == events, "already-retired A fabricates no host denial audit: \(reconciliation)")
                if reconciliation != "deny" {
                    try require(subject.errorMessage == nil, "dismiss recognizes controller-retired action")
                }
                await subject.dismiss(a)
                try require(subject.pending == [b] && subject.activity == events, "repeated dismiss leaves B and audit unchanged")
            }
            let boundedURL = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: boundedURL) }
            let bounded = WorkbenchModel(newAuditFileAt: boundedURL)
            for _ in 0..<205 { try await bounded.recordGuestDiagnostic(runID: UUID(), operation: "observe", resource: "test", message: "guest") }
            try require(bounded.activity.count == 200 && bounded.trustedDenialCount == 0, "bounded durable guest activity")
            let persisted = try String(contentsOf: boundedURL, encoding: .utf8).split(separator: "\n")
            try require(persisted.count == 206, "disk retains all actual writes")
            let failureURL = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID()).jsonl")
            let startupFailureURL = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: failureURL); try? FileManager.default.removeItem(at: startupFailureURL) }
            let failing = WorkbenchModel(newAuditFileAt: failureURL)
            try await failing.installTrustedGrant(grant)
            let failureAction = try await failing.proposeTrustedAction(binding: binding, display: "Real write failure")
            try await withWritesBlocked {
                let startupFailure = WorkbenchModel(newAuditFileAt: startupFailureURL)
                try require(!startupFailure.authorityAvailable && startupFailure.errorMessage != nil, "startup write failure disables authority")
                do { try await failing.deny(failureAction); throw Failure(message: "failed disk write accepted") } catch let error as AuthorizationError {
                    try require(error == .auditFailed, "real OS write error reaches controller")
                }
            }
            try require(!failing.authorityAvailable && failing.pending.isEmpty && failing.activity.isEmpty, "failed append not forwarded; run revoked")
            print("WorkbenchChecks: \(checks) assertions passed, 0 failed (no GUI interaction tested)")
            try await ConnectionSettingsChecks.run()
            try await CompositionCloseChecks.run()
            try await CompositionBoundsChecks.run()
            try await CompositionDiagnosticChecks.run()
            try await CompositionNativeCloseChecks.run()
        } catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func withWritesBlocked(_ operation: @MainActor () async throws -> Void) async throws {
        var saved = rlimit()
        guard getrlimit(RLIMIT_FSIZE, &saved) == 0 else { throw Failure(message: "getrlimit failed") }
        let previous = signal(SIGXFSZ, SIG_IGN)
        var blocked = saved; blocked.rlim_cur = 0
        defer { _ = setrlimit(RLIMIT_FSIZE, &saved); _ = signal(SIGXFSZ, previous) }
        guard setrlimit(RLIMIT_FSIZE, &blocked) == 0 else { throw Failure(message: "setrlimit failed") }
        try await operation()
    }
    @MainActor static var checks = 0
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
        checks += 1
    }
    final class Clock: @unchecked Sendable {
        let source: RunClock
        init(_ date: Date) { source = .manual(wall: date) }
        func now() -> Date { source.now() }
        func advance(_ seconds: TimeInterval) { source.advance(seconds) }
    }
    struct Failure: Error { let message: String }
}
