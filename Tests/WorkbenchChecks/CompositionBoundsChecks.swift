import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

@MainActor enum CompositionBoundsChecks {
    static func run() async throws {
        var failures = 0
        for entry in ["composition", "model", "MCP", "workbench"] {
            do { try await retainedCapacity(entry) }
            catch { failures += 1; print("FAIL bounds retained \(entry): \(error)") }
        }
        do { try await repeatedAttachment() }
        catch { failures += 1; print("FAIL bounds duplicate attachment: \(error)") }
        do { try await sequentialReuse() }
        catch { failures += 1; print("FAIL bounds sequential reuse: \(error)") }
        for entry in ["model", "MCP"] {
            for phase in HostAttachmentPhase.allCases {
                do { try await exposure(entry, phase: phase) }
                catch { failures += 1; print("FAIL bounds exposure \(entry) \(phase.rawValue): \(error)") }
            }
        }
        do { try await issuedTicketDrain() }
        catch { failures += 1; print("FAIL bounds issued ticket drain: \(error)") }
        do { try await failedTicketSettlement() }
        catch { failures += 1; print("FAIL bounds failed ticket settlement: \(error)") }
        do { try await pendingCapacityAndFailureRecovery() }
        catch { failures += 1; print("FAIL bounds pending capacity recovery: \(error)") }
        do { try await CompositionSettlementChecks.gatewayAuditFailure() }
        catch { failures += 1; print("FAIL bounds model gateway settlement: \(error)") }
        do { try await CompositionSettlementChecks.gatewayAuditFailure(preparationFails: true) }
        catch { failures += 1; print("FAIL bounds model prestart settlement: \(error)") }
        do { try await CompositionSettlementChecks.mcpPrestartSettlementFailure() }
        catch { failures += 1; print("FAIL bounds MCP prestart settlement: \(error)") }
        for entry in ["model", "MCP"] {
            for duplicate in [false, true] {
                do { try await generationExposure(entry, duplicate: duplicate) }
                catch { failures += 1; print("FAIL bounds generation exposure \(entry) duplicate=\(duplicate): \(error)") }
            }
        }
        do { try await pureOutcomeExactlyOnce() }
        catch { failures += 1; print("FAIL bounds pure outcome exact-once: \(error)") }
        for fails in [false, true] {
            do { try await authorityOutcomeSettlement(fails: fails) }
            catch { failures += 1; print("FAIL bounds authority outcome settlement fails=\(fails): \(error)") }
            do { try await CompositionSettlementChecks.countedTicketRelease(fails: fails) }
            catch { failures += 1; print("FAIL bounds counted ticket release fails=\(fails): \(error)") }
        }
        if failures != 0 { throw ConnectionSettingsChecks.Failure(message: "bounded ownership checks failed") }
    }
    static func authorityOutcomeSettlement(fails: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("authority-outcome-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore())
        let installed = try await root.install(CompositionCloseChecks.modelGrant(UUID())), grant = installed.grant
        let binding = try ActionBinding(runID: grant.runID, epoch: grant.epoch,
            grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: grant.connections[0].connectionID,
            operation: "complete", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "deepseek-flash", canonicalRequest: Data("{}".utf8))
        let action = try await root.workbench.proposeTrustedAction(binding: binding, display: "authority outcome")
        let approval = try await root.workbench.approveOnce(action)
        let ticket = try await root.workbench.consumeForTrustedHost(runID: grant.runID, approved: approval)
        root.beginClose()
        var failedExpected = false
        if fails {
            try await WorkbenchChecks.withWritesBlocked {
                do { try await root.authority.complete(handle: installed.authorityHandle, ticket: ticket, outcome: .unknown) }
                catch AuthorizationError.auditFailed { failedExpected = true }
            }
        } else {
            try await root.authority.complete(handle: installed.authorityHandle, ticket: ticket, outcome: .unknown)
        }
        // Do not hang the test on the old leaked owner reservation: inspect the
        // real authority settlement before attempting the draining close API.
        try ConnectionSettingsChecks.require(root.pendingOwnedWork == 0,
            "real ticket settlement must release ownership even through the authority outcome API")
        var replayDenied = false
        do { try await root.workbench.completeForTrustedHost(runID: grant.runID, ticket: ticket, outcome: .completed) }
        catch AuthorizationError.completionAlreadyRecorded { replayDenied = true }
        let closed = await root.close(), repeated = await root.close()
        try ConnectionSettingsChecks.require(replayDenied && failedExpected == fails && closed == !fails && repeated == !fails &&
            installed.authorityHandle.lifecycle.currentStatus != .active && root.pendingOwnedWork == 0 &&
            audit.snapshot().filter { $0.reason == "dispatch-completion" }.count == (fails ? 0 : 1),
            "authority settlement has one release and truthful repeated close without execution revival")
        print("PASS bounds authority pure outcome fails=\(fails) releases once and preserves close truth")
    }
    static func pureOutcomeExactlyOnce() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pure-outcome-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore())
        let grant = try CompositionCloseChecks.modelGrant(UUID()), other = try ConnectionSettingsChecks.makeGrant(nil)
        try await root.workbench.installTrustedGrant(grant)
        try await root.workbench.installTrustedGrant(other)
        let binding = try ActionBinding(runID: grant.runID, epoch: grant.epoch,
            grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: grant.connections[0].connectionID,
            operation: "complete", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "deepseek-flash", canonicalRequest: Data("{}".utf8))
        let action = try await root.workbench.proposeTrustedAction(binding: binding, display: "outcome only")
        let approval = try await root.workbench.approveOnce(action)
        let ticket = try await root.workbench.consumeForTrustedHost(runID: grant.runID, approved: approval)
        var wrongRun = false, wrongOutcome = false
        do { try await root.workbench.completeForTrustedHost(runID: other.runID, ticket: ticket, outcome: .unknown) }
        catch AuthorizationError.ticketInvalid { wrongRun = true }
        do { try await root.workbench.completeForTrustedHost(runID: grant.runID, ticket: ticket, outcome: .notDispatched) }
        catch AuthorizationError.completionAlreadyRecorded { wrongOutcome = true }
        let retained = root.pendingOwnedWork == 1 && audit.snapshot().filter { $0.reason == "dispatch-completion" }.isEmpty
        root.beginClose()
        let lifecycle = try root.workbench.lifecycle(runID: grant.runID), generation = lifecycle.currentGeneration
        let tasks = (0..<2).map { _ in Task { () -> Int in
            do { try await root.workbench.completeForTrustedHost(runID: grant.runID, ticket: ticket, outcome: .unknown); return 1 }
            catch AuthorizationError.completionAlreadyRecorded { return 2 }
            catch { return 0 }
        } }
        var results: [Int] = []
        for task in tasks { results.append(await task.value) }
        var executionDenied = false
        do { _ = try await root.workbench.consumeForTrustedHost(runID: grant.runID, approved: approval) }
        catch AuthorizationError.runRevoked { executionDenied = true }
        let closed = await root.close(), repeated = await root.close()
        let completions = audit.snapshot().filter { $0.reason == "dispatch-completion" }
        try ConnectionSettingsChecks.require(wrongRun && wrongOutcome && retained && results.sorted() == [1, 2] && executionDenied &&
            lifecycle.currentStatus == .stopped && lifecycle.currentGeneration == generation && root.pendingOwnedWork == 0 &&
            closed && repeated && completions.count == 1 && completions[0].outcome == .unknown,
            "invalid completions retain reservation; concurrent pure outcomes release once without restoring execution")
        print("PASS bounds pure outcome wrong-owner invalid-outcome concurrent exact-once no execution revival")
    }
    static func generationExposure(_ entry: String, duplicate: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("generation-exposure-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore())
        let grant = try ConnectionSettingsChecks.makeGrant(nil), handle = try await root.authority.install(grant: grant)
        let model = root.model
        if duplicate { try await CompositionCloseChecks.attach(entry, root: root, grant: grant, handle: handle) }
        let barrier = CloseClock()
        let hook: @Sendable (HostAttachmentPhase) async -> Void = { phase in
            if phase == .afterRegistration { await Task.detached { barrier.arm(); _ = barrier.now() }.value }
        }
        if entry == "model" { await model.setAttachmentBarrier(hook) }
        else { await root.mcp.setAttachmentBarrier(hook) }
        let attaching = Task {
            if entry == "model" { _ = try await model.install(grant: grant, authorityHandle: handle) }
            else { _ = try await root.mcp.install(grant: grant, authorityHandle: handle) }
        }
        let entered = await Task.detached { barrier.wait() }.value
        let registered = root.pendingOwnedWork == 1
        // A configuration generation retires every pending intake, even when
        // this genuine handle has no affected connection and remains live.
        await root.connectionSettings.save("synthetic-" + UUID().uuidString)
        let activeBeforeReturn = handle.lifecycle.currentStatus == .active
        barrier.release.signal()
        var rejected = false
        do { try await attaching.value } catch AuthorizationError.runRevoked { rejected = true }
        let closed = await root.close()
        try ConnectionSettingsChecks.require(entered && !barrier.timedOut && registered && activeBeforeReturn && rejected && closed,
            "late attachment must recheck owner generation on both fresh and duplicate return paths")
        print("PASS bounds generation exposure \(entry) duplicate=\(duplicate) rejects stale intake")
    }
    static func exposure(_ entry: String, phase: HostAttachmentPhase) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("exposure-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore())
        let grant = try ConnectionSettingsChecks.makeGrant(nil), handle = try await root.authority.install(grant: grant)
        let barrier = CloseClock()
        let hook: @Sendable (HostAttachmentPhase) async -> Void = { observed in
            if observed == phase { await Task.detached { barrier.arm(); _ = barrier.now() }.value }
        }
        if entry == "model" { await root.model.setAttachmentBarrier(hook) }
        else { await root.mcp.setAttachmentBarrier(hook) }
        let attaching = Task { try await CompositionCloseChecks.attach(entry, root: root, grant: grant, handle: handle) }
        let entered = await Task.detached { barrier.wait() }.value
        let registered = root.pendingOwnedWork == 1 && root.retainedOwnedRuns == 1
        root.beginClose()
        let terminal = handle.lifecycle.currentStatus == .stopped
        barrier.release.signal()
        var rejected = false
        do { try await attaching.value }
        catch AuthorizationError.runRevoked { rejected = true }
        catch HostMCPGatewayError.revoked { rejected = true }
        let closed = await root.close()
        try ConnectionSettingsChecks.require(entered && !barrier.timedOut && registered && terminal && rejected && closed &&
            root.workbench.grants.isEmpty && audit.snapshot().isEmpty,
            "post-registration/pre-exposure close must reject return, with no exposed activity")
        print("PASS bounds exposure \(entry) \(phase.rawValue) rejected after synchronous close")
    }
    static func issuedTicketDrain() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ticket-drain-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore())
        let grant = try CompositionCloseChecks.modelGrant(UUID())
        try await root.workbench.installTrustedGrant(grant)
        let binding = try ActionBinding(runID: grant.runID, epoch: grant.epoch,
            grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: grant.connections[0].connectionID,
            operation: "complete", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "deepseek-flash", canonicalRequest: Data("{}".utf8))
        let action = try await root.workbench.proposeTrustedAction(binding: binding, display: "offline ticket")
        let approval = try await root.workbench.approveOnce(action)
        let ticket = try await root.workbench.consumeForTrustedHost(runID: grant.runID, approved: approval)
        try await root.workbench.stop(runID: grant.runID)
        for _ in 0..<31 { _ = try await root.model.install(grant: ConnectionSettingsChecks.makeGrant(nil)) }
        var rejected = false
        do { _ = try await root.model.install(grant: ConnectionSettingsChecks.makeGrant(nil)) }
        catch AuthorizationError.pendingLimit { rejected = true }
        let cleanup = root.workbench.closeOwnedRuns!, entered = CloseClock()
        root.workbench.closeOwnedRuns = { entered.entered.signal(); return await cleanup() }
        let closing = Task { await root.close() }
        let reachedCleanup = await Task.detached { entered.wait() }.value
        let waited = !root.isClosed && root.pendingOwnedWork == 1
        try await root.workbench.completeForTrustedHost(runID: grant.runID, ticket: ticket, outcome: .unknown)
        let closed = await closing.value, repeated = await root.close()
        let completions = audit.snapshot().filter { $0.reason == "dispatch-completion" }
        try ConnectionSettingsChecks.require(rejected && reachedCleanup && waited && closed && repeated &&
            root.pendingOwnedWork == 0 && completions.count == 1 && completions[0].outcome == .unknown,
            "issued unfinished ticket must retain capacity and prevent successful close until exact settlement")
        print("PASS bounds issued ticket retains capacity and drains before close acknowledgment")
    }
    static func failedTicketSettlement() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ticket-failure-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
        let grant = try CompositionCloseChecks.modelGrant(UUID())
        try await root.workbench.installTrustedGrant(grant)
        let binding = try ActionBinding(runID: grant.runID, epoch: grant.epoch,
            grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: grant.connections[0].connectionID,
            operation: "complete", schemaDigest: String(repeating: "c", count: 64), resolvedResource: "deepseek-flash", canonicalRequest: Data("{}".utf8))
        let action = try await root.workbench.proposeTrustedAction(binding: binding, display: "offline failure")
        let approval = try await root.workbench.approveOnce(action)
        let ticket = try await root.workbench.consumeForTrustedHost(runID: grant.runID, approved: approval)
        var rejected = false
        try await WorkbenchChecks.withWritesBlocked {
            do { try await root.workbench.completeForTrustedHost(runID: grant.runID, ticket: ticket, outcome: .unknown) }
            catch AuthorizationError.auditFailed { rejected = true }
        }
        let closed = await root.close(), repeated = await root.close()
        try ConnectionSettingsChecks.require(rejected && !closed && !repeated && !root.isClosed,
            "failed durable settlement must not become a successful close acknowledgment")
        print("PASS bounds failed ticket settlement keeps close false")
    }
    static func pendingCapacityAndFailureRecovery() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pending-cap-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let clock = CloseClock(), root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore(), now: clock.now)
        // An expired grant blocks inside install's first sample then fails; all
        // 32 reservations must recover without allocating any retained run.
        let valid = try ConnectionSettingsChecks.makeGrant(nil)
        let expired = try RunGrant(runID: valid.runID, epoch: valid.epoch, createdAt: Date().addingTimeInterval(-100),
            expiresAt: Date().addingTimeInterval(-1), workloadImageDigest: valid.workloadImageDigest,
            agentAdapterVersion: valid.agentAdapterVersion, workspaceSnapshotID: valid.workspaceSnapshotID,
            policyDigest: valid.policyDigest, approvalSnapshotID: valid.approvalSnapshotID, connections: [],
            explicitDenies: [], resourceLimits: valid.resourceLimits)
        clock.arm()
        let tasks = (0..<32).map { _ in Task { () -> Bool in
            do { _ = try await root.model.install(grant: expired); return false }
            catch AuthorizationError.grantExpired { return true }
            catch { return false }
        } }
        let entered = await Task.detached { clock.wait() }.value
        for _ in 0..<5000 { if root.pendingOwnedWork == 32 { break }; try await Task.sleep(for: .milliseconds(1)) }
        let full = root.pendingOwnedWork == 32 && root.retainedOwnedRuns == 0
        var rejected = false
        do { _ = try await root.mcp.install(grant: valid) }
        catch AuthorizationError.pendingLimit { rejected = true }
        clock.release.signal()
        var failedExpected = true
        for task in tasks { failedExpected = await task.value && failedExpected }
        let empty = root.pendingOwnedWork == 0 && root.retainedOwnedRuns == 0
        _ = try await root.install(valid)
        let closed = await root.close()
        try ConnectionSettingsChecks.require(entered && !clock.timedOut && full && rejected && failedExpected && empty && closed,
            "pending cap rejects before allocation and releases all failed reservations for reuse")
        print("PASS bounds pending cap+1 before allocation and failure recovery")
    }
    static func retainedCapacity(_ entry: String) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bounds-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
        for _ in 0..<32 { _ = try await root.model.install(grant: ConnectionSettingsChecks.makeGrant(nil)) }
        let grant = try ConnectionSettingsChecks.makeGrant(nil)
        var rejected = false
        do {
            switch entry {
            case "composition": _ = try await root.install(grant)
            case "model": _ = try await root.model.install(grant: grant)
            case "MCP": _ = try await root.mcp.install(grant: grant)
            default: try await root.workbench.installTrustedGrant(grant)
            }
        } catch AuthorizationError.pendingLimit { rejected = true }
        let closed = await root.close()
        try ConnectionSettingsChecks.require(rejected && closed,
            "unique retained cap+1 must reject at composition intake, including every direct API")
        print("PASS bounds retained \(entry) cap+1 rejected")
    }
    static func repeatedAttachment() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("duplicates-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
        let grant = try ConnectionSettingsChecks.makeGrant(nil), handle = try await root.authority.install(grant: grant)
        let model = try await root.model.install(grant: grant, authorityHandle: handle)
        let mcp = try await root.mcp.install(grant: grant, authorityHandle: handle)
        var identical = true
        for _ in 0..<40 {
            identical = try await root.model.install(grant: grant, authorityHandle: handle) === model && identical
            identical = try await root.mcp.install(grant: grant, authorityHandle: handle) === mcp && identical
            try await root.workbench.installTrustedGrant(grant, authorityHandle: handle)
        }
        let visible = root.workbench.grants.count
        let closed = await root.close()
        try ConnectionSettingsChecks.require(identical && visible == 1 && closed, "genuine repeated attachment must not allocate duplicate gateway/UI ownership")
        print("PASS bounds duplicate attachment identity and single UI record")
    }
    static func sequentialReuse() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reuse-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
        for _ in 0..<40 {
            let handle = try await root.mcp.install(grant: ConnectionSettingsChecks.makeGrant(nil))
            try await root.mcp.stop(handle: handle)
        }
        let closed = await root.close()
        try ConnectionSettingsChecks.require(closed, "terminal settled runs must recover capacity, not impose a lifetime quota")
        print("PASS bounds sequential reuse beyond capacity")
    }
}
