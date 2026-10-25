import Foundation
import Darwin
import CryptoKit
import SandboxHost
import SandboxContracts

// Test-only. This file is never an Agent, MCP executor, or credential fallback.
enum StructuredCheckMode {
    case fixtures, live(String), invalid
    static func parse(_ args: [String]) -> Self {
        if args.isEmpty { return .fixtures }
        guard args.count == 3, args[0] == "--live", args[1] == "--evidence-dir",
              args[2].hasPrefix("/"), args[2] != "/",
              !args[2].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .invalid }
        let parts = args[2].dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return .invalid }
        return .live(args[2])
    }
}

private enum LiveFailure: Error { case rejected }
private func demand(_ condition: Bool) throws { if !condition { throw LiveFailure.rejected } }

private final class StructuredLiveCredential: ModelCredentialProvider, @unchecked Sendable {
    private let key: String
    private let lock = NSLock()
    private var reads = 0
    init(_ key: String) { self.key = key }
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { reads += 1 }
        return key
    }
    var count: Int { lock.withLock { reads } }
}

// Walk without following symlinks; refuse writable-by-others parents. Never
// remove evidence, reuse a directory, create missing parents, or overwrite files.
private func newEvidenceDirectory(_ path: String) throws -> URL {
    let components = path.split(separator: "/").map(String.init)
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    try demand(fd >= 0)
    defer { close(fd) }
    for component in components.dropLast() {
        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        try demand(next >= 0)
        close(fd); fd = next
        var info = stat()
        try demand(fstat(fd, &info) == 0 && (info.st_uid == getuid() || info.st_uid == 0) && info.st_mode & 0o022 == 0)
    }
    try demand(mkdirat(fd, components.last!, 0o700) == 0)
    let child = openat(fd, components.last!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    try demand(child >= 0)
    defer { close(child) }
    var info = stat()
    try demand(fstat(child, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700)
    return URL(fileURLWithPath: path, isDirectory: true)
}

private struct DiskEvent: Decodable {
    let runID: UUID
    let actionID: UUID?
    let reason: String
    let outcome: String
    let origin: String
}
private func diskEvents(_ url: URL) throws -> [DiskEvent] {
    let data = try Data(contentsOf: url)
    try demand(data.count <= 262_144 && (data.isEmpty || data.last == 10))
    return try data.split(separator: 10).map { try JSONDecoder().decode(DiskEvent.self, from: Data($0)) }
}
private final class TerminalObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var terminals = 0, finals = 0
    private var valid = true
    func accept(_ chunk: ModelStreamChunk, auditURL: URL, action: UUID) {
        guard chunk.isTerminal else { return }
        // Read the actual fsynced JSONL inside EACH delta/stop callback. An
        // in-memory append notification is deliberately not accepted as evidence.
        let readable: Bool
        do {
            let records = try diskEvents(auditURL).filter { $0.actionID == action }
            readable = records.filter { $0.reason == "dispatch-intent" }.count == 1 &&
                records.filter { $0.reason == "dispatch-completion" && $0.outcome == "completed" && $0.origin == "hostEnforcement" }.count == 1
        } catch { readable = false }
        lock.withLock { terminals += 1; if chunk.isFinal { finals += 1 }; valid = valid && readable }
    }
    func verify(streaming: Bool) throws {
        try lock.withLock { try demand(valid && (streaming ? terminals >= 2 && finals == 1 : terminals == 0 && finals == 0)) }
    }
}

private struct LiveCaseReport: Codable {
    let name: String
    let runID: UUID
    var status = "NOT_RUN"
    var startedCalls = 0
    var startIndeterminate = false
    var credentialReads = 0
    var intents = 0
    var completions = 0
    var toolUses = 0
    var finalTextBytes = 0
    var stopLabels: [String] = []
    var stopped = false
    var auditCountsMatch = false
}
private struct LiveSummary: Encodable {
    let scope = "REAL_MODEL_PROTOCOL_SYNTHETIC_TOOL_RESULT"
    let excluded = "Agent/MCP/VM/Keychain NOT_RUN"
    let auditSource = "audit.jsonl"
    let status: String
    let cases: [LiveCaseReport]
    let auditSHA256: String
}

private func fixtureTool() throws -> ModelToolDefinition {
    try ModelToolDefinition(name: "echo_fixture", description: "Test fixture only; no real tool executes", inputSchema: .object([
        "type": .string("object"), "properties": .object(["text": .object(["type": .string("string"), "enum": .array([.string("sandbox-tool-check")])])]),
        "required": .array([.string("text")]), "additionalProperties": .bool(false)
    ]))
}
private func fixtureResults(_ completion: ModelCompletion) throws -> [ModelBlock] {
    try demand(completion.metadata.stopReason == "tool_use" && completion.blocks.count <= 128)
    var seen = Set<String>(), results: [ModelBlock] = []
    for block in completion.blocks {
        switch block {
        case .text(let text): try demand(text.utf8.count <= 4096)
        case .toolUse(let id, let name, let input):
            try demand(ModelBlock.validID(id) && ModelBlock.validName(name) && seen.insert(id).inserted && name == "echo_fixture" && input == .object(["text": .string("sandbox-tool-check")]))
            results.append(.toolResult(toolUseID: id, content: "SYNTHETIC fixture result: sandbox-tool-check. No tool executed.", isError: false))
        case .toolResult: throw LiveFailure.rejected
        }
    }
    try demand(!results.isEmpty && results.count <= 128)
    return results
}

private func liveCase(streaming: Bool, key: String, audit: JSONLAuditSink, auditURL: URL) async -> LiveCaseReport {
    var report = LiveCaseReport(name: streaming ? "stream" : "nonstream", runID: UUID())
    report.status = "FAIL"
    let credential = StructuredLiveCredential(key)
    var gateway: HostModelGateway?, handle: HostModelRunHandle?
    var actions: [UUID] = []
    do {
        let connection = HostModelConnection(connectionID: UUID(), accountID: UUID(), accountBindingVersion: 1, routeVersion: 1,
            model: .deepSeekFlash, protocol: .anthropic, credentialProvider: credential)
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
        let now = Date()
        let grant = try RunGrant(runID: report.runID, epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
            workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "trusted-structured-test-driver",
            workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
            connections: [ConnectionGrant(connectionID: connection.connectionID, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])], explicitDenies: [],
            resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 268_435_456, diskBytes: 1_073_741_824, messageBytes: 65_536, concurrentRequests: 1))
        let g = try HostModelGateway(connections: [connection], auditSink: audit)
        gateway = g
        let h = try await g.install(grant: grant); handle = h
        var messages = try [FixedMessage(role: .user, content: "Call echo_fixture with text exactly sandbox-tool-check. After the synthetic fixture result, reply briefly with OK.")]
        for turn in 0..<2 {
            let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic, messages: messages, maxOutputTokens: 64,
                tools: [fixtureTool()], toolChoice: ModelToolChoice(type: turn == 0 ? .tool : .none, name: turn == 0 ? "echo_fixture" : nil))
            let proposal = try await g.propose(handle: h, connectionID: connection.connectionID, request: request, streaming: streaming)
            let approval = try await g.hostApprove(handle: h, proposal: proposal)
            actions.append(proposal.actionID)
            let observation = TerminalObservation()
            let completion: ModelCompletion
            do {
                completion = try await g.execute(handle: h, approval: approval) { observation.accept($0, auditURL: auditURL, action: proposal.actionID) }
                report.startedCalls += 1
            } catch {
                if let error = error as? HostModelGatewayError {
                    if error == .outcomeUnknown { report.startedCalls += 1 }
                    else if error == .auditFailed { report.startIndeterminate = true }
                } else { report.startIndeterminate = true }
                throw LiveFailure.rejected
            }
            try observation.verify(streaming: streaming)
            try demand(completion.metadata.usage?.outputTokens.map { $0 <= 64 } ?? false)
            if turn == 0 {
                let results = try fixtureResults(completion)
                report.toolUses = results.count; report.stopLabels.append("tool_use")
                messages += try [FixedMessage(role: .assistant, blocks: completion.blocks), FixedMessage(role: .user, blocks: results)]
            } else {
                try demand(completion.metadata.stopReason == "end_turn" && !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && completion.text.utf8.count <= 4096)
                try demand(completion.blocks.allSatisfy { if case .text = $0 { true } else { false } })
                report.finalTextBytes = completion.text.utf8.count; report.stopLabels.append("end_turn")
            }
        }
        report.status = "PASS"
    } catch { report.status = "FAIL" } // Never interpolate arbitrary errors or provider data.
    if let gateway, let handle {
        do { try await gateway.stop(handle: handle); report.stopped = try await gateway.isRevoked(handle: handle) }
        catch { report.status = "FAIL" }
    }
    report.credentialReads = credential.count
    do {
        let events = try diskEvents(auditURL).filter { $0.runID == report.runID }
        let intents = events.filter { $0.reason == "dispatch-intent" }
        let completions = events.filter { $0.reason == "dispatch-completion" }
        report.intents = intents.count; report.completions = completions.count
        let started = completions.filter { $0.outcome == "completed" || $0.outcome == "unknown" }.count
        report.auditCountsMatch = !report.startIndeterminate && intents.count == completions.count && started == report.startedCalls && actions.allSatisfy { action in
            let i = intents.filter { $0.actionID == action }, c = completions.filter { $0.actionID == action }
            return (i.isEmpty && c.isEmpty) || (i.count == 1 && c.count == 1)
        }
        try demand(report.auditCountsMatch)
        if report.status == "PASS" {
            try demand(report.stopped && report.startedCalls == 2 && report.credentialReads == 2 && intents.count == 2 && completions.allSatisfy { $0.outcome == "completed" })
        }
    } catch { report.status = "FAIL" }
    return report
}

