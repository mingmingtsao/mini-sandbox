import Foundation

@testable import SandboxHost

// Permanent local socket/codec regressions; no provider or CLI execution.
func nativeRepairChecks() throws {
    let cases: [(String, () throws -> Void)] = [
        ("native-repair-below-cap-decoder-socket", nativeBelowCapReply),
        ("native-repair-terminal-reconstruction-release", nativeTerminalReconstructionRelease),
        ("native-repair-receiver-contention-no-wait", nativeReceiverContention),
        ("native-repair-exact-http-frame-boundaries", nativeExactFrameBoundaries),
        ("native-repair-escaped-json-sse-boundaries", nativeEscapedSizing),
        ("native-repair-multitool-metadata-roundtrip", nativeMultiMetadataRoundtrip),
    ]
    var failures = 0
    for (name, body) in cases {
        do {
            try body()
            print("PASS \(name)")
        } catch {
            failures += 1
            print("FAIL \(name): \(error)")
        }
    }
    try check(failures == 0, "native repair failures=\(failures)")
}

func nativeReferenceJSON(_ completion: ModelCompletion) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(NativeResponseSerializer.message(completion.metadata, blocks: completion.blocks))
}
func nativeDrain(_ output: ControlledRunOutput, _ pair: NativeSocketPair) throws -> Data {
    var bytes = Data()
    for _ in 0..<1024 {
        _ = try output.acceptNext()
        bytes.append(try pair.readAvailable())
        if output.nativeProgress!.queuedEvents == 0 { return bytes }
    }
    throw Failure(message: "native bounded drain")
}
func nativeBelowCapReply() throws {
    let completion = ModelCompletion(
        blocks: (0..<3).map { .text(String(repeating: String($0), count: 60_000)) }, metadata: try nativeMetadata())
    let raw = try nativeReferenceJSON(completion)
    let expected = nativeWire(String(decoding: raw, as: UTF8.self))
    let decoded = try AnthropicResponse.decode(raw)
    try check(
        decoded == completion && expected.count < NativeResponseChannel.maxFrameBytes, "actual upstream eligibility")
    let pair = try NativeSocketPair()
    let output = try nativeOutput(pair, lifecycle(Clock()))
    try output.enqueue(.modelCompletion(decoded))
    let actual = try nativeDrain(output, pair)
    try check(
        actual == expected && output.nativeProgress!.committedBytes == actual.count
            && output.nativeProgress!.acceptedFinals == 1, "below-cap content/socket accounting")
    let delimiter = actual.range(of: Data("\r\n\r\n".utf8))!
    try check(
        try AnthropicResponse.decode(Data(actual[delimiter.upperBound...])) == completion,
        "downstream production decoder equality")
    print("OBS below-cap json_bytes=\(raw.count) http_bytes=\(actual.count) semantic_bytes=180000")
}

