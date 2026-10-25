import Darwin
import Foundation
import SandboxContracts

private actor FixtureState {
    var finishedSHA: String?
    var transferred = false
    var models = 0, permissions = 0
    var failures: [String] = []
    var reflectedMetadataRejected = false
    var mcpReplies = 0, mcpDenials = 0, mcpCalls = 0
    var permissionResourceRejected = false
    var retiringMCP = false, retiredMCPChecked = false
    func finished(_ sha: String) { finishedSHA = sha }
    func transfer() { transferred = true }
    func model() { models += 1 }
    func permission() { permissions += 1 }
    func fail(_ error: Error) { failures.append(String(describing: type(of: error))) }
    func progress() -> (String?, Bool, Int, Int, [String]) { (finishedSHA, transferred, models, permissions, failures) }
    func reflection() { reflectedMetadataRejected = true }
    func reflectionComplete() -> Bool { reflectedMetadataRejected }
    func claimMCPCall() -> Bool {
        mcpCalls += 1
        return mcpCalls == 1
    }
    func mcpReply() { mcpReplies += 1 }
    func mcpDenied() { mcpDenials += 1 }
    func mcpProgress() -> (Int, Int) { (mcpReplies, mcpDenials) }
    func rejectedPermissionResource() { permissionResourceRejected = true }
    func resourceRejectionComplete() -> Bool { permissionResourceRejected }
    func beginMCPRetirement() { retiringMCP = true }
    func isRetiringMCP() -> Bool { retiringMCP }
    func checkedMCPRetirement() { retiredMCPChecked = true }
    func retirementComplete() -> Bool { retiredMCPChecked }
}

private final class FixtureMCPCredentials: MCPCredentialProvider, @unchecked Sendable {
    private let token: String
    private let lock = NSLock()
    private var count = 0
    private var pauseNext = false, paused = false
    private let pauseGate = DispatchSemaphore(value: 0)
    init(_ token: String) { self.token = token }
    func credential(for binding: MCPCredentialBinding) throws -> MCPCredential {
        let shouldPause = lock.withLock { () -> Bool in
            count += 1
            if pauseNext {
                pauseNext = false
                paused = true
                return true
            }
            return false
        }
        if shouldPause {
            guard pauseGate.wait(timeout: .now() + 15) == .success else { throw BusinessVMError.closed }
            lock.withLock { paused = false }
        }
        return MCPCredential(binding: binding, bearer: token)
    }
    var reads: Int { lock.withLock { count } }
    func pauseNextRead() { lock.withLock { pauseNext = true } }
    var isPaused: Bool { lock.withLock { paused } }
    func releaseRead() { pauseGate.signal() }
}
private struct FixtureMCPContext: Sendable {
    let gateway: HostMCPGateway
    let handle: HostMCPRunHandle
    let connectionID: UUID
    let credentials: FixtureMCPCredentials
}

