import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

@MainActor enum CompositionBusinessChecks {
    static func run() async throws {
        for succeeded in [true, false] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("business-close-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            let composition = try RunComposition(audit: WorkbenchAuditSink(newFileAt: url), credentialStore: SettingsStore())
            let run = try await composition.install(ConnectionSettingsChecks.makeGrant(nil))
            let token = try composition.beginBusinessOwnership(run)
            let business = composition.business
            composition.beginClose()
            var completed = false
            let close = Task { let result = await composition.close(); completed = true; return result }
            for _ in 0..<100 { await Task.yield() }
            let held = !completed && !composition.isClosed && business.isClosing && run.authorityHandle.lifecycle.currentStatus != .active
            composition.finishBusinessOwnership(token, succeeded: succeeded)
            let first = await close.value, again = await composition.close()
            try CompositionDiagnosticChecks.require(held && first == succeeded && again == succeeded,
                "business attachment cleanup must hold native close and preserve failure")
            print("PASS composition business close waits cleanup succeeded=\(succeeded)")
        }
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("business-source-\(UUID()).jsonl")
        let receiverURL = FileManager.default.temporaryDirectory.appendingPathComponent("business-receiver-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: sourceURL); try? FileManager.default.removeItem(at: receiverURL) }
        let source = try RunComposition(audit: WorkbenchAuditSink(newFileAt: sourceURL), credentialStore: SettingsStore())
        let receiver = try RunComposition(audit: WorkbenchAuditSink(newFileAt: receiverURL), credentialStore: SettingsStore())
        let grant = try ConnectionSettingsChecks.makeGrant(nil)
        let local = try await source.install(grant)
        _ = try await receiver.install(grant)
        var rejected = false
        do { _ = try receiver.beginBusinessOwnership(local) }
        catch AuthorizationError.invalidHandle { rejected = true }
        let receivingClosed = await receiver.close()
        let sourceActive = local.authorityHandle.lifecycle.currentStatus == .active
        let sourceClosed = await source.close()
        try CompositionDiagnosticChecks.require(rejected && receivingClosed && sourceActive && sourceClosed,
            "business intake must reject foreign equal-ID authority without retiring source")
        print("PASS composition business owner rejects foreign equal-ID run")
    }
}