func nativeField<T>(_ object: Any, _ label: String, _: T.Type) throws -> T {
    guard let value = Mirror(reflecting: object).children.first(where: { $0.label == label })?.value as? T else {
        throw Failure(message: "fixture missing field \(label)")
    }
    return value
}
func nativeReconstructionEmpty(_ channel: NativeResponseChannel) throws -> Bool {
    let serializer = try nativeField(channel, "serializer", NativeResponseSerializer.self)
    let blocks = try nativeField(serializer, "blocks", [ModelBlock].self)
    let active: ModelBlock? = try nativeField(serializer, "active", Optional<ModelBlock>.self)
    let metadata: ModelMetadata? = try nativeField(serializer, "metadata", Optional<ModelMetadata>.self)
    let partial = try nativeField(serializer, "partialJSON", String.self)
    return blocks.isEmpty && active == nil && metadata == nil && partial.isEmpty
}
func nativeTerminalReconstructionRelease() throws {
    for mode in ["cancel", "disconnect", "finish"] {
        let pair = try NativeSocketPair()
        try pair.smallSendBuffer()
        let channel = try NativeResponseChannel(takingAcceptedSocket: pair.takeWriter(), streaming: true)
        let start = try nativeMetadata(stop: nil)
        try channel.enqueue(.modelChunk(ModelStreamChunk(event: .messageStart(start))))
        var blocks: [ModelBlock] = []
        for index in 0..<3 {
            let block = ModelBlock.text(String(repeating: String(index), count: 60_000))
            blocks.append(block)
            try channel.enqueue(.modelChunk(ModelStreamChunk(event: .blockStart(index: index, block: block))))
            try channel.enqueue(.modelChunk(ModelStreamChunk(event: .blockStop(index: index, block: block))))
        }
        if mode == "finish" {
            let end = try nativeMetadata()
            try channel.enqueue(.modelChunk(ModelStreamChunk(event: .messageDelta(end))))
            let completion = ModelCompletion(blocks: blocks, metadata: end)
            try channel.enqueue(.modelChunk(ModelStreamChunk(event: .messageStop(completion), completion: completion)))
        } else {
            try channel.enqueue(
                .modelChunk(
                    ModelStreamChunk(
                        event: .blockStart(
                            index: 3, block: .toolUse(id: "tool_cleanup", name: "read_file", input: .object([:]))))))
            try channel.enqueue(
                .modelChunk(ModelStreamChunk(event: .inputJSONDelta(index: 3, partialJSON: "{\"path\":\"retained"))))
        }
        _ = try channel.acceptOne()
        _ = try pair.readAvailable()
        _ = try channel.acceptOne()  // real partial frame, retained sent prefix
        let committed = channel.committedBytes
        let events = channel.acceptedEvents
        let partials = channel.partialWriteCount
        try check(committed > 0 && partials > 0, "cleanup partial OS-write setup")
        if mode == "finish" {
            for _ in 0..<1024 {
                _ = try pair.readAvailable()
                _ = try channel.acceptOne()
                if channel.isClosed { break }
            }
            try check(channel.acceptedFinals == 1 && channel.committedBytes > committed, "finish delivery accounting")
        } else if mode == "disconnect" {
            pair.closePeer()
            do {
                _ = try channel.acceptOne()
                throw Failure(message: "disconnect accepted")
            } catch NativeResponseError.disconnected {}
        } else {
            channel.detachTerminal()
            channel.takeCleanup().dispose()
        }
        channel.takeCleanup().dispose()
        try check(
            channel.isClosed && channel.queuedEvents == 0 && channel.bufferedBytes == 0 && channel.pendingBytes == 0,
            "terminal frame cleanup \(mode)")
        try check(try nativeReconstructionEmpty(channel), "terminal retained reconstruction \(mode)")
        if mode != "finish" {
            try check(
                channel.committedBytes == committed && channel.acceptedEvents == events
                    && channel.partialWriteCount == partials && channel.acceptedFinals == 0,
                "terminal rewrote history \(mode)")
        }
        let historical = [
            channel.committedBytes, channel.acceptedEvents, channel.acceptedFinals, channel.partialWriteCount,
            channel.wouldBlockCount,
        ]
        channel.detachTerminal()
        channel.takeCleanup().dispose()
        channel.detachTerminal()
        channel.takeCleanup().dispose()
        try check(
            historical == [
                channel.committedBytes, channel.acceptedEvents, channel.acceptedFinals, channel.partialWriteCount,
                channel.wouldBlockCount,
            ], "repeated cancel rewrote counters")
        print("OBS cleanup mode=\(mode) committed_bytes=\(channel.committedBytes) reconstruction_empty=true")
    }
}

