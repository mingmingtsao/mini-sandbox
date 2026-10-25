import Foundation

/// Completed model output is only a proposal source, never execution authority.
/// Deliberately accepts no provisional ModelStreamChunk or guest approval object.
package enum MCPModelHandoff {
    package static func propose(
        completion: ModelCompletion, gateway: HostMCPGateway, handle: HostMCPRunHandle, connectionID: UUID
    ) async throws -> HostMCPProposal {
        guard completion.metadata.stopReason == "tool_use", completion.blocks.count == 1,
            case .toolUse(let id, let name, let input) = completion.blocks[0], ModelBlock.validID(id)
        else { throw HostMCPGatewayError.denied }
        let payload = ModelJSON.object([
            "jsonrpc": .string("2.0"), "id": .string(UUID().uuidString), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": input]),
        ])
        return try await gateway.propose(
            handle: handle, connectionID: connectionID, raw: MCPProtocol.canonical(payload), sourceToolUseID: id)
    }
    /// Only an audit-gated MCP completion can supply a successful tool result.
    package static func toolResult(_ completion: MCPCompletion, matching toolUseID: String) throws -> ModelBlock {
        guard completion.sourceToolUseID == toolUseID, ModelBlock.validID(toolUseID) else {
            throw HostMCPGatewayError.denied
        }
        return .toolResult(toolUseID: toolUseID, content: completion.text, isError: false)
    }
}
