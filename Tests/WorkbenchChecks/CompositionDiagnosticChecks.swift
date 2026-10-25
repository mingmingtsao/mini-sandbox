import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

/// Actual in-process diagnostic entrypoint; no VM, socket, provider or Keychain.
@MainActor enum CompositionDiagnosticChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func run() async throws {
        var failures = 0
        for sameID in [false, true] {
            do { try await foreignIntake(sameID: sameID) } catch {
                failures += 1
                print("FAIL composition diagnostic foreign sameID=\(sameID): \(error)")
            }
        }
        for revoke in [false, true] {
            do { try await localTermination(revoke: revoke) } catch {
                failures += 1
                print("FAIL composition diagnostic local revoke=\(revoke): \(error)")
            }
        }
        do { try await installedGrantValidation() } catch {
            failures += 1
            print("FAIL composition diagnostic installed grant validation: \(error)")
        }
        if failures != 0 { throw Failure(message: "diagnostic ownership regressions failed") }
        print("CompositionDiagnosticChecks: 5 cases passed, 0 failed (in-process only)")
    }

    static func foreignIntake(sameID: Bool) async throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "diagnostic-source-\(UUID()).jsonl")
        let receiverURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "diagnostic-receiver-\(UUID()).jsonl")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: receiverURL)
        }
        let sourceAudit = try WorkbenchAuditSink(newFileAt: sourceURL)
        let receiverAudit = try WorkbenchAuditSink(newFileAt: receiverURL)
        let source = try RunComposition(audit: sourceAudit, credentialStore: SettingsStore())
        let receiver = try RunComposition(audit: receiverAudit, credentialStore: SettingsStore())
        let grant = try ConnectionSettingsChecks.makeGrant(nil)
        let installed = try await source.install(grant)
        // Exact same grant/ID/digest in a different authority must still be foreign.
        let receivingGrant = try sameID ? grant : ConnectionSettingsChecks.makeGrant(nil)
        let receivingRun = try await receiver.install(receivingGrant)
        let owner = NSObject()
        let local = try source.diagnosticSession(owner: owner, run: installed)
        let receivingOwner = NSObject()
        let receivingLocal = try receiver.diagnosticSession(owner: receivingOwner, run: receivingRun)
        let receiverBefore = receiverAudit.snapshot()
        let sourceBefore = sourceAudit.snapshot()
        var rejected = false
        var foreign: VMDiagnosticSession?
        do { foreign = try receiver.diagnosticSession(owner: NSObject(), run: installed) } catch AuthorizationError
            .invalidHandle
        { rejected = true }
        let unchangedOnIntake = receiverAudit.snapshot() == receiverBefore && sourceAudit.snapshot() == sourceBefore
        let sourceActiveOnIntake = installed.authorityHandle.lifecycle.currentStatus == .active
        #if DEBUG
            let onlyOwnRunRetained = receiver.retainedOwnedRuns == 1 && receiver.pendingOwnedWork == 0
        #else
            let onlyOwnRunRetained = true
        #endif
        receiver.beginClose()
        let ownSessionStopped = receivingLocal.revoked
        let firstClose = await receiver.close()
        let receiverAfterClose = receiverAudit.snapshot()
        let secondClose = await receiver.close()
        let repeatedCloseUnchanged = receiverAudit.snapshot() == receiverAfterClose
        let sourceStillActive = installed.authorityHandle.lifecycle.currentStatus == .active
        try local.open(owner: owner, now: 0)
        let reply = try local.reply(to: VMFrame(runID: grant.runID, epoch: grant.epoch, nonce: 1), owner: owner, now: 1)
        let sourceUsable = reply.type == 2 && local.lifecycle === installed.authorityHandle.lifecycle
        let auditIsolated =
            receiverAudit.snapshot() == receiverAfterClose && sourceAudit.snapshot().count == sourceBefore.count + 1
        let sourceClosed = await source.close()
        let sourceClosedAgain = await source.close()
        print(
            "OBS diagnostic sameID=\(sameID) foreign_rejected=\(rejected) returned_foreign=\(foreign != nil) source_usable=\(sourceUsable) audit_isolated=\(auditIsolated) receiving_closed=\(firstClose && secondClose) source_closed=\(sourceClosed && sourceClosedAgain)"
        )
        try require(rejected && foreign == nil, "foreign InstalledRun accepted by actual diagnosticSession")
        try require(
            unchangedOnIntake && sourceActiveOnIntake && onlyOwnRunRetained,
            "rejection changed source, audit or ownership")
        try require(
            ownSessionStopped && firstClose && secondClose && repeatedCloseUnchanged,
            "receiving close must be truthful and idempotent")
        try require(
            sourceStillActive && sourceUsable && auditIsolated, "receiving rejection/close contaminated source or audit"
        )
        try require(sourceClosed && sourceClosedAgain && local.revoked, "source owns its real session shutdown")
        print("PASS composition diagnostic foreign sameID=\(sameID)")
    }

    static func localTermination(revoke: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-local-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: url), credentialStore: SettingsStore())
        let run = try await root.install(ConnectionSettingsChecks.makeGrant(nil))
        let owner = NSObject()
        let session = try root.diagnosticSession(owner: owner, run: run)
        try session.open(owner: owner, now: 0)
        _ = try session.reply(
            to: VMFrame(runID: run.grant.runID, epoch: run.grant.epoch, nonce: 1), owner: owner, now: 1)
        session.close()
        try require(!session.revoked, "connection close must not revoke an otherwise live run")
        try session.open(owner: owner, now: 2)
        if revoke { session.revoke() } else { root.beginClose() }
        try require(
            session.revoked && run.authorityHandle.lifecycle.currentStatus == .stopped,
            "real owner termination must reach the same lifecycle synchronously")
        do {
            _ = try session.reply(
                to: VMFrame(runID: run.grant.runID, epoch: run.grant.epoch, nonce: 2), owner: owner, now: 3)
            throw Failure(message: "terminal local session replied")
        } catch VMProtocolError.stopped {}
        let first = await root.close()
        let second = await root.close()
        try require(first && second && root.isClosed, "local cleanup must remain truthful")
        do {
            _ = try root.diagnosticSession(owner: owner, run: run)
            throw Failure(message: "closed composition created session")
        } catch AuthorizationError.runRevoked {}
        print("PASS composition diagnostic local revoke=\(revoke)")
    }

    static func installedGrantValidation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-grant-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let audit = try WorkbenchAuditSink(newFileAt: url)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore())
        let run = try await root.install(ConnectionSettingsChecks.makeGrant(nil))
        let other = try ConnectionSettingsChecks.makeGrant(nil)
        let before = audit.snapshot()
        do {
            _ = try VMDiagnosticSession(
                owner: NSObject(), runID: other.runID, epoch: other.epoch,
                workloadDigest: other.workloadImageDigest, sink: audit,
                authorityHandle: run.authorityHandle, installedGrant: other)
            throw Failure(message: "mismatched installed grant accepted")
        } catch VMProtocolError.crossContext {}
        try require(
            run.authorityHandle.lifecycle.currentStatus == .active && audit.snapshot() == before,
            "invalid grant mutated source or audit")
        let closed = await root.close()
        try require(closed, "grant-validation cleanup failed")
        print("PASS composition diagnostic installed grant validation")
    }
}
