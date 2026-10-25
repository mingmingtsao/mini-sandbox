import Darwin
import Foundation
import SandboxContracts

@testable import SandboxHost

/// Own only the two descriptors allocated by this fixture.
final class NativeSocketPair {
    private var writer: Int32
    private var reader: Int32
    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw Failure(message: "socketpair") }
        writer = descriptors[0]
        reader = descriptors[1]
        _ = fcntl(reader, F_SETFL, O_NONBLOCK)
    }
    deinit {
        if writer >= 0 { Darwin.close(writer) }
        if reader >= 0 { Darwin.close(reader) }
    }
    func takeWriter() -> Int32 {
        let fd = writer
        writer = -1
        return fd
    }
    func smallSendBuffer() throws {
        var size: Int32 = 4096
        try check(
            setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0,
            "small send buffer")
    }
    func readAvailable() throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<4096 {
            let n = Darwin.read(reader, &buffer, buffer.count)
            if n > 0 {
                result.append(contentsOf: buffer.prefix(n))
                continue
            }
            if n == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return result }
            if errno == EINTR { continue }
            throw Failure(message: "socket read")
        }
        throw Failure(message: "bounded socket read exceeded")
    }
    func closePeer() {
        if reader >= 0 {
            Darwin.close(reader)
            reader = -1
        }
    }
}
func nativeMetadata(stop: String? = "end_turn") throws -> ModelMetadata {
    ModelMetadata(
        messageID: "msg_fixture", model: "fixture-model",
        usage: try ModelUsage(wire: .object(["input_tokens": .integer(3), "output_tokens": .integer(2)])),
        stopReason: stop)
}
func nativeCompletion(_ text: String = "hello / world\n") throws -> ModelCompletion {
    ModelCompletion(blocks: [.text(text)], metadata: try nativeMetadata())
}
func nativeWire(_ body: String) -> Data {
    Data(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            .utf8)
}
func nativeOutput(
    _ pair: NativeSocketPair, _ authority: RunLifecycle, connection: UUID = UUID(), streaming: Bool = false
) throws -> ControlledRunOutput {
    try ControlledRunOutput(
        lifecycle: authority, scope: authority.effectScope(connectionID: connection),
        takingAcceptedSocket: pair.takeWriter(), streaming: streaming)
}
func nativeResponseChecks() async throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    let output = try nativeOutput(pair, lifecycle(clock))
    try output.enqueue(.modelCompletion(nativeCompletion()))
    try check(try output.acceptNext(), "completion acceptance")
    let expected = nativeWire(
        #"{"content":[{"text":"hello / world\n","type":"text"}],"id":"msg_fixture","model":"fixture-model","role":"assistant","stop_reason":"end_turn","stop_sequence":null,"type":"message","usage":{"input_tokens":3,"output_tokens":2}}"#
    )
    try check(try pair.readAvailable() == expected, "native actual socket bytes absent or wrong framing")
    print("PASS native-response-exact-text-socket")
    try nativeToolCompletionSocket()
    try nativeStreamSocket()
    for mode in ["stop", "expiry", "revoke", "revision", "cancel"] { try nativeDeniedBeforeAcceptance(mode) }
    try nativeBackpressure(stop: false)
    try nativeBackpressure(stop: true)
    try nativeDisconnect()
    try nativeDisconnectAfterPrefix()
    try nativeOwnedDescriptorRejection()
    try nativeQueueLimits()
    try nativeRetainedBufferLimit()
    try await nativeFencedObservation(cancelTask: false)
    try await nativeFencedObservation(cancelTask: true)
    try nativeStreamStopAfterText()
    try nativeMalformedIsTransactional()
    try nativeTotalResponseBudget()
    try await nativeActualGateway(streaming: false)
    try await nativeActualGateway(streaming: true)
    try await nativeActualGateway(streaming: true, held: true)
}

