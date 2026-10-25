import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench
import SharedClockSupport

struct Failure: Error { let message: String }
func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
final class Sink: SynchronousAuditSink, @unchecked Sendable {
    let lock = NSLock()
    var barrier = false
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func append(_ event: SecurityEvent) throws {
        if lock.withLock({ barrier }) { entered.signal(); release.wait() }
    }
}
func grant(_ clock: SharedHostClock, id: UUID = UUID(), connections: [ConnectionGrant] = []) throws -> RunGrant {
    try RunGrant(runID: id, epoch: 1, createdAt: clock.base, expiresAt: clock.base.addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "shared-test", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: connections, explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 2))
}
final class NeverCredentials: ModelCredentialProvider, MCPCredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { reads += 1 }; throw Failure(message: "unexpected credential read")
    }
    func credential(for binding: MCPCredentialBinding) throws -> MCPCredential {
        lock.withLock { reads += 1 }; throw Failure(message: "unexpected credential read")
    }
}
@main struct SharedAuthorityChecks {
    @MainActor static func main() async {
        var failed = 0
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("approval sheet binds shared Stop outside ordinary disabled controls", sheetStopBinding),
            ("approval sheet denial keeps Stop reachable through real busy audit", sheetBusyStop),
            ("approval presentation preserves deny stale closing and approved policies", presentationPolicies),
            ("UI Stop preserves unavailable closing and terminal policy", stopAvailabilityStates),
            ("UI Stop remains reachable during workbench-originated busy audit", workbenchBusyStop),
            ("UI stop shares identity and terminates while audit blocked", stopWhileAuditBlocked),
            ("VM shared terminal denies access", vmStop),
            ("VM rejects a handle from another run", vmForeignHandle),
            ("App composition injects one reference into all participants", composition),
            ("wall highwater and exact expiry never revive", wall),
            ("fixed monotonic deadline and simulated sleep", monotonic),
            ("new controller rejects old handle identity", oldHandle),
            ("shared Stop and diagnostic expiry reject both approved gateways", approvedGateways),
            ("connection revocation leaves unrelated run usable", connectionIsolation)
        ]
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        print("SharedAuthorityChecks: \(tests.count - failed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
    @MainActor static func stopWhileAuditBlocked() async throws {
        let clock = SharedHostClock(), sink = Sink()
        let a = RunAuthorizationController(auditSink: sink, clock: clock.source)
        let g = try grant(clock), h = try await a.install(grant: g)
        let other = try await a.install(grant: grant(clock))
        let owner = NSObject()
        let vm = try VMDiagnosticSession(owner: owner, runID: g.runID, epoch: g.epoch,
            workloadDigest: g.workloadImageDigest, sink: sink, authorityHandle: h, installedGrant: g)
        try check(vm.lifecycle === h.lifecycle, "VM identity in blocked-audit run")
        let m = try HostModelGateway(connections: [], auditSink: sink, authority: a)
        let c = try HostMCPGateway(connections: [], auditSink: sink, authority: a)
        let mh = try await m.install(grant: g, authorityHandle: h)
        let ch = try await c.install(grant: g, authorityHandle: h)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-ui-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let ui = WorkbenchModel(newAuditFileAt: url, clock: clock.source, authority: a)
        try await ui.installTrustedGrant(g, authorityHandle: h)
        let ml = try await m.lifecycle(handle: mh), cl = try await c.lifecycle(handle: ch)
        try check(ml === h.lifecycle && cl === h.lifecycle && ui.lifecycle(runID: g.runID) === h.lifecycle, "actual reference identity")
        sink.lock.withLock { sink.barrier = true }
        let audit = Task { try await a.recordGuestDiagnostic(runID: g.runID, operation: "fixture", resourceSummary: "fixture", message: "fixture") }
        let entered = await Task.detached { sink.waitUntilEntered() }.value
        guard entered else { sink.release.signal(); throw Failure(message: "audit did not enter") }
        var stop: Task<Void, Error>?
        await withCheckedContinuation { ack in
            stop = Task { @MainActor in ack.resume(); try await ui.stop(runID: g.runID) }
        }
        // Same MainActor resumes only after Stop reaches its first suspension.
        let terminal = h.lifecycle.currentStatus
        let modelRevoked = try await m.isRevoked(handle: mh), mcpRevoked = try await c.isRevoked(handle: ch)
        sink.lock.withLock { sink.barrier = false }
        var vmDenied = false
        do { try vm.open(owner: owner, now: 0) } catch VMProtocolError.stopped { vmDenied = true }
        sink.release.signal()
        let auditResult = await audit.result, stopResult = await stop!.result
        try auditResult.get(); try stopResult.get()
        try check(vmDenied, "VM access denied before blocked authority audit returns")
        try check(terminal == .stopped && modelRevoked && mcpRevoked, "Stop must invalidate both gateways before audit returns")
        try check(other.lifecycle.currentStatus == .active, "distinct runs independent")
        try check(h.lifecycle.currentGeneration == 2, "single terminal generation increment")
    }
    @MainActor static func composition() async throws {
        let clock = SharedHostClock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("composition-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: url), clock: clock.source)
        let run = try await root.install(grant(clock))
        let modelLifecycle = try await root.model.lifecycle(handle: run.modelHandle)
        let mcpLifecycle = try await root.mcp.lifecycle(handle: run.mcpHandle)
        let vm = try root.diagnosticSession(owner: NSObject(), run: run)
        let modelAuthority = await root.model.authority, mcpAuthority = await root.mcp.authority
        try check(modelAuthority === root.authority && mcpAuthority === root.authority, "same controller reference")
        try check(modelLifecycle === run.authorityHandle.lifecycle && mcpLifecycle === modelLifecycle && vm.lifecycle === modelLifecycle && root.workbench.lifecycle(runID: run.grant.runID) === modelLifecycle, "all five actual run references")
        try await root.workbench.stop(runID: run.grant.runID)
        try check(vm.revoked && modelLifecycle.currentStatus == .stopped, "composition Stop")
    }
    @MainActor static func vmForeignHandle() async throws {
        let clock = SharedHostClock(), sink = Sink()
        let a = RunAuthorizationController(auditSink: sink, clock: clock.source)
        let g = try grant(clock), foreign = try await a.install(grant: grant(clock))
        do {
            _ = try VMDiagnosticSession(owner: NSObject(), runID: g.runID, epoch: g.epoch,
                workloadDigest: g.workloadImageDigest, sink: sink, authorityHandle: foreign, installedGrant: g)
            throw Failure(message: "foreign authority accepted by VM")
        } catch VMProtocolError.crossContext {}
    }
    @MainActor static func vmStop() async throws {
        let clock = SharedHostClock(), sink = Sink(), owner = NSObject()
        let a = RunAuthorizationController(auditSink: sink, clock: clock.source)
        let g = try grant(clock), h = try await a.install(grant: g)
        let vm = try VMDiagnosticSession(owner: owner, runID: g.runID, epoch: g.epoch,
            workloadDigest: g.workloadImageDigest, sink: sink, authorityHandle: h, installedGrant: g)
        try check(vm.lifecycle === h.lifecycle, "VM actual shared reference")
        h.lifecycle.terminate(.stopped)
        do { try vm.open(owner: owner, now: 0); throw Failure(message: "VM accepted access after shared Stop") }
        catch VMProtocolError.stopped {}
    }
    static func wall() async throws {
        let clock = SharedHostClock(), a = RunAuthorizationController(auditSink: Sink(), clock: .system())
        _ = a // independent controller cannot manufacture a handle
        let authority = RunAuthorizationController(auditSink: Sink(), clock: clock.source)
        let h = try await authority.install(grant: grant(clock))
        clock.set(wall: 800, elapsed: .seconds(1))
        let first = h.lifecycle.observeAndReduce(reason: "test")
        clock.set(wall: 0, elapsed: .seconds(2))
        let rollback = h.lifecycle.observeAndReduce(reason: "test")
        try check(rollback.effectiveTime == first.effectiveTime && rollback.sequence > first.sequence, "highwater and sequence")
        clock.set(wall: 900, elapsed: .seconds(3))
        try check(h.lifecycle.observeAndReduce(reason: "test").status == .expired, "wall wins over living monotonic deadline at equality")
        clock.set(wall: 0, elapsed: .seconds(4))
        try check(h.lifecycle.observeAndReduce(reason: "test").status == .expired, "rollback cannot revive")
    }
    static func monotonic() async throws {
        for elapsed in [Duration.seconds(900), .seconds(3600)] {
            let clock = SharedHostClock()
            let a = RunAuthorizationController(auditSink: Sink(), clock: clock.source)
            let h = try await a.install(grant: grant(clock))
            clock.set(wall: 500, elapsed: .seconds(899))
            try check(h.lifecycle.observeAndReduce(reason: "retry").status == .active, "before fixed deadline")
            clock.set(wall: -100, elapsed: elapsed)
            try check(h.lifecycle.observeAndReduce(reason: "sleep").status == .expired, "monotonic expiry despite rollback; no reset on retry")
        }
    }
    @MainActor static func approvedGateways() async throws {
      for stop in [false, true] {
        let clock = SharedHostClock(), credentials = NeverCredentials(), sink = Sink()
        let mi = UUID(), ci = UUID()
        let ms = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        let cs = try ResourceScope(service: "mcp", resource: "control", operation: "initialize")
        let g = try grant(clock, connections: [ConnectionGrant(connectionID: mi, accountBindingVersion: 1, routeVersion: 1, scopes: [ms]), ConnectionGrant(connectionID: ci, accountBindingVersion: 1, routeVersion: 1, scopes: [cs])])
        let a = RunAuthorizationController(auditSink: sink, clock: clock.source)
        let h = try await a.install(grant: g)
        let m = try HostModelGateway(connections: [HostModelConnection(connectionID: mi, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials)], auditSink: sink, authority: a)
        let c = try HostMCPGateway(connections: [HostMCPConnection.testOnlyLoopback(connectionID: ci, accountID: UUID(), port: 1, provider: credentials)], auditSink: sink, authority: a)
        let mh = try await m.install(grant: g, authorityHandle: h), ch = try await c.install(grant: g, authorityHandle: h)
        let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: [FixedMessage(role: .user, content: "fixture")], maxOutputTokens: 1)
        let mp = try await m.propose(handle: mh, connectionID: mi, request: request, streaming: false)
        let cp = try await c.propose(handle: ch, connectionID: ci, raw: Data(#"{"jsonrpc":"2.0","id":"fixture","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bounded-host-fixture","version":"1"}}}"#.utf8))
        let ma = try await m.hostApprove(handle: mh, proposal: mp), ca = try await c.hostApprove(handle: ch, proposal: cp)
        if stop {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("approved-stop-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let ui = WorkbenchModel(newAuditFileAt: url, clock: clock.source, authority: a)
            try await ui.installTrustedGrant(g, authorityHandle: h)
            try await ui.stop(runID: g.runID)
        } else {
            // A trusted F03 diagnostic observes exact expiry while mono is alive.
            clock.set(wall: 900, elapsed: .seconds(1))
            try await a.recordGuestDiagnostic(runID: g.runID, operation: "fixture", resourceSummary: "fixture", message: "fixture")
        }
        clock.set(wall: 0, elapsed: .seconds(2))
        do { _ = try await m.execute(handle: mh, approval: ma); throw Failure(message: "model old approval revived") }
        catch HostModelGatewayError.revoked {}
        do { _ = try await c.execute(handle: ch, approval: ca); throw Failure(message: "MCP old approval revived") }
        catch HostMCPGatewayError.revoked {}
        try check(credentials.count == 0, "shared terminal stops both before credential preparation")
      }
    }
    static func connectionIsolation() async throws {
        let clock = SharedHostClock(), credentials = NeverCredentials(), sink = Sink(), x = UUID(), y = UUID()
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        let a = RunAuthorizationController(auditSink: sink, clock: clock.source)
        let m = try HostModelGateway(connections: [x, y].map { HostModelConnection(connectionID: $0, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials) }, auditSink: sink, authority: a)
        let gx = try grant(clock, connections: [ConnectionGrant(connectionID: x, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])])
        let gy = try grant(clock, connections: [ConnectionGrant(connectionID: y, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])])
        let hx = try await a.install(grant: gx), hy = try await a.install(grant: gy)
        let mx = try await m.install(grant: gx, authorityHandle: hx), my = try await m.install(grant: gy, authorityHandle: hy)
        try await m.revokeConnection(x)
        try check(!hx.lifecycle.permitsConnection(x) && hy.lifecycle.permitsConnection(y), "only bound connection invalidated")
        let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: [FixedMessage(role: .user, content: "fixture")], maxOutputTokens: 1)
        do { _ = try await m.propose(handle: mx, connectionID: x, request: request, streaming: false); throw Failure(message: "revoked connection accepted") }
        catch HostModelGatewayError.invalidConnection {}
        _ = try await m.propose(handle: my, connectionID: y, request: request, streaming: false)
    }
    static func oldHandle() async throws {
        let clock = SharedHostClock(), g = try grant(clock)
        let first = RunAuthorizationController(auditSink: Sink(), clock: clock.source)
        let second = RunAuthorizationController(auditSink: Sink(), clock: clock.source)
        let old = try await first.install(grant: g), new = try await second.install(grant: g)
        try check(old !== new && old.lifecycle !== new.lifecycle, "same UUID is not authority identity")
        do { try await second.validateAttachment(handle: old, grant: g); throw Failure(message: "old handle accepted") }
        catch AuthorizationError.invalidHandle {}
    }
}
/// Holds the real synchronous authority append, not a simulated UI busy flag.
private final class WorkbenchStopAudit: SynchronousAuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SecurityEvent] = []
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func append(_ event: SecurityEvent) throws {
        if event.reason == "explicit-deny" {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw Failure(message: "audit barrier timeout") }
        }
        lock.withLock { events.append(event) }
    }
    var snapshot: [SecurityEvent] { lock.withLock { events } }
}

