import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

@MainActor enum MCPSettingsChecks {
    static func run() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-settings-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let composition = try RunComposition(
            audit: WorkbenchAuditSink(newFileAt: url), credentialStore: SettingsStore())
        let settings = composition.mcpSettings
        try CompositionDiagnosticChecks.require(
            settings.configuration == nil && !settings.isClosed, "MCP defaults unavailable")
        await settings.connect(port: "49153", bearer: String(repeating: "x", count: 4096))
        guard let first = settings.configuration else {
            throw CompositionDiagnosticChecks.Failure(message: "MCP configure failed")
        }
        let now = Date()
        let grant = try RunGrant(
            runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
            workloadImageDigest: String(repeating: "1", count: 64), agentAdapterVersion: "settings-check",
            workspaceSnapshotID: UUID(),
            policyDigest: String(repeating: "2", count: 64), approvalSnapshotID: UUID(),
            connections: [
                ConnectionGrant(
                    connectionID: first.connectionID, accountBindingVersion: first.version, routeVersion: first.version,
                    scopes: [ResourceScope(service: "mcp", resource: "A", operation: "read")])
            ], explicitDenies: [],
            resourceLimits: ResourceLimits(
                cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 65536, concurrentRequests: 1))
        let run = try await composition.install(grant)
        let oldGateway = run.mcpGateway
        await settings.connect(port: "0", bearer: "invalid-port")
        try CompositionDiagnosticChecks.require(
            settings.configuration == first && run.authorityHandle.lifecycle.currentStatus == .active,
            "invalid MCP settings must not retire valid configuration")
        for bearer in ["", "has space", "unicode-é", String(repeating: "x", count: 4097)] {
            await settings.connect(port: "49153", bearer: bearer)
            try CompositionDiagnosticChecks.require(
                settings.configuration == first && run.authorityHandle.lifecycle.currentStatus == .active
                    && oldGateway === composition.mcp,
                "invalid MCP credential format must preserve the active configuration and run")
        }
        await settings.connect(port: "49154", bearer: "public-test-only-second")
        guard let second = settings.configuration else {
            throw CompositionDiagnosticChecks.Failure(message: "MCP replacement failed")
        }
        try CompositionDiagnosticChecks.require(
            second.connectionID == first.connectionID && second.version == first.version + 1
                && run.authorityHandle.lifecycle.currentStatus != .active && oldGateway !== composition.mcp,
            "MCP replacement retires old run before exposing a fresh gateway/version")
        await settings.disconnect()
        try CompositionDiagnosticChecks.require(
            settings.configuration == nil, "MCP disconnect removes future configuration")
        let closed = await composition.close()
        try CompositionDiagnosticChecks.require(
            closed && settings.isClosed && settings.configuration == nil, "MCP close is composed")
        print(
            "PASS native local MCP settings reject invalid input, replace bound runs, retain old gateway identity and close; network=0 Keychain=0"
        )
    }
}
