import Foundation
import SandboxContracts
import SandboxHost

func actualQueuedModel(streaming: Bool, stopBeforeConsumer: Bool, acceptFirst: Bool = false, anthropic: Bool = false)
    async throws
{
    let id = UUID()
    let audit = Audit()
    let credentials = Credentials()
    OfflineProtocol.probe.setResponse(
        streaming
            ? Data(
                "data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"second\"}}]}\n\ndata: [DONE]\n\n"
                    .utf8) : Data("{\"choices\":[{\"message\":{\"content\":\"offline-result\"}}]}".utf8))
    if anthropic {
        let events = [
            #"{"type":"message_start","message":{"id":"offline_1","type":"message","role":"assistant","model":"deepseek-flash","content":[],"stop_reason":null,"usage":{"input_tokens":1,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"first"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
            #"{"type":"message_stop"}"#,
        ]
        OfflineProtocol.probe.setResponse(Data(events.map { "data: " + $0 + "\n\n" }.joined().utf8))
    }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfflineProtocol.self]
    let connection = HostModelConnection(
        connectionID: id, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash,
        protocol: anthropic ? .anthropic : .openAI, credentialProvider: credentials, configuration: config)
    let scope = try ResourceScope(
        service: "model", resource: "deepseek-flash", operation: streaming ? "stream" : "complete")
    let grant = try RunGrant(
        runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1), expiresAt: Date().addingTimeInterval(600),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "offline",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
        connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])],
        explicitDenies: [],
        resourceLimits: ResourceLimits(
            cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
    let gateway = try HostModelGateway(connections: [connection], auditSink: audit)
    let handle = try await gateway.install(grant: grant)
    let lifecycle = try await gateway.lifecycle(handle: handle)
    let request = try FixedModelRequest(
        model: .deepSeekFlash, protocol: anthropic ? .anthropic : .openAI,
        messages: [FixedMessage(role: .user, content: "offline")], maxOutputTokens: 32)
    let proposal = try await gateway.propose(handle: handle, connectionID: id, request: request, streaming: streaming)
    let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
    let output = try await gateway.makeOutput(handle: handle, approval: approval)
    let before = OfflineProtocol.probe.count
    try await gateway.execute(handle: handle, approval: approval, output: output)
    let queued = anthropic ? 6 : (streaming ? 3 : 1)
    try check(
        output.summary.queuedEvents == queued && output.summary.acceptedEvents == 0,
        "producer queue falsely claimed acceptance")
    if stopBeforeConsumer {
        if acceptFirst {
            repeat {
                try check(try output.acceptNext(), "first real stream chunk missing")
            } while output.summary.acceptedTextBytes == 0
        }
        lifecycle.terminate(.stopped)
        do {
            _ = try output.acceptNext()
            throw Failure(message: "queued actual output delivered after stop")
        } catch is AuthorizationError {}
    } else {
        while try output.acceptNext() {}
    }
    let expected = stopBeforeConsumer ? (acceptFirst ? (anthropic ? 3 : 1) : 0) : queued
    try check(
        output.summary.acceptedEvents == expected && output.summary.acceptedFinals == (stopBeforeConsumer ? 0 : 1),
        "actual consumer state incorrect")
    try check(
        credentials.count == 1 && OfflineProtocol.probe.count - before == 1 && audit.completions.count == 1,
        "actual effect counters/audit")
    try check(try await gateway.resumedTaskCount(handle: handle) == 1, "actual synchronous resume counter")
    try check(
        output.summary.acceptedMetadata == (anthropic && !stopBeforeConsumer ? 1 : 0), "actual metadata acceptance")
    print(
        "PASS actual-model-\(anthropic ? "metadata" : (streaming ? "stream" : "nonstream"))-\(acceptFirst ? "first-then-stop" : (stopBeforeConsumer ? "stop" : "accept")) credential_reads=1 actual_resume_calls=1 callback_arrivals=1 accepted=\(expected)"
    )
}
