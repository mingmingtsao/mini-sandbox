import AppKit
import Foundation
import SandboxHost

@testable import SandboxWorkbench

@MainActor enum BusinessPresentationChecks {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("business-presentation-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresentationStore()
        let composition = try RunComposition(
            audit: WorkbenchAuditSink(newFileAt: directory.appendingPathComponent("audit.jsonl")),
            credentialStore: store)
        let controller = composition.business
        let surface = Surface(
            BusinessTaskView(
                controller: controller, connections: composition.connectionSettings,
                mcpConnections: composition.mcpSettings), width: 1250, height: 1500)
        defer { surface.dispose() }
        try await PresentationChecks.settle()
        try expectPresentation(try surface.contains(controller.status), "initial task availability missing from pixels")
        try expectPresentation(
            !controller.canStart && !controller.isBusy && store.count == 0,
            "empty task view performed IO or admitted work")
        controller.permissionsConfirmed = true
        controller.selectProject(directory.appendingPathComponent("fixture-project"))
        try expectPresentation(!controller.permissionsConfirmed, "project change retained consent")
        controller.permissionsConfirmed = true
        controller.selectRuntime(directory.appendingPathComponent("fixture-runtime"))
        try expectPresentation(!controller.permissionsConfirmed, "runtime change retained consent")
        controller.permissionsConfirmed = true
        controller.selectVendor(directory.appendingPathComponent("fixture-vendor.raw"))
        try expectPresentation(!controller.permissionsConfirmed, "vendor change retained consent")
        controller.task = "Synthetic task rendering check"
        for agent in [BusinessTaskController.Agent.codex, .dsh] {
            controller.agent = agent
            try await PresentationChecks.settle()
            try expectPresentation(
                !controller.canStart && surface.contains("not implemented"),
                "unsupported agent was admitted or not identified")
        }
        controller.agent = .claude
        await composition.connectionSettings.save("synthetic-model-only")
        await composition.mcpSettings.connect(port: "49152", bearer: "synthetic-mcp-only")
        try expectPresentation(
            composition.mcpSettings.configuration != nil, "local MCP presentation fixture not configured")
        controller.permissionsConfirmed = true
        controller.useMCP = true
        try await PresentationChecks.settle()
        try expectPresentation(!controller.permissionsConfirmed, "MCP selection retained stale consent")
        controller.permissionsConfirmed = true
        controller.allowMCPWrite = true
        try await PresentationChecks.settle()
        try expectPresentation(!controller.permissionsConfirmed, "MCP write selection retained stale consent")
        try expectPresentation(
            try surface.contains("fixture-project") && surface.contains("fixture-runtime")
                && surface.contains("fixture-vendor.raw"), "selected immutable paths missing from pixels")
        controller.permissionsConfirmed = true
        try expectPresentation(
            controller.activationAvailable && controller.canStart,
            "complete selection not admitted with the production route enabled")
        let storageOperations = store.count
        controller.start()
        for _ in 0..<40 where controller.isBusy { try await PresentationChecks.settle() }
        try expectPresentation(
            !controller.isBusy && controller.error != nil && composition.workbench.grants.isEmpty
                && store.count == storageOperations,
            "unverifiable runtime installed a grant or touched the credential store")
        let mcp = Surface(MCPConnectionSettingsView(controller: composition.mcpSettings), width: 1100, height: 500)
        defer { mcp.dispose() }
        try await PresentationChecks.settle()
        try expectPresentation(
            try mcp.contains("49152") && !mcp.contains("synthetic-mcp-only"), "MCP metadata missing or bearer visible")
        await composition.mcpSettings.disconnect()
        try await PresentationChecks.settle()
        try expectPresentation(
            composition.mcpSettings.configuration == nil && mcp.contains("Disconnected"),
            "disconnected MCP state not rendered")
        controller.cancel()
        controller.finishReview()
        controller.export(to: directory.appendingPathComponent("unapproved-export"))
        try expectPresentation(
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("unapproved-export").path),
            "missing review exported")
        let closed = await composition.close()
        try expectPresentation(
            closed && controller.isClosing && !controller.canStart, "close did not retire task admission")
        print(
            "PASS business task selection consent agent gates and MCP metadata projection; unverifiable runtime fails closed before grant"
        )
    }
}
