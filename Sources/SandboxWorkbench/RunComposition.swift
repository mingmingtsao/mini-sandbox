import Foundation
import SandboxContracts
import SandboxHost

/// App-owned composition. The gateways and UI never reinstall an existing run.
/// Empty connection registries are deliberate until trusted configuration exists.
@MainActor package final class RunComposition {
    package let authority: RunAuthorizationController
    package let workbench: WorkbenchModel
    package let model: HostModelGateway
    package let mcp: HostMCPGateway
    private let audit: WorkbenchAuditSink

    package struct InstalledRun: Sendable {
        package let grant: RunGrant
        package let authorityHandle: HostRunHandle
        package let modelHandle: HostModelRunHandle
        package let mcpHandle: HostMCPRunHandle
    }

    package init(audit: WorkbenchAuditSink, modelConnections: [HostModelConnection] = [],
                 mcpConnections: [HostMCPConnection] = [],
                 clock: RunClock = .system()) throws {
        self.audit = audit
        let authority = RunAuthorizationController(auditSink: audit, clock: clock)
        self.authority = authority
        workbench = WorkbenchModel(audit: audit, authority: authority)
        model = try HostModelGateway(connections: modelConnections, auditSink: audit, authority: authority)
        mcp = try HostMCPGateway(connections: mcpConnections, auditSink: audit, authority: authority)
    }

    package func install(_ grant: RunGrant) async throws -> InstalledRun {
        let handle = try await authority.install(grant: grant)
        do {
            let modelHandle = try await model.install(grant: grant, authorityHandle: handle)
            let mcpHandle = try await mcp.install(grant: grant, authorityHandle: handle)
            try await workbench.installTrustedGrant(grant, authorityHandle: handle)
            return InstalledRun(grant: grant, authorityHandle: handle, modelHandle: modelHandle, mcpHandle: mcpHandle)
        } catch {
            handle.lifecycle.terminate(.faulted)
            try? await authority.stop(handle: handle)
            throw error
        }
    }

    /// Session hook only; this does not launch a VM or provide a guest data plane.
    package func diagnosticSession(owner: AnyObject, run: InstalledRun) throws -> VMDiagnosticSession {
        try VMDiagnosticSession(owner: owner, runID: run.grant.runID, epoch: run.grant.epoch,
            workloadDigest: run.grant.workloadImageDigest, sink: audit,
            authorityHandle: run.authorityHandle, installedGrant: run.grant)
    }

    package static func application() throws -> RunComposition {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniSandbox/Audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try RunComposition(audit: WorkbenchAuditSink(newFileAt: directory.appendingPathComponent("\(UUID()).jsonl")))
    }
}
