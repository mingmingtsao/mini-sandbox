import Foundation
import SandboxContracts
import SandboxHost

func nativeEffortControls() async throws {
    for effort in ["low", "high", "max"] {
        Fixture.install([[Data(toolReply.utf8)]])
        let credential = Credential()
        let audit = Audit()
        let (g, h, id) = try await gateway(credential, audit)
        var object = try ModelJSON.parse(Data(nativeFixture.utf8)).object!
        object["output_config"] = .object(["effort": .string(effort)])
        let p = try await g.proposeNative(handle: h, connectionID: id, body: nativeBytes(object), streaming: false)
        let a = try await g.hostApprove(handle: h, proposal: p)
        _ = try await g.execute(handle: h, approval: a)
        object["thinking"] = .object(["type": .string("disabled")])
        try check(try nativeWireBytes(Fixture.requests[0]) == nativeBytes(object), "native effort meaning changed")
        let resumes = try await g.resumedTaskCount(handle: h)
        try check(credential.reads == 1 && resumes == 1 && Fixture.requests.count == 1, "native effort counters")
        print(
            "Native effort \(effort) credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count)"
        )
    }
}

func nativeIdentityRejections() async throws {
    for mode in ["protocol", "account", "route", "epoch", "handle"] {
        Fixture.install([])
        let credential = Credential()
        let audit = Audit()
        let id = UUID()
        let account = UUID()
        func connection(
            accountID: UUID, accountVersion: UInt64 = 1, route: UInt64 = 1, kind: FixedProtocol = .anthropic
        ) -> HostModelConnection {
            HostModelConnection(
                connectionID: id, accountID: accountID, accountBindingVersion: accountVersion, routeVersion: route,
                model: .deepSeekFlash, protocol: kind, credentialProvider: credential, configuration: configuration())
        }
        let authority = RunAuthorizationController(auditSink: audit)
        let g = try HostModelGateway(
            connections: [connection(accountID: account, kind: mode == "protocol" ? .openAI : .anthropic)],
            auditSink: audit, authority: authority)
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        func grant(epoch: UInt64) throws -> RunGrant {
            try RunGrant(
                runID: UUID(), epoch: epoch, createdAt: Date().addingTimeInterval(-10),
                expiresAt: Date().addingTimeInterval(600), workloadImageDigest: String(repeating: "a", count: 64),
                agentAdapterVersion: "fixture", workspaceSnapshotID: UUID(),
                policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
                connections: [
                    ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])
                ], explicitDenies: [],
                resourceLimits: ResourceLimits(
                    cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 65536, concurrentRequests: 2))
        }
        let original = try grant(epoch: 1)
        let authorityHandle = try await authority.install(grant: original)
        let h = try await g.install(grant: original, authorityHandle: authorityHandle)
        if mode == "protocol" {
            do {
                _ = try await g.proposeNative(
                    handle: h, connectionID: id, body: Data(nativeFixture.utf8), streaming: false)
                throw Failure.check("native wrong protocol accepted")
            } catch HostModelGatewayError.denied {}
        } else {
            let p = try await g.proposeNative(
                handle: h, connectionID: id, body: Data(nativeFixture.utf8), streaming: false)
            if mode == "epoch" {
                let b = try nativePending(p).binding
                let wrong = try ActionBinding(
                    runID: b.runID, epoch: 2, grantDigest: b.grantDigest, connectionID: b.connectionID,
                    operation: b.operation, schemaDigest: b.schemaDigest, resolvedResource: b.resolvedResource,
                    canonicalRequest: b.canonicalRequest)
                do {
                    _ = try await authority.propose(
                        handle: authorityHandle, binding: wrong, display: "native epoch fixture")
                    throw Failure.check("native wrong epoch accepted")
                } catch AuthorizationError.wrongEpoch {}
            } else {
                let a = try await g.hostApprove(handle: h, proposal: p)
                if mode == "handle" {
                    let other = try await g.install(grant: grant(epoch: 2))
                    do {
                        _ = try await g.execute(handle: other, approval: a)
                        throw Failure.check("native approval crossed run epoch")
                    } catch HostModelGatewayError.invalidHandle {}
                } else {
                    let replacement =
                        mode == "account"
                        ? connection(accountID: UUID(), accountVersion: 2)
                        : connection(accountID: account, route: 2, kind: .openAI)
                    try await g.updateConnection(replacement)
                    do {
                        _ = try await g.execute(handle: h, approval: a)
                        throw Failure.check("native changed identity accepted")
                    } catch HostModelGatewayError.invalidConnection {}
                }
            }
        }
        let resumes = try await g.resumedTaskCount(handle: h)
        try check(credential.reads == 0 && Fixture.requests.isEmpty && resumes == 0, "native identity side effects")
        print(
            "Native identity \(mode) credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count)"
        )
    }
}

func nativeShapeControls() async throws {
    let seed = try ModelJSON.parse(Data(nativeFixture.utf8)).object!
    var variants: [[String: ModelJSON]] = [seed]
    var root = seed
    root["system"] = .string("plain system")
    root["tool_choice"] = .object(["type": .string("tool"), "name": .string("weather")])
    variants.append(root)
    root = seed
    var messages = root["messages"]!.array!
    var result = messages[2].object!
    result["content"] = .array([
        .object([
            "type": .string("tool_result"), "tool_use_id": .string("tool_1"), "content": .string("exact result"),
            "cache_control": .object(["type": .string("ephemeral")]),
        ])
    ])
    messages[2] = .object(result)
    root["messages"] = .array(messages)
    variants.append(root)
    root = [
        "model": .string("deepseek-flash"), "max_tokens": .integer(1), "stream": .bool(false),
        "messages": .array([.object(["role": .string("user"), "content": .string("simple")])]),
    ]
    variants.append(root)
    for (index, object) in variants.enumerated() {
        Fixture.install([[Data(toolReply.utf8)]])
        let credential = Credential()
        let audit = Audit()
        let (g, h, id) = try await gateway(credential, audit)
        let p = try await g.proposeNative(handle: h, connectionID: id, body: nativeBytes(object), streaming: false)
        let a = try await g.hostApprove(handle: h, proposal: p)
        let result = try await g.execute(handle: h, approval: a)
        var expected = object
        expected["thinking"] = .object(["type": .string("disabled")])
        try check(try nativeWireBytes(Fixture.requests[0]) == nativeBytes(expected), "native shape byte preservation")
        try check(result.blocks.count == 1 && result.metadata.stopReason == "tool_use", "native tool-only response")
        let resumes = try await g.resumedTaskCount(handle: h)
        try check(credential.reads == 1 && resumes == 1 && Fixture.requests.count == 1, "native shape counters")
        print(
            "Native shape \(index) credential_reads=\(credential.reads) resume_calls=\(resumes) arrivals=\(Fixture.requests.count)"
        )
    }
}