func nativeDeniedBeforeAcceptance(_ mode: String) throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    let authority = lifecycle(clock)
    let id = UUID()
    let output = try nativeOutput(pair, authority, connection: id)
    try output.enqueue(.modelCompletion(nativeCompletion()))
    switch mode {
    case "stop": authority.terminate(.stopped)
    case "expiry": clock.advance(600)
    case "revoke": authority.invalidateConnection(id)
    case "revision": authority.advanceConnection(id)
    case "cancel": output.cancel()
    default: throw Failure(message: "invalid fixture mode")
    }
    do {
        _ = try output.acceptNext()
        throw Failure(message: "native revoked write")
    } catch is AuthorizationError {} catch is CancellationError {}
    try check(
        try pair.readAvailable().isEmpty && output.nativeProgress?.committedBytes == 0,
        "native denied acceptance wrote bytes")
    output.cancel()
    print("PASS native-response-preaccept-\(mode) actual_bytes=0")
}
func nativeBackpressure(stop: Bool) throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    let authority = lifecycle(clock)
    try pair.smallSendBuffer()
    let output = try nativeOutput(pair, authority)
    let body = String(repeating: "x", count: 60_000)
    try output.enqueue(.modelCompletion(nativeCompletion(body)))
    for _ in 0..<64 { if try !output.acceptNext() { break } }
    let blocked = output.nativeProgress!
    try check(
        blocked.committedBytes > 0 && blocked.pendingBytes > 0 && blocked.wouldBlockCount > 0
            && blocked.partialWriteCount > 0, "real partial send/EAGAIN not reached")
    try check(blocked.acceptedEvents == 0 && blocked.acceptedFinals == 0, "partial frame falsely completed")
    if stop {
        authority.terminate(.stopped)
        do {
            _ = try output.acceptNext()
            throw Failure(message: "late partial write")
        } catch is AuthorizationError {}
        let actual = try pair.readAvailable()
        try check(
            actual.count == blocked.committedBytes && output.nativeProgress?.committedBytes == actual.count,
            "committed prefix retracted or extended")
        output.cancel()
        try check(
            output.nativeProgress?.committedBytes == actual.count && output.nativeProgress?.pendingBytes == 0,
            "cancel rewrote commit accounting")
    } else {
        var actual = try pair.readAvailable()
        for _ in 0..<128 {
            _ = try output.acceptNext()
            actual.append(try pair.readAvailable())
            if output.nativeProgress?.closed == true { break }
        }
        let expectedJSON =
            #"{"content":[{"text":""# + body
            + #"","type":"text"}],"id":"msg_fixture","model":"fixture-model","role":"assistant","stop_reason":"end_turn","stop_sequence":null,"type":"message","usage":{"input_tokens":3,"output_tokens":2}}"#
        try check(actual == nativeWire(expectedJSON), "backpressure duplicated or dropped actual bytes")
        try check(
            output.nativeProgress?.acceptedFinals == 1 && output.nativeProgress?.committedBytes == actual.count,
            "partial completion accounting")
    }
    print(
        "PASS native-response-backpressure-\(stop ? "stop" : "resume") partial_writes=\(blocked.partialWriteCount) eagain=\(blocked.wouldBlockCount) committed_prefix=\(blocked.committedBytes)"
    )
}
func nativeDisconnect() throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    let output = try nativeOutput(pair, lifecycle(clock))
    try output.enqueue(.modelCompletion(nativeCompletion()))
    pair.closePeer()
    do {
        _ = try output.acceptNext()
        throw Failure(message: "disconnected socket accepted")
    } catch NativeResponseError.disconnected {}
    try check(
        output.nativeProgress?.committedBytes == 0 && output.nativeProgress?.acceptedFinals == 0
            && output.nativeProgress?.closed == true, "disconnect accounting")
    output.cancel()
    output.cancel()
    print("PASS native-response-disconnect-no-sigpipe")
}
func nativeQueueLimits() throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    let output = try nativeOutput(pair, lifecycle(clock), streaming: true)
    try output.enqueue(.modelChunk(ModelStreamChunk(event: .messageStart(try nativeMetadata(stop: nil)))))
    try output.enqueue(.modelChunk(ModelStreamChunk(event: .blockStart(index: 0, block: .text("")))))
    for _ in 0..<254 { try output.enqueue(.modelChunk(ModelStreamChunk(event: .textDelta(index: 0, text: "")))) }
    let before = output.nativeProgress!
    do {
        try output.enqueue(.modelChunk(ModelStreamChunk(event: .textDelta(index: 0, text: ""))))
        throw Failure(message: "event queue limit")
    } catch NativeResponseError.limitExceeded {}
    try check(
        output.nativeProgress?.queuedEvents == 256 && output.nativeProgress?.pendingBytes == before.pendingBytes,
        "queue rejection changed state")
    try check(try output.acceptNext(), "queue capacity release")
    _ = try pair.readAvailable()
    try output.enqueue(.modelChunk(ModelStreamChunk(event: .textDelta(index: 0, text: ""))))
    try check(output.nativeProgress?.queuedEvents == 256, "queue capacity not reusable")
    output.cancel()
    let other = try NativeSocketPair()
    let oversized = try nativeOutput(other, lifecycle(clock))
    do {
        try oversized.enqueue(.modelCompletion(nativeCompletion(String(repeating: "x", count: 1_048_576))))
        throw Failure(message: "frame bound")
    } catch NativeResponseError.limitExceeded {}
    try check(
        oversized.nativeProgress?.pendingBytes == 0 && oversized.nativeProgress?.committedBytes == 0,
        "oversize retained bytes")
    try oversized.enqueue(.modelCompletion(nativeCompletion()))
    _ = try oversized.acceptNext()
    try check(try !other.readAvailable().isEmpty, "oversize damaged state")
    print("PASS native-response-event-frame-limits-transactional-reuse")
}
func nativeActualGateway(streaming: Bool, held: Bool = false, nativeRequest: Bool = false) async throws {
    let id = UUID()
    let audit = Audit()
    let credentials = Credentials()
    let pair = try NativeSocketPair()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = held ? [NativeHeldProtocol.self] : [OfflineProtocol.self]
    let fixture = try nativeStreamFixture()
    let body =
        streaming
        ? fixture.map { "data: " + $0.1 + "\n\n" }.joined()
        : #"{"content":[{"type":"text","text":"hello / world\n"}],"id":"msg_fixture","type":"message","role":"assistant","model":"fixture-model","stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":2}}"#
    OfflineProtocol.probe.setResponse(Data(body.utf8))
    let connection = HostModelConnection(
        connectionID: id, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash,
        protocol: .anthropic, credentialProvider: credentials, configuration: config)
    let scope = try ResourceScope(
        service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
    let now = Date()
    let grant = try RunGrant(
        runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(600),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "offline",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
        connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])],
        explicitDenies: [],
        resourceLimits: ResourceLimits(
            cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
    let gateway = try HostModelGateway(connections: [connection], auditSink: audit)
    let handle = try await gateway.install(grant: grant)
    let request = try FixedModelRequest(
        model: .deepSeekFlash, protocol: .anthropic, messages: [FixedMessage(role: .user, content: "offline")],
        maxOutputTokens: 32)
    let proposal: HostModelProposal
    if nativeRequest {
        let body = Data(
            ("{\"model\":\"deepseek-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"offline\"}],\"max_tokens\":32,\"stream\":"
                + (streaming ? "true" : "false") + "}").utf8)
        proposal = try await gateway.proposeNative(handle: handle, connectionID: id, body: body, streaming: streaming)
    } else {
        proposal = try await gateway.propose(handle: handle, connectionID: id, request: request, streaming: streaming)
    }
    let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
    let output = try await gateway.makeNativeOutput(
        handle: handle, approval: approval, takingAcceptedSocket: pair.takeWriter())
    let before = held ? NativeHeldProtocol.state.count : OfflineProtocol.probe.count
    let otherProposal = try await gateway.propose(
        handle: handle, connectionID: id, request: request, streaming: streaming)
    let otherApproval = try await gateway.hostApprove(handle: handle, proposal: otherProposal)
    do {
        try await gateway.execute(handle: handle, approval: otherApproval, output: output)
        throw Failure(message: "foreign action selected native channel")
    } catch HostModelGatewayError.invalidApproval {}
    try check(
        credentials.count == 0 && (held ? NativeHeldProtocol.state.count : OfflineProtocol.probe.count) == before,
        "wrong binding dispatched")
    var bytes = Data()
    if held {
        let task = Task { try await gateway.execute(handle: handle, approval: approval, output: output) }
        var ready = false
        for _ in 0..<200 {
            if output.nativeProgress!.queuedEvents >= 3 {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !ready {
            task.cancel()
            NativeHeldProtocol.state.finish()
            _ = await task.result
            throw Failure(message: "open upstream prefix did not arrive")
        }
        let beforeEOF: Bool
        do {
            try check(try pair.readAvailable().isEmpty, "enqueue bypassed native fence")
            for _ in 0..<3 {
                _ = try output.acceptNext()
                bytes.append(try pair.readAvailable())
            }
            beforeEOF =
                !bytes.isEmpty && String(decoding: bytes, as: UTF8.self).contains("hi π") && audit.completions.isEmpty
                && output.nativeProgress!.acceptedFinals == 0
        } catch {
            task.cancel()
            NativeHeldProtocol.state.finish()
            _ = await task.result
            throw error
        }
        NativeHeldProtocol.state.finish()
        try await task.value
        try check(beforeEOF, "native bytes were held until upstream EOF or falsely completed")
    } else {
        try await gateway.execute(handle: handle, approval: approval, output: output)
        try check(try pair.readAvailable().isEmpty, "enqueue wrote outside acceptance fence")
    }
    for _ in 0..<64 {
        _ = try output.acceptNext()
        bytes.append(try pair.readAvailable())
        if output.nativeProgress?.closed == true { break }
    }
    try check(
        !bytes.isEmpty && output.nativeProgress?.committedBytes == bytes.count
            && output.nativeProgress?.acceptedFinals == 1, "gateway native concrete consumer missing")
    try check(
        credentials.count == 1 && (held ? NativeHeldProtocol.state.count : OfflineProtocol.probe.count) - before == 1
            && audit.completions.count == 1, "gateway real producer accounting")
    try check(try await gateway.resumedTaskCount(handle: handle) == 1, "gateway actual resume")
    print(
        "PASS \(nativeRequest ? "r3-native-request-writer" : "native-response-gateway")-\(held ? "sse-before-upstream-eof" : (streaming ? "sse" : "json")) credential_reads=1 resume=1 urlprotocol_arrivals=1"
    )
}

func nativeRetainedBufferLimit() throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    try pair.smallSendBuffer()
    let output = try nativeOutput(pair, lifecycle(clock), streaming: true)
    try output.enqueue(.modelChunk(ModelStreamChunk(event: .messageStart(try nativeMetadata(stop: nil)))))
    let text = String(repeating: "x", count: 60_000)
    var index = 0
    for _ in 0..<64 {
        do {
            try output.enqueue(.modelChunk(ModelStreamChunk(event: .blockStart(index: index, block: .text(text)))))
        } catch NativeResponseError.limitExceeded { break }
        try output.enqueue(.modelChunk(ModelStreamChunk(event: .blockStop(index: index, block: .text(text)))))
        index += 1
    }
    let remaining = NativeResponseChannel.maxPendingBytes - output.nativeProgress!.pendingBytes
    try check(remaining > 256 && remaining < 60_000, "pending-byte saturation")
    try output.enqueue(
        .modelChunk(
            ModelStreamChunk(
                event: .blockStart(index: index, block: .text(String(repeating: "x", count: remaining - 256))))))
    let empty = ModelStreamChunk(event: .textDelta(index: index, text: ""))
    func fill() throws {
        for _ in 0..<100 {
            do { try output.enqueue(.modelChunk(empty)) } catch NativeResponseError.limitExceeded { return }
        }
        throw Failure(message: "byte saturation not reached")
    }
    try fill()
    _ = try output.acceptNext()
    _ = try pair.readAvailable()
    try fill()
    _ = try output.acceptNext()
    try check(output.nativeProgress!.partialWriteCount > 0, "buffer test did not partially write")
    try fill()
    try check(
        output.nativeProgress!.bufferedBytes <= NativeResponseChannel.maxPendingBytes,
        "partially sent frame escaped retained-byte limit")
    output.cancel()
    try check(output.nativeProgress!.bufferedBytes == 0, "cancel retained frame storage")
    print("PASS native-response-retained-byte-cap-after-partial-write")
}

func nativeToolCompletionSocket() throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    let output = try nativeOutput(pair, lifecycle(clock))
    let tool = ModelBlock.toolUse(id: "tool_fixture", name: "read_file", input: .object(["path": .string("a/b")]))
    try output.enqueue(
        .modelCompletion(ModelCompletion(blocks: [tool], metadata: try nativeMetadata(stop: "tool_use"))))
    _ = try output.acceptNext()
    let expected = nativeWire(
        #"{"content":[{"id":"tool_fixture","input":{"path":"a/b"},"name":"read_file","type":"tool_use"}],"id":"msg_fixture","model":"fixture-model","role":"assistant","stop_reason":"tool_use","stop_sequence":null,"type":"message","usage":{"input_tokens":3,"output_tokens":2}}"#
    )
    try check(try pair.readAvailable() == expected, "native nonstream tool framing")
    print("PASS native-response-exact-tool-json-socket")
}
func nativeDisconnectAfterPrefix() throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    try pair.smallSendBuffer()
    let output = try nativeOutput(pair, lifecycle(clock))
    try output.enqueue(.modelCompletion(nativeCompletion(String(repeating: "x", count: 60_000))))
    _ = try output.acceptNext()
    let bytes = try pair.readAvailable().count
    try check(bytes > 0 && bytes == output.nativeProgress!.committedBytes, "disconnect prefix not observed")
    pair.closePeer()
    do {
        _ = try output.acceptNext()
        throw Failure(message: "disconnected partial response accepted")
    } catch NativeResponseError.disconnected {}
    try check(
        output.nativeProgress!.committedBytes == bytes && output.nativeProgress!.acceptedFinals == 0,
        "disconnect erased committed prefix")
    output.cancel()
    print("PASS native-response-disconnect-retains-committed-prefix actual_bytes=\(bytes)")
}
func nativeOwnedDescriptorRejection() throws {
    var fds: [Int32] = [-1, -1]
    try check(pipe(&fds) == 0, "owned pipe fixture")
    defer { Darwin.close(fds[0]) }
    let clock = Clock()
    let authority = lifecycle(clock)
    do {
        _ = try ControlledRunOutput(
            lifecycle: authority, scope: authority.effectScope(connectionID: UUID()), takingAcceptedSocket: fds[1],
            streaming: false)
        throw Failure(message: "non-socket descriptor accepted")
    } catch NativeResponseError.invalidSocket {}
    _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
    var byte: UInt8 = 0
    try check(Darwin.read(fds[0], &byte, 1) == 0, "rejected owned writer leaked")
    print("PASS native-response-owned-nonsocket-rejection-closes-only-transferred-fd")
}

