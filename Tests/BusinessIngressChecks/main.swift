import Foundation
import SandboxContracts
@testable import SandboxHost

enum CheckFailure: Error { case failed(String) }
func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    if try !condition() { throw CheckFailure.failed(label) }
}
func rejected(_ label: String, _ action: () throws -> Void) throws {
    do { try action(); throw CheckFailure.failed(label) }
    catch is BusinessHTTPIngress.Failure {} catch is ModelTransportError {} catch is HostModelGatewayError {} catch is AuthorizationError {}
}
func wire(_ body: String, target: String = "/v1/messages?beta=true", headers: String = "", length: String? = nil, beta: String? = ClaudeRequestSelectors.pinned.beta) -> Data {
    var value = "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1:4061\r\nAuthorization: Bearer mini-sandbox-local-only\r\nContent-Type: application/json\r\nAnthropic-Version: 2023-06-01\r\nContent-Length: \(length ?? String(body.utf8.count))\r\n"
    if let beta { value += "Anthropic-Beta: \(beta)\r\nAnthropic-Dangerous-Direct-Browser-Access: true\r\n" }
    return Data((value + headers + "\r\n" + body).utf8)
}
let body = #"{"model":"deepseek-flash","max_tokens":512,"stream":true,"system":[{"type":"text","text":"top","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":"fix the project"},{"role":"system","content":[{"type":"text","text":"local context"}]}],"tools":[{"name":"Read","input_schema":{"type":"object"}}]}"#
final class Credential: ModelCredentialProvider, @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func credential(for model: FixedModel) throws -> String { lock.withLock { count += 1 }; return "fake-unused-" + UUID().uuidString }
    var reads: Int { lock.withLock { count } }
}
final class Audit: SynchronousAuditSink, @unchecked Sendable {
    func append(_ event: SecurityEvent) throws {}
}
func installed(_ credential: Credential, messageBytes: Int = 65_536) async throws -> (RunAuthorizationController, HostRunHandle, HostModelConnection) {
    let id = UUID(), now = Date()
    let connection = HostModelConnection(connectionID: id, accountID: UUID(), accountBindingVersion: 1, routeVersion: 1,
        model: .deepSeekFlash, protocol: .anthropic, credentialProvider: credential)
    let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream")
    let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(600),
        workloadImageDigest: String(repeating: "a", count: 64), agentAdapterVersion: "claude-2.1.309",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "b", count: 64), approvalSnapshotID: UUID(),
        connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: [scope])],
        explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: messageBytes, concurrentRequests: 1))
    let authority = RunAuthorizationController(auditSink: Audit())
    return (authority, try await authority.install(grant: grant), connection)
}

