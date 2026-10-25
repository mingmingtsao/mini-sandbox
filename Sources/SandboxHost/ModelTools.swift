import Foundation

package struct ModelToolDefinition: Equatable, Sendable, Codable {
    package let name: String
    package let description: String?
    package let inputSchema: ModelJSON
    private enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
    package init(name: String, description: String? = nil, inputSchema: ModelJSON) throws {
        guard ModelBlock.validName(name), (description?.utf8.count ?? 0) <= 4096, inputSchema.object != nil,
            inputSchema["type"]?.string == "object"
        else { throw ModelTransportError.invalidRequest("tool schema") }
        do { _ = try inputSchema.validated() } catch { throw ModelTransportError.invalidRequest("tool schema") }
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: c.decode(String.self, forKey: .name),
            description: c.decodeIfPresent(String.self, forKey: .description),
            inputSchema: c.decode(ModelJSON.self, forKey: .inputSchema))
    }
}

package struct ModelToolChoice: Equatable, Sendable, Codable {
    package enum Kind: String, Codable, Sendable { case auto, any, tool, none }
    package let type: Kind
    package let name: String?
    package let disableParallelToolUse: Bool?
    private enum CodingKeys: String, CodingKey {
        case type, name
        case disableParallelToolUse = "disable_parallel_tool_use"
    }
    package init(type: Kind, name: String? = nil, disableParallelToolUse: Bool? = nil) throws {
        guard (type == .tool) == (name != nil), name.map(ModelBlock.validName) ?? true,
            type != .none || disableParallelToolUse == nil
        else { throw ModelTransportError.invalidRequest("tool choice") }
        self.type = type
        self.name = name
        self.disableParallelToolUse = disableParallelToolUse
    }
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            type: c.decode(Kind.self, forKey: .type), name: c.decodeIfPresent(String.self, forKey: .name),
            disableParallelToolUse: c.decodeIfPresent(Bool.self, forKey: .disableParallelToolUse))
    }
}

package enum ModelConversationValidation {
    package static func validate(
        messages: [FixedMessage], tools: [ModelToolDefinition], choice: ModelToolChoice?, protocol kind: FixedProtocol
    ) throws {
        try validateImpl(messages: messages, tools: tools, choice: choice, protocol: kind, midSystem: false)
    }
    static func validateClaude(messages: [FixedMessage], tools: [ModelToolDefinition], choice: ModelToolChoice?) throws
    {
        try validateImpl(messages: messages, tools: tools, choice: choice, protocol: .anthropic, midSystem: true)
    }
    private static func validateImpl(
        messages: [FixedMessage], tools: [ModelToolDefinition], choice: ModelToolChoice?, protocol kind: FixedProtocol,
        midSystem: Bool
    ) throws {
        let structured = !tools.isEmpty || choice != nil || messages.contains { !$0.isLegacyText }
        guard kind == .anthropic || !structured else {
            throw ModelTransportError.invalidRequest("structured OpenAI unsupported")
        }
        guard tools.count <= 64, Set(tools.map(\.name)).count == tools.count else {
            throw ModelTransportError.invalidRequest("tools")
        }
        let names = Set(tools.map(\.name))
        if let choice {
            guard !tools.isEmpty || choice.type == .none, choice.name.map(names.contains) ?? true else {
                throw ModelTransportError.invalidRequest("tool choice")
            }
        }
        guard structured else { return }
        var ids = Set<String>()
        var pending = Set<String>()
        var nonSystem = false
        for (index, message) in messages.enumerated() {
            if message.role == .system {
                if midSystem {
                    var first = index
                    while first > 0 && messages[first - 1].role == .system { first -= 1 }
                    var end = index + 1
                    while end < messages.count && messages[end].role == .system { end += 1 }
                    guard pending.isEmpty, first > 0, messages[first - 1].role == .user,
                        end == messages.count || messages[end].role == .assistant,
                        message.blocks.allSatisfy({ if case .text(let text) = $0 { !text.isEmpty } else { false } })
                    else {
                        throw ModelTransportError.invalidRequest("system placement")
                    }
                    continue
                }
                guard !nonSystem, message.blocks.allSatisfy({ if case .text = $0 { true } else { false } }) else {
                    throw ModelTransportError.invalidRequest("system blocks")
                }
                continue
            }
            if !nonSystem {
                guard message.role == .user else { throw ModelTransportError.invalidRequest("first role") }
                nonSystem = true
            }
            let expected = pending
            var results = Set<String>()
            var sawText = false
            if !expected.isEmpty && message.role != .user {
                throw ModelTransportError.invalidRequest("missing tool results")
            }
            for block in message.blocks {
                switch block {
                case .text: sawText = true
                case .toolUse(let id, let name, _):
                    guard message.role == .assistant, expected.isEmpty, names.contains(name), ids.insert(id).inserted
                    else { throw ModelTransportError.invalidRequest("tool use") }
                    pending.insert(id)
                case .toolResult(let id, _, _):
                    guard message.role == .user, !sawText, expected.contains(id), results.insert(id).inserted else {
                        throw ModelTransportError.invalidRequest("tool result")
                    }
                }
            }
            if !expected.isEmpty {
                guard results == expected else { throw ModelTransportError.invalidRequest("missing tool results") }
                pending.removeAll()
            }
        }
        guard nonSystem, pending.isEmpty else { throw ModelTransportError.invalidRequest("missing tool results") }
    }
}
