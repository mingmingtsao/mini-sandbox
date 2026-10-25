import Foundation
import Darwin
@testable import SandboxHost
import SandboxContracts

#if DEBUG || SANDBOX_TEST_FIXTURES
private func clientJSON(_ method: String, repo: String = "A", write: Bool = false, id: ModelJSON = .integer(7)) -> ModelJSON {
    let meta: ModelJSON = .object([
        ClaudeMCPProtocol.metaVersion: .string(ClaudeMCPProtocol.version),
        ClaudeMCPProtocol.metaClient: .object(["name": .string("claude-code"), "title": .string("Claude Code"),
            "version": .string("2.1.309"), "description": .string("Anthropic's agentic coding tool"),
            "websiteUrl": .string("https://claude.com/claude-code")]),
        ClaudeMCPProtocol.metaCapabilities: .object(["roots": .object(["listChanged": .bool(true)]), "elicitation": .object(["form": .object([:]), "url": .object([:])])])])
    var params: [String: ModelJSON] = ["_meta": meta]
    if method == "tools/call" {
        params["name"] = .string(write ? "repo_write" : "repo_read")
        var args: [String: ModelJSON] = ["repo": .string(repo)]
        if write { args["content"] = .string("approved-once") }
        params["arguments"] = .object(args)
    }
    return .object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": .object(params)])
}
private func clientWire(_ value: ModelJSON) throws -> Data {
    let body = try MCPProtocol.canonical(value)
    let name = value["params"]?["name"]?.string.map { "Mcp-Name: \($0)\r\n" } ?? ""
    return Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:4063\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nMcp-Protocol-Version: 2026-07-28\r\nMcp-Method: \(value["method"]!.string!)\r\n\(name)Content-Length: \(body.count)\r\n\r\n".utf8) + body
}
private func clientIngress(_ method: String, repo: String = "A", write: Bool = false, id: ModelJSON = .integer(7)) throws -> ClaudeMCPIngress {
    guard let result = try ClaudeMCPIngress.parse(clientWire(clientJSON(method, repo: repo, write: write, id: id))) else { throw Failure(message: "client frame incomplete") }
    return result
}
private final class ClientSocket {
    var writer: Int32; let reader: Int32
    init() throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure(message: "client socketpair") }
        writer = pair[0]; reader = pair[1]
        guard fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else { throw Failure(message: "client nonblocking") }
    }
    func takeWriter() -> Int32 { let fd = writer; writer = -1; return fd }
    func readAvailable() throws -> Data {
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(reader, &bytes, bytes.count)
            if n > 0 { data.append(contentsOf: bytes.prefix(n)); continue }
            if n == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return data }
            if errno == EINTR { continue }
            throw Failure(message: "client peer read")
        }
    }
    deinit { if writer >= 0 { Darwin.close(writer) }; Darwin.close(reader) }
}
private func clientGrant(_ id: UUID) throws -> RunGrant {
    let scopes = Set(try [
        ResourceScope(service: "mcp", resource: "control", operation: "server/discover"),
        ResourceScope(service: "mcp", resource: "control", operation: "tools/list"),
        ResourceScope(service: "mcp", resource: "A", operation: "read"),
        ResourceScope(service: "mcp", resource: "A", operation: "write")])
    return try RunGrant(runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1), expiresAt: Date().addingTimeInterval(120),
        workloadImageDigest: String(repeating: "c", count: 64), agentAdapterVersion: "native-client-loopback-test",
        workspaceSnapshotID: UUID(), policyDigest: String(repeating: "d", count: 64), approvalSnapshotID: UUID(),
        connections: [ConnectionGrant(connectionID: id, accountBindingVersion: 1, routeVersion: 1, scopes: scopes)],
        explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 65536, concurrentRequests: 2))
}
private struct ClientContext {
    let gateway: HostMCPGateway; let handle: HostMCPRunHandle; let connectionID: UUID; let credentials: Credentials
    func propose(_ ingress: ClaudeMCPIngress) async throws -> HostMCPProposal {
        try await gateway.proposeLocalClientForTesting(handle: handle, connectionID: connectionID, ingress: ingress)
    }
    func send(_ ingress: ClaudeMCPIngress, stopBeforeSend: Bool = false) async throws -> ModelJSON? {
        let proposal = try await propose(ingress)
        let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
        let pair = try ClientSocket()
        let output = try await gateway.makeLocalClientTestOutput(handle: handle, approval: approval, takingAcceptedSocket: pair.takeWriter())
        defer { output.cancel() }
        try await gateway.execute(handle: handle, approval: approval, output: output)
        if stopBeforeSend {
            try await gateway.stop(handle: handle)
            do { _ = try output.acceptNext(); throw Failure(message: "MCP stale output accepted") } catch is AuthorizationError {}
            try check(try pair.readAvailable().isEmpty && output.nativeProgress?.writeCalls == 0, "MCP stopped final consumer wrote")
            return nil
        }
        var received = Data()
        for _ in 0..<4096 {
            if output.nativeProgress?.acceptedFinals == 1 { break }
            _ = try output.acceptNext(); received.append(try pair.readAvailable())
        }
        received.append(try pair.readAvailable())
        guard let p = output.nativeProgress else { throw Failure(message: "MCP native progress") }
        try check(p.acceptedFinals == 1 && p.closed && p.cumulativeEnqueuedBytes == p.committedBytes && p.committedBytes == received.count, "MCP actual peer and byte metrics")
        guard let split = received.range(of: Data("\r\n\r\n".utf8)), received.starts(with: Data("HTTP/1.1 200 OK\r\n".utf8)) else { throw Failure(message: "MCP actual HTTP framing") }
        let body = try ModelJSON.parse(Data(received[split.upperBound...]))
        try check(body["id"] == ingress.request.payload["id"], "MCP numeric/string correlation")
        return body
    }
}