@main struct Checks {
    static func main() async {
        do {
            let bytes = wire(body)
            for n in 0..<bytes.count {
                try check(try BusinessHTTPIngress.parse(Data(bytes.prefix(n))) == nil, "fragment \(n)")
            }
            let ingress = try BusinessHTTPIngress.parse(bytes)!
            let request = try ingress.claudeRequest()
            try check(request.body["messages"] == ModelJSON.parse(Data(body.utf8))["messages"], "system position and content preserved")
            try check(request.body["thinking"] == .object(["type": .string("disabled")]), "thinking policy expanded before approval")
            try rejected("legacy native dialect unchanged") { _ = try ingress.nativeRequest() }
            for (name, bad) in [
                ("pipeline", bytes + bytes), ("smuggled trailing byte", bytes + Data([0])),
                ("duplicate length", wire(body, headers: "Content-Length: 1\r\n")),
                ("chunked", wire(body, headers: "Transfer-Encoding: chunked\r\n")),
                ("gzip", wire(body, headers: "Content-Encoding: gzip\r\n")),
                ("expect", wire(body, headers: "Expect: 100-continue\r\n")),
                ("upgrade", wire(body, headers: "Upgrade: websocket\r\n")),
                ("api key", wire(body, headers: "X-Api-Key: unexpected\r\n")),
                ("unknown semantic header", wire(body, headers: "Anthropic-Workspace-Id: another-account\r\n")),
                ("unknown header", wire(body, headers: "X-Unknown: private-sentinel\r\n")),
                ("fold", wire(body, headers: " X-Unknown: x\r\n")),
                ("key whitespace", wire(body, headers: "X-Unknown : x\r\n")),
                ("value control", wire(body, headers: "X-Unknown: x\u{7f}\r\n")),
                ("negative length", wire(body, length: "-1")), ("leading zero", wire(body, length: "00012")),
                ("overflow", wire(body, length: "999999999999999999999")),
                ("large body", wire(body, length: "65537")),
                ("absolute target", wire(body, target: "https://example.com/v1/messages")),
                ("unknown query", wire(body, target: "/v1/messages?beta=false")),
                ("count tokens unsupported", wire(body, target: "/v1/messages/count_tokens")),
                ("header limit", Data(repeating: 65, count: BusinessHTTPIngress.maxHeaderBytes)),
                ("wire limit", Data(repeating: 65, count: BusinessHTTPIngress.maxWireBytes + 1))
            ] { try rejected(name) { _ = try BusinessHTTPIngress.parse(bad) } }
            try check(try BusinessHTTPIngress.parse(wire(body, headers: "Accept: text/event-stream\r\nX-Stainless-Retry-Count: 0\r\nUser-Agent: claude-cli\r\nX-Claude-Code-Session-Id: guest-has-no-authority\r\n"))?.claudeRequest().body == request.body, "known transport and diagnostic headers do not change semantics")
            for badBeta in ["unknown-2026", "", ClaudeRequestSelectors.pinned.beta + ",files-api-2025-04-14"] {
                try rejected("beta contract") { _ = try BusinessHTTPIngress.parse(wire(body, beta: badBeta))?.claudeRequest() }
            }
            for changed in [
                String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Direct-Browser-Access: true", with: "Direct-Browser-Access: false"),
                String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Anthropic-Dangerous-Direct-Browser-Access: true\r\n", with: "")
            ] { try rejected("fixed direct browser selector") { _ = try BusinessHTTPIngress.parse(Data(changed.utf8))?.claudeRequest() } }
            for changed in [
                body.replacingOccurrences(of: "\"role\":\"system\"", with: "\"role\":\"developer\""),
                body.replacingOccurrences(of: "\"type\":\"text\",\"text\":\"local context\"", with: "\"type\":\"image\",\"source\":{}"),
                body.replacingOccurrences(of: "\"role\":\"user\"", with: "\"role\":\"assistant\""),
                body.replacingOccurrences(of: "\"stream\":true", with: "\"stream\":true,\"thinking\":{\"type\":\"enabled\"}"),
                body.replacingOccurrences(of: "\"max_tokens\":512", with: "\"max_tokens\":512,\"max_tokens\":512")
            ] { try rejected("invalid body") { _ = try BusinessHTTPIngress.parse(wire(changed))?.claudeRequest() } }
            let credential = Credential()
            let (authority, handle, connection) = try await installed(credential)
            try await workspaceSessionBoundaryChecks()
            try displayBoundaryChecks(handle: handle)
            try businessBudgetChecks(authority: authority, handle: handle, connection: connection)
            if let index = CommandLine.arguments.firstIndex(of: "--captured-http"), index + 1 < CommandLine.arguments.count {
                let captured = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                guard let parsed = try BusinessHTTPIngress.parse(captured) else { throw CheckFailure.failed("captured request incomplete") }
                let admitted = try ClaudeModelAdmission.prepare(ingress: parsed, authority: authority, handle: handle, connection: connection)
                print("PASS captured real CLI HTTP bytes=\(captured.count) raw_body=\(parsed.body.count) canonical_body=\(admitted.request.canonicalBody.count) approval=\(admitted.binding.canonicalRequest.count) credential_reads=0 network_starts=0")
            }
            let admission = try ClaudeModelAdmission.prepare(ingress: ingress, authority: authority, handle: handle, connection: connection)
            let canonical = try ModelJSON.parse(admission.binding.canonicalRequest)
            try check(canonical["claudeSelectors"]?["beta"]?.string == ClaudeRequestSelectors.pinned.beta, "beta bound")
            try check(canonical["claudeSelectors"]?["query"]?.string == "beta=true", "query bound")
            try check(canonical["claudeSelectors"]?["directBrowserAccess"]?.string == "true", "SDK direct browser selector bound")
            try check(canonical["nativeBody"] == request.body, "complete body bound")
            try check(admission.measurements.approvalEnvelopeBytes == admission.binding.canonicalRequest.count && admission.measurements.httpBytes == bytes.count, "measured actual bytes")
            let gateway = try HostModelGateway(connections: [connection], auditSink: Audit(), authority: authority)
            let modelHandle = try await gateway.install(grant: authority.installedGrantForOwnership(of: handle), authorityHandle: handle)
            let proposal = try await gateway.proposeClaude(handle: modelHandle, connectionID: connection.connectionID, ingress: ingress)
            try check(proposal.pendingAction.binding.canonicalRequest == admission.binding.canonicalRequest, "preflight and actual proposal bytes identical")
            let approval = try await gateway.hostApprove(handle: modelHandle, proposal: proposal)
            do { _ = try await gateway.makeOutput(handle: modelHandle, approval: approval); throw CheckFailure.failed("schema4 memory output") }
            catch HostModelGatewayError.invalidApproval {}
            do { _ = try await gateway.execute(handle: modelHandle, approval: approval); throw CheckFailure.failed("activation bypass") }
            catch HostModelGatewayError.businessRouteDisabled {}
            let gatedMeasurements = try await gateway.measurements(handle: modelHandle)
            try check(gatedMeasurements.dispatchedRequests == 0 && gatedMeasurements.outboundBodyBytes == 0 && gatedMeasurements.configuredHeaderBytes == 0, "disabled route has no outbound measurements")
            let transport = ModelTransport(credentialProvider: credential)
#if SANDBOX_TEST_FIXTURES
            let local = try ModelTransport(localClaudeFixturePort: 49152)
            try check(local.claudeRouteEnabled && !transport.claudeRouteEnabled, "only dedicated fixed-loopback fixture route is enabled")
            try rejected("local fixture transport requires actual VM owner") { _ = try local.prepareClaude(request, selectors: .pinned) }
            try rejected("fixture zero port") { _ = try ModelTransport(localClaudeFixturePort: 0) }
            let fixture = try HostModelConnection.localClaudeFixture(port: 49152, connectionID: connection.connectionID, accountID: connection.accountID)
            try check(fixture.model == .deepSeekFlash && fixture.protocol == .anthropic, "fixture fixed model dialect")
            let fixtureGateway = try HostModelGateway(connections: [fixture], auditSink: Audit(), authority: authority)
            let fixtureHandle = try await fixtureGateway.install(grant: authority.installedGrantForOwnership(of: handle), authorityHandle: handle)
            let pureProposal = try await fixtureGateway.proposeClaude(handle: fixtureHandle, connectionID: fixture.connectionID, ingress: ingress)
            let pureApproval = try await fixtureGateway.hostApprove(handle: fixtureHandle, proposal: pureProposal)
            do { _ = try await fixtureGateway.execute(handle: fixtureHandle, approval: pureApproval); throw CheckFailure.failed("pure proposal fixture dispatch") }
            catch HostModelGatewayError.invalidApproval {}
            let fixtureResumes = try await fixtureGateway.resumedTaskCount(handle: fixtureHandle)
            try check(fixtureResumes == 0, "pure schema4 cannot start local fixture transport")
#endif
            try rejected("direct transport gate") { _ = try transport.prepareClaude(request, selectors: .pinned) }
            try rejected("native fallback gate") { _ = try transport.prepareNative(request) }
            try check(!BusinessModelActivation.credentialEgressEnabled, "immutable product gate")
            let runtimeID = UUID()
            let display = BusinessDisplayOutput(lifecycle: handle.lifecycle,
                scope: try handle.lifecycle.runScope(for: handle, epoch: 1), runtimeID: runtimeID)
            try display.enqueue(channel: "stdout", bytes: Data("actual output\n\u{1b}[31m".utf8), runtimeID: runtimeID)
            try check(try display.acceptNext(), "display accepted through lifecycle")
            try check(display.snapshot.stdout == "actual output\n\\u{1b}[31m" && display.snapshot.acceptedEvents == 1, "display escapes terminal control")
            do { try display.enqueue(channel: "stdout", bytes: Data([65]), runtimeID: UUID()); throw CheckFailure.failed("foreign runtime output") }
            catch NativeResponseError.invalidEvent {}
            try display.enqueue(channel: "stderr", bytes: Data("late".utf8), runtimeID: runtimeID)
            let permission = #"{"type":"control_request","request_id":"request-1","request":{"subtype":"can_use_tool","tool_use_id":"tool-1","tool_name":"Edit","input":{"file_path":"/work/project/logic.py","old_string":"-","new_string":"+"}}}"#
            let tool = try CLIPermissionRequest.parse(Data(permission.utf8))
            try check(tool.operation == "write" && tool.input["old_string"]?.string == "-", "normal CLI permission retains exact input")
            let metadata = permission.replacingOccurrences(of: "\"subtype\":", with: "\"display_name\":\"Edit\",\"description\":\"logic.py\",\"decision_reason_type\":\"other\",\"permission_suggestions\":[{\"type\":\"setMode\",\"mode\":\"acceptEdits\",\"destination\":\"session\"}],\"subtype\":")
            let withMetadata = try CLIPermissionRequest.parse(Data(metadata.utf8))
            try check(withMetadata.root == ModelJSON.parse(Data(metadata.utf8)) && withMetadata.input == tool.input,
                "SDK suggestions retained as metadata without changing one-action input")
            try rejected("unknown permission semantics") { _ = try CLIPermissionRequest.parse(Data(permission.replacingOccurrences(of: "\"subtype\":", with: "\"updatedPermissions\":[],\"subtype\":").utf8)) }
            let mcpPermission = #"{"type":"control_request","request_id":"mcp-request","request":{"subtype":"can_use_tool","tool_use_id":"mcp-1","tool_name":"mcp__sandbox__repo_read","input":{"repo":"A"},"mcp_server":{"name":"sandbox","source":"dynamic"},"server_policy_ask_only":true}}"#
            let mcp = try CLIPermissionRequest.parse(Data(mcpPermission.utf8))
            try check(mcp.service == "mcp" && mcp.resource == "A" && mcp.operation == "read", "MCP permission resolves separate service/resource")
            for changed in [mcpPermission.replacingOccurrences(of: "\"source\":\"dynamic\"", with: "\"source\":\"untrusted\""),
                            mcpPermission.replacingOccurrences(of: "\"server_policy_ask_only\":true", with: "\"server_policy_ask_only\":false"),
                            mcpPermission.replacingOccurrences(of: "mcp__sandbox__repo_read", with: "mcp__other__repo_read"),
                            mcpPermission.replacingOccurrences(of: "\"repo\":\"A\"", with: "\"repo\":\"A\",\"url\":\"https://example.invalid\"")] {
                try rejected("unsupported MCP permission metadata/input") { _ = try CLIPermissionRequest.parse(Data(changed.utf8)) }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--captured-permission"), index + 1 < CommandLine.arguments.count {
                let captured = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                let parsed = try CLIPermissionRequest.parse(captured)
                try check(parsed.root == ModelJSON.parse(captured), "real permission metadata preserved")
                print("PASS captured real CLI permission bytes=\(captured.count) input_bytes=\(parsed.argumentsJSON.utf8.count) operation=\(parsed.operation) session_suggestions_applied=0")
            }
            for path in ["/etc/passwd", "/work/project/../private", "../outside", "logic.py", "~/logic.py", "~user/logic.py", "/work/project/", "/work/project//logic.py"] {
                try rejected("permission path") { _ = try CLIPermissionRequest.parse(Data(permission.replacingOccurrences(of: "/work/project/logic.py", with: path).utf8)) }
            }
            let shortCredential = Credential()
            let (shortAuthority, shortHandle, shortConnection) = try await installed(shortCredential, messageBytes: 100)
            try rejected("grant envelope bound") { _ = try ClaudeModelAdmission.prepare(ingress: ingress, authority: shortAuthority, handle: shortHandle, connection: shortConnection) }
            handle.lifecycle.terminate(.stopped)
            try rejected("late display after stop") { _ = try display.acceptNext() }
            try check(display.snapshot.stderr.isEmpty && display.snapshot.acceptedEvents == 1, "no late UI adoption")
            try rejected("stop admission") { _ = try ClaudeModelAdmission.prepare(ingress: ingress, authority: authority, handle: handle, connection: connection) }
            try check(credential.reads == 0 && shortCredential.reads == 0, "admission never reads credentials")
            print("PASS business HTTP framing, fixed Claude selectors, unchanged native dialect, mid-system preservation, complete approval binding, budget and Stop; credential_reads=0 network_starts=0")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