final class NativeRepairClock: @unchecked Sendable {
    let source = RunClock.manual(wall: Date(), elapsed: .zero)
    var value: Date { source.wall }
    func expire() { source.advance(600) }
}
final class NativeRepairAttempt: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0), lock = NSLock()
    private var result: Result<Bool, Error>?
    func run(_ output: ControlledRunOutput) {
        let value = Result { try output.acceptNext() }
        lock.withLock { result = value }
        done.signal()
    }
    func value() throws -> Bool { try lock.withLock { try result!.get() } }
}
func nativeExactFrameBoundaries() throws {
    for adjustment in [-1, 0, 1] {
        let target = NativeResponseChannel.maxFrameBytes + adjustment
        var blocks = [ModelBlock](repeating: .text(String(repeating: "x", count: ModelJSON.maxBytes)), count: 16)
        let metadata = try nativeMetadata()
        let full = try nativeReferenceJSON(ModelCompletion(blocks: blocks, metadata: metadata))
        let lastCount = ModelJSON.maxBytes + target - nativeWire(String(decoding: full, as: UTF8.self)).count
        try check(lastCount > 0 && lastCount <= ModelJSON.maxBytes, "exact frame fixture block bounds")
        blocks[15] = .text(String(repeating: "y", count: lastCount))
        let completion = ModelCompletion(blocks: blocks, metadata: metadata)
        let raw = try nativeReferenceJSON(completion)
        let expected = nativeWire(String(decoding: raw, as: UTF8.self))
        try check(
            expected.count == target && (try AnthropicResponse.decode(raw)) == completion,
            "exact frame decoder eligibility")
        let pair = try NativeSocketPair()
        let output = try nativeOutput(pair, lifecycle(Clock()))
        if adjustment > 0 {
            for _ in 0..<2 {
                do {
                    try output.enqueue(.modelCompletion(completion))
                    throw Failure(message: "frame cap+1 admitted")
                } catch NativeResponseError.limitExceeded {}
                try check(
                    output.nativeProgress!.queuedEvents == 0 && output.nativeProgress!.pendingBytes == 0
                        && output.nativeProgress!.committedBytes == 0, "oversize consumed state")
            }
            try output.enqueue(.modelCompletion(nativeCompletion()))
            try check(
                try !nativeDrain(output, pair).isEmpty && output.nativeProgress!.acceptedFinals == 1,
                "frame failure non-consuming retry")
        } else {
            try output.enqueue(.modelCompletion(completion))
            let actual = try nativeDrain(output, pair)
            try check(
                actual == expected && output.nativeProgress!.committedBytes == target
                    && output.nativeProgress!.acceptedFinals == 1, "exact HTTP frame boundary bytes")
            let delimiter = actual.range(of: Data("\r\n\r\n".utf8))!
            try check(
                try AnthropicResponse.decode(Data(actual[delimiter.upperBound...])) == completion,
                "exact-cap downstream decode")
        }
        print("OBS exact-http-frame bytes=\(target) admitted=\(adjustment <= 0)")
    }
}

