import Foundation
@testable import SandboxHost

func nativeFencedObservation(cancelTask: Bool) async throws {
    let clock = StartClock(), pair = try NativeSocketPair()
    let authority = RunLifecycle(expiresAt: clock.date.addingTimeInterval(600), epoch: 1, installedAt: clock.date, clock: clock.source)
    let output = try nativeOutput(pair, authority)
    try output.enqueue(.modelCompletion(nativeCompletion()))
    let task = Task.detached { clock.gate.block(); return try output.acceptNext() }
    let entered = clock.gate.awaitEntry()
    if cancelTask { task.cancel() } else { authority.terminate(.stopped) }
    clock.gate.open()
    do { _ = try await task.value; throw Failure(message: "observation bypassed actual native fence") }
    catch is AuthorizationError {} catch is CancellationError {}
    try check(entered, "native observation barrier timed out")
    try check(try pair.readAvailable().isEmpty && output.nativeProgress!.committedBytes == 0, "native observation race wrote bytes")
    output.cancel()
    print("PASS native-response-observation-race-\(cancelTask ? "task-cancel" : "stop") actual_bytes=0")
}

func nativeStreamStopAfterText() throws {
    let clock = Clock(), authority = lifecycle(clock), pair = try NativeSocketPair()
    let output = try nativeOutput(pair, authority, streaming: true)
    for (event, _) in try nativeStreamFixture() { try output.enqueue(.modelChunk(event)) }
    for _ in 0..<3 { try check(try output.acceptNext(), "native first text acceptance") }
    let before = output.nativeProgress!
    authority.terminate(.stopped)
    do { _ = try output.acceptNext(); throw Failure(message: "native stream after stop") } catch is AuthorizationError {}
    let bytes = try pair.readAvailable(), text = String(decoding: bytes, as: UTF8.self)
    try check(bytes.count == before.committedBytes && text.contains("hi π") && !text.contains("event: message_delta") && !text.contains("event: message_stop"), "native terminal tail after Stop")
    try check(output.nativeProgress!.acceptedFinals == 0 && output.nativeProgress!.committedBytes == before.committedBytes, "native terminal accounting")
    output.cancel()
    print("PASS native-response-text-before-stop-no-terminal-tail")
}

func nativeMalformedIsTransactional() throws {
    let pair = try NativeSocketPair(), clock = Clock(), output = try nativeOutput(pair, lifecycle(clock), streaming: true)
    let fixture = try nativeStreamFixture()
    try output.enqueue(.modelChunk(fixture[0].0))
    let before = output.nativeProgress!
    for _ in 0..<2 {
        do { try output.enqueue(.modelChunk(ModelStreamChunk(event: .blockStart(index: 7, block: .text("bad"))))); throw Failure(message: "wrong native block index") }
        catch NativeResponseError.invalidEvent {}
        try check(output.nativeProgress!.pendingBytes == before.pendingBytes && output.nativeProgress!.queuedEvents == before.queuedEvents, "malformed event changed native queue")
    }
    for (event, _) in fixture.dropFirst() { try output.enqueue(.modelChunk(event)) }
    for _ in 0..<64 { _ = try output.acceptNext(); _ = try pair.readAvailable(); if output.nativeProgress!.closed { break } }
    try check(output.nativeProgress!.acceptedFinals == 1, "rejected event damaged native serializer state")
    print("PASS native-response-malformed-event-transactional-retry")
}

func nativeTotalResponseBudget() throws {
    let pair = try NativeSocketPair(), clock = Clock(), output = try nativeOutput(pair, lifecycle(clock), streaming: true)
    var received = 0
    func drain() throws {
        for _ in 0..<128 {
            _ = try output.acceptNext(); received += try pair.readAvailable().count
            if output.nativeProgress!.queuedEvents == 0 { return }
        }
        throw Failure(message: "bounded drain did not finish")
    }
    try output.enqueue(.modelChunk(ModelStreamChunk(event: .messageStart(try nativeMetadata(stop: nil)))))
    try drain()
    let text = String(repeating: "\n", count: 60_000)
    var rejected = false
    for index in 0..<128 {
        let before = output.nativeProgress!
        do { try output.enqueue(.modelChunk(ModelStreamChunk(event: .blockStart(index: index, block: .text(text))))) }
        catch NativeResponseError.limitExceeded {
            try check(output.nativeProgress!.pendingBytes == before.pendingBytes && output.nativeProgress!.committedBytes == before.committedBytes, "response cap changed committed state")
            rejected = true; break
        }
        try drain()
        try output.enqueue(.modelChunk(ModelStreamChunk(event: .blockStop(index: index, block: .text(text)))))
        try drain()
    }
    try check(rejected && received <= NativeResponseChannel.maxResponseBytes && received > NativeResponseChannel.maxResponseBytes - 130_000, "total response budget not exercised")
    try check(output.nativeProgress!.committedBytes == received && output.nativeProgress!.acceptedFinals == 0, "total response truthful bytes")
    output.cancel()
    print("PASS native-response-total-byte-budget actual_bytes=\(received) limit=\(NativeResponseChannel.maxResponseBytes)")
}
