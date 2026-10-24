import Foundation

/// A deliberately limited Anthropic wire request, not a lossy FixedModelRequest
/// conversion. Only the original validated JSON tree is retained/sent. Projection
/// into existing DTOs below is exclusively for the existing pairing checks.
package struct AnthropicNativeRequest: Sendable {
    package let body: ModelJSON
    package let canonicalBody: Data
    package let streaming: Bool
    package var model: FixedModel { .deepSeekFlash }

    package static func decodeValidated(_ bytes: Data, streaming: Bool) throws -> Self {
        do { return try Self(root: ModelJSON.parse(bytes), streaming: streaming) }
        catch { throw ModelTransportError.invalidRequest("native request") }
    }

    private init(root: ModelJSON, streaming: Bool) throws {
        var object = try Self.keys(root, ["model", "max_tokens", "stream", "system", "messages", "tools", "tool_choice", "thinking", "metadata", "output_config"])
        guard object["model"]?.string == FixedModel.deepSeekFlash.rawValue,
              let tokens = object["max_tokens"]?.integer, (1...Int64(FixedModelRequest.maxOutputTokens)).contains(tokens),
              object["stream"] == .bool(streaming),
              let messages = object["messages"]?.array, !messages.isEmpty,
              messages.count <= FixedModelRequest.maxMessages else { throw Self.invalid }
        // Host policy is explicit in approved bytes. Omission is NOT treated as
        // evidence of the upstream default. Incoming adaptive/enabled are denied.
        let disabled = ModelJSON.object(["type": .string("disabled")])
        if let thinking = object["thinking"] { guard thinking == disabled else { throw Self.invalid } }
        object["thinking"] = disabled
        if let config = object["output_config"] {
            let fields = try Self.keys(config, ["effort"])
            guard let effort = fields["effort"]?.string, ["low", "high", "max"].contains(effort) else { throw Self.invalid }
            // Retain the documented setting verbatim. It neither enables thinking
            // nor promises active reasoning under the explicit disabled policy.
        }
        if let system = object["system"] {
            if let text = system.string { _ = try FixedMessage(role: .system, content: text) }
            else {
                guard let blocks = system.array, !blocks.isEmpty, blocks.count <= 128 else { throw Self.invalid }
                for block in blocks { _ = try Self.textBlock(block) }
            }
        }
        if let metadata = object["metadata"] {
            let fields = try Self.keys(metadata, ["user_id"])
            guard let user = fields["user_id"]?.string, !user.isEmpty, user.utf8.count <= 256,
                  !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Self.invalid }
        }
        var tools: [ModelToolDefinition] = []
        if let value = object["tools"] {
            guard let array = value.array, array.count <= 64 else { throw Self.invalid }
            tools = try array.map { value in
                let t = try Self.keys(value, ["name", "description", "input_schema", "cache_control"])
                try Self.cache(t["cache_control"])
                guard let name = t["name"]?.string, let schema = t["input_schema"] else { throw Self.invalid }
                if let description = t["description"], description.string == nil { throw Self.invalid }
                return try ModelToolDefinition(name: name, description: t["description"]?.string, inputSchema: schema)
            }
        }
        var choice: ModelToolChoice?
        if let value = object["tool_choice"] {
            // Parallelism enforcement is not established for this upstream.
            let c = try Self.keys(value, ["type", "name"])
            guard let raw = c["type"]?.string, let kind = ModelToolChoice.Kind(rawValue: raw) else { throw Self.invalid }
            if let name = c["name"], name.string == nil { throw Self.invalid }
            choice = try ModelToolChoice(type: kind, name: c["name"]?.string)
        }
        let projection: [FixedMessage] = try messages.map { message in
            let m = try Self.keys(message, ["role", "content"])
            guard let role = m["role"]?.string, role == "user" || role == "assistant", let content = m["content"] else { throw Self.invalid }
            let kind: FixedMessageRole = role == "user" ? .user : .assistant
            if let text = content.string {
                _ = try FixedMessage(role: kind, content: text)
                return try FixedMessage(role: kind, blocks: [.text(text)])
            }
            guard let array = content.array, !array.isEmpty, array.count <= 128 else { throw Self.invalid }
            return try FixedMessage(role: kind, blocks: array.map(Self.messageBlock))
        }
        try ModelConversationValidation.validate(messages: projection, tools: tools, choice: choice, protocol: .anthropic)
        let body = ModelJSON.object(object)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(body)
        _ = try ModelJSON.parse(canonical) // policy expansion must also fit unchanged bounds
        self.body = body; canonicalBody = canonical; self.streaming = streaming
    }

    private static var invalid: ModelTransportError { .invalidRequest("native request") }
    private static func keys(_ value: ModelJSON, _ allowed: Set<String>) throws -> [String: ModelJSON] {
        guard let fields = value.object, Set(fields.keys).isSubset(of: allowed) else { throw invalid }
        return fields
    }
    private static func cache(_ value: ModelJSON?) throws {
        guard let value else { return }
        // Preserve the marker even though DeepSeek documents it as ignored.
        // No TTL promise or unknown cache setting is accepted.
        guard value == .object(["type": .string("ephemeral")]) else { throw invalid }
    }
    private static func textBlock(_ value: ModelJSON) throws -> ModelBlock {
        let fields = try keys(value, ["type", "text", "cache_control"])
        guard fields["type"]?.string == "text", let text = fields["text"]?.string else { throw invalid }
        try cache(fields["cache_control"])
        return .text(text)
    }
    private static func messageBlock(_ value: ModelJSON) throws -> ModelBlock {
        switch value["type"]?.string {
        case "text": return try textBlock(value)
        case "tool_use":
            let fields = try keys(value, ["type", "id", "name", "input", "cache_control"])
            try cache(fields["cache_control"])
            var plain = fields; plain.removeValue(forKey: "cache_control")
            return try ModelBlock(wire: .object(plain))
        case "tool_result":
            let fields = try keys(value, ["type", "tool_use_id", "content", "is_error", "cache_control"])
            try cache(fields["cache_control"])
            guard let id = fields["tool_use_id"]?.string, ModelBlock.validID(id), let content = fields["content"] else { throw invalid }
            let error: Bool
            if let value = fields["is_error"] { guard case .bool(let b) = value else { throw invalid }; error = b } else { error = false }
            if content.string == nil {
                guard let blocks = content.array, blocks.count <= 128 else { throw invalid }
                for block in blocks { _ = try textBlock(block) }
            }
            // Pairing uses only the ID/role/order. Never send this projection.
            return .toolResult(toolUseID: id, content: "", isError: error)
        default: throw invalid
        }
    }
}
