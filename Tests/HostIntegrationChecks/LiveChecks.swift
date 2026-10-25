import Foundation
import SandboxContracts
import SandboxHost

private final class LiveCredential: ModelCredentialProvider, @unchecked Sendable {
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

private final class LiveAudit: SynchronousAuditSink, @unchecked Sendable {
    private let disk: JSONLAuditSink
    private let lock = NSLock()
    private var events: [SecurityEvent] = []
    init(url: URL) throws { disk = try JSONLAuditSink(newFileAt: url) }
    func append(_ event: SecurityEvent) throws {
        try lock.withLock {
            try disk.append(event)
            events.append(event)
        }
    }
    var snapshot: [SecurityEvent] { lock.withLock { events } }
}

private final class LiveStreamObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var finals = 0
    private var finalBeforeAudit = false
    func accept(_ chunk: ModelStreamChunk, audited: Bool) {
        lock.withLock {
            if chunk.isFinal {
                finals += 1
                finalBeforeAudit = finalBeforeAudit || !audited
            } else {
                text += chunk.text
            }
        }
    }
    var snapshot: (String, Int, Bool) { lock.withLock { (text, finals, finalBeforeAudit) } }
}

/// Opt-in host-only smoke. Normal fixture checks never read a key or call a service.
/// It does not validate Keychain, guest isolation, native UI consent, or an Agent workflow.
func runGatewayLiveChecks() async -> Int32 {
    guard let key = ProcessInfo.processInfo.environment["TEST_DEEPSEEK_KEY"], !key.isEmpty else {
        print("BLOCKED live gateway: TEST_DEEPSEEK_KEY not set")
        return 2
    }
    let prompt = "Reply with exactly OK."
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("host-model-live-\(UUID()).jsonl")
    do {
        let audit = try LiveAudit(url: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let provider = LiveCredential(key)
        let account = UUID()
        let routes = [FixedProtocol.openAI, .anthropic].map { kind in
            HostModelConnection(
                connectionID: UUID(), accountID: account,
                accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash,
                protocol: kind, credentialProvider: provider)
        }
        let scopes: Set<ResourceScope> = [
            try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete"),
            try ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream"),
        ]
        let now = Date()
        let grant = try RunGrant(
            runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(600), workloadImageDigest: String(repeating: "a", count: 64),
            agentAdapterVersion: "host-live-smoke", workspaceSnapshotID: UUID(),
            policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
            connections: routes.map {
                try ConnectionGrant(
                    connectionID: $0.connectionID,
                    accountBindingVersion: 1, routeVersion: 1, scopes: scopes)
            }, explicitDenies: [],
            resourceLimits: ResourceLimits(
                cpuCount: 1, memoryBytes: 256 * 1024 * 1024,
                diskBytes: 1024 * 1024 * 1024, messageBytes: 65_536, concurrentRequests: 1))
        let gateway = try HostModelGateway(connections: routes, auditSink: audit)
        let handle = try await gateway.install(grant: grant)
        var results: [[String: Any]] = []
        do {
            for route in routes {
                for streaming in [false, true] {
                    let request = try FixedModelRequest(
                        model: .deepSeekFlash, protocol: route.protocol,
                        messages: [FixedMessage(role: .user, content: prompt)], maxOutputTokens: 32)
                    let proposal = try await gateway.propose(
                        handle: handle, connectionID: route.connectionID,
                        request: request, streaming: streaming)
                    let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
                    let observation = LiveStreamObservation()
                    let result = try await gateway.execute(handle: handle, approval: approval) { chunk in
                        let recorded = audit.snapshot.contains {
                            $0.actionID == proposal.actionID && $0.reason == "dispatch-completion"
                                && $0.outcome == .completed
                        }
                        observation.accept(chunk, audited: recorded)
                    }
                    try require(!result.text.isEmpty, "live response must contain text")
                    let observed = observation.snapshot
                    if streaming {
                        try require(
                            observed.0 == result.text && observed.1 == 1 && !observed.2,
                            "live final follows durable completion")
                    }
                    let pair = audit.snapshot.filter { $0.actionID == proposal.actionID }
                    try require(
                        pair.map(\.reason) == ["dispatch-intent", "dispatch-completion"]
                            && pair.last?.outcome == .completed, "live request has exact audited lifecycle")
                    results.append(["protocol": route.protocol.rawValue, "streaming": streaming, "status": "PASS"])
                }
            }
            try await gateway.stop(handle: handle)
        } catch {
            try? await gateway.stop(handle: handle)
            throw error
        }
        let records = try String(contentsOf: path, encoding: .utf8)
        try require(!records.contains(key) && !records.contains(prompt), "live audit must exclude key and prompt")
        try require(results.count == 4, "four protocol/mode checks required")
        try require(provider.count == results.count, "one host credential read per dispatched live request")
        let summary: [String: Any] = [
            "checks": results, "passed": results.count,
            "credential_reads": provider.count, "audit_excludes_key_and_prompt": true,
            "scope": "host-only trusted test grants; Keychain/VM/Agent/UI NOT_RUN",
        ]
        print(
            String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self)
        )
        return 0
    } catch {
        // Do not render arbitrary errors or provider response text in live diagnostics.
        print("FAIL live gateway smoke; no credential, prompt, or response body logged")
        return 1
    }
}
