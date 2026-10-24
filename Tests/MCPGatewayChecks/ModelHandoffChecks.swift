import Foundation
import SandboxHost
import SandboxContracts

final class OfflineModelCredential: ModelCredentialProvider {
    func credential(for model: FixedModel) throws -> String { "synthetic-offline-only" }
}
final class OfflineModelState: @unchecked Sendable {
    let lock = NSLock(); var requests: [URLRequest] = []
}
final class OfflineModel: URLProtocol {
    static let state = OfflineModelState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = Self.state.lock.withLock { Self.state.requests.append(request); return Self.state.requests.count }
        let body = index == 1 ? #"{"id":"offline_1","type":"message","role":"assistant","model":"deepseek-flash","content":[{"type":"tool_use","id":"read_repo_1","name":"repo_read","input":{"repo":"A"}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}"# : #"{"id":"offline_2","type":"message","role":"assistant","model":"deepseek-flash","content":[{"type":"text","text":"offline continuation"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func modelHandoff(_ c: Context) async throws {
    try phase("model-handoff")
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OfflineModel.self]
    let id = UUID(); let audit = Audit()
    let model = try HostModelGateway(connections: [HostModelConnection(connectionID: id, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash, protocol: .anthropic, credentialProvider: OfflineModelCredential(), configuration: configuration)], auditSink: audit)
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
    let g = try RunGrant(runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-5), expiresAt: Date().addingTimeInterval(120), workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "offline", workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(), connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 65536, concurrentRequests: 1))
    let handle = try await model.install(grant: g)
    let initial = try FixedMessage(role: .user, content: "Read A")
    let request = try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic, messages: [initial], maxOutputTokens: 32, tools: [ModelToolDefinition(name: "repo_read", inputSchema: .object(["type": .string("object")]))])
    let p = try await model.propose(handle: handle, connectionID: id, request: request, streaming: false)
    let a = try await model.hostApprove(handle: handle, proposal: p)
    let completed = try await model.execute(handle: handle, approval: a)
    let reads = c.credentials.count
    let mcpProposal = try await MCPModelHandoff.propose(completion: completed, gateway: c.gateway, handle: c.handle, connectionID: c.id)
    try check(c.credentials.count == reads, "model tool block is not approval")
    let mcpApproval = try await c.gateway.hostApprove(handle: c.handle, proposal: mcpProposal)
    let result = try await c.execute(mcpApproval)
    let block = try MCPModelHandoff.toolResult(result, matching: "read_repo_1")
    try check(block == .toolResult(toolUseID: "read_repo_1", content: "repo-A-initial", isError: false), "matching real MCP result")
    try await denied { _ = try MCPModelHandoff.toolResult(result, matching: "wrong-id") }
    let next = try FixedModelRequest(model: .deepSeekFlash, protocol: .anthropic, messages: [initial, FixedMessage(role: .assistant, blocks: completed.blocks), FixedMessage(role: .user, blocks: [block])], maxOutputTokens: 32, tools: [ModelToolDefinition(name: "repo_read", inputSchema: .object(["type": .string("object")]))])
    let np = try await model.propose(handle: handle, connectionID: id, request: next, streaming: false)
    let na = try await model.hostApprove(handle: handle, proposal: np)
    let final = try await model.execute(handle: handle, approval: na)
    try check(final.text == "offline continuation" && audit.snapshot.count == 4, "second offline audited model turn")
    try check(OfflineModel.state.lock.withLock { OfflineModel.state.requests.count } == 2, "offline turns")
    try report("model-handoff", hits: 1, reads: 1)
}
