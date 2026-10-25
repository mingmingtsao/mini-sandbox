import Foundation

/// Exact active-request credential matching, not general encoded-secret DLP.
/// Owned only by the prepared operation; never stored in a connection or DTO.
final class ModelCredentialReflection: @unchecked Sendable {
    private let lock = NSLock()
    private var credential: String?
    private var tail = ""
    private var pending: [ModelStreamChunk] = []
    private var pendingBytes = 0
    private var toolIndex: Int?
    private var unstructuredText = ""
    private var pattern: [Unicode.Scalar]
    private var fallback: [Int]
    private var matched = 0

    init(_ credential: String) {
        self.credential = credential
        pattern = Array(credential.unicodeScalars)
        fallback = Array(repeating: 0, count: pattern.count)
        if pattern.count > 1 {
            var length = 0
            for index in 1..<pattern.count {
                while length > 0 && pattern[index] != pattern[length] { length = fallback[length - 1] }
                if pattern[index] == pattern[length] { length += 1 }
                fallback[index] = length
            }
        }
    }

    func clear() {
        lock.withLock {
            credential = nil
            tail = ""
            pending.removeAll()
            pendingBytes = 0
            toolIndex = nil
            unstructuredText = ""
            pattern.removeAll()
            fallback.removeAll()
            matched = 0
        }
    }

    func validate(_ completion: ModelCompletion) throws {
        try lock.withLock {
            guard let credential else { throw ModelTransportError.cancelled }
            try validateCompletion(completion, credential)
        }
    }

    func consume(_ chunk: ModelStreamChunk) throws -> [ModelStreamChunk] {
        try lock.withLock {
            guard let credential else { throw ModelTransportError.cancelled }
            // Validate every exposed field, including duplicate assembled block data.
            if let completion = chunk.completion { try validateCompletion(completion, credential) }
            if let event = chunk.event {
                switch event {
                case .messageStart(let metadata), .messageDelta(let metadata):
                    try validateMetadata(metadata, credential)
                case .messageStop(let completion): try validateCompletion(completion, credential)
                case .blockStart(let index, let block):
                    try validateBlock(block, credential)
                    if case .toolUse = block { toolIndex = index }
                case .blockStop(let index, let block):
                    // The decoder has now parsed the COMPLETE argument JSON. Do not
                    // release equivalent raw fragments before this validation.
                    try validateBlock(block, credential)
                    if toolIndex == index {
                        // These exact strings, not a re-encoding of the parsed
                        // object, will be released below. Match their bounded
                        // concatenation too: an escape spelling or a literal
                        // spanning JSON syntax need not occur in decoded values.
                        let raw = pending.compactMap { item -> String? in
                            if case .inputJSONDelta(let i, let part) = item.event, i == index { return part }
                            return nil
                        }.joined()
                        try reject(raw, credential)
                        toolIndex = nil
                    }
                case .textDelta(_, let text): try reject(text, credential)
                case .inputJSONDelta: break  // withheld until decoded blockStop
                }
            }
            if !chunk.text.isEmpty {
                // Linear prefix matching avoids quadratic work for a long key
                // with repeated prefixes. State is at most key length minus one.
                for scalar in chunk.text.unicodeScalars {
                    while matched > 0 && scalar != pattern[matched] { matched = fallback[matched - 1] }
                    if scalar == pattern[matched] { matched += 1 }
                    if matched == pattern.count { throw ModelTransportError.invalidResponse }
                }
                tail = String(String.UnicodeScalarView(pattern.prefix(matched)))
            }
            // OpenAI has no assembled completion in its codec. Preserve its
            // bounded transcript so audit-held trailing text is not omitted by
            // the gateway's legacy nonterminal-text fallback. Delivery is still
            // incremental; this is not an EOF-only output buffer.
            if chunk.event == nil {
                guard chunk.text.utf8.count <= ModelTransport.maxResponseBytes - unstructuredText.utf8.count else {
                    throw ModelTransportError.responseTooLarge
                }
                unstructuredText += chunk.text
            }
            pending.append(
                chunk.isFinal && chunk.event == nil
                    ? ModelStreamChunk(finalCompletion: ModelCompletion(text: unstructuredText)) : chunk)
            // Event queue is bounded independently of total response bytes; one
            // tool block is additionally bounded by ModelJSON.maxBytes in codec.
            pendingBytes += chunk.text.utf8.count
            if case .inputJSONDelta(_, let part) = chunk.event { pendingBytes += part.utf8.count }
            guard pending.count <= ModelTransport.maxResponseBytes,
                pendingBytes <= ModelTransport.maxResponseBytes
            else { throw ModelTransportError.responseTooLarge }
            if chunk.isFinal {
                guard toolIndex == nil else { throw ModelTransportError.invalidResponse }
                let result = pending.map { tail.isEmpty ? $0 : $0.gatedByCompletionAudit() }
                pending.removeAll()
                pendingBytes = 0
                tail = ""
                matched = 0
                return result
            }
            guard toolIndex == nil else { return [] }
            // Release ordinary text immediately even when the same SSE event
            // ends in a possible key prefix. Split only text events; never drop
            // a block, reorder metadata, or expose provisional tool arguments.
            var safeCount = pending.reduce(0) { $0 + $1.text.unicodeScalars.count } - tail.unicodeScalars.count
            var result: [ModelStreamChunk] = []
            var consumed = 0
            while consumed < pending.count {
                let first = pending[consumed]
                let count = first.text.unicodeScalars.count
                if count <= safeCount {
                    result.append(first)
                    consumed += 1
                    safeCount -= count
                } else {
                    if safeCount > 0 {
                        let parts = splitText(first, count: safeCount)
                        result.append(parts.0)
                        pending[consumed] = parts.1
                    }
                    break
                }
            }
            pending.removeFirst(consumed)
            pendingBytes = pending.reduce(0) { sum, item in
                if case .inputJSONDelta(_, let part) = item.event { return sum + part.utf8.count }
                return sum + item.text.utf8.count
            }
            return result
        }
    }

