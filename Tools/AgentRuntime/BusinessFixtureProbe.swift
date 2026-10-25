import Foundation
import SandboxContracts
import Darwin

private actor FixtureState {
    var finishedSHA: String?
    var transferred = false
    var models = 0, permissions = 0
    var failures: [String] = []
    var reflectedMetadataRejected = false
    func finished(_ sha: String) { finishedSHA = sha }
    func transfer() { transferred = true }
    func model() { models += 1 }
    func permission() { permissions += 1 }
    func fail(_ error: Error) { failures.append(String(describing: type(of: error))) }
    func progress() -> (String?, Bool, Int, Int, [String]) { (finishedSHA, transferred, models, permissions, failures) }
    func reflection() { reflectedMetadataRejected = true }
    func reflectionComplete() -> Bool { reflectedMetadataRejected }
}

/// Fixture-only actual VM tool loop. Every tool executes in the real CLI/VM;
/// only the upstream model is a fixed loopback fixture. No exported host code is
/// run, and none of this entry point is included in the application target.
@main struct BusinessFixtureProbe {
    static let original = Data("def add(a, b):\n    return a - b\n".utf8)
    static let fixed = Data("def add(a, b):\n    return a + b\n".utf8)
    static let test = Data("from logic import add\nassert add(2, 3) == 5\n".utf8)
    static func report(_ object: [String: Any]) {
        print(String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
    }
    static func errorLabel(_ error: Error) -> String {
        if let value = error as? BusinessVMError { return String(describing: value) }
        if let value = error as? HostModelGatewayError { return String(describing: value) }
        if let value = error as? AuthorizationError { return String(describing: value) }
        if let value = error as? BusinessHTTPIngress.Failure { return String(describing: value) }
        return String(describing: type(of: error))
    }
    static func frame(_ connection: BusinessVMConnection) async throws -> Data {
        var data = Data()
        while data.count < 4 {
            let part = try await connection.receive(maxBytes: 4 - data.count)
            guard !part.isEmpty else { throw BusinessVMError.closed }; data.append(part)
        }
        let length = data.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 16_384 else { throw BusinessVMError.capacity }
        data.removeAll()
        while data.count < length {
            let part = try await connection.receive(maxBytes: min(4096, length - data.count))
            guard !part.isEmpty else { throw BusinessVMError.closed }; data.append(part)
        }
        return data
    }
    static func send(_ writer: BusinessVMFrameOutput) async throws {
        while !writer.completed {
            if try !writer.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
    static func receiveModel(_ connection: BusinessVMConnection) async throws -> BusinessHTTPIngress {
        var bytes = Data()
        while true {
            if let ingress = try BusinessHTTPIngress.parse(bytes) { return ingress }
            let part = try await connection.receive(maxBytes: 4096)
            guard !part.isEmpty else { throw BusinessVMError.closed }; bytes.append(part)
        }
    }
    static func main() async {
        var vm: BusinessVMSession?
        var displayForEvidence: BusinessDisplayOutput?
        var evidenceRoot: URL?
        do {
            let args = CommandLine.arguments
            guard (5...6).contains(args.count), let port = UInt16(args[4]), port != 0 else { throw BusinessVMError.invalidResource }
            let reflection = args.count == 6 && args[5] == "reflection"
            guard args.count == 5 || reflection else { throw BusinessVMError.invalidProfile }
            let root = URL(fileURLWithPath: args[3], isDirectory: true)
            evidenceRoot = root
            let bundle = try BusinessRuntimeBundle(directory: URL(fileURLWithPath: args[1], isDirectory: true), vendorDisk: URL(fileURLWithPath: args[2]))
            let source = root.appendingPathComponent("original", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try original.write(to: source.appendingPathComponent("logic.py"), options: [.withoutOverwriting])
            try test.write(to: source.appendingPathComponent("test_logic.py"), options: [.withoutOverwriting])
            let store = try WorkspaceStore(newRoot: root.appendingPathComponent("store").path)
            let snapshot = try store.importTree(from: source.path)
            let audit = try JSONLAuditSink(newFileAt: root.appendingPathComponent("audit.jsonl"))
            let authority = RunAuthorizationController(auditSink: audit)
            let modelConnection = try HostModelConnection.localClaudeFixture(port: port)
            let resource = "workspace:" + snapshot.id.grantSnapshotID.uuidString
            let scopes = try [ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream")] +
                ["read", "write", "execute"].map { try ResourceScope(service: "workspace", resource: resource, operation: $0) }
            let now = Date()
            let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(300),
                workloadImageDigest: bundle.imageSHA256, agentAdapterVersion: BusinessRuntimeBundle.profile,
                workspaceSnapshotID: snapshot.id.grantSnapshotID, policyDigest: String(repeating: "1", count: 64), approvalSnapshotID: UUID(),
                connections: [ConnectionGrant(connectionID: modelConnection.connectionID, accountBindingVersion: 1, routeVersion: 1, scopes: Set(scopes))], explicitDenies: [],
                resourceLimits: ResourceLimits(cpuCount: 2, memoryBytes: 1_073_741_824, diskBytes: 67_108_864, messageBytes: 65_536, concurrentRequests: 2))
            let handle = try await authority.install(grant: grant)
            let workspace = try WorkspaceRunSession.bind(store: store, snapshot: snapshot, authority: authority, handle: handle, grant: grant,
                limits: WorkspaceTaskLimits(retainedPayloadBytes: 1_048_576, diskBytes: 4_194_304, cumulativeInputBytes: 4_194_304))
            let gateway = try HostModelGateway(connections: [modelConnection], auditSink: audit, authority: authority)
            let modelHandle = try await gateway.install(grant: grant, authorityHandle: handle)
            let permissions = try HostCLIPermissionGateway(authority: authority, handle: handle, grant: grant, connectionID: modelConnection.connectionID)
            let session = try BusinessVMSession(authority: authority, handle: handle, grant: grant, bundle: bundle, sessionDirectory: root)
            vm = session
            try workspace.prepareTransfer(runtimeID: session.id)
            let display = BusinessDisplayOutput(lifecycle: handle.lifecycle, scope: try handle.lifecycle.runScope(for: handle, epoch: grant.epoch), runtimeID: session.id)
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
                                    guard try RuntimeJSON.parse(await frame(connection)).object == ["v": .integer(1), "type": .string("ready"), "profile": .string(BusinessRuntimeBundle.profile)] else { throw BusinessVMError.invalidProfile }
                                    let start = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "start", "mcp": false,
                                        "task": "Read logic.py, run python3 -B test_logic.py to observe the failure, fix the arithmetic bug in logic.py, then run the unchanged test again. Do not edit test_logic.py."], options: [.sortedKeys])
                                    try await send(session.makeFrameOutput(connection: connection, body: start))
                                    while true {
                                        guard let object = try RuntimeJSON.parse(await frame(connection)).object, object["v"] == .integer(1) else { throw BusinessVMError.invalidProfile }
                                        if object["type"] == .string("output") {
                                            guard Set(object.keys) == ["v", "type", "channel", "data", "sha256"],
                                                  let channel = object["channel"]?.string, ["stdout", "stderr"].contains(channel),
                                                  let encoded = object["data"]?.string, let bytes = Data(base64Encoded: encoded),
                                                  bytes.count <= 4096, bytes.base64EncodedString() == encoded,
                                                  object["sha256"]?.string == WorkspaceTransferWire.hash(bytes) else { throw BusinessVMError.invalidProfile }
                                            try display.enqueue(channel: channel, bytes: bytes, runtimeID: session.id)
                                            guard try display.acceptNext() else { throw BusinessVMError.invalidOwner }
                                        } else {
                                            guard Set(object.keys) == ["v", "type", "workspaceSHA256", "exit", "initialized", "isError", "outputBytes", "permissions", "timedOut"],
                                                  object["type"] == .string("finished"), object["exit"] == .integer(0),
                                                  object["initialized"] == .bool(true), object["isError"] == .bool(false), object["timedOut"] == .bool(false),
                                                  let sha = object["workspaceSHA256"]?.string else { throw BusinessVMError.invalidProfile }
                                            await state.finished(sha); report(["event": "guest.finished", "workspaceSHA256": sha]); break
                                        }
                                    }
                                case .workspace:
                                    while !workspace.transferCompleted {
                                        if let body = try workspace.receive(await frame(connection)) {
                                            try await send(session.makeFrameOutput(connection: connection, body: body))
                                        }
                                    }
                                    await state.transfer(); report(["event": "workspace.transfer-complete"])
                                case .model:
                                    let ingress = try await receiveModel(connection)
                                    let proposal = try await gateway.proposeVMClaude(handle: modelHandle, connectionID: modelConnection.connectionID, ingress: ingress, connection: connection)
                                    report(["event": "model.approval-sizes", "httpBytes": ingress.wireBytes, "rawBodyBytes": ingress.body.count,
                                            "canonicalBodyBytes": try ingress.claudeRequest().canonicalBody.count, "fullApprovalBytes": proposal.pendingAction.binding.canonicalRequest.count])
                                    let approval = try await gateway.hostApprove(handle: modelHandle, proposal: proposal)
                                    let output = try await gateway.makeVMNativeOutput(handle: modelHandle, approval: approval, connection: connection)
                                    let execution = Task { try await gateway.execute(handle: modelHandle, approval: approval, output: output) }
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
                                        do { try await execution.value }
                                        catch { rejected = error as? HostModelGatewayError == .outcomeUnknown }
                                        guard rejected, let progress = output.nativeProgress,
                                              progress.committedBytes == 0, progress.writeCalls == 0, progress.acceptedFinals == 0 else { throw BusinessVMError.invalidOwner }
                                        await state.reflection(); session.cancel(); return
                                    }
                                    try await execution.value
                                    guard let progress = output.nativeProgress, progress.committedBytes > 0, progress.acceptedFinals == 1 else { throw BusinessVMError.invalidOwner }
                                    await state.model(); report(["event": "model.native-response", "bytes": progress.committedBytes, "writeCalls": progress.writeCalls, "finals": progress.acceptedFinals,
                                                                "largestFrameBytes": progress.largestFrameBytes, "peakQueuedEvents": progress.peakQueuedEvents,
                                                                "peakBufferedBytes": progress.peakBufferedBytes, "cumulativeEnqueuedBytes": progress.cumulativeEnqueuedBytes])
                                case .permission:
                                    let bytes = try await frame(connection)
                                    try bytes.write(to: root.appendingPathComponent("permission-" + connection.id.uuidString + ".json"), options: [.withoutOverwriting])
                                    let request = try CLIPermissionRequest.parse(bytes)
                                    switch request.toolName {
                                    case "Bash": guard request.input["command"]?.string == "python3 -B test_logic.py" else { throw BusinessVMError.invalidProfile }
                                    case "Read": guard request.input["file_path"]?.string == "/work/project/logic.py" else { throw BusinessVMError.invalidProfile }
                                    case "Edit": guard request.input["file_path"]?.string == "/work/project/logic.py",
                                                       request.input["old_string"]?.string == "return a - b", request.input["new_string"]?.string == "return a + b" else { throw BusinessVMError.invalidProfile }
                                    default: throw BusinessVMError.invalidProfile
                                    }
                                    let proposal = try await permissions.propose(connection: connection, body: bytes)
                                    try await permissions.approveAndSend(proposal)
                                    await state.permission(); report(["event": "permission.normal-sdk", "tool": request.toolName])
                                case .mcp: throw BusinessVMError.invalidProfile
                                }
                            } catch {
                                report(["event": "channel.failed", "service": connection.service.rawValue, "error": errorLabel(error)])
                                await state.fail(error); connection.retire(); session.cancel()
                            }
                        }
                    }
                    await group.waitForAll()
                }
            }
            try await session.start()
            if reflection {
                while !(await state.reflectionComplete()) {
                    if !(await state.progress().4.isEmpty), !(await state.reflectionComplete()) { throw BusinessVMError.closed }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let stopped = await session.waitUntilStopped()
                await incoming.value
                let canary = try LocalClaudeFixtureCredential().credential(for: .deepSeekFlash)
                let output = display.snapshot
                guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved,
                      !output.stdout.contains(canary), !output.stderr.contains(canary) else { throw BusinessVMError.invalidOwner }
                try Data(output.stdout.utf8).write(to: root.appendingPathComponent("cli.stdout"), options: [.withoutOverwriting])
                try Data(output.stderr.utf8).write(to: root.appendingPathComponent("cli.stderr"), options: [.withoutOverwriting])
                report(["event": "PASS", "scope": "actual-VZ-active-fake-credential-reflection", "nativeBytes": 0, "nativeWriteCalls": 0,
                        "guestOutputCanaryOccurrences": 0, "actualStopped": true, "callbacksSettled": true, "realProvider": "NOT_RUN"])
                _ = await events.value; return
            }
            while true {
                let progress = await state.progress()
                guard progress.4.isEmpty, handle.lifecycle.currentStatus == .active else { throw BusinessVMError.closed }
                if progress.0 != nil, progress.1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            session.stopForResult()
            let stopped = await session.waitUntilStopped()
            await incoming.value
            let progress = await state.progress()
            guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved, progress.4.isEmpty,
                  progress.2 == 5, progress.3 >= 1 else { throw BusinessVMError.invalidOwner }
            let review = try workspace.sealAndAdopt(after: stopped)
            // The transfer wire digest and host review digest use different
            // domains. Compare wire to wire, then verify actual reviewed bytes.
            guard WorkspaceTransferWire.treeHash(["logic.py": fixed, "test_logic.py": test]) == progress.0,
                  review.changes.count == 1, review.changes[0].path == "logic.py",
                  review.changes[0].kind == .change else { throw BusinessVMError.invalidProfile }
            let exported = root.appendingPathComponent("exported", isDirectory: true)
            try workspace.exportReviewed(review, toNewDirectory: exported.path)
            guard try Data(contentsOf: source.appendingPathComponent("logic.py")) == original,
                  try Data(contentsOf: source.appendingPathComponent("test_logic.py")) == test,
                  try Data(contentsOf: exported.appendingPathComponent("logic.py")) == fixed,
                  try Data(contentsOf: exported.appendingPathComponent("test_logic.py")) == test else { throw BusinessVMError.invalidProfile }
            let output = display.snapshot
            try Data(output.stdout.utf8).write(to: root.appendingPathComponent("cli.stdout"), options: [.withoutOverwriting])
            try Data(output.stderr.utf8).write(to: root.appendingPathComponent("cli.stderr"), options: [.withoutOverwriting])
            let measurements = try await gateway.measurements(handle: modelHandle)
            report(["event": "model.run-measurements", "dispatches": measurements.dispatchedRequests, "outboundBodyBytes": measurements.outboundBodyBytes,
                    "configuredHeaderBytes": measurements.configuredHeaderBytes, "largestBodyBytes": measurements.largestBodyBytes,
                    "largestConfiguredHeaderBytes": measurements.largestConfiguredHeaderBytes, "peakActiveRequests": measurements.peakActiveRequests])
            report(["event": "PASS", "scope": "actual-VM-CLI-with-fixed-loopback-model", "models": progress.2, "normalPermissions": progress.3,
                    "actualStopped": stopped.actualStopped, "callbacksSettled": stopped.callbacksSettled, "originalUnchanged": true,
                    "originalTestsUnchanged": true, "onlyChangedPath": "logic.py", "reviewSHA256": review.sha256, "realProvider": "NOT_RUN", "hostProjectExecution": false])
            handle.lifecycle.terminate(.stopped); _ = await events.value
        } catch {
            vm?.cancel()
            if let vm { _ = await vm.waitUntilStopped() }
            if let displayForEvidence, let evidenceRoot {
                let output = displayForEvidence.snapshot
                try? Data(output.stdout.utf8).write(to: evidenceRoot.appendingPathComponent("cli.stdout"), options: [.withoutOverwriting])
                try? Data(output.stderr.utf8).write(to: evidenceRoot.appendingPathComponent("cli.stderr"), options: [.withoutOverwriting])
            }
            report(["event": "FAIL", "error": (error as? BusinessVMError).map { String(describing: $0) } ?? String(describing: type(of: error))]); exit(1)
        }
    }
}
