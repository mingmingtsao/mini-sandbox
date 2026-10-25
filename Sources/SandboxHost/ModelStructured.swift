import Foundation

package enum ModelBlock: Equatable, Sendable, Codable {
    case text(String)
    case toolUse(id: String, name: String, input: ModelJSON)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    package var text: String { if case .text(let t) = self { t } else { "" } }
    package var wire: ModelJSON {
        switch self {
        case .text(let t): return .object(["type": .string("text"), "text": .string(t)])
        case .toolUse(let id, let name, let input): return .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])
        case .toolResult(let id, let content, let isError): return .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(content), "is_error": .bool(isError)])
        }
    }
    package init(wire: ModelJSON) throws {
        guard let o = wire.object else { throw ModelTransportError.invalidResponse }
        switch o["type"]?.string {
        case "text":
            guard let t = o["text"]?.string, Set(o.keys).isSubset(of: ["type", "text"]) else { throw ModelTransportError.invalidResponse }
            self = .text(t)
        case "tool_use":
            guard let id = o["id"]?.string, let name = o["name"]?.string, let input = o["input"], input.object != nil,
                  Set(o.keys).isSubset(of: ["type", "id", "name", "input"]), Self.validID(id), Self.validName(name) else { throw ModelTransportError.invalidResponse }
            _ = try input.validated(); self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            guard let id = o["tool_use_id"]?.string, let content = o["content"]?.string,
                  Set(o.keys).isSubset(of: ["type", "tool_use_id", "content", "is_error"]), Self.validID(id) else { throw ModelTransportError.invalidResponse }
            let isError: Bool
            if let e = o["is_error"] { guard case .bool(let b) = e else { throw ModelTransportError.invalidResponse }; isError = b } else { isError = false }
            self = .toolResult(toolUseID: id, content: content, isError: isError)
        default: throw ModelTransportError.invalidResponse
        }
    }
    package static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }
    package static func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { $0 >= 33 && $0 <= 126 } }
    package init(from decoder: any Decoder) throws { try self.init(wire: ModelJSON(from: decoder)) }
    package func encode(to encoder: any Encoder) throws { try wire.encode(to: encoder) }
}

package struct ModelUsage: Equatable, Sendable {
    package enum ServiceTier: String, Equatable, Sendable { case standard, priority, batch }
    package let serviceTier: ServiceTier?
    package let values: [String: Int64]
    package var inputTokens: Int64? { values["input_tokens"] }
    package var outputTokens: Int64? { values["output_tokens"] }
    package init(wire: ModelJSON) throws {
        guard let o = wire.object else { throw ModelTransportError.invalidResponse }
        if let tier = o["service_tier"], tier != .null {
            guard let raw = tier.string, let value = ServiceTier(rawValue: raw) else { throw ModelTransportError.invalidResponse }
            serviceTier = value
        } else { serviceTier = nil }
        var values: [String: Int64] = [:]
        for (k, v) in o where k != "service_tier" {
            guard let n = v.integer, n >= 0 else { throw ModelTransportError.invalidResponse }; values[k] = n
        }
        self.values = values
    }
}

package struct ModelMetadata: Equatable, Sendable {
    package let messageID: String?
    package let model: String?
    package let usage: ModelUsage?
    package let stopReason: String?
    package let stopSequence: String?
    package init(messageID: String? = nil, model: String? = nil, usage: ModelUsage? = nil, stopReason: String? = nil, stopSequence: String? = nil) {
        self.messageID = messageID; self.model = model; self.usage = usage; self.stopReason = stopReason; self.stopSequence = stopSequence
    }
}

package struct ModelCompletion: Equatable, Sendable {
    package let blocks: [ModelBlock]
    package let metadata: ModelMetadata
    package var text: String { blocks.map(\.text).joined() }
    package init(text: String) { blocks = [.text(text)]; metadata = ModelMetadata() }
    package init(blocks: [ModelBlock], metadata: ModelMetadata) { self.blocks = blocks; self.metadata = metadata }
}

