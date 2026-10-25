import Foundation
import SandboxHost
import SandboxWorkbench

#if SANDBOX_TEST_FIXTURES
@MainActor enum CompositionLocalFixtureChecks {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-local-fixture-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let composition = try RunComposition.localBusinessFixture(port: 49152, newRoot: root, mcpPort: 49153)
        let settings = composition.connectionSettings
        let configuration = settings.configuration
        try CompositionDiagnosticChecks.require(composition.isLocalFixture && composition.businessRouteAvailable &&
            settings.isLocalFixture && configuration != nil && !BusinessModelActivation.credentialEgressEnabled,
            "local fixture must not enable production gate")
        await settings.save("unused-user-input")
        await settings.checkStoredCredential()
        await settings.deleteStoredCredential()
        try CompositionDiagnosticChecks.require(settings.configuration == configuration && !settings.isBusy,
            "fixture cannot replace its connection or call credential storage")
        let mcp = composition.mcpSettings, mcpConfiguration = composition.mcpSettings.configuration
        await mcp.connect(port: "49154", bearer: "must-not-replace-fixture")
        await mcp.disconnect()
        try CompositionDiagnosticChecks.require(mcp.isLocalFixture && mcpConfiguration != nil && mcp.configuration == mcpConfiguration,
            "local MCP fixture cannot replace public-canary connection")
        try CompositionDiagnosticChecks.require(composition.business.activationAvailable && composition.business.isLocalFixture &&
            !composition.business.canStart && composition.businessTaskDirectory == root.appendingPathComponent("Tasks", isDirectory: true),
            "fixture still requires explicit project/runtime/task/consent")
        do {
            _ = try RunComposition.localBusinessFixture(port: 49152, newRoot: root)
            throw CompositionDiagnosticChecks.Failure(message: "fixture root reused")
        } catch BusinessTaskFailure.unavailable {}
        let closed = await composition.close()
        try CompositionDiagnosticChecks.require(closed && composition.business.isClosing, "fixture native cleanup close")
        print("PASS App local fixture is isolated, cannot use Keychain settings, keeps production disabled and still requires task consent; VM/provider NOT_RUN")
    }
}
#endif