func runStructuredLiveChecks(evidencePath: String) async -> Int32 {
    // This is the sole key lookup. The CLI must select the explicit live branch
    // first; absence gates ALL filesystem, provider construction and networking.
    guard let key = ProcessInfo.processInfo.environment["TEST_DEEPSEEK_KEY"], !key.isEmpty else {
        print("BLOCKED structured live: missing TEST_DEEPSEEK_KEY")
        return 2
    }
    do {
        let directory = try newEvidenceDirectory(evidencePath)
        let auditURL = directory.appendingPathComponent("audit.jsonl")
        let audit = try JSONLAuditSink(newFileAt: auditURL)
        var cases: [LiveCaseReport] = []
        for streaming in [false, true] {
            if cases.contains(where: { $0.status != "PASS" }) {
                cases.append(LiveCaseReport(name: "stream", runID: UUID()))
                break
            }
            cases.append(await liveCase(streaming: streaming, key: key, audit: audit, auditURL: auditURL))
        }
        let passed = cases.count == 2 && cases.allSatisfy { $0.status == "PASS" }
        let digest = SHA256.hash(data: try Data(contentsOf: auditURL)).map { String(format: "%02x", $0) }.joined()
        let summary = LiveSummary(status: passed ? "PASS" : "FAIL", cases: cases, auditSHA256: digest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(summary)
        let fd = open(directory.appendingPathComponent("summary.json").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try demand(fd >= 0)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data); try file.synchronize(); try file.close()
        print(String(decoding: data, as: UTF8.self))
        return passed ? 0 : 1
    } catch {
        print("FAIL structured live: sanitized setup/evidence failure; no full PASS")
        return 1
    }
}
