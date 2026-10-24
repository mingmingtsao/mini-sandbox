import Foundation

/// A bounded queue and its concrete consumer-owned state, not a callback or permit.
/// Queuing is not acceptance. No raw completion/tool-execution DTO escapes this API.
package final class ControlledRunOutput: @unchecked Sendable {
    package enum Event: Sendable {
        case modelChunk(ModelStreamChunk)
        case modelCompletion(ModelCompletion)
        case mcpCompletion(MCPCompletion)
    }
    package struct Summary: Sendable {
        package let queuedEvents: Int
        package let acceptedEvents: Int
        package let acceptedTextBytes: Int
        package let acceptedFinals: Int
        package let acceptedMetadata: Int
        package let acceptedToolResults: Int
    }
    let lifecycle: RunLifecycle
    let scope: RunEffectScope
    private let actionID: UUID?
    private let lock = NSLock()
    private var queue: [Event] = []
    private var retainedBytes = 0
    private var accepted = 0
    private var finals = 0
    private var metadata = 0
    private var cancelled = false
    // Actual consumer state, not just test counters. It is deliberately not a
    // transferable ModelCompletion/MCPCompletion; future tool dispatch needs F03.
    private var text = ""
    private var completion: ModelCompletion?
    private var latestMetadata: ModelMetadata?
    private var toolResults: [ModelBlock] = []
    package init(lifecycle: RunLifecycle, scope: RunEffectScope, actionID: UUID? = nil) {
        self.lifecycle = lifecycle; self.scope = scope; self.actionID = actionID
    }
    package func enqueue(_ event: Event) throws {
        // Bounded, outside the authority lock. Reflection is used only to measure
        // retained value size, never emitted/logged or used as protocol encoding.
        let bytes = String(reflecting: event).utf8.count
        try lock.withLock {
            guard !cancelled, queue.count < 256, bytes <= 8 * 1024 * 1024 - retainedBytes else { throw HostModelGatewayError.busy }
            retainedBytes += bytes; queue.append(event)
        }
    }
    package func acceptNext() throws -> Bool { try lifecycle.acceptOutput(self) }
    // Only the concrete lifecycle calls this after the consumer gate.
    func acceptOne() throws -> Bool {
        try lock.withLock {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            guard let event = queue.first else { return false }
            // Validate every fallible field before committing consumer state or
            // dequeueing. Rejection leaves the head and all accepted state intact;
            // explicit cancellation may discard the queue, but is not acceptance.
            if case .mcpCompletion(let value) = event, let id = value.sourceToolUseID {
                guard ModelBlock.validID(id) else { throw HostMCPGatewayError.denied }
            }
            switch event {
            case .modelChunk(let chunk):
                text += chunk.text
                if chunk.isFinal { finals += 1 }
                if case .messageStart(let value) = chunk.event { latestMetadata = value }
                if case .messageDelta(let value) = chunk.event { latestMetadata = value; metadata += 1 }
                if let value = chunk.completion { completion = value }
            case .modelCompletion(let value): completion = value; text = value.text; finals += 1
            case .mcpCompletion(let value):
                text = value.text; finals += 1
                if let id = value.sourceToolUseID {
                    toolResults.append(.toolResult(toolUseID: id, content: value.text, isError: false))
                }
            }
            queue.removeFirst()
            accepted += 1
            return true
        }
    }
    package func cancel() { lock.withLock { cancelled = true; queue.removeAll() } }
    package var summary: Summary {
        lock.withLock { Summary(queuedEvents: queue.count, acceptedEvents: accepted, acceptedTextBytes: text.utf8.count,
                               acceptedFinals: finals, acceptedMetadata: metadata, acceptedToolResults: toolResults.count) }
    }
    func matches(_ lifecycle: RunLifecycle, _ scope: RunEffectScope, actionID: UUID) -> Bool {
        self.actionID == actionID && self.lifecycle === lifecycle && self.scope.generation == scope.generation &&
        self.scope.connectionID == scope.connectionID && self.scope.connectionRevision == scope.connectionRevision
    }
}