    private func splitText(_ chunk: ModelStreamChunk, count: Int) -> (ModelStreamChunk, ModelStreamChunk) {
        let scalars = chunk.text.unicodeScalars
        let prefix = String(String.UnicodeScalarView(scalars.prefix(count)))
        let suffix = String(String.UnicodeScalarView(scalars.dropFirst(count)))
        switch chunk.event {
        case .blockStart(let index, .text):
            return (
                ModelStreamChunk(text: prefix, event: .blockStart(index: index, block: .text(prefix))),
                ModelStreamChunk(text: suffix, event: .textDelta(index: index, text: suffix))
            )
        case .textDelta(let index, _):
            return (
                ModelStreamChunk(text: prefix, event: .textDelta(index: index, text: prefix)),
                ModelStreamChunk(text: suffix, event: .textDelta(index: index, text: suffix))
            )
        default:
            return (ModelStreamChunk(text: prefix, isFinal: false), ModelStreamChunk(text: suffix, isFinal: false))
        }
    }

    private func reject(_ value: String, _ credential: String) throws {
        if value.contains(credential) { throw ModelTransportError.invalidResponse }
    }
    private func validateJSON(_ value: ModelJSON, _ credential: String) throws {
        switch value {
        case .string(let text): try reject(text, credential)
        case .integer(let number): try reject(String(number), credential)
        case .bool(let flag): try reject(flag ? "true" : "false", credential)
        case .null: try reject("null", credential)
        case .array(let values): for value in values { try validateJSON(value, credential) }
        case .object(let fields):
            for (key, value) in fields {
                try reject(key, credential)
                try validateJSON(value, credential)
            }
        }
    }
    private func validateBlock(_ block: ModelBlock, _ credential: String) throws {
        switch block {
        case .text(let text): try reject(text, credential)
        case .toolUse(let id, let name, let input):
            try reject(id, credential)
            try reject(name, credential)
            try validateJSON(input, credential)
        case .toolResult(let id, let content, _):
            try reject(id, credential)
            try reject(content, credential)
        }
    }
    private func validateMetadata(_ metadata: ModelMetadata, _ credential: String) throws {
        for value in [
            metadata.messageID, metadata.model, metadata.stopReason, metadata.stopSequence,
            metadata.usage?.serviceTier?.rawValue,
        ].compactMap({ $0 }) { try reject(value, credential) }
        for (key, value) in metadata.usage?.values ?? [:] {
            try reject(key, credential)
            try reject(String(value), credential)
        }
    }
    private func validateCompletion(_ completion: ModelCompletion, _ credential: String) throws {
        try reject(completion.text, credential)
        try validateMetadata(completion.metadata, credential)
        for block in completion.blocks { try validateBlock(block, credential) }
    }
}