package enum ModelStreamEvent: Equatable, Sendable {
    case messageStart(ModelMetadata)
    case blockStart(index: Int, block: ModelBlock)
    case textDelta(index: Int, text: String)
    case inputJSONDelta(index: Int, partialJSON: String)
    case blockStop(index: Int, block: ModelBlock)
    case messageDelta(ModelMetadata)
    case messageStop(ModelCompletion)
}

package struct ModelStreamChunk: Equatable, Sendable {
    package let text: String
    package let isFinal: Bool
    package let event: ModelStreamEvent?
    package let completion: ModelCompletion?
    private var completionAuditRequired = false
    /// All message_delta metadata is terminal, not only an explicit stop_reason.
    package var isTerminal: Bool {
        if isFinal || completionAuditRequired { return true }
        if case .messageDelta = event { return true }
        return false
    }
    package init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal; event = nil; completion = nil }
    init(finalCompletion: ModelCompletion) {
        text = ""; isFinal = true; event = nil; completion = finalCompletion
    }
    /// Preserve event identity/order while routing delayed prefix output through
    /// the existing gateway completion barrier, rather than a new callback path.
    func gatedByCompletionAudit() -> Self {
        var copy = self; copy.completionAuditRequired = true; return copy
    }
    package init(text: String = "", event: ModelStreamEvent, completion: ModelCompletion? = nil) {
        self.text = text; self.event = event; self.completion = completion
        if case .messageStop = event { isFinal = true } else { isFinal = false }
    }
}

package enum AnthropicResponse {
    package static func decode(_ data: Data) throws -> ModelCompletion {
        let root = try ModelJSON.parse(data, maxBytes: ModelTransport.maxResponseBytes)
        guard root["error"] == nil, let content = root["content"]?.array, content.count <= 128 else { throw ModelTransportError.invalidResponse }
        if let role = root["role"] { guard role.string == "assistant" else { throw ModelTransportError.invalidResponse } }
        let blocks = try content.map { try ModelBlock(wire: $0) }
        var ids = Set<String>(); var hasTool = false
        for block in blocks {
            switch block {
            case .toolUse(let id, _, _): hasTool = true; guard ids.insert(id).inserted else { throw ModelTransportError.invalidResponse }
            case .toolResult: throw ModelTransportError.invalidResponse
            case .text: break
            }
        }
        let metadata = try metadata(root)
        if metadata.stopReason == "tool_use" && !hasTool { throw ModelTransportError.invalidResponse }
        if hasTool { guard validMessageMetadata(root, metadata), metadata.stopReason == "tool_use" else { throw ModelTransportError.invalidResponse } }
        return ModelCompletion(blocks: blocks, metadata: metadata)
    }
    /// Full tool replies and SSE starts share identity/usage requirements. The
    /// legacy text-only completion path may still omit this metadata entirely.
    package static func validMessageMetadata(_ root: ModelJSON, _ metadata: ModelMetadata) -> Bool {
        guard root["type"]?.string == "message", root["role"]?.string == "assistant",
              let id = metadata.messageID, ModelBlock.validID(id),
              let model = metadata.model, !model.isEmpty, model.utf8.count <= 256,
              !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let input = metadata.usage?.inputTokens, input >= 0,
              let output = metadata.usage?.outputTokens, output >= 0 else { return false }
        return true
    }
    package static func metadata(_ root: ModelJSON) throws -> ModelMetadata {
        func optionalString(_ key: String) throws -> String? {
            guard let value = root[key], value != .null else { return nil }
            guard let s = value.string, s.utf8.count <= 256 else { throw ModelTransportError.invalidResponse }; return s
        }
        let reason = try optionalString("stop_reason")
        if reason == "aborted" || reason == "insufficient_system_resource" { throw ModelTransportError.providerFailure }
        return try ModelMetadata(messageID: optionalString("id"), model: optionalString("model"),
            usage: root["usage"].map { try ModelUsage(wire: $0) }, stopReason: reason, stopSequence: optionalString("stop_sequence"))
    }
}
