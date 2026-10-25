import Foundation

/// One instance per prepared request. URLSession serializes its callbacks; lock
/// also makes closure ownership explicit. No state is shared between requests.
package final class AnthropicStreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var ended = false
    private var deltaPhase = false
    private var deltaCount = 0
    private var metadata = ModelMetadata()
    private var blocks: [ModelBlock] = []
    private var active: ModelBlock?
    private var partialJSON = ""
    private var sawJSONDelta = false
    private var ids = Set<String>()

    package init() {}
    package func consume(_ event: String) throws -> ModelStreamChunk? {
        try lock.withLock { try consumeLocked(event) }
    }
    private func consumeLocked(_ event: String) throws -> ModelStreamChunk? {
        let root = try ModelJSON.parse(Data(event.utf8), maxBytes: ModelTransport.maxSSELineBytes)
        guard let type = root["type"]?.string, !ended else { throw ModelTransportError.malformedSSE }
        if type == "error" || root["error"] != nil { throw ModelTransportError.providerFailure }
        if type == "ping" { return nil }
        switch type {
        case "message_start":
            guard !started, let message = root["message"],
                message["content"]?.array == []
            else { throw ModelTransportError.malformedSSE }
            let m = try AnthropicResponse.metadata(message)
            guard AnthropicResponse.validMessageMetadata(message, m),
                m.stopReason == nil, m.stopSequence == nil
            else { throw ModelTransportError.malformedSSE }
            metadata = m
            started = true
            return ModelStreamChunk(event: .messageStart(m))
        case "content_block_start":
            guard started, !deltaPhase, active == nil, blocks.count < 128,
                root["index"]?.integer == Int64(blocks.count), let wire = root["content_block"]
            else { throw ModelTransportError.malformedSSE }
            let block = try ModelBlock(wire: wire)
            switch block {
            case .toolUse(let id, _, let input):
                guard input == .object([:]), ids.insert(id).inserted else { throw ModelTransportError.malformedSSE }
            case .toolResult: throw ModelTransportError.malformedSSE
            case .text: break
            }
            active = block
            partialJSON = ""
            sawJSONDelta = false
            return ModelStreamChunk(text: block.text, event: .blockStart(index: blocks.count, block: block))
        case "content_block_delta":
            guard started, !deltaPhase, let block = active, root["index"]?.integer == Int64(blocks.count),
                let delta = root["delta"]
            else { throw ModelTransportError.malformedSSE }
            switch (block, delta["type"]?.string) {
            case (.text(let text), "text_delta"):
                guard let part = delta["text"]?.string, part.utf8.count <= ModelJSON.maxBytes - text.utf8.count else {
                    throw ModelTransportError.malformedSSE
                }
                active = .text(text + part)
                return ModelStreamChunk(text: part, event: .textDelta(index: blocks.count, text: part))
            case (.toolUse, "input_json_delta"):
                guard let part = delta["partial_json"]?.string,
                    part.utf8.count <= ModelJSON.maxBytes - partialJSON.utf8.count
                else { throw ModelTransportError.malformedSSE }
                partialJSON += part
                sawJSONDelta = true
                return ModelStreamChunk(event: .inputJSONDelta(index: blocks.count, partialJSON: part))
            default: throw ModelTransportError.malformedSSE
            }
        case "content_block_stop":
            guard started, !deltaPhase, var block = active, root["index"]?.integer == Int64(blocks.count) else {
                throw ModelTransportError.malformedSSE
            }
            if case .toolUse(let id, let name, _) = block {
                let input = sawJSONDelta ? try ModelJSON.parse(Data(partialJSON.utf8)) : .object([:])
                guard input.object != nil else { throw ModelTransportError.malformedSSE }
                block = .toolUse(id: id, name: name, input: input)
            }
            let index = blocks.count
            blocks.append(block)
            active = nil
            partialJSON = ""
            return ModelStreamChunk(event: .blockStop(index: index, block: block))
        case "message_delta":
            guard started, active == nil, deltaCount < 128, let delta = root["delta"], let d = delta.object,
                Set(d.keys).isSubset(of: ["stop_reason", "stop_sequence"])
            else { throw ModelTransportError.malformedSSE }
            let m = try AnthropicResponse.metadata(delta)
            // Missing and explicit null fields are no-update, never a reset.
            // Compatible non-null terminal metadata may repeat until message_stop.
            if let reason = m.stopReason, let prior = metadata.stopReason, reason != prior {
                throw ModelTransportError.malformedSSE
            }
            if let sequence = m.stopSequence, let prior = metadata.stopSequence, sequence != prior {
                throw ModelTransportError.malformedSSE
            }
            var usage = metadata.usage?.values ?? [:]
            var serviceTier = metadata.usage?.serviceTier
            if let wire = root["usage"] {
                let update = try ModelUsage(wire: wire)
                if let tier = update.serviceTier {
                    guard serviceTier == nil || serviceTier == tier else { throw ModelTransportError.malformedSSE }
                    serviceTier = tier
                }
                for (key, count) in update.values {
                    guard count >= (usage[key] ?? 0) else { throw ModelTransportError.malformedSSE }
                    usage[key] = count
                }
            }
            var mergedUsage = usage.mapValues { ModelJSON.integer($0) }
            if let serviceTier { mergedUsage["service_tier"] = .string(serviceTier.rawValue) }
            metadata = try ModelMetadata(
                messageID: metadata.messageID, model: metadata.model,
                usage: ModelUsage(wire: .object(mergedUsage)),
                stopReason: m.stopReason ?? metadata.stopReason, stopSequence: m.stopSequence ?? metadata.stopSequence)
            deltaPhase = true
            deltaCount += 1
            return ModelStreamChunk(event: .messageDelta(metadata))
        case "message_stop":
            guard started, deltaPhase, active == nil, let reason = metadata.stopReason, !reason.isEmpty else {
                throw ModelTransportError.malformedSSE
            }
            if !ids.isEmpty && reason != "tool_use" { throw ModelTransportError.malformedSSE }
            if reason == "tool_use" && ids.isEmpty { throw ModelTransportError.malformedSSE }
            ended = true
            let result = ModelCompletion(blocks: blocks, metadata: metadata)
            return ModelStreamChunk(event: .messageStop(result), completion: result)
        default: throw ModelTransportError.malformedSSE
        }
    }
}
