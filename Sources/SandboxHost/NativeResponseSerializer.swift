import Foundation

/// Anthropic native response framing over one close-delimited HTTP exchange.
/// Uses the existing typed model response, never reflection or a raw callback.
struct NativeResponseSerializer {
    let streaming: Bool
    let mcp: Bool
    private var ended = false
    private var started = false
    private var active: ModelBlock?
    private var partialJSON = ""
    private var blocks: [ModelBlock] = []
    private var metadata: ModelMetadata?
    private var deltaCount = 0
    init(streaming: Bool, mcp: Bool = false) { self.streaming = streaming; self.mcp = mcp }

    mutating func encode(_ event: ControlledRunOutput.Event, maxBytes: Int = NativeResponseChannel.maxFrameBytes) throws -> NativeResponseChannel.Frame {
        if mcp {
            guard !ended, !streaming, case .mcpResponse(let response) = event else { throw NativeResponseError.invalidEvent }
            let bytes: Data
            if let payload = response.payload {
                let body = try Self.json(payload, maxBytes: min(65_536, maxBytes))
                let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                guard body.count <= maxBytes - header.count else { throw NativeResponseError.limitExceeded }
                bytes = header + body
            } else {
                bytes = Data("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                guard bytes.count <= maxBytes else { throw NativeResponseError.limitExceeded }
            }
            ended = true
            return .init(bytes: bytes, final: true)
        }
        if streaming { return try encodeStream(event, maxBytes: maxBytes) }
        guard !streaming, !ended, case .modelCompletion(let completion) = event else { throw NativeResponseError.invalidEvent }
        let root = try Self.message(completion.metadata, blocks: completion.blocks)
        guard let reason = completion.metadata.stopReason, !reason.isEmpty else { throw NativeResponseError.invalidEvent }
        let size = try Self.jsonSize(root, maxBytes: maxBytes)
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n".utf8)
        guard header.count <= maxBytes, size <= maxBytes - header.count else { throw NativeResponseError.limitExceeded }
        let bytes = try Self.renderJSON(root, size: size)
        // Reuse the actual native response contract, including tool ID/reason rules.
        _ = try AnthropicResponse.decode(bytes)

        ended = true
        return .init(bytes: header + bytes, final: true)
    }
    private mutating func encodeStream(_ event: ControlledRunOutput.Event, maxBytes: Int) throws -> NativeResponseChannel.Frame {
        guard !ended, case .modelChunk(let chunk) = event, let event = chunk.event else { throw NativeResponseError.invalidEvent }
        let first = !started
        let type: String
        var fields: [String: ModelJSON] = [:]
        switch event {
        case .messageStart(let value):
            guard !started, value.stopReason == nil, value.stopSequence == nil else { throw NativeResponseError.invalidEvent }
            type = "message_start"; fields["message"] = try Self.message(value, blocks: [])
            metadata = value; started = true
        case .blockStart(let index, let block):
            guard started, deltaCount == 0, active == nil, index == blocks.count, index < 128 else { throw NativeResponseError.invalidEvent }
            _ = try ModelBlock(wire: block.wire)
            switch block {
            case .toolResult: throw NativeResponseError.invalidEvent
            case .toolUse(let id, _, let input):
                guard input == .object([:]), !blocks.contains(where: { if case .toolUse(let prior, _, _) = $0 { return prior == id }; return false }) else { throw NativeResponseError.invalidEvent }
            case .text(let text): guard text.utf8.count <= ModelJSON.maxBytes else { throw NativeResponseError.limitExceeded }
            }
            active = block; partialJSON = ""
            type = "content_block_start"; fields["index"] = .integer(Int64(index)); fields["content_block"] = block.wire
        case .textDelta(let index, let text):
            guard deltaCount == 0, index == blocks.count, case .text(let prior) = active,
                  text.utf8.count <= ModelJSON.maxBytes - prior.utf8.count else { throw NativeResponseError.invalidEvent }
            active = .text(prior + text)
            type = "content_block_delta"; fields["index"] = .integer(Int64(index))
            fields["delta"] = .object(["type": .string("text_delta"), "text": .string(text)])
        case .inputJSONDelta(let index, let text):
            guard deltaCount == 0, index == blocks.count, case .toolUse = active,
                  text.utf8.count <= ModelJSON.maxBytes - partialJSON.utf8.count else { throw NativeResponseError.invalidEvent }
            partialJSON += text
            type = "content_block_delta"; fields["index"] = .integer(Int64(index))
            fields["delta"] = .object(["type": .string("input_json_delta"), "partial_json": .string(text)])
        case .blockStop(let index, let block):
            guard index == blocks.count, var expected = active else { throw NativeResponseError.invalidEvent }
            if case .toolUse(let id, let name, _) = expected {
                let input = partialJSON.isEmpty ? ModelJSON.object([:]) : try ModelJSON.parse(Data(partialJSON.utf8))
                guard input.object != nil else { throw NativeResponseError.invalidEvent }
                expected = .toolUse(id: id, name: name, input: input)
            }
            guard expected == block else { throw NativeResponseError.invalidEvent }
            blocks.append(block); active = nil; partialJSON = ""
            type = "content_block_stop"; fields["index"] = .integer(Int64(index))
        case .messageDelta(let value):
            guard started, active == nil, deltaCount < 128, let prior = metadata,
                  value.messageID == prior.messageID, value.model == prior.model,
                  prior.stopReason == nil || prior.stopReason == value.stopReason,
                  prior.stopSequence == nil || prior.stopSequence == value.stopSequence else { throw NativeResponseError.invalidEvent }
            for (key, count) in prior.usage?.values ?? [:] {
                guard (value.usage?.values[key] ?? -1) >= count else { throw NativeResponseError.invalidEvent }
            }
            metadata = value; deltaCount += 1
            type = "message_delta"
            fields["delta"] = .object(["stop_reason": value.stopReason.map(ModelJSON.string) ?? .null, "stop_sequence": value.stopSequence.map(ModelJSON.string) ?? .null])
            fields["usage"] = Self.usage(value)
        case .messageStop(let completion):
            guard started, active == nil, deltaCount > 0, completion.blocks == blocks,
                  completion.metadata == metadata, let reason = metadata?.stopReason, !reason.isEmpty else { throw NativeResponseError.invalidEvent }
            let hasTools = blocks.contains { if case .toolUse = $0 { return true }; return false }
            guard hasTools == (reason == "tool_use") else { throw NativeResponseError.invalidEvent }
            type = "message_stop"; ended = true
        }
        fields["type"] = .string(type)
        var bytes = first ? Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8) : Data()
        bytes.append(Data("event: \(type)\ndata: ".utf8))
        guard bytes.count + 2 <= maxBytes else { throw NativeResponseError.limitExceeded }
        let data = try Self.json(.object(fields), maxBytes: maxBytes - bytes.count - 2)
        bytes.append(data); bytes.append(Data("\n\n".utf8))
        return .init(bytes: bytes, final: ended)
    }
    static func usage(_ metadata: ModelMetadata) -> ModelJSON {
        var result = (metadata.usage?.values ?? [:]).mapValues { ModelJSON.integer($0) }
        if let tier = metadata.usage?.serviceTier { result["service_tier"] = .string(tier.rawValue) }
        return .object(result)
    }
    static func message(_ metadata: ModelMetadata, blocks: [ModelBlock]) throws -> ModelJSON {
        guard blocks.count <= 128 else { throw NativeResponseError.limitExceeded }
        let root = ModelJSON.object([
            "id": metadata.messageID.map(ModelJSON.string) ?? .null,
            "type": .string("message"), "role": .string("assistant"),
            "model": metadata.model.map(ModelJSON.string) ?? .null,
            "content": .array(blocks.map(\.wire)),
            "stop_reason": metadata.stopReason.map(ModelJSON.string) ?? .null,
            "stop_sequence": metadata.stopSequence.map(ModelJSON.string) ?? .null,
            "usage": usage(metadata)
        ])
        guard AnthropicResponse.validMessageMetadata(root, metadata) else { throw NativeResponseError.invalidEvent }
        return root
    }
    /// Count the exact same JSON grammar used for emission, without allocating
    /// escaped output. Every charge is subtraction-bounded; keys, punctuation,
    /// safe integers and UTF-8 are included, not a worst-case escape multiplier.
    private static func jsonSize(_ value: ModelJSON, maxBytes: Int) throws -> Int {
        var remaining = maxBytes
        guard remaining >= 0 else { throw NativeResponseError.limitExceeded }
        try walkJSON(value) { byte in
            guard remaining > 0 else { throw NativeResponseError.limitExceeded }
            remaining -= 1
        }
        return maxBytes - remaining
    }
    private static func renderJSON(_ value: ModelJSON, size: Int) throws -> Data {
        var bytes = Data(); bytes.reserveCapacity(size)
        try walkJSON(value) { byte in
            // Keep the allocation bounded even if the sizing implementation changes.
            guard bytes.count < size else { throw NativeResponseError.limitExceeded }
            bytes.append(byte)
        }
        guard bytes.count == size else { throw NativeResponseError.invalidEvent }
        return bytes
    }
    static func json(_ value: ModelJSON, maxBytes: Int = NativeResponseChannel.maxFrameBytes) throws -> Data {
        try renderJSON(value, size: jsonSize(value, maxBytes: maxBytes))
    }
    private static func walkJSON(_ value: ModelJSON, emit: (UInt8) throws -> Void) throws {
        var nodes = 0
        func literal(_ value: String) throws { for byte in value.utf8 { try emit(byte) } }
        func string(_ value: String) throws {
            try emit(34)
            for byte in value.utf8 {
                switch byte {
                case 34: try literal("\\\"")
                case 92: try literal("\\\\")
                case 8: try literal("\\b")
                case 9: try literal("\\t")
                case 10: try literal("\\n")
                case 12: try literal("\\f")
                case 13: try literal("\\r")
                case 0...31:
                    try literal("\\u00")
                    let digits = Array("0123456789abcdef".utf8)
                    try emit(digits[Int(byte >> 4)]); try emit(digits[Int(byte & 15)])
                default: try emit(byte) // slash and well-formed multibyte UTF-8 unchanged
                }
            }
            try emit(34)
        }
        func visit(_ value: ModelJSON, depth: Int) throws {
            nodes += 1
            guard depth <= ModelJSON.maxDepth, nodes <= ModelJSON.maxNodes else { throw NativeResponseError.limitExceeded }
            switch value {
            case .object(let fields):
                // Bound sorting storage before constructing the key list.
                guard fields.count <= ModelJSON.maxNodes - nodes else { throw NativeResponseError.limitExceeded }
                try emit(123)
                for (index, key) in fields.keys.sorted().enumerated() {
                    if index > 0 { try emit(44) }
                    try string(key); try emit(58); try visit(fields[key]!, depth: depth + 1)
                }
                try emit(125)
            case .array(let children):
                guard children.count <= ModelJSON.maxNodes - nodes else { throw NativeResponseError.limitExceeded }
                try emit(91)
                for (index, child) in children.enumerated() {
                    if index > 0 { try emit(44) }
                    try visit(child, depth: depth + 1)
                }
                try emit(93)
            case .string(let text): try string(text)
            case .integer(let number):
                guard (-ModelJSON.maxInteger...ModelJSON.maxInteger).contains(number) else { throw ModelTransportError.invalidResponse }
                try literal(String(number))
            case .bool(let value): try literal(value ? "true" : "false")
            case .null: try literal("null")
            }
        }
        try visit(value, depth: 0)
    }
}
