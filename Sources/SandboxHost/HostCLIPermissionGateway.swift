import CryptoKit
import Foundation
import SandboxContracts

package struct CLIPermissionRequest: Sendable {
    package let root: ModelJSON
    package let requestID: String
    package let toolUseID: String
    package let toolName: String
    package let input: ModelJSON
    package let operation: String
    package let argumentsJSON: String

    package static func parse(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 16_384 else { throw HostModelGatewayError.messageTooLarge }
        let root = try ModelJSON.parse(bytes)
        guard let fields = root.object, Set(fields.keys) == ["type", "request_id", "request"],
              fields["type"]?.string == "control_request",
              let requestID = fields["request_id"]?.string, validID(requestID),
              let request = fields["request"]?.object,
              Set(request.keys).isSubset(of: ["subtype", "tool_name", "input", "tool_use_id", "permission_suggestions", "blocked_path", "decision_reason", "agent_id"]),
              request["subtype"]?.string == "can_use_tool",
              let toolUseID = request["tool_use_id"]?.string, validID(toolUseID),
              let name = request["tool_name"]?.string,
              let input = request["input"], let values = input.object else { throw HostModelGatewayError.denied }
        let operation: String
        switch name {
        case "Read", "Edit", "Write":
            guard let path = values["file_path"]?.string, projectPath(path) else { throw HostModelGatewayError.denied }
            operation = name == "Read" ? "read" : "write"
        case "Glob", "Grep":
            if let path = values["path"] { guard let text = path.string, projectPath(text, allowRoot: true) else { throw HostModelGatewayError.denied } }
            operation = "read"
        case "Bash":
            guard let command = values["command"]?.string, !command.isEmpty, command.utf8.count <= 8192,
                  !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { throw HostModelGatewayError.denied }
            operation = "execute"
        default: throw HostModelGatewayError.denied
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self(root: root, requestID: requestID, toolUseID: toolUseID, toolName: name, input: input,
                    operation: operation, argumentsJSON: String(decoding: try encoder.encode(input), as: UTF8.self))
    }
    private static func validID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256 && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func projectPath(_ path: String, allowRoot: Bool = false) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if allowRoot, path == "/work/project" || path == "." { return true }
        let relative: String
        if path.hasPrefix("/work/project/") { relative = String(path.dropFirst("/work/project/".count)) }
        else if path.hasPrefix("/") { return false }
        else { relative = path }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Bridges the pinned CLI's normal stdio permission request to a one-use native
/// host decision. It never runs the tool and never creates a tool_result.
package actor HostCLIPermissionGateway {
    package struct Proposal: Sendable {
        package let pending: PendingAction
        package let toolName: String
        package let argumentsJSON: String
        fileprivate let channel: BusinessVMConnection
        fileprivate let scope: RunEffectScope
    }
    private let authority: RunAuthorizationController
    private let handle: HostRunHandle
    private let grant: RunGrant
    private let connectionID: UUID
    private let resource: String
    private var totalRequests = 0
    private var pendingChannels: Set<UUID> = []

    package init(authority: RunAuthorizationController, handle: HostRunHandle, grant: RunGrant, connectionID: UUID) throws {
        guard try authority.installedGrantForOwnership(of: handle) == grant,
              grant.connections.contains(where: { $0.connectionID == connectionID }) else { throw HostModelGatewayError.invalidHandle }
        self.authority = authority; self.handle = handle; self.grant = grant; self.connectionID = connectionID
        resource = "workspace:" + grant.workspaceSnapshotID.uuidString
    }
    package func propose(connection: BusinessVMConnection, body: Data) async throws -> Proposal {
        guard connection.lifecycle === handle.lifecycle, connection.runID == grant.runID, connection.epoch == grant.epoch,
              connection.service == .permission, totalRequests < 64, !pendingChannels.contains(connection.id) else { throw HostModelGatewayError.invalidHandle }
        let request = try CLIPermissionRequest.parse(body)
        let observation = handle.lifecycle.observeAndReduce(reason: "cli-permission-proposal")
        let requested = try ResourceScope(service: "workspace", resource: resource, operation: request.operation)
        guard observation.status == .active,
              grant.decision(for: requested, connectionID: connectionID, at: observation.effectiveTime) == .allowed else { throw HostModelGatewayError.denied }
        let envelope = ModelJSON.object(["schema": .integer(1), "runID": .string(grant.runID.uuidString),
            "epoch": .string(String(grant.epoch)), "channelID": .string(connection.id.uuidString),
            "runtimeID": .string(connection.runtimeID.uuidString), "request": request.root])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(envelope)
        guard canonical.count <= min(grant.resourceLimits.messageBytes, 16_384) else { throw HostModelGatewayError.messageTooLarge }
        let schema = SHA256.hash(data: Data("claude-stdio-permission-v1".utf8)).map { String(format: "%02x", $0) }.joined()
        let binding = try ActionBinding(runID: grant.runID, epoch: grant.epoch,
            grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: connectionID,
            operation: request.operation, schemaDigest: schema, resolvedResource: resource, canonicalRequest: canonical)
        let scope = handle.lifecycle.effectScope(connectionID: connectionID)
        totalRequests += 1; pendingChannels.insert(connection.id)
        do {
            let pending = try await authority.propose(handle: handle, binding: binding,
                display: "Claude \(request.toolName) in isolated VM project copy. Review exact arguments before approving.")
            guard !connection.isRetired, handle.lifecycle.observeAndReduce(reason: "cli-permission-return").status == .active,
                  handle.lifecycle.currentGeneration == scope.generation else { throw HostModelGatewayError.revoked }
            return Proposal(pending: pending, toolName: request.toolName, argumentsJSON: request.argumentsJSON, channel: connection, scope: scope)
        } catch { pendingChannels.remove(connection.id); connection.retire(); throw error }
    }

    package func deny(_ proposal: Proposal) async throws {
        guard pendingChannels.remove(proposal.channel.id) != nil else { throw HostModelGatewayError.invalidApproval }
        defer { proposal.channel.retire() }
        try await authority.deny(handle: handle, actionID: proposal.pending.actionID)
        let bytes = Data(#"{"behavior":"deny","message":"User denied this tool action"}"#.utf8)
        let output = try BusinessVMFrameOutput(connection: proposal.channel, handle: handle, scope: proposal.scope,
            body: bytes, actionID: proposal.pending.actionID)
        try await drain(output)
    }
    package func approveAndSend(_ proposal: Proposal) async throws {
        guard pendingChannels.remove(proposal.channel.id) != nil else { throw HostModelGatewayError.invalidApproval }
        defer { proposal.channel.retire() }
        let approved = try await authority.hostApprove(handle: handle, actionID: proposal.pending.actionID, nonce: proposal.pending.nonce)
        let ticket = try await authority.consume(handle: handle, approved: approved)
        var output: BusinessVMFrameOutput?
        var completionAttempted = false
        do {
            guard ticket.approvedRequest == proposal.pending.binding.canonicalRequest else { throw HostModelGatewayError.invalidApproval }
            let envelope = try ModelJSON.parse(ticket.approvedRequest)
            guard envelope["channelID"]?.string == proposal.channel.id.uuidString,
                  envelope["runtimeID"]?.string == proposal.channel.runtimeID.uuidString,
                  let root = envelope["request"] else { throw HostModelGatewayError.invalidApproval }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let request = try CLIPermissionRequest.parse(encoder.encode(root))
            let response = try encoder.encode(ModelJSON.object(["behavior": .string("allow"), "updatedInput": request.input]))
            let writer = try BusinessVMFrameOutput(connection: proposal.channel, handle: handle, scope: proposal.scope,
                body: response, actionID: proposal.pending.actionID)
            output = writer
            try await drain(writer)
            completionAttempted = true
            try await authority.complete(handle: handle, ticket: ticket, outcome: .completed)
        } catch {
            output?.cancel()
            if !completionAttempted {
                try? await authority.complete(handle: handle, ticket: ticket, outcome: (output?.committedBytes ?? 0) > 0 ? .unknown : .failed)
            }
            throw error
        }
    }
    private func drain(_ output: BusinessVMFrameOutput) async throws {
        while !output.completed {
            try Task.checkCancellation()
            if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}