/// Fixture-only actual VM tool loop. Every tool executes in the real CLI/VM;
/// only the upstream model is a fixed loopback fixture. No exported host code is
/// run, and none of this entry point is included in the application target.
@main struct BusinessFixtureProbe {
    static let original = Data("def add(a, b):\n    return a - b\n".utf8)
    static let fixed = Data("def add(a, b):\n    return a + b\n".utf8)
    static let test = Data("from logic import add\nassert add(2, 3) == 5\n".utf8)
    static func report(_ object: [String: Any]) {
        print(
            String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        )
        fflush(stdout)
    }
    static func errorLabel(_ error: Error) -> String {
        if let value = error as? BusinessVMError { return String(describing: value) }
        if let value = error as? HostModelGatewayError { return String(describing: value) }
        if let value = error as? HostMCPGatewayError { return String(describing: value) }
        if let value = error as? AuthorizationError { return String(describing: value) }
        if let value = error as? BusinessHTTPIngress.Failure { return String(describing: value) }
        return String(describing: type(of: error))
    }
    static func frame(_ connection: BusinessVMConnection) async throws -> Data {
        var data = Data()
        while data.count < 4 {
            let part = try await connection.receive(maxBytes: 4 - data.count)
            guard !part.isEmpty else { throw BusinessVMError.closed }
            data.append(part)
        }
        let length = data.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 16_384 else { throw BusinessVMError.capacity }
        data.removeAll()
        while data.count < length {
            let part = try await connection.receive(maxBytes: min(4096, length - data.count))
            guard !part.isEmpty else { throw BusinessVMError.closed }
            data.append(part)
        }
        return data
    }
    static func send(_ writer: BusinessVMFrameOutput) async throws {
        while !writer.completed {
            if try !writer.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
    static func receiveModel(_ connection: BusinessVMConnection, evidence: URL) async throws -> BusinessHTTPIngress {
        var bytes = Data()
        while true {
            do {
                if let ingress = try BusinessHTTPIngress.parse(bytes) {
                    try bytes.write(
                        to: evidence.appendingPathComponent("model-wire-" + connection.id.uuidString + ".http"),
                        options: [.withoutOverwriting])
                    return ingress
                }
            } catch {
                try? bytes.write(
                    to: evidence.appendingPathComponent("model-wire-" + connection.id.uuidString + ".http"),
                    options: [.withoutOverwriting])
                throw error
            }
            let part = try await connection.receive(maxBytes: 4096)
            guard !part.isEmpty else { throw BusinessVMError.closed }
            bytes.append(part)
        }
    }
    static func receiveMCP(_ connection: BusinessVMConnection, evidence: URL) async throws -> ClaudeMCPIngress {
        var bytes = Data()
        while true {
            do {
                if let ingress = try ClaudeMCPIngress.parse(bytes) {
                    try bytes.write(
                        to: evidence.appendingPathComponent("mcp-wire-" + connection.id.uuidString + ".http"),
                        options: [.withoutOverwriting])
                    return ingress
                }
            } catch {
                try? bytes.write(
                    to: evidence.appendingPathComponent("mcp-wire-" + connection.id.uuidString + ".http"),
                    options: [.withoutOverwriting])
                throw error
            }
            let part = try await connection.receive(maxBytes: 4096)
            guard !part.isEmpty else { throw BusinessVMError.closed }
            bytes.append(part)
        }
    }
    static func main() async {
        var vm: BusinessVMSession?
        var displayForEvidence: BusinessDisplayOutput?
        var evidenceRoot: URL?
        do {
            let args = CommandLine.arguments
            guard (5...6).contains(args.count), let port = UInt16(args[4]), port != 0 else {
                throw BusinessVMError.invalidResource
            }
            let mode = args.count == 6 ? args[5] : "tools"
            let reflection = mode == "reflection"
            let mcpMode = mode.hasPrefix("mcp-")
            guard
                [
                    "tools", "reflection", "mcp-read", "mcp-write", "mcp-denied-resource", "mcp-denied-write",
                    "mcp-retired-start", "mcp-retired-send",
                ].contains(mode)
            else { throw BusinessVMError.invalidProfile }
            let root = URL(fileURLWithPath: args[3], isDirectory: true)
            evidenceRoot = root
            let bundle = try BusinessRuntimeBundle(
                directory: URL(fileURLWithPath: args[1], isDirectory: true), vendorDisk: URL(fileURLWithPath: args[2]))
            let source = root.appendingPathComponent("original", isDirectory: true)
            try FileManager.default.createDirectory(
                at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try original.write(to: source.appendingPathComponent("logic.py"), options: [.withoutOverwriting])
            try test.write(to: source.appendingPathComponent("test_logic.py"), options: [.withoutOverwriting])
            let store = try WorkspaceStore(newRoot: root.appendingPathComponent("store").path)
            let snapshot = try store.importTree(from: source.path)
            let audit = try JSONLAuditSink(newFileAt: root.appendingPathComponent("audit.jsonl"))
            let authority = RunAuthorizationController(auditSink: audit)
            let modelConnection = try HostModelConnection.localClaudeFixture(port: port)
            let mcpConfiguration: (HostMCPConnection, FixtureMCPCredentials)?
            if mcpMode {
                guard let line = readLine(), line.utf8.count <= 1024,
                    let config = try ModelJSON.parse(Data(line.utf8)).object, Set(config.keys) == ["port", "token"],
                    case .integer(let value) = config["port"], (1...65535).contains(value),
                    let token = config["token"]?.string, token.hasPrefix("mcp-canary-"), token.utf8.count == 59
                else { throw BusinessVMError.invalidProfile }
                let credentials = FixtureMCPCredentials(token)
                mcpConfiguration = (
                    try HostMCPConnection.claudeLocalRepository(
                        connectionID: UUID(), accountID: UUID(), port: UInt16(value), provider: credentials),
                    credentials
                )
            } else {
                mcpConfiguration = nil
            }
            let resource = "workspace:" + snapshot.id.grantSnapshotID.uuidString
            let scopes =
                try [ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream")]
                + ["read", "write", "execute"].map {
                    try ResourceScope(service: "workspace", resource: resource, operation: $0)
                }
            var connections = [
                try ConnectionGrant(
                    connectionID: modelConnection.connectionID, accountBindingVersion: 1, routeVersion: 1,
                    scopes: Set(scopes))
            ]
            if let (connection, _) = mcpConfiguration {
                connections.append(
                    try ConnectionGrant(
                        connectionID: connection.connectionID, accountBindingVersion: 1, routeVersion: 1,
                        scopes: Set(
                            try [
                                ResourceScope(service: "mcp", resource: "control", operation: "server/discover"),
                                ResourceScope(service: "mcp", resource: "control", operation: "tools/list"),
                                ResourceScope(service: "mcp", resource: "A", operation: "read"),
                                ResourceScope(service: "mcp", resource: "A", operation: "write"),
                            ])))
            }
            let now = Date()
            let grant = try RunGrant(
                runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
                workloadImageDigest: bundle.imageSHA256, agentAdapterVersion: BusinessRuntimeBundle.profile,
                workspaceSnapshotID: snapshot.id.grantSnapshotID, policyDigest: String(repeating: "1", count: 64),
                approvalSnapshotID: UUID(),
                connections: connections, explicitDenies: [],
                resourceLimits: ResourceLimits(
                    cpuCount: 2, memoryBytes: 1_073_741_824, diskBytes: 67_108_864, messageBytes: 65_536,
                    concurrentRequests: 2))
            let handle = try await authority.install(grant: grant)
            let workspace = try WorkspaceRunSession.bind(
                store: store, snapshot: snapshot, authority: authority, handle: handle, grant: grant,
                limits: WorkspaceTaskLimits(
                    retainedPayloadBytes: 1_048_576, diskBytes: 4_194_304, cumulativeInputBytes: 4_194_304))
            let gateway = try HostModelGateway(connections: [modelConnection], auditSink: audit, authority: authority)
            let modelHandle = try await gateway.install(grant: grant, authorityHandle: handle)
            let mcpContext: FixtureMCPContext?
            if let (connection, credentials) = mcpConfiguration {
                let mcpGateway = try HostMCPGateway(connections: [connection], auditSink: audit, authority: authority)
                mcpContext = FixtureMCPContext(
                    gateway: mcpGateway, handle: try await mcpGateway.install(grant: grant, authorityHandle: handle),
                    connectionID: connection.connectionID, credentials: credentials)
            } else {
                mcpContext = nil
            }
            let permissions = try HostCLIPermissionGateway(
                authority: authority, handle: handle, grant: grant, connectionID: modelConnection.connectionID,
                mcpConnectionID: mcpConfiguration?.0.connectionID)
            let session = try BusinessVMSession(
                authority: authority, handle: handle, grant: grant, bundle: bundle, sessionDirectory: root)
            vm = session
            try workspace.prepareTransfer(runtimeID: session.id)
            let display = BusinessDisplayOutput(
                lifecycle: handle.lifecycle, scope: try handle.lifecycle.runScope(for: handle, epoch: grant.epoch),
                runtimeID: session.id)
            displayForEvidence = display
            let state = FixtureState()
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(150))
                if !Task.isCancelled { session.cancel() }
            }
            defer { watchdog.cancel() }
            let events = Task { for await event in session.events { report(["event": "vm." + event.rawValue]) } }
            let incoming = Task {
                await withTaskGroup(of: Void.self) { group in
                    for await connection in session.incoming {
                        group.addTask {
                            do {
                                switch connection.service {
                                case .control:
                                    guard
                                        try RuntimeJSON.parse(await frame(connection)).object == [
                                            "v": .integer(1), "type": .string("ready"),
                                            "profile": .string(BusinessRuntimeBundle.profile),
                                        ]
                                    else { throw BusinessVMError.invalidProfile }
                                    let task =
                                        mcpMode
                                        ? "Use the selected sandbox MCP repository tool for the requested bounded check. Do not modify local project files."
                                        : "Read logic.py, run python3 -B test_logic.py to observe the failure, fix the arithmetic bug in logic.py, then run the unchanged test again. Do not edit test_logic.py."
                                    let start = try JSONSerialization.data(
                                        withJSONObject: ["v": 1, "type": "start", "mcp": mcpMode, "task": task],
                                        options: [.sortedKeys])
                                    try await send(session.makeFrameOutput(connection: connection, body: start))
                                    while true {
                                        guard let object = try RuntimeJSON.parse(await frame(connection)).object,
                                            object["v"] == .integer(1)
                                        else { throw BusinessVMError.invalidProfile }
                                        if object["type"] == .string("output") {
                                            guard Set(object.keys) == ["v", "type", "channel", "data", "sha256"],
                                                let channel = object["channel"]?.string,
                                                ["stdout", "stderr"].contains(channel),
                                                let encoded = object["data"]?.string,
                                                let bytes = Data(base64Encoded: encoded),
                                                bytes.count <= 4096, bytes.base64EncodedString() == encoded,
                                                object["sha256"]?.string == WorkspaceTransferWire.hash(bytes)
                                            else { throw BusinessVMError.invalidProfile }
                                            try display.enqueue(channel: channel, bytes: bytes, runtimeID: session.id)
                                            guard try display.acceptNext() else { throw BusinessVMError.invalidOwner }
                                        } else {
                                            guard
                                                Set(object.keys) == [
                                                    "v", "type", "workspaceSHA256", "exit", "initialized", "isError",
                                                    "outputBytes", "permissions", "timedOut",
                                                ],
                                                object["type"] == .string("finished"), object["exit"] == .integer(0),
                                                object["initialized"] == .bool(true), object["isError"] == .bool(false),
                                                object["timedOut"] == .bool(false),
                                                let sha = object["workspaceSHA256"]?.string
                                            else { throw BusinessVMError.invalidProfile }
                                            await state.finished(sha)
                                            report(["event": "guest.finished", "workspaceSHA256": sha])
                                            break
                                        }
                                    }
                                case .workspace:
                                    while !workspace.transferCompleted {
                                        if let body = try workspace.receive(await frame(connection)) {
                                            try await send(session.makeFrameOutput(connection: connection, body: body))
                                        }
                                    }
                                    await state.transfer()
                                    report(["event": "workspace.transfer-complete"])
                                case .model:
                                    let ingress = try await receiveModel(connection, evidence: root)
                                    let proposal = try await gateway.proposeVMClaude(
                                        handle: modelHandle, connectionID: modelConnection.connectionID,
                                        ingress: ingress, connection: connection)
                                    report([
                                        "event": "model.approval-sizes", "httpBytes": ingress.wireBytes,
                                        "rawBodyBytes": ingress.body.count,
                                        "canonicalBodyBytes": try ingress.claudeRequest().canonicalBody.count,
                                        "fullApprovalBytes": proposal.pendingAction.binding.canonicalRequest.count,
                                    ])
                                    let approval = try await gateway.hostApprove(
                                        handle: modelHandle, proposal: proposal)
                                    let output = try await gateway.makeVMNativeOutput(
                                        handle: modelHandle, approval: approval, connection: connection)
                                    let execution = Task {
                                        try await gateway.execute(
                                            handle: modelHandle, approval: approval, output: output)
                                    }
                                    while output.nativeProgress?.closed == false {
                                        do {
                                            if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
                                        } catch {
                                            if reflection, output.nativeProgress?.closed == true { break }
                                            throw error
                                        }
                                    }
                                    if reflection {
                                        var rejected = false
                                        do { try await execution.value } catch {
                                            rejected = error as? HostModelGatewayError == .outcomeUnknown
                                        }
                                        guard rejected, let progress = output.nativeProgress,
                                            progress.committedBytes == 0, progress.writeCalls == 0,
                                            progress.acceptedFinals == 0
                                        else { throw BusinessVMError.invalidOwner }
                                        await state.reflection()
                                        session.cancel()
                                        return
                                    }
                                    try await execution.value
                                    guard let progress = output.nativeProgress, progress.committedBytes > 0,
                                        progress.acceptedFinals == 1
                                    else { throw BusinessVMError.invalidOwner }
                                    await state.model()
                                    report([
                                        "event": "model.native-response", "bytes": progress.committedBytes,
                                        "writeCalls": progress.writeCalls, "finals": progress.acceptedFinals,
                                        "largestFrameBytes": progress.largestFrameBytes,
                                        "peakQueuedEvents": progress.peakQueuedEvents,
                                        "peakBufferedBytes": progress.peakBufferedBytes,
                                        "cumulativeEnqueuedBytes": progress.cumulativeEnqueuedBytes,
                                    ])
                                case .permission:
                                    let bytes = try await frame(connection)
                                    try bytes.write(
                                        to: root.appendingPathComponent(
                                            "permission-" + connection.id.uuidString + ".json"),
                                        options: [.withoutOverwriting])
                                    let request = try CLIPermissionRequest.parse(bytes)
                                    switch request.toolName {
                                    case "Bash":
                                        guard request.input["command"]?.string == "python3 -B test_logic.py" else {
                                            throw BusinessVMError.invalidProfile
                                        }
                                    case "Read":
                                        guard request.input["file_path"]?.string == "/work/project/logic.py" else {
                                            throw BusinessVMError.invalidProfile
                                        }
                                    case "Edit":
                                        guard request.input["file_path"]?.string == "/work/project/logic.py",
                                            request.input["old_string"]?.string == "return a - b",
                                            request.input["new_string"]?.string == "return a + b"
                                        else { throw BusinessVMError.invalidProfile }
                                    case "mcp__sandbox__repo_read", "mcp__sandbox__repo_write":
                                        guard mcpContext != nil,
                                            request.input["repo"] == .string(mode == "mcp-denied-resource" ? "B" : "A")
                                        else { throw BusinessVMError.invalidProfile }
                                    default: throw BusinessVMError.invalidProfile
                                    }
                                    let proposal: HostCLIPermissionGateway.Proposal
                                    do {
                                        proposal = try await permissions.propose(connection: connection, body: bytes)
                                    } catch {
                                        guard mode == "mcp-denied-resource",
                                            request.toolName == "mcp__sandbox__repo_read",
                                            request.input["repo"] == .string("B"),
                                            error as? HostModelGatewayError == .denied
                                        else { throw error }
                                        await state.rejectedPermissionResource()
                                        session.cancel()
                                        return
                                    }
                                    try await permissions.approveAndSend(proposal)
                                    await state.permission()
                                    report(["event": "permission.normal-sdk", "tool": request.toolName])
                                case .mcp:
                                    guard let mcpContext else { throw BusinessVMError.invalidProfile }
                                    let ingress = try await receiveMCP(connection, evidence: root)
                                    let proposal: HostMCPProposal
                                    do {
                                        proposal = try await mcpContext.gateway.proposeVMClient(
                                            handle: mcpContext.handle, connectionID: mcpContext.connectionID,
                                            ingress: ingress, connection: connection)
                                    } catch {
                                        guard mode == "mcp-denied-resource", ingress.selectors.method == "tools/call",
                                            ingress.request.payload["params"]?["arguments"]?["repo"] == .string("B"),
                                            error as? HostMCPGatewayError == .denied
                                        else { throw error }
                                        await state.mcpDenied()
                                        report(["event": "mcp.resource-denied", "upstreamDispatch": false])
                                        connection.retire()
                                        return
                                    }
                                    if ingress.selectors.method == "tools/call" {
                                        if mode == "mcp-denied-write" {
                                            try await mcpContext.gateway.hostDeny(
                                                handle: mcpContext.handle, proposal: proposal)
                                            await state.mcpDenied()
                                            report(["event": "mcp.write-denied", "upstreamDispatch": false])
                                            connection.retire()
                                            return
                                        }
                                        guard await state.claimMCPCall() else { throw BusinessVMError.capacity }
                                    }
                                    let approval = try await mcpContext.gateway.hostApprove(
                                        handle: mcpContext.handle, proposal: proposal)
                                    let output = try await mcpContext.gateway.makeVMNativeOutput(
                                        handle: mcpContext.handle, approval: approval, connection: connection)
                                    if ingress.selectors.method == "tools/call", mode.hasPrefix("mcp-retired-") {
                                        let before = try await mcpContext.gateway.resumedTaskCount(
                                            handle: mcpContext.handle)
                                        if mode == "mcp-retired-start" {
                                            // Hold only the fixture credential provider. The gateway has
                                            // consumed this actual-VM approval but has not resumed HTTP.
                                            mcpContext.credentials.pauseNextRead()
                                            let execution = Task {
                                                try await mcpContext.gateway.execute(
                                                    handle: mcpContext.handle, approval: approval, output: output)
                                            }
                                            while !mcpContext.credentials.isPaused {
                                                try await Task.sleep(for: .milliseconds(2))
                                            }
                                            await state.beginMCPRetirement()
                                            session.stopForResult()
                                            let stopped = await session.waitUntilStopped()
                                            guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved,
                                                handle.lifecycle.currentStatus == .active
                                            else {
                                                mcpContext.credentials.releaseRead()
                                                throw BusinessVMError.invalidOwner
                                            }
                                            mcpContext.credentials.releaseRead()
                                            var rejected = false
                                            do { try await execution.value } catch {
                                                rejected = error as? HostMCPGatewayError == .notStarted
                                                report([
                                                    "event": "mcp.retired-start-rejection", "error": errorLabel(error),
                                                ])
                                            }
                                            guard rejected,
                                                try await mcpContext.gateway.resumedTaskCount(handle: mcpContext.handle)
                                                    == before
                                            else { throw BusinessVMError.invalidOwner }
                                        } else {
                                            try await mcpContext.gateway.execute(
                                                handle: mcpContext.handle, approval: approval, output: output)
                                            guard
                                                try await mcpContext.gateway.resumedTaskCount(handle: mcpContext.handle)
                                                    == before + 1
                                            else { throw BusinessVMError.invalidOwner }
                                            await state.beginMCPRetirement()
                                            session.stopForResult()
                                            let stopped = await session.waitUntilStopped()
                                            guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved,
                                                handle.lifecycle.currentStatus == .active
                                            else { throw BusinessVMError.invalidOwner }
                                        }
                                        var sendRejected = false
                                        do { _ = try output.acceptNext() } catch {
                                            sendRejected = true
                                            report(["event": "mcp.retired-send-rejection", "error": errorLabel(error)])
                                        }
                                        guard sendRejected, let progress = output.nativeProgress,
                                            progress.committedBytes == 0, progress.writeCalls == 0,
                                            progress.acceptedFinals == 0
                                        else { throw BusinessVMError.invalidOwner }
                                        await state.checkedMCPRetirement()
                                        report([
                                            "event": "mcp.retirement-checked", "mode": mode, "nativeBytes": 0,
                                            "nativeWriteCalls": 0,
                                            "upstreamResumes": mode == "mcp-retired-start" ? 0 : 1,
                                            "grantStillActive": true,
                                        ])
                                        return
                                    }
                                    try await mcpContext.gateway.execute(
                                        handle: mcpContext.handle, approval: approval, output: output)
                                    while output.nativeProgress?.closed == false {
                                        if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
                                    }
                                    guard let progress = output.nativeProgress, progress.acceptedFinals == 1,
                                        progress.committedBytes > 0
                                    else { throw BusinessVMError.invalidOwner }
                                    await state.mcpReply()
                                    report([
                                        "event": "mcp.native-response", "method": ingress.selectors.method,
                                        "bytes": progress.committedBytes,
                                    ])
                                }
                            } catch {
                                if mode.hasPrefix("mcp-retired-"), await state.isRetiringMCP(),
                                    [.control, .workspace].contains(connection.service),
                                    error as? BusinessVMError == .closed
                                {
                                    report(["event": "channel.expected-stop", "service": connection.service.rawValue])
                                    return
                                }
                                report([
                                    "event": "channel.failed", "service": connection.service.rawValue,
                                    "error": errorLabel(error),
                                ])
                                await state.fail(error)
                                connection.retire()
                                session.cancel()
                            }
                        }
                    }
                    await group.waitForAll()
                }
            }
            try await session.start()
            if mode.hasPrefix("mcp-retired-") {
                while !(await state.retirementComplete()) {
                    guard await state.progress().4.isEmpty else { throw BusinessVMError.closed }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let stopped = await session.waitUntilStopped()
                await incoming.value
                let counts = await state.mcpProgress()
                let progress = await state.progress()
                guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved,
                    handle.lifecycle.currentStatus == .active,
                    counts.0 == 2, progress.2 == 1, progress.3 == 1, progress.4.isEmpty,
                    try Data(contentsOf: source.appendingPathComponent("logic.py")) == original,
                    try Data(contentsOf: source.appendingPathComponent("test_logic.py")) == test
                else { throw BusinessVMError.invalidOwner }
                report([
                    "event": "PASS", "scope": mode, "nativeBytes": 0, "nativeWriteCalls": 0,
                    "upstreamToolDispatches": mode == "mcp-retired-start" ? 0 : 1,
                    "actualStopped": true, "callbacksSettled": true, "diskRemoved": true, "grantStillActive": true,
                    "originalUnchanged": true, "realProvider": "NOT_RUN",
                ])
                handle.lifecycle.terminate(.stopped)
                _ = await events.value
                return
            }
            if mode == "mcp-denied-resource" {
                while !(await state.resourceRejectionComplete()) {
                    if !(await state.progress().4.isEmpty), !(await state.resourceRejectionComplete()) {
                        throw BusinessVMError.closed
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let stopped = await session.waitUntilStopped()
                await incoming.value
                let counts = await state.mcpProgress()
                let progress = await state.progress()
                guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved,
                    counts.0 == 2, progress.2 == 1, progress.3 == 0,
                    try Data(contentsOf: source.appendingPathComponent("logic.py")) == original,
                    try Data(contentsOf: source.appendingPathComponent("test_logic.py")) == test
                else { throw BusinessVMError.invalidOwner }
                let output = display.snapshot
                try Data(output.stdout.utf8).write(
                    to: root.appendingPathComponent("cli.stdout"), options: [.withoutOverwriting])
                try Data(output.stderr.utf8).write(
                    to: root.appendingPathComponent("cli.stderr"), options: [.withoutOverwriting])
                report([
                    "event": "PASS", "scope": mode, "permissionResponseBytes": 0, "upstreamToolDispatch": false,
                    "actualStopped": true, "callbacksSettled": true, "originalUnchanged": true,
                    "realProvider": "NOT_RUN",
                ])
                _ = await events.value
                return
            }
            if reflection {
                while !(await state.reflectionComplete()) {
                    if !(await state.progress().4.isEmpty), !(await state.reflectionComplete()) {
                        throw BusinessVMError.closed
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let stopped = await session.waitUntilStopped()
                await incoming.value
                let canary = try LocalClaudeFixtureCredential().credential(for: .deepSeekFlash)
                let output = display.snapshot
                guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved,
                    !output.stdout.contains(canary), !output.stderr.contains(canary)
                else { throw BusinessVMError.invalidOwner }
                try Data(output.stdout.utf8).write(
                    to: root.appendingPathComponent("cli.stdout"), options: [.withoutOverwriting])
                try Data(output.stderr.utf8).write(
                    to: root.appendingPathComponent("cli.stderr"), options: [.withoutOverwriting])
                report([
                    "event": "PASS", "scope": "actual-VZ-active-fake-credential-reflection", "nativeBytes": 0,
                    "nativeWriteCalls": 0,
                    "guestOutputCanaryOccurrences": 0, "actualStopped": true, "callbacksSettled": true,
                    "realProvider": "NOT_RUN",
                ])
                _ = await events.value
                return
            }
            while true {
                let progress = await state.progress()
                guard progress.4.isEmpty, handle.lifecycle.currentStatus == .active else {
                    throw BusinessVMError.closed
                }
                if progress.0 != nil, progress.1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            session.stopForResult()
            let stopped = await session.waitUntilStopped()
            await incoming.value
            let progress = await state.progress()
            guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved, progress.4.isEmpty,
                progress.2 == (mcpMode ? 2 : 5), mcpMode || progress.3 >= 1
            else { throw BusinessVMError.invalidOwner }
            let review = try workspace.sealAndAdopt(after: stopped)
            // The transfer wire digest and host review digest use different
            // domains. Compare wire to wire, then verify actual reviewed bytes.
            let expected = mcpMode ? original : fixed
            guard WorkspaceTransferWire.treeHash(["logic.py": expected, "test_logic.py": test]) == progress.0 else {
                throw BusinessVMError.invalidProfile
            }
            if mcpMode {
                guard review.changes.isEmpty else { throw BusinessVMError.invalidProfile }
            } else {
                guard review.changes.count == 1, review.changes[0].path == "logic.py", review.changes[0].kind == .change
                else { throw BusinessVMError.invalidProfile }
            }
            let exported = root.appendingPathComponent("exported", isDirectory: true)
            try workspace.exportReviewed(review, toNewDirectory: exported.path)
            guard try Data(contentsOf: source.appendingPathComponent("logic.py")) == original,
                try Data(contentsOf: source.appendingPathComponent("test_logic.py")) == test,
                try Data(contentsOf: exported.appendingPathComponent("logic.py")) == expected,
                try Data(contentsOf: exported.appendingPathComponent("test_logic.py")) == test
            else { throw BusinessVMError.invalidProfile }
            let output = display.snapshot
            try Data(output.stdout.utf8).write(
                to: root.appendingPathComponent("cli.stdout"), options: [.withoutOverwriting])
            try Data(output.stderr.utf8).write(
                to: root.appendingPathComponent("cli.stderr"), options: [.withoutOverwriting])
            let measurements = try await gateway.measurements(handle: modelHandle)
            report([
                "event": "model.run-measurements", "dispatches": measurements.dispatchedRequests,
                "outboundBodyBytes": measurements.outboundBodyBytes,
                "configuredHeaderBytes": measurements.configuredHeaderBytes,
                "largestBodyBytes": measurements.largestBodyBytes,
                "largestConfiguredHeaderBytes": measurements.largestConfiguredHeaderBytes,
                "peakActiveRequests": measurements.peakActiveRequests,
            ])
            if let mcpContext {
                let counts = await state.mcpProgress()
                guard counts.0 >= 2, !mode.contains("denied") || counts.1 >= 1 else {
                    throw BusinessVMError.invalidOwner
                }
                report([
                    "event": "mcp.counts", "responses": counts.0, "denied": counts.1,
                    "fakeCredentialReads": mcpContext.credentials.reads,
                ])
            }
            report([
                "event": "PASS", "scope": mcpMode ? mode : "actual-VM-CLI-with-fixed-loopback-model",
                "models": progress.2, "normalPermissions": progress.3,
                "actualStopped": stopped.actualStopped, "callbacksSettled": stopped.callbacksSettled,
                "originalUnchanged": true,
                "originalTestsUnchanged": true, "changedPaths": review.changes.map(\.path),
                "reviewSHA256": review.sha256, "realProvider": "NOT_RUN", "hostProjectExecution": false,
            ])
            handle.lifecycle.terminate(.stopped)
            _ = await events.value
        } catch {
            vm?.cancel()
            if let vm { _ = await vm.waitUntilStopped() }
            if let displayForEvidence, let evidenceRoot {
                let output = displayForEvidence.snapshot
                try? Data(output.stdout.utf8).write(
                    to: evidenceRoot.appendingPathComponent("cli.stdout"), options: [.withoutOverwriting])
                try? Data(output.stderr.utf8).write(
                    to: evidenceRoot.appendingPathComponent("cli.stderr"), options: [.withoutOverwriting])
            }
            report([
                "event": "FAIL",
                "error": (error as? BusinessVMError).map { String(describing: $0) }
                    ?? String(describing: type(of: error)),
            ])
            exit(1)
        }
    }
}
