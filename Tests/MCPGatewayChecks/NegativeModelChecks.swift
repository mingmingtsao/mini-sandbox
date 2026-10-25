import Foundation
import SandboxContracts
import SandboxHost

final class NegativeModelCredential: ModelCredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let token = UUID().uuidString
    var reads: Int { lock.withLock { count } }
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { count += 1 }
        return token
    }
}
final class NegativeModelState: @unchecked Sendable {
    let lock = NSLock()
    var mode = ""
    var count = 0
    func reset(_ mode: String) {
        lock.withLock {
            self.mode = mode
            count = 0
        }
    }
    var requests: Int { lock.withLock { count } }
}
final class NegativeModel: URLProtocol {
    static let state = NegativeModelState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.lock.withLock {
            Self.state.count += 1
            return Self.state.mode
        }
        if mode == "failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(
            self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        let body: String
        if mode == "provisional" {
            body =
                "data: "
                + #"{"type":"message_start","message":{"id":"offline_neg","type":"message","role":"assistant","model":"deepseek-flash","content":[],"stop_reason":null,"usage":{"input_tokens":1,"output_tokens":0}}}"#
                + "\n\ndata: "
                + #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"negative_tool","name":"repo_read","input":{}}}"#
                + "\n\n"
        } else {
            let write = ["write", "drop-write"].contains(mode)
            let input =
                write ? #"{"repo":"A","content":"changed"}"# : (mode == "B" ? #"{"repo":"B"}"# : #"{"repo":"A"}"#)
            let content =
                mode == "non-tool"
                ? #"{"type":"text","text":"no tool"}"#
                : "{\"type\":\"tool_use\",\"id\":\"negative_tool\",\"name\":\"\(write ? "repo_write" : "repo_read")\",\"input\":\(input)}"
            let stop = mode == "non-tool" ? "end_turn" : (mode == "truncated" ? "max_tokens" : "tool_use")
            body =
                "{\"id\":\"offline_neg\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"deepseek-flash\",\"content\":[\(content)],\"stop_reason\":\"\(stop)\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class ProvisionalObservation: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    var terminal = 0
    func observe(_ chunk: ModelStreamChunk) {
        lock.withLock {
            count += 1
            if chunk.isTerminal { terminal += 1 }
        }
    }
}
func negativeCompletion(_ mode: String) async throws -> ModelCompletion {
    NegativeModel.state.reset(mode)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NegativeModel.self]
    let id = UUID()
    let audit = Audit()
    let credential = NegativeModelCredential()
    let model = try HostModelGateway(
        connections: [
            HostModelConnection(
                connectionID: id, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash,
                protocol: .anthropic, credentialProvider: credential, configuration: configuration)
        ], auditSink: audit)
    let streaming = mode == "provisional"
    let scope = try ResourceScope(
        service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
    let g = try RunGrant(
        runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-5), expiresAt: Date().addingTimeInterval(900),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "offline",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
        connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])],
        explicitDenies: [],
        resourceLimits: ResourceLimits(
            cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 65536, concurrentRequests: 1))
    let handle = try await model.install(grant: g)
    let request = try FixedModelRequest(
        model: .deepSeekFlash, protocol: .anthropic,
        messages: [FixedMessage(role: .user, content: "synthetic negative handoff")], maxOutputTokens: 32,
        tools: [
            ModelToolDefinition(name: "repo_read", inputSchema: .object(["type": .string("object")])),
            ModelToolDefinition(name: "repo_write", inputSchema: .object(["type": .string("object")])),
        ])
    let p = try await model.propose(handle: handle, connectionID: id, request: request, streaming: streaming)
    let a = try await model.hostApprove(handle: handle, proposal: p)
    let observation = ProvisionalObservation()
    do {
        let result = try await model.execute(handle: handle, approval: a, emit: { observation.observe($0) })
        try check(
            credential.reads == 1 && audit.snapshot.count == 2 && audit.snapshot.last?.outcome == .completed,
            "model completion audit and credential count")
        output(
            "MODEL negative-model-" + mode
                + " requests=\(NegativeModel.state.requests) credential_reads=\(credential.reads) terminal=\(observation.lock.withLock { observation.terminal })"
        )
        return result
    } catch {
        try check(observation.lock.withLock { observation.terminal == 0 }, "failed model emitted terminal completion")
        if streaming {
            try check(observation.lock.withLock { observation.count > 0 }, "provisional fixture did not emit")
        }
        try check(
            credential.reads == 1 && audit.snapshot.count == 2 && audit.snapshot.last?.outcome == .unknown,
            "failed model audit and credential count")
        output(
            "MODEL negative-model-" + mode
                + " requests=\(NegativeModel.state.requests) credential_reads=\(credential.reads) terminal=\(observation.lock.withLock { observation.terminal })"
        )
        throw error
    }
}
func negativeModelChecks(_ port: UInt16, _ token: String) async throws {
    let c = try await make(port, token)
    try await discover(c, name: "negative-model-discovery")
    for mode in ["B", "write", "denied", "unapproved", "non-tool", "truncated", "provisional", "failure"] {
        let name = "negative-model-" + mode
        try phase(name)
        if ["truncated", "provisional", "failure"].contains(mode) {
            try await expectError(HostModelGatewayError.outcomeUnknown) { _ = try await negativeCompletion(mode) }
        } else {
            let completed = try await negativeCompletion(mode)
            if ["B", "write", "non-tool"].contains(mode) {
                try await denied {
                    _ = try await MCPModelHandoff.propose(
                        completion: completed, gateway: c.gateway, handle: c.handle, connectionID: c.id)
                }
            } else {
                let proposal = try await MCPModelHandoff.propose(
                    completion: completed, gateway: c.gateway, handle: c.handle, connectionID: c.id)
                if mode == "denied" {
                    try await c.gateway.hostDeny(handle: c.handle, proposal: proposal)
                    try await denied(AuthorizationError.actionDenied) {
                        _ = try await c.gateway.hostApprove(handle: c.handle, proposal: proposal)
                    }
                }
            }
        }
        try check(NegativeModel.state.requests == 1, "negative handoff caused next model turn")
        try report(name, hits: 0, reads: 0)
    }
    let w = try await make(port, token, write: true)
    try await discover(w, name: "negative-model-write-discovery")
    try phase("negative-model-drop-write")
    let completed = try await negativeCompletion("drop-write")
    let proposal = try await MCPModelHandoff.propose(
        completion: completed, gateway: w.gateway, handle: w.handle, connectionID: w.id)
    let approval = try await w.gateway.hostApprove(handle: w.handle, proposal: proposal)
    try await denied(.outcomeUnknown) { _ = try await w.execute(approval) }
    try await denied(AuthorizationError.ticketAlreadyConsumed) { _ = try await w.execute(approval) }
    try check(
        w.audit.snapshot.last?.outcome == .unknown && NegativeModel.state.requests == 1,
        "lost write completion or next model turn")
    try report("negative-model-drop-write", hits: 1, reads: 1)
}