func nativeEscapedSizing() throws {
    let controls = (0...31).map { String(UnicodeScalar($0)!) }.joined()
    let unit = controls + "\"\\/π中😀\u{2028}\u{2029}e\u{0301}"
    let value = ModelJSON.object([
        unit: .array([
            .string(unit), .integer(-ModelJSON.maxInteger), .integer(ModelJSON.maxInteger), .integer(0), .bool(true),
            .bool(false), .null, .object([:]), .array([]),
        ])
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let reference = try encoder.encode(value)
    for budget in [reference.count - 1, reference.count, reference.count + 1] {
        if budget < reference.count {
            do {
                _ = try NativeResponseSerializer.json(value, maxBytes: budget)
                throw Failure(message: "escaped JSON cap bypass")
            } catch NativeResponseError.limitExceeded {}
        } else {
            let actual = try NativeResponseSerializer.json(value, maxBytes: budget)
            try check(
                actual.count == reference.count && (try ModelJSON.parse(actual)) == value,
                "exact escape/key/number grammar")
        }
    }
    do {
        _ = try NativeResponseSerializer.json(.integer(Int64.max))
        throw Failure(message: "unsafe JSON integer")
    } catch ModelTransportError.invalidResponse {}
    // A genuinely decoded below-cap response with large escaped/multibyte strings.
    let text = String(repeating: unit, count: 700)
    try check(text.utf8.count <= ModelJSON.maxBytes, "escaped semantic bound")
    let completion = ModelCompletion(blocks: [.text(text), .text(text), .text(text)], metadata: try nativeMetadata())
    let raw = try nativeReferenceJSON(completion)
    try check(try AnthropicResponse.decode(raw) == completion, "escaped upstream production eligibility")
    let pair = try NativeSocketPair()
    let output = try nativeOutput(pair, lifecycle(Clock()))
    try output.enqueue(.modelCompletion(completion))
    let actual = try nativeDrain(output, pair)
    try check(actual == nativeWire(String(decoding: raw, as: UTF8.self)), "escaped positive real socket content")

    // Exact per-event budget includes initial HTTP header, SSE type/data and LF.
    var serializer = NativeResponseSerializer(streaming: true)
    let fixture = try nativeStreamFixture()
    for (chunk, json) in fixture {
        let type = try ModelJSON.parse(Data(json.utf8))["type"]!.string!
        let prefix =
            type == "message_start"
            ? "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            : ""
        let expected = Data((prefix + "event: \(type)\ndata: \(json)\n\n").utf8)
        var rejected = serializer
        do {
            _ = try rejected.encode(.modelChunk(chunk), maxBytes: expected.count - 1)
            throw Failure(message: "SSE overhead omitted")
        } catch NativeResponseError.limitExceeded {}
        let frame = try serializer.encode(.modelChunk(chunk), maxBytes: expected.count)
        try check(frame.bytes == expected, "SSE exact boundary positive")
    }
    print("OBS escaped-json bytes=\(reference.count) escaped-http=\(actual.count) sse_exact_frames=\(fixture.count)")
}

func nativeMultiMetadataRoundtrip() throws {
    let rawEvents = [
        #"{"type":"message_start","message":{"id":"msg_review","type":"message","role":"assistant","model":"local-fixture","content":[],"stop_reason":null,"usage":{"input_tokens":3,"output_tokens":2,"service_tier":"standard"}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi π"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_one","name":"read_file","input":{}}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a/b\"}"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool_two","name":"echo_text","input":{}}}"#,
        #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"text\":\"π\"}"}}"#,
        #"{"type":"content_block_stop","index":2}"#,
        #"{"type":"message_delta","delta":{"stop_sequence":null},"usage":{"output_tokens":3,"service_tier":null}}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":4}}"#,
        #"{"type":"message_delta","delta":{},"usage":{"output_tokens":5,"service_tier":"standard"}}"#,
        #"{"type":"message_stop"}"#,
    ]
    let upstream = AnthropicStreamDecoder()
    let downstream = AnthropicStreamDecoder()
    let pair = try NativeSocketPair()
    let output = try nativeOutput(pair, lifecycle(Clock()), streaming: true)
    var source: ModelCompletion?
    var actual = Data()
    for raw in rawEvents {
        guard let chunk = try upstream.consume(raw) else { throw Failure(message: "dropped upstream fixture event") }
        if let completion = chunk.completion { source = completion }
        try output.enqueue(.modelChunk(chunk))
        actual.append(try nativeDrain(output, pair))
    }
    var decoded: ModelCompletion?
    var count = 0
    var deltas = 0
    for line in String(decoding: actual, as: UTF8.self).components(separatedBy: "\n") where line.hasPrefix("data: ") {
        if let chunk = try downstream.consume(String(line.dropFirst(6))) {
            count += 1
            if case .messageDelta = chunk.event { deltas += 1 }
            if let completion = chunk.completion { decoded = completion }
        }
    }
    try check(
        source != nil && decoded == source && count == rawEvents.count && deltas == 3,
        "multi-tool cumulative metadata lost")
    try check(
        output.nativeProgress!.acceptedFinals == 1 && output.nativeProgress!.committedBytes == actual.count,
        "multi-tool committed accounting")
    print("OBS multi-tool events=\(count) deltas=\(deltas) tool_blocks=2 socket_bytes=\(actual.count)")
}

func nativeReceiverContention() throws {
    for expires in [false, true] {
        let clock = NativeRepairClock()
        let initial = clock.value
        let authority = RunLifecycle(
            expiresAt: initial.addingTimeInterval(600), epoch: 1, installedAt: initial, clock: clock.source)
        let pair = try NativeSocketPair()
        let output = try nativeOutput(pair, authority)
        try output.enqueue(.modelCompletion(nativeCompletion()))
        let mutex = try nativeField(output, "lock", NSLock.self)
        let attempt = NativeRepairAttempt()
        mutex.lock()
        DispatchQueue.global().async { attempt.run(output) }
        let noWait = attempt.done.wait(timeout: .now() + 1) == .success
        let sampled = clock.source.observation.0 > 0
        if expires { clock.expire() }
        mutex.unlock()
        let finished = noWait || attempt.done.wait(timeout: .now() + 2) == .success
        try check(sampled && finished, "contention fixture barrier")
        let actual = try pair.readAvailable()
        try check(
            noWait && (try attempt.value()) == false && actual.isEmpty && output.nativeProgress!.committedBytes == 0
                && output.nativeProgress!.queuedEvents == 1, "receiver lock waited after sample or consumed output")
        if expires {
            do {
                _ = try output.acceptNext()
                throw Failure(message: "retry reused stale authority")
            } catch is AuthorizationError {}
            try check(try pair.readAvailable().isEmpty, "expiry retry wrote bytes")
        } else {
            try check(try output.acceptNext(), "contention retry failed")
            try check(
                try !pair.readAvailable().isEmpty && output.nativeProgress!.acceptedFinals == 1,
                "fresh retry did not send")
        }
        output.cancel()
    }
}
