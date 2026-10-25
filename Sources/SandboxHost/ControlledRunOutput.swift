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
    private let native: NativeResponseChannel?
    package struct NativeProgress: Sendable {
        package let committedBytes: Int
        package let writeCalls: Int
        package let pendingBytes: Int
        package let bufferedBytes: Int
        package let queuedEvents: Int
        package let acceptedEvents: Int
        package let acceptedFinals: Int
        package let wouldBlockCount: Int
        package let partialWriteCount: Int
        package let closed: Bool
    }
    package var nativeProgress: NativeProgress? {
        lock.withLock {
            native.map { NativeProgress(committedBytes: $0.committedBytes, writeCalls: $0.writeCalls, pendingBytes: $0.pendingBytes,
                bufferedBytes: $0.bufferedBytes,
                queuedEvents: $0.queuedEvents, acceptedEvents: $0.acceptedEvents, acceptedFinals: $0.acceptedFinals,
                wouldBlockCount: $0.wouldBlockCount, partialWriteCount: $0.partialWriteCount, closed: $0.isClosed) }
        }
    }
    // Actual consumer state, not just test counters. It is deliberately not a
    // transferable ModelCompletion/MCPCompletion; future tool dispatch needs F03.
    private var text = ""
    private var completion: ModelCompletion?
    private var latestMetadata: ModelMetadata?
    private var toolResults: [ModelBlock] = []
    private struct AcceptanceState {
        var text: String
        var completion: ModelCompletion?
        var metadata: ModelMetadata?
        var tools: [ModelBlock]
        var finals: Int
        var metadataCount: Int
    }
    private struct PreparedAcceptance {
        let event: Event
        let previous: AcceptanceState
        let next: AcceptanceState
    }
    private var preparedAcceptance: PreparedAcceptance?
    package init(lifecycle: RunLifecycle, scope: RunEffectScope, actionID: UUID? = nil) {
        self.lifecycle = lifecycle; self.scope = scope; self.actionID = actionID
        self.native = nil
    }
    // Internal host binding; gateway factory derives the scope and wire mode from
    // the approved request. Descriptor ownership transfers even on setup failure.
    init(lifecycle: RunLifecycle, scope: RunEffectScope, actionID: UUID? = nil,
         takingAcceptedSocket fd: Int32, streaming: Bool) throws {
        self.lifecycle = lifecycle; self.scope = scope; self.actionID = actionID
        native = try NativeResponseChannel(takingAcceptedSocket: fd, streaming: streaming)
    }
    init(lifecycle: RunLifecycle, scope: RunEffectScope, actionID: UUID,
         takingVMConnection owner: BusinessVMConnection, streaming: Bool) throws {
        self.lifecycle = lifecycle; self.scope = scope; self.actionID = actionID
        native = try NativeResponseChannel(takingVMConnection: owner, streaming: streaming)
    }
    package func enqueue(_ event: Event) throws {
        if try lock.withLock({ () throws -> Bool in
            guard !cancelled else { throw CancellationError() }
            guard let native else { return false }
            try native.enqueue(event); return true
        }) { return }
        // Bounded, outside the authority lock. Reflection is used only to measure
        // retained value size, never emitted/logged or used as protocol encoding.
        let bytes = String(reflecting: event).utf8.count
        try lock.withLock {
            guard !cancelled, queue.count < 256, bytes <= 8 * 1024 * 1024 - retainedBytes else { throw HostModelGatewayError.busy }
            retainedBytes += bytes; queue.append(event)
        }
    }
    /// Native mode: true means one bounded send committed bytes. False may mean
    /// Receiver contention or EAGAIN/EINTR, not completion; inspect nativeProgress.
    /// Every retry fences anew; no authority or delivery permit is retained.
    /// In-memory compatibility mode: true means one complete event was accepted.
    package func acceptNext() throws -> Bool { try lifecycle.acceptOutput(self) }
    // Only the concrete lifecycle calls this after the consumer gate.
    func acquireForAcceptance() -> Bool {
        if let native {
            guard lock.try() else { return false }
            guard native.acquireOwnerForAcceptance() else { lock.unlock(); return false }
            return true
        }
        lock.lock(); return true
    }
    func releaseForAcceptance() {
        let cleanup = native?.takeCleanup()
        let prepared = preparedAcceptance
        preparedAcceptance = nil
        native?.releaseOwnerForAcceptance()
        lock.unlock()
        cleanup?.dispose()
        withExtendedLifetime(prepared) {}
    }
    // Fallible validation and construction are outside the final lifecycle fence.
    func prepareAcceptanceLocked() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard native == nil, let event = queue.first else { return }
        if case .mcpCompletion(let value) = event, let id = value.sourceToolUseID {
            guard ModelBlock.validID(id) else { throw HostMCPGatewayError.denied }
        }
        let previous = AcceptanceState(text: text, completion: completion, metadata: latestMetadata,
            tools: toolResults, finals: finals, metadataCount: metadata)
        var next = previous
        switch event {
        case .modelChunk(let chunk):
            next.text += chunk.text
            if chunk.isFinal { next.finals += 1 }
            if case .messageStart(let value) = chunk.event { next.metadata = value }
            if case .messageDelta(let value) = chunk.event { next.metadata = value; next.metadataCount += 1 }
            if let value = chunk.completion { next.completion = value }
        case .modelCompletion(let value): next.completion = value; next.text = value.text; next.finals += 1
        case .mcpCompletion(let value):
            next.text = value.text; next.finals += 1
            if let id = value.sourceToolUseID { next.tools.append(.toolResult(toolUseID: id, content: value.text, isError: false)) }
        }
        preparedAcceptance = PreparedAcceptance(event: event, previous: previous, next: next)
    }
    func acceptLocked() throws -> Bool {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            // Concrete nonblocking socket effect under the unchanged lifecycle
            // fence and this receiver's cancellation mutex. No callback or Task.
            if let native { return try native.acceptOne() }
            guard let preparedAcceptance else { return false }
            let next = preparedAcceptance.next
            text = next.text; completion = next.completion; latestMetadata = next.metadata
            toolResults = next.tools; finals = next.finals; metadata = next.metadataCount
            queue.removeFirst()
            accepted += 1
            return true
    }
    package func cancel() {
        lock.lock()
        cancelled = true
        let discarded = queue
        queue.removeAll()
        native?.detachTerminal()
        let cleanup = native?.takeCleanup()
        lock.unlock()
        cleanup?.dispose()
        withExtendedLifetime(discarded) {}
    }
    package var summary: Summary {
        lock.withLock { Summary(queuedEvents: queue.count, acceptedEvents: accepted, acceptedTextBytes: text.utf8.count,
                               acceptedFinals: finals, acceptedMetadata: metadata, acceptedToolResults: toolResults.count) }
    }
    func matches(_ lifecycle: RunLifecycle, _ scope: RunEffectScope, actionID: UUID) -> Bool {
        self.actionID == actionID && self.lifecycle === lifecycle && self.scope.generation == scope.generation &&
        self.scope.connectionID == scope.connectionID && self.scope.connectionRevision == scope.connectionRevision
    }
}