func nativeStreamFixture() throws -> [(ModelStreamChunk, String)] {
    let tool = ModelBlock.toolUse(id: "tool_fixture", name: "read_file", input: .object(["path": .string("a/b")]))
    let completion = ModelCompletion(blocks: [.text("hi π\n"), tool], metadata: try nativeMetadata(stop: "tool_use"))
    return [
        (
            ModelStreamChunk(event: .messageStart(try nativeMetadata(stop: nil))),
            #"{"message":{"content":[],"id":"msg_fixture","model":"fixture-model","role":"assistant","stop_reason":null,"stop_sequence":null,"type":"message","usage":{"input_tokens":3,"output_tokens":2}},"type":"message_start"}"#
        ),
        (
            ModelStreamChunk(event: .blockStart(index: 0, block: .text(""))),
            #"{"content_block":{"text":"","type":"text"},"index":0,"type":"content_block_start"}"#
        ),
        (
            ModelStreamChunk(text: "hi π\n", event: .textDelta(index: 0, text: "hi π\n")),
            #"{"delta":{"text":"hi π\n","type":"text_delta"},"index":0,"type":"content_block_delta"}"#
        ),
        (
            ModelStreamChunk(event: .blockStop(index: 0, block: .text("hi π\n"))),
            #"{"index":0,"type":"content_block_stop"}"#
        ),
        (
            ModelStreamChunk(
                event: .blockStart(
                    index: 1, block: .toolUse(id: "tool_fixture", name: "read_file", input: .object([:])))),
            #"{"content_block":{"id":"tool_fixture","input":{},"name":"read_file","type":"tool_use"},"index":1,"type":"content_block_start"}"#
        ),
        (
            ModelStreamChunk(event: .inputJSONDelta(index: 1, partialJSON: #"{"path":"a/b"}"#)),
            #"{"delta":{"partial_json":"{\"path\":\"a/b\"}","type":"input_json_delta"},"index":1,"type":"content_block_delta"}"#
        ),
        (ModelStreamChunk(event: .blockStop(index: 1, block: tool)), #"{"index":1,"type":"content_block_stop"}"#),
        (
            ModelStreamChunk(event: .messageDelta(try nativeMetadata(stop: "tool_use"))),
            #"{"delta":{"stop_reason":"tool_use","stop_sequence":null},"type":"message_delta","usage":{"input_tokens":3,"output_tokens":2}}"#
        ),
        (ModelStreamChunk(event: .messageStop(completion), completion: completion), #"{"type":"message_stop"}"#),
    ]
}
func nativeStreamSocket() throws {
    let pair = try NativeSocketPair()
    let clock = Clock()
    let output = try nativeOutput(pair, lifecycle(clock), streaming: true)
    let fixture = try nativeStreamFixture()
    var expected = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            .utf8)
    for (chunk, json) in fixture {
        try output.enqueue(.modelChunk(chunk))
        let type = try ModelJSON.parse(Data(json.utf8))["type"]!.string!
        expected.append(Data("event: \(type)\ndata: \(json)\n\n".utf8))
    }
    var actual = Data()
    for _ in 0..<64 {
        _ = try output.acceptNext()
        actual.append(try pair.readAvailable())
        if output.nativeProgress?.closed == true { break }
    }
    try check(actual == expected, "native SSE exact text/tool framing")
    try check(
        output.nativeProgress?.committedBytes == actual.count && output.nativeProgress?.acceptedFinals == 1,
        "native SSE committed bytes")
    print("PASS native-response-exact-sse-text-tool-socket")
}
