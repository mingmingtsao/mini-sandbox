import Foundation
import SandboxHost

// Synthetic SHAPE fixtures, not captured provider bodies. The diagnostic observed
// a string service_tier alongside four integer counters, not its string value.
private let usageCounters: [String: ModelJSON] = [
    "input_tokens": .integer(12), "output_tokens": .integer(9), "cache_creation_input_tokens": .integer(2),
    "cache_read_input_tokens": .integer(3),
]
private let usageTiers = ["standard", "priority", "batch"]
private func usageWire(_ tier: ModelJSON?) -> ModelJSON {
    var fields = usageCounters
    fields["service_tier"] = tier
    return .object(fields)
}
private func usageBody(_ usage: ModelJSON) throws -> Data {
    var body = try ModelJSON.parse(Data(toolReply.utf8)).object!
    body["usage"] = usage
    return try JSONEncoder().encode(ModelJSON.object(body))
}
private func usageStart(_ usage: ModelJSON) throws -> String {
    var start = try ModelJSON.parse(Data(toolEvents()[0].utf8)).object!
    var message = start["message"]!.object!
    message["usage"] = usage
    start["message"] = .object(message)
    return String(decoding: try JSONEncoder().encode(ModelJSON.object(start)), as: UTF8.self)
}
private func usageEvents(_ usage: ModelJSON) throws -> [String] {
    var events = toolEvents()
    events[0] = try usageStart(usage)
    return events
}
func usageOfficialTiers(streaming: Bool) async throws {
    var failures: [String] = []
    for tier in usageTiers {
        do {
            let wire = usageWire(.string(tier))
            Fixture.install(streaming ? [sse(try usageEvents(wire))] : [[try usageBody(wire)]])
            let credential = Credential()
            let transport = ModelTransport(credentialProvider: credential, configuration: configuration())
            let completion: ModelCompletion
            if streaming {
                var chunks: [ModelStreamChunk] = []
                for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) }
                guard let result = chunks.last?.completion else { throw Failure.check("no final") }
                completion = result
            } else {
                completion = try await transport.complete(baseRequest())
            }
            try check(completion.metadata.usage == ModelUsage(wire: wire), "usage erased during transport")
            try check(
                completion.metadata.usage?.serviceTier?.rawValue == tier
                    && completion.metadata.usage?.values == usageCounters.mapValues { $0.integer! },
                "typed tier separate from all four counters")
            try check(
                completion.metadata.stopReason == "tool_use" && completion.blocks.count == 1, "tool metadata changed")
            try check(credential.reads == 1 && Fixture.requests.count == 1, "single synthetic dispatch")
        } catch { failures.append("\(tier): \(error)") }
    }
    try check(failures.isEmpty, failures.joined(separator: "; "))
}
private func usageDelta(_ usage: ModelJSON?, fields: [String: ModelJSON] = [:]) throws -> String {
    var event: [String: ModelJSON] = ["type": .string("message_delta"), "delta": .object(fields)]
    event["usage"] = usage
    return String(decoding: try JSONEncoder().encode(ModelJSON.object(event)), as: UTF8.self)
}
func usageNullableAndCounters() async throws {
    for tier: ModelJSON? in [nil, .null] {
        for caches in [false, true] {
            var fields = usageCounters
            if !caches {
                fields.removeValue(forKey: "cache_creation_input_tokens")
                fields.removeValue(forKey: "cache_read_input_tokens")
            }
            fields["future_integer_counter"] = .integer(4)
            fields["service_tier"] = tier
            let wire = ModelJSON.object(fields)
            Fixture.install([[try usageBody(wire)]])
            let completion = try await ModelTransport(credentialProvider: Credential(), configuration: configuration())
                .complete(baseRequest())
            let chunks = try await collectDeltaStream(usageEvents(wire))
            for usage in [completion.metadata.usage, chunks.last?.completion?.metadata.usage] {
                try check(
                    usage?.serviceTier == nil
                        && usage?.values == fields.filter { $0.key != "service_tier" }.mapValues { $0.integer! },
                    "missing/null initial tier and optional counters unchanged")
            }
        }
    }
}
func usageStrictRejections() async throws {
    let invalidTiers: [(String, ModelJSON)] = [
        ("number", .integer(0)), ("negative number", .integer(-1)), ("bool", .bool(true)),
        ("array", .array([])), ("object", .object([:])), ("unknown string", .string("auto")),
        ("empty string", .string("")), ("control", .string("standard\n")),
        ("overlong", .string(String(repeating: "s", count: 257))),
    ]
    var cases = invalidTiers.map { ($0.0, usageWire($0.1)) }
    for (label, key, value): (String, String, ModelJSON) in [
        ("unknown string field", "future_metadata", .string("standard")),
        ("unknown null field", "future_metadata", .null),
        ("unknown bool field", "future_metadata", .bool(false)),
        ("unknown array field", "future_metadata", .array([])),
        ("unknown nested field", "future_metadata", .object([:])),
        ("nested cache_creation", "cache_creation", .object(["ephemeral_5m_input_tokens": .integer(0)])),
        ("null optional cache", "cache_creation_input_tokens", .null),
        ("negative optional cache", "cache_read_input_tokens", .integer(-1)),
    ] {
        var fields = usageCounters
        fields[key] = value
        cases.append((label, .object(fields)))
    }
    var failures: [String] = []
    var count = 0
    for (label, wire) in cases {
        for mode in ["completion", "start", "delta"] {
            count += 1
            do {
                let events =
                    mode == "delta"
                    ? Array(toolEvents().prefix(5)) + [
                        try usageDelta(wire, fields: ["stop_reason": .string("tool_use")]), toolEvents().last!,
                    ] : try usageEvents(wire)
                try await usageExpectRejection(
                    mode == "completion" ? [try usageBody(wire)] : sse(events), streaming: mode != "completion",
                    expected: .invalidResponse, noChunks: mode != "delta")
            } catch { failures.append("\(label) \(mode): \(error)") }
        }
    }
    // Raw duplicate decoded keys must reach the raw parser, not a dictionary.
    for duplicate in [
        #""service_tier":"standard","service_tier":"standard""#,
        #""service_tier":"standard","\u0073ervice_tier":"batch""#,
    ] {
        let raw = String(decoding: try usageBody(usageWire(nil)), as: UTF8.self).replacingOccurrences(
            of: #""usage":{"#, with: #""usage":{"# + duplicate + ",")
        let start = try usageStart(usageWire(nil)).replacingOccurrences(
            of: #""usage":{"#, with: #""usage":{"# + duplicate + ",")
        let delta = #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"# + duplicate + "}}"
        for (mode, data) in [
            ("completion", [Data(raw.utf8)]), ("start", sse([start] + Array(toolEvents().dropFirst()))),
            ("delta", sse(Array(toolEvents().prefix(5)) + [delta, toolEvents().last!])),
        ] {
            count += 1
            do {
                try await usageExpectRejection(
                    data, streaming: mode != "completion", expected: .invalidResponse, noChunks: mode != "delta")
            } catch { failures.append("duplicate \(mode): \(error)") }
        }
    }
    print("Usage strict cases: \(count); failures: \(failures.count)")
    try check(failures.isEmpty, failures.joined(separator: "; "))
}
private func usageExpectRejection(
    _ data: [Data], streaming: Bool, expected: ModelTransportError, noChunks: Bool = false
) async throws {
    Fixture.install([data])
    let credential = Credential()
    let transport = ModelTransport(credentialProvider: credential, configuration: configuration())
    var chunks: [ModelStreamChunk] = []
    var received: ModelTransportError?
    do {
        if streaming {
            for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) }
        } else {
            _ = try await transport.complete(baseRequest())
        }
    } catch let error as ModelTransportError { received = error }
    try check(
        received == expected && !chunks.contains(where: \.isFinal),
        "expected \(expected), got \(String(describing: received))")
    try check(!noChunks || chunks.isEmpty, "invalid initial usage exposed chunks")
    try check(credential.reads == 1 && Fixture.requests.count == 1, "invalid usage never retries")
}
func usageMergeControls() async throws {
    for tier in usageTiers {
        for initial: ModelJSON? in [nil, .null, .string(tier)] {
            let events =
                [try usageStart(usageWire(initial))] + [
                    try usageDelta(.object(["service_tier": .null])),
                    try usageDelta(
                        .object(["service_tier": .string(tier), "output_tokens": .integer(10)]),
                        fields: ["stop_sequence": .string("END")]),
                    try usageDelta(.object(["service_tier": .string(tier), "cache_read_input_tokens": .integer(4)])),
                    try usageDelta(
                        .object(["service_tier": .null, "cache_creation_input_tokens": .integer(3)]),
                        fields: ["stop_reason": .string("stop_sequence")]),
                    try usageDelta(.object(["output_tokens": .integer(11)]), fields: ["stop_sequence": .null]),
                    try usageDelta(nil), toolEvents().last!,
                ]
            let chunks = try await collectDeltaStream(events)
            let metadata = deltaMetadata(chunks)
            try check(
                metadata.map { $0.usage?.serviceTier?.rawValue } == [initial?.string, tier, tier, tier, tier, tier],
                "late/identical/null/omitted tier merge")
            try check(metadata.map { $0.usage?.outputTokens } == [9, 10, 10, 10, 11, 11], "output cumulative merge")
            try check(
                metadata.map { $0.usage?.values["cache_creation_input_tokens"] } == [2, 2, 2, 3, 3, 3],
                "creation counter retained")
            try check(
                metadata.map { $0.usage?.values["cache_read_input_tokens"] } == [3, 3, 4, 4, 4, 4],
                "read counter retained")
            try check(
                metadata.allSatisfy {
                    $0.usage?.inputTokens == 12 && $0.messageID == "msg_1" && $0.model == "deepseek-flash"
                        && $0.usage?.values["service_tier"] == nil
                }, "no erased identity/input or tier in counters")
            try check(
                metadata.last?.stopSequence == "END" && metadata.last?.stopReason == "stop_sequence"
                    && chunks.last?.completion?.metadata == metadata.last, "final retains every merged field")
        }
    }
    // Optional cache counters may first arrive in a later update.
    let chunks = try await collectDeltaStream([
        toolEvents()[0],
        try usageDelta(
            .object(["cache_read_input_tokens": .integer(2), "service_tier": .string("standard")]),
            fields: ["stop_reason": .string("end_turn")]), try usageDelta(nil), toolEvents().last!,
    ])
    try check(
        chunks.last?.completion?.metadata.usage?.values == [
            "input_tokens": 12, "output_tokens": 0, "cache_read_input_tokens": 2,
        ], "late optional cache preserved, absent creation counter not invented")
}
func usageMergeRejections() async throws {
    let first = try usageDelta(
        .object(["service_tier": .string("standard")]), fields: ["stop_reason": .string("end_turn")])
    var cases: [(String, ModelJSON)] = [
        ("conflicting tier", .object(["service_tier": .string("priority")])),
        ("numeric tier update", .object(["service_tier": .integer(1)])),
    ]
    for (key, value) in usageCounters {
        cases.append(
            ("rollback \(key)", .object([key: .integer(value.integer! - 1), "service_tier": .string("standard")])))
    }
    for (label, update) in cases {
        let events = [
            try usageStart(usageWire(.string("standard"))), first, try usageDelta(update), toolEvents().last!,
        ]
        try await usageExpectRejection(
            sse(events), streaming: true, expected: label == "numeric tier update" ? .invalidResponse : .malformedSSE)
    }
    // A first tier learned in a delta cannot later be replaced either.
    try await usageExpectRejection(
        sse([
            try usageStart(usageWire(nil)), first, try usageDelta(.object(["service_tier": .string("batch")])),
            toolEvents().last!,
        ]), streaming: true, expected: .malformedSSE)
    print("Usage merge negative cases: \(cases.count + 1); failures: 0")
}
private final class UsageReturned: @unchecked Sendable {
    private let lock = NSLock()
    private var returned = false
    func mark() { lock.withLock { returned = true } }
    var value: Bool { lock.withLock { returned } }
}
func usageGatewayAudit() async throws {
    for streaming in [false, true] {
        for fail in [false, true] {
            let wire = usageWire(.string("priority"))
            Fixture.install(streaming ? [sse(try usageEvents(wire))] : [[try usageBody(wire)]])
            let credentials = Credential()
            let audit = Audit()
            let barrier = AuditBarrier()
            audit.barrier = barrier
            audit.fail = fail
            let emitted = Emissions()
            let returned = UsageReturned()
            let (g, h, id) = try await gateway(credentials, audit, streaming: streaming)
            let p = try await g.propose(handle: h, connectionID: id, request: toolRequest(), streaming: streaming)
            let a = try await g.hostApprove(handle: h, proposal: p)
            let task = Task {
                defer { returned.mark() }
                return try await g.execute(handle: h, approval: a) { emitted.add($0, audit: audit) }
            }
            defer {
                barrier.release()
                task.cancel()
            }
            for _ in 0..<1000 {
                if barrier.isEntered { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try check(
                barrier.isEntered && !returned.value && !emitted.snapshot.contains(where: \.isTerminal),
                "tier-bearing success held before completion audit")
            try check(audit.snapshot.map(\.reason) == ["dispatch-intent"], "only intent while append held")
            barrier.release()
            let result = await task.result
            if fail {
                guard case .failure(let error) = result else { throw Failure.check("tier returned after failed audit") }
                try check(
                    error as? HostModelGatewayError == .auditFailed && !emitted.snapshot.contains(where: \.isTerminal),
                    "failed audit suppresses tier terminal delivery")
            } else {
                let completion = try result.get()
                try check(
                    completion.metadata.usage == ModelUsage(wire: wire)
                        && completion.metadata.usage?.serviceTier == .priority, "gateway returned typed usage unchanged"
                )
                try check(
                    completion.metadata.messageID == "msg_1" && completion.metadata.model == "deepseek-flash"
                        && completion.metadata.stopReason == "tool_use" && completion.blocks.count == 1,
                    "gateway preserves other metadata and blocks")
                try check(
                    audit.snapshot.map(\.reason) == ["dispatch-intent", "dispatch-completion"]
                        && audit.snapshot.last?.outcome == .completed, "one completed audit")
                if streaming {
                    try check(
                        deltaMetadata(emitted.snapshot).allSatisfy { $0.usage == completion.metadata.usage }
                            && emitted.snapshot.last?.completion == completion
                            && emitted.snapshot.filter(\.isTerminal).count == 2 && !emitted.premature,
                        "tier preserved in every audited terminal event")
                }
            }
            try check(credentials.reads == 1 && Fixture.requests.count == 1, "one synthetic gateway dispatch")
            try check(
                try body(Fixture.requests[0])["service_tier"] == nil, "response-only support adds no request tier")
        }
    }
}
func usageNumericTierRejected() async throws {
    var failures: [String] = []
    for streaming in [false, true] {
        Fixture.install(
            streaming ? [sse(try usageEvents(usageWire(.integer(1))))] : [[try usageBody(usageWire(.integer(1)))]])
        let transport = ModelTransport(credentialProvider: Credential(), configuration: configuration())
        var chunks: [ModelStreamChunk] = []
        var rejected = false
        do {
            if streaming {
                for try await chunk in transport.stream(try baseRequest()) { chunks.append(chunk) }
            } else {
                _ = try await transport.complete(baseRequest())
            }
        } catch is ModelTransportError { rejected = true }
        if !rejected || !chunks.isEmpty {
            failures.append("\(streaming ? "SSE" : "completion") accepted numeric service_tier")
        }
    }
    try check(failures.isEmpty, failures.joined(separator: "; "))
}