func claudeClientChecks(_ port: UInt16, _ token: String) async throws {
    let id = UUID(), audit = Audit()
    let credentials = Credentials(token, audit)
    let connection = try HostMCPConnection.claudeLocalRepository(connectionID: id, accountID: UUID(), port: port, provider: credentials)
    let gateway = try HostMCPGateway(connections: [connection], auditSink: audit)
    let context = ClientContext(gateway: gateway, handle: try await gateway.install(grant: clientGrant(id)), connectionID: id, credentials: credentials)
    let capture = try clientWire(clientJSON("server/discover", id: .string("server-discover-probe-1")))
    for size in [0, 1, 30, capture.count - 1] { try check(try ClaudeMCPIngress.parse(Data(capture.prefix(size))) == nil, "MCP partial HTTP") }
    for wire in [capture + Data([0]), Data(String(decoding: capture, as: UTF8.self).replacingOccurrences(of: "Mcp-Method: server/discover", with: "Mcp-Method: tools/list").utf8), Data(String(decoding: capture, as: UTF8.self).replacingOccurrences(of: "Host: 127.0.0.1:4063", with: "Host: [::1]:4063").utf8), Data(String(decoding: capture, as: UTF8.self).replacingOccurrences(of: "Content-Type:", with: "Authorization: Bearer untrusted\r\nContent-Type:").utf8)] {
        do { _ = try ClaudeMCPIngress.parse(wire); throw Failure(message: "MCP malformed HTTP accepted") } catch HostMCPGatewayError.denied {}
    }
    try check(credentials.count == 0, "MCP parser read credentials")
    try phase("modern-discovery")
    _ = try await context.send(clientIngress("server/discover", id: .string("server-discover-probe-1")))
    _ = try await context.send(clientIngress("tools/list"))
    try check(try await gateway.discovery(connectionID: id) == .knownReady, "modern catalog")
    try report("modern-discovery", hits: 2, reads: 2)

    try phase("modern-read")
    let response = try await context.send(clientIngress("tools/call"))
    try check(response?["result"]?["content"]?.array?.first?["text"] == .string("repo-A-initial"), "modern read A")
    try report("modern-read", hits: 1, reads: 1)

    try phase("modern-denied")
    for write in [false, true] { try await denied { _ = try await context.propose(clientIngress("tools/call", repo: "B", write: write)) } }
    let deniedProposal = try await context.propose(clientIngress("tools/call", write: true))
    try await gateway.hostDeny(handle: context.handle, proposal: deniedProposal)
    try await denied(AuthorizationError.actionDenied) { _ = try await gateway.hostApprove(handle: context.handle, proposal: deniedProposal) }
    let raw = try clientIngress("tools/call")
    try await denied { _ = try await gateway.propose(handle: context.handle, connectionID: id, raw: raw.body) }
    try report("modern-denied", hits: 0, reads: 0)

    try phase("modern-write-once")
    let proposal = try await context.propose(clientIngress("tools/call", write: true))
    let approval = try await gateway.hostApprove(handle: context.handle, proposal: proposal)
    try await denied { _ = try await gateway.execute(handle: context.handle, approval: approval) }
    let pair = try ClientSocket()
    let nativeOutput = try await gateway.makeLocalClientTestOutput(handle: context.handle, approval: approval, takingAcceptedSocket: pair.takeWriter())
    defer { nativeOutput.cancel() }
    try await gateway.execute(handle: context.handle, approval: approval, output: nativeOutput)
    while nativeOutput.nativeProgress?.acceptedFinals != 1 { _ = try nativeOutput.acceptNext(); _ = try pair.readAvailable() }
    try await denied(AuthorizationError.ticketAlreadyConsumed) { try await gateway.execute(handle: context.handle, approval: approval, output: nativeOutput) }
    try report("modern-write-once", hits: 1, reads: 1)

    for mode in ["modern-reflection", "modern-split-reflection", "modern-wrong-id"] {
        try phase(mode)
        let p = try await context.propose(clientIngress("tools/call"))
        let a = try await gateway.hostApprove(handle: context.handle, proposal: p)
        let sockets = try ClientSocket()
        let sink = try await gateway.makeLocalClientTestOutput(handle: context.handle, approval: a, takingAcceptedSocket: sockets.takeWriter())
        do { try await gateway.execute(handle: context.handle, approval: a, output: sink); throw Failure(message: "modern unsafe response accepted") } catch HostMCPGatewayError.outcomeUnknown {}
        try check(try sockets.readAvailable().isEmpty && sink.nativeProgress?.writeCalls == 0, "modern response leaked before refusal")
        try report(mode, hits: 1, reads: 1)
    }
    try phase("modern-error")
    let error = try await context.send(clientIngress("tools/call"))
    try check(error?["error"]?["code"] == .integer(-32602), "modern legal RPC error")
    try report("modern-error", hits: 1, reads: 1)

    try phase("modern-stop")
    _ = try await context.send(clientIngress("tools/call"), stopBeforeSend: true)
    try await denied(.revoked) { _ = try await context.propose(clientIngress("tools/call")) }
    try report("modern-stop", hits: 1, reads: 1)

    // Both requests cross the actual HTTP boundary while discovery is unknown.
    // The fixture releases the second, changed catalog only after the first
    // response has reached its actual native peer.
    let raceID = UUID()
    let raceConnection = try HostMCPConnection.claudeLocalRepository(connectionID: raceID, accountID: UUID(), port: port, provider: credentials)
    let raceGateway = try HostMCPGateway(connections: [raceConnection], auditSink: audit)
    let race = ClientContext(gateway: raceGateway, handle: try await raceGateway.install(grant: clientGrant(raceID)), connectionID: raceID, credentials: credentials)
    try phase("modern-catalog-race")
    let first = Task { try await race.send(clientIngress("tools/list", id: .integer(101))) }
    let second = Task { try await race.send(clientIngress("tools/list", id: .integer(102))) }
    _ = try await first.value
    try check(try await raceGateway.discovery(connectionID: raceID) == .knownReady, "first catalog not learned")
    output("RELEASE modern-catalog-race")
    do { _ = try await second.value; throw Failure(message: "concurrent changed catalog replaced frozen catalog") }
    catch HostMCPGatewayError.outcomeUnknown {}
    try await denied(.invalidConnection) { _ = try await raceGateway.discovery(connectionID: raceID) }
    let readsAfterConflict = credentials.count
    for method in ["tools/list", "tools/call"] {
        try await denied(.invalidConnection) { _ = try await race.propose(clientIngress(method)) }
    }
    try check(credentials.count == readsAfterConflict, "retired catalog read credentials")
    try await raceGateway.stop(handle: race.handle)
    try report("modern-catalog-race", hits: 2, reads: 2)
    try check(!String(reflecting: audit.snapshot).contains(token), "MCP audit excludes fake credential")
    output("PASS actual loopback modern MCP to native socket; VZ/CLI/App NOT_RUN")
}
#else
func claudeClientChecks(_ port: UInt16, _ token: String) async throws {
    throw Failure(message: "modern MCP local fixture requires DEBUG or SANDBOX_TEST_FIXTURES")
}
#endif
