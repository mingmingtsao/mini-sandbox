import Foundation

/// The concrete consumer of a VM's bounded stdout/stderr. Preparation may copy
/// bytes before the lifecycle fence; final acceptance only adopts prepared state.
/// UI reads immutable history already accepted by this owner, never a send permit.
package final class BusinessDisplayOutput: @unchecked Sendable {
    package struct Snapshot: Sendable {
        package let stdout: String
        package let stderr: String
        package let acceptedBytes: Int
        package let acceptedEvents: Int
        package let queuedEvents: Int
    }
    package static let maxBytes = 131_072
    package static let maxChunkBytes = 4_096
    let lifecycle: RunLifecycle
    let scope: RunEffectScope
    package let runtimeID: UUID
    private let lock = NSLock()
    private struct Event {
        let stderr: Bool
        let bytes: Data
    }
    private struct State {
        var stdout = Data(), stderr = Data()
        var bytes = 0, events = 0
    }
    private struct Prepared {
        let event: Event
        let previous: State
        let next: State
    }
    private var state = State()
    private var queue: [Event] = []
    private var totalBytes = 0
    private var prepared: Prepared?
    private var cancelled = false

    package init(lifecycle: RunLifecycle, scope: RunEffectScope, runtimeID: UUID) {
        self.lifecycle = lifecycle
        self.scope = scope
        self.runtimeID = runtimeID
    }
    package func enqueue(channel: String, bytes: Data, runtimeID: UUID) throws {
        guard runtimeID == self.runtimeID, ["stdout", "stderr"].contains(channel),
            !bytes.isEmpty, bytes.count <= Self.maxChunkBytes
        else { throw NativeResponseError.invalidEvent }
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard queue.count < 64, bytes.count <= Self.maxBytes - totalBytes else {
                throw NativeResponseError.limitExceeded
            }
            queue.append(Event(stderr: channel == "stderr", bytes: bytes))
            totalBytes += bytes.count
        }
    }
    package func acceptNext() throws -> Bool { try lifecycle.acceptBusinessDisplay(self) }
    func acquireForAcceptance() -> Bool {
        lock.lock()
        return true
    }
    func prepareAcceptanceLocked() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard let event = queue.first else { return }
        var next = state
        if event.stderr { next.stderr.append(event.bytes) } else { next.stdout.append(event.bytes) }
        next.bytes += event.bytes.count
        next.events += 1
        prepared = Prepared(event: event, previous: state, next: next)
    }
    func acceptLocked() throws -> Bool {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        guard let prepared else { return false }
        state = prepared.next
        // Keep the old data alive through release, outside the final lifecycle lock.
        queue.removeFirst()
        return true
    }
    func releaseForAcceptance() {
        let retained = prepared
        prepared = nil
        lock.unlock()
        withExtendedLifetime(retained) {}
    }
    package func cancel() {
        lock.lock()
        cancelled = true
        let discarded = queue
        queue.removeAll()
        lock.unlock()
        withExtendedLifetime(discarded) {}
    }
    package var snapshot: Snapshot {
        let (saved, count) = lock.withLock { (state, queue.count) }
        return Snapshot(
            stdout: Self.display(saved.stdout), stderr: Self.display(saved.stderr),
            acceptedBytes: saved.bytes, acceptedEvents: saved.events, queuedEvents: count)
    }
    private static func display(_ bytes: Data) -> String {
        var text = ""
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\r", scalar != "\t" {
                text += String(format: "\\u{%02x}", scalar.value)
            } else {
                text.unicodeScalars.append(scalar)
            }
        }
        return text
    }
}