extension SharedAuthorityChecks {
    @MainActor static func sheetStopBinding() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SandboxWorkbench/WorkbenchView.swift"), encoding: .utf8)
        let sheet = String(source.components(separatedBy: "private func approvalSheet").last!)
        try check(sheet.contains("stopControl(runID: action.binding.runID)"), "P1-UI-STOP-MODAL: modal sheet has no reachable Stop")
        try check(source.contains("stopControl(runID: grant.runID)"), "parent shares the Stop control")
        try check(sheet.contains("}.disabled(approval.ordinaryControlsDisabled)\n            stopControl"), "Stop is outside ordinary disabled row")
        try check(source.components(separatedBy: "Button(\"Stop and revoke\")").count == 2, "one reusable Stop implementation")
        try check(source.contains("try await approval.stop(runID: runID)") && source.contains("}.disabled(!model.canStop(runID: runID))"), "Stop uses tested presentation route and availability")
        try check(source.contains(".sheet(item: $approval.presentation"), "actual sheet binds tested presentation")
        try check(sheet.components(separatedBy: "await approval.dismiss(action)").count == 3 && sheet.contains(".keyboardShortcut(.defaultAction)") && sheet.contains(".keyboardShortcut(.cancelAction)"), "Return/Escape remain deny routes")
    }
    @MainActor static func stopAvailabilityStates() async throws {
        let unavailable = WorkbenchModel(unavailable: "fixture")
        try check(!unavailable.canStop(runID: UUID()), "fault/no handle disables Stop")
        for terminal in [RunLifecycle.Status.expired, .revoked, .stopped, .faulted] {
            let clock = SharedHostClock(), g = try grant(clock)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stop-policy-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let ui = WorkbenchModel(newAuditFileAt: url, clock: clock.source)
            try check(!ui.canStop(runID: g.runID), "no installed handle disables Stop")
            try await ui.installTrustedGrant(g)
            try check(ui.canStop(runID: g.runID), "active idle run enables Stop")
            try ui.lifecycle(runID: g.runID).terminate(terminal)
            try check(!ui.canStop(runID: g.runID), "terminal disables Stop: \(terminal)")
            try await ui.stop(runID: g.runID)
            try await ui.stop(runID: g.runID)
            try check(ui.lifecycle(runID: g.runID).currentStatus == terminal, "cleanup cannot rewrite terminal cause")
            let closed = await ui.close()
            try check(closed && ui.isClosing && ui.isClosed && !ui.canStop(runID: g.runID), "closing/closed disables Stop")
        }
    }
    @MainActor static func presentationPolicies() async throws {
        for scenario in ["approve", "dismiss", "expiry", "close"] {
            let clock = SharedHostClock(), connectionID = UUID()
            let scope = try ResourceScope(service: "fixture", resource: "fixture", operation: "read")
            let g = try grant(clock, connections: [ConnectionGrant(connectionID: connectionID, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let ui = WorkbenchModel(newAuditFileAt: url, clock: clock.source)
            try await ui.installTrustedGrant(g)
            let binding = try ActionBinding(runID: g.runID, epoch: 1, grantDigest: RunAuthorizationController.grantDigest(for: g), connectionID: connectionID, operation: "read", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "fixture", canonicalRequest: Data("{}".utf8))
            let action = try await ui.proposeTrustedAction(binding: binding, display: "fixture")
            let sheet = WorkbenchApprovalController(model: ui)
            sheet.present(action)
            try check(sheet.presentation?.id == action.actionID && ui.approvedActions.isEmpty, "presentation grants no permission")
            switch scenario {
            case "approve":
                try await sheet.approve(action)
                await sheet.didDismiss()
                await sheet.dismiss(action)
                try check(ui.approvedActions[action.actionID] != nil && ui.trustedDenialCount == 0, "stale dismissal must not revoke existing approval")
            case "dismiss":
                sheet.presentation = nil // SwiftUI's native dismissal binding.
                await sheet.didDismiss()
                await sheet.didDismiss()
                try check(ui.trustedDenialCount == 1 && ui.approvedActions.isEmpty, "native dismissal denies exactly once")
            case "expiry":
                clock.set(wall: 301, elapsed: .seconds(1))
                await ui.expirePending()
                sheet.reconcile()
                do { try await sheet.approve(action); throw Failure(message: "stale sheet approved") }
                catch AuthorizationError.actionDenied { /* Expiry reconciliation uses the deny route. */ }
                await sheet.didDismiss()
            default:
                let closed = await ui.close()
                sheet.reconcile()
                try check(closed && sheet.ordinaryControlsDisabled && !ui.canStop(runID: g.runID), "closing policy")
                do { try await sheet.approve(action); throw Failure(message: "closed sheet approved") }
                catch AuthorizationError.runRevoked {}
                await sheet.didDismiss()
            }
            try check(sheet.presentation == nil && ui.pending.isEmpty, "presentation cleared safely: \(scenario)")
            sheet.present(action)
            try check(sheet.presentation == nil, "stale action cannot be re-presented")
        }
    }
    @MainActor static func workbenchBusyStop() async throws { try await busyStop(sheet: false) }
    @MainActor static func sheetBusyStop() async throws { try await busyStop(sheet: true) }
    @MainActor static func busyStop(sheet: Bool) async throws {
        let clock = SharedHostClock(), sink = WorkbenchStopAudit()
        let authority = RunAuthorizationController(auditSink: sink, clock: clock.source)
        let connectionID = UUID(), mi = UUID(), ci = UUID(), credentials = NeverCredentials()
        let scope = try ResourceScope(service: "fixture", resource: "fixture", operation: "read")
        let ms = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        let cs = try ResourceScope(service: "mcp", resource: "control", operation: "initialize")
        let g = try grant(clock, connections: [ConnectionGrant(connectionID: connectionID, accountBindingVersion: 1, routeVersion: 1, scopes: [scope]), ConnectionGrant(connectionID: mi, accountBindingVersion: 1, routeVersion: 1, scopes: [ms]), ConnectionGrant(connectionID: ci, accountBindingVersion: 1, routeVersion: 1, scopes: [cs])])
        let handle = try await authority.install(grant: g)
        let model = try HostModelGateway(connections: [HostModelConnection(connectionID: mi, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials)], auditSink: sink, authority: authority)
        let mcp = try HostMCPGateway(connections: [HostMCPConnection.testOnlyLoopback(connectionID: ci, accountID: UUID(), port: 1, provider: credentials)], auditSink: sink, authority: authority)
        let mh = try await model.install(grant: g, authorityHandle: handle)
        let ch = try await mcp.install(grant: g, authorityHandle: handle)
        let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .openAI, messages: [FixedMessage(role: .user, content: "fixture")], maxOutputTokens: 1)
        let mp = try await model.propose(handle: mh, connectionID: mi, request: request, streaming: false)
        let cp = try await mcp.propose(handle: ch, connectionID: ci, raw: Data(#"{"jsonrpc":"2.0","id":"fixture","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bounded-host-fixture","version":"1"}}}"#.utf8))
        let ma = try await model.hostApprove(handle: mh, proposal: mp)
        let ca = try await mcp.hostApprove(handle: ch, proposal: cp)
        let owner = NSObject()
        let vm = try VMDiagnosticSession(owner: owner, runID: g.runID, epoch: g.epoch, workloadDigest: g.workloadImageDigest, sink: sink, authorityHandle: handle, installedGrant: g)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("busy-stop-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let ui = WorkbenchModel(newAuditFileAt: url, clock: clock.source, authority: authority)
        try await ui.installTrustedGrant(g, authorityHandle: handle)
        let binding = try ActionBinding(runID: g.runID, epoch: 1, grantDigest: RunAuthorizationController.grantDigest(for: g), connectionID: connectionID, operation: "read", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "fixture", canonicalRequest: Data("{}".utf8))
        // An already-issued ticket must remain usable for bookkeeping only.
        let started = try await ui.proposeTrustedAction(binding: binding, display: "started fixture")
        let approved = try await ui.approveOnce(started)
        let ticket = try await ui.consumeForTrustedHost(runID: g.runID, approved: approved)
        let action = try await ui.proposeTrustedAction(binding: binding, display: "deny fixture")
        try check(ui.lifecycle(runID: g.runID) === handle.lifecycle && vm.lifecycle === handle.lifecycle, "presentation uses original authority reference")
        let presentation = WorkbenchApprovalController(model: ui)
        if sheet { presentation.present(action) }
        let denial = Task { @MainActor in
            if sheet { await presentation.dismiss(action) } else { try await ui.deny(action) }
        }
        guard await Task.detached(operation: { sink.waitUntilEntered() }).value else {
            sink.release.signal(); try await denial.value
            throw Failure(message: "workbench denial did not reach audit")
        }
        let busy = ui.isBusy
        let modalBlocked = !sheet || (presentation.presentation?.id == action.actionID && presentation.ordinaryControlsDisabled)
        let initiallyActive = handle.lifecycle.currentStatus == .active
        // The actual SwiftUI control uses this policy and calls the same stop path.
        // This is compiled control-policy/action coverage, not a rendered GUI click.
        let enabled = ui.canStop(runID: g.runID)
        var stop: Task<Void, Error>?
        if enabled {
            await withCheckedContinuation { ack in
                stop = Task { @MainActor in
                    ack.resume()
                    if sheet { try await presentation.stop(runID: g.runID) } else { try await ui.stop(runID: g.runID) }
                }
            }
        }
        let terminalBeforeRelease = handle.lifecycle.currentStatus
        let modelDenied = try await model.isRevoked(handle: mh)
        let mcpDenied = try await mcp.isRevoked(handle: ch)
        // Error delivery can await authority bookkeeping; never wait for that
        // cleanup while deliberately holding its audit. Access is already revoked.
        let modelAttempt = enabled ? Task { try await model.execute(handle: mh, approval: ma) } : nil
        let mcpAttempt = enabled ? Task { try await mcp.execute(handle: ch, approval: ca) } : nil
        let readsBeforeRelease = credentials.count
        var vmDenied = false
        if enabled {
            do { try vm.open(owner: owner, now: 0) } catch VMProtocolError.stopped { vmDenied = true }
        }
        let clearedBeforeRelease = ui.pending.isEmpty && ui.approvedActions.isEmpty && (!sheet || presentation.presentation == nil)
        var nativeDismissal: Task<Void, Never>?
        if sheet {
            await withCheckedContinuation { ack in
                nativeDismissal = Task { @MainActor in ack.resume(); await presentation.didDismiss() }
            }
        }
        sink.release.signal()
        let denialResult = await denial.result, stopResult = await stop?.result
        await nativeDismissal?.value
        try denialResult.get()
        if let stopResult { try stopResult.get() }
        if sheet { await presentation.didDismiss(); await presentation.dismiss(action) }
        var modelExecutionDenied = false, mcpExecutionDenied = false
        if let modelAttempt {
            do { _ = try await modelAttempt.value } catch HostModelGatewayError.revoked { modelExecutionDenied = true }
        }
        if let mcpAttempt {
            do { _ = try await mcpAttempt.value } catch HostMCPGatewayError.revoked { mcpExecutionDenied = true }
        }
        try check(modalBlocked, "actual presentation remains while Deny/Cancel audit blocks ordinary controls")
        try check(busy && initiallyActive, "real workbench deny is busy during active blocked audit")
        try check(enabled, "P1-UI-STOP-BUSY: actual Stop availability must remain enabled during workbench audit")
        try check(terminalBeforeRelease == .stopped && modelDenied && mcpDenied && vmDenied, "shared model/MCP/VM unavailable before audit release")
        try check(modelExecutionDenied && mcpExecutionDenied && readsBeforeRelease == 0 && credentials.count == 0, "old approvals rejected without credential reads; error cleanup may await audit release")
        try check(clearedBeforeRelease, "Stop clears pending snapshots before audit release")
        try check(!ui.canStop(runID: g.runID) && ui.errorMessage == nil, "terminal disables control without cleanup errors")
        try await ui.stop(runID: g.runID)
        try await ui.completeForTrustedHost(runID: g.runID, ticket: ticket, outcome: .unknown)
        do {
            try await ui.completeForTrustedHost(runID: g.runID, ticket: ticket, outcome: .unknown)
            throw Failure(message: "duplicate completion accepted")
        } catch AuthorizationError.completionAlreadyRecorded {}
        let events = sink.snapshot
        try check(events.filter { $0.reason == "explicit-deny" }.count == 1, "denial audit exactly once")
        try check(events.filter { $0.reason == "dispatch-intent" }.count == 1 && events.filter { $0.reason == "dispatch-completion" }.count == 1, "issued-ticket completion exactly once after Stop")
        try check(handle.lifecycle.currentGeneration == 2 && ui.pending.isEmpty && ui.approvedActions.isEmpty && !ui.isBusy, "idempotent terminal and cleanup")
    }
}