import Combine
import CryptoKit
import Foundation
import SandboxContracts
import SandboxHost

package enum BusinessTaskFailure: Error { case unavailable, cancelled, invalidFrame, incompleteResult, cleanupFailed }

private actor TaskWorkspaceOwner {
    struct Summary: Sendable { let id: UUID; let files: Int; let bytes: Int; let exclusions: [String] }
    private var store: WorkspaceStore?
    private var snapshot: WorkspaceSnapshot?
    func prepare(source: URL, root: URL) throws -> Summary {
        guard store == nil else { throw BusinessTaskFailure.unavailable }
        let value = try WorkspaceStore(newRoot: root.path)
        let snapshot = try value.importTree(from: source.path)
        store = value; self.snapshot = snapshot
        return Summary(id: snapshot.id.grantSnapshotID, files: snapshot.manifest.filter { !$0.directory }.count,
                       bytes: snapshot.manifest.reduce(0) { $0 + $1.bytes }, exclusions: snapshot.exclusions)
    }
    func bind(authority: RunAuthorizationController, handle: HostRunHandle, grant: RunGrant) throws -> WorkspaceRunSession {
        guard let store, let snapshot else { throw BusinessTaskFailure.unavailable }
        let limits = WorkspaceTaskLimits(retainedPayloadBytes: 64 * 1024 * 1024,
            diskBytes: 128 * 1024 * 1024, cumulativeInputBytes: 64 * 1024 * 1024)
        let session = try WorkspaceRunSession.bind(store: store, snapshot: snapshot,
            authority: authority, handle: handle, grant: grant, limits: limits)
        self.store = nil; self.snapshot = nil
        return session
    }
}

package struct BusinessFrameBuffer {
    private var buffer = Data()
    package init() {}
    package var isEmpty: Bool { buffer.isEmpty }
    package mutating func append(_ bytes: Data) throws {
        guard bytes.count <= 32_768 - buffer.count else { throw BusinessTaskFailure.invalidFrame }
        buffer.append(bytes)
    }
    package mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard (1...16_384).contains(length) else { throw BusinessTaskFailure.invalidFrame }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.index(buffer.startIndex, offsetBy: 4)
        let end = buffer.index(start, offsetBy: length)
        let result = Data(buffer[start..<end])
        // Data.removeFirst preserves its nonzero startIndex. Normalize the
        // retained bounded tail before a subsequent frame arrives.
        buffer = Data(buffer.dropFirst(4 + length))
        return result
    }
}

private actor BusinessFrameReader {
    private let connection: BusinessVMConnection
    private var frames = BusinessFrameBuffer()
    private var reading = false
    init(_ connection: BusinessVMConnection) { self.connection = connection }
    func next() async throws -> Data? {
        guard !reading else { throw BusinessTaskFailure.invalidFrame }; reading = true
        defer { reading = false }
        while true {
            if let next = try frames.next() { return next }
            let bytes = try await connection.receive(maxBytes: 4096)
            if bytes.isEmpty {
                guard frames.isEmpty else { throw BusinessTaskFailure.invalidFrame }; return nil
            }
            try frames.append(bytes)
        }
    }
}

private final class BusinessDecisionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let value = lock.withLock { () -> Bool? in
            if let result { return result }; self.continuation = continuation; return nil
        }
        if let value { continuation.resume(returning: value) }
    }
    func resolve(_ value: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard result == nil else { return nil }; result = value
            let pending = continuation; continuation = nil; return pending
        }
        pending?.resume(returning: value)
    }
}

@MainActor package final class BusinessTaskController: ObservableObject {
    package enum Agent: String, CaseIterable, Identifiable { case claude = "Claude Code 2.1.309", codex = "Codex — not implemented", dsh = "DSH — not implemented"; package var id: String { rawValue } }
    package struct Approval: Identifiable {
        package let id: UUID
        package let title: String
        package let details: String
        package let expiresAt: Date
    }
    @Published package var agent: Agent = .claude
    @Published package var task = ""
    @Published package var permissionsConfirmed = false
    @Published package var useMCP = false
    @Published package var allowMCPWrite = false
    @Published package private(set) var project: URL?
    @Published package private(set) var runtimeDirectory: URL?
    @Published package private(set) var vendorDisk: URL?
    @Published package private(set) var status = "Select a project, runtime and model connection."
    @Published package private(set) var error: String?
    @Published package private(set) var isBusy = false
    @Published package private(set) var isClosing = false
    @Published package private(set) var stdout = ""
    @Published package private(set) var stderr = ""
    @Published package private(set) var approvals: [Approval] = []
    @Published package private(set) var review: WorkspaceReview?
    @Published package private(set) var measurements: [String] = []
    @Published package private(set) var stopSummary: String?
    @Published package private(set) var importExclusions: [String] = []
    private unowned let composition: RunComposition
    private var generation = UUID()
    private var runTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var run: RunComposition.InstalledRun?
    private var vm: BusinessVMSession?
    private var workspace: WorkspaceRunSession?
    private var display: BusinessDisplayOutput?
    private var decisions: [UUID: BusinessDecisionWaiter] = [:]
    private var exportCancellation: WorkspaceExportCancellation?
    private var guestFinished = false
    private var transferFinished = false
    private var guestSucceeded = false
    private var resultStopRequested = false
    private var finishedDigest: String?
    private var transferredDigest: String?
    private var selectedConnectionID: UUID?
    private var selectedMCPConnectionID: UUID?

    package init(composition: RunComposition) { self.composition = composition }
    package var canStart: Bool {
        !isBusy && review == nil && !isClosing && !composition.isClosing && agent == .claude && project != nil &&
        runtimeDirectory != nil && vendorDisk != nil && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        task.utf8.count <= 8192 && permissionsConfirmed && composition.connectionSettings.configuration != nil &&
        !composition.mcpSettings.isBusy && (!useMCP || composition.mcpSettings.configuration != nil) &&
        composition.businessRouteAvailable
    }
    package var activationAvailable: Bool { composition.businessRouteAvailable }
    package var isLocalFixture: Bool { composition.isLocalFixture }
    package func selectProject(_ value: URL) { guard !isBusy else { return }; project = value; permissionsConfirmed = false }
    package func selectRuntime(_ value: URL) { guard !isBusy else { return }; runtimeDirectory = value; permissionsConfirmed = false }
    package func selectVendor(_ value: URL) { guard !isBusy else { return }; vendorDisk = value; permissionsConfirmed = false }

    package func start() {
        guard canStart, let project, let runtimeDirectory, let vendorDisk,
              let configuration = composition.connectionSettings.configuration else { return }
        isBusy = true; error = nil; stdout = ""; stderr = ""; measurements = []; stopSummary = nil; importExclusions = []
        run = nil; vm = nil; workspace = nil; display = nil
        selectedConnectionID = configuration.connectionID
        let mcpConfiguration = useMCP ? composition.mcpSettings.configuration : nil
        selectedMCPConnectionID = mcpConfiguration?.connectionID
        guestFinished = false; transferFinished = false; guestSucceeded = false; resultStopRequested = false
        finishedDigest = nil; transferredDigest = nil
        generation = UUID(); let token = generation, task = task
        runTask = Task { [self] in
            do { try await execute(project: project, runtime: runtimeDirectory, vendor: vendorDisk, task: task,
                configuration: configuration, mcpConfiguration: mcpConfiguration, token: token) }
            catch {
                if !(error is CancellationError), !(error is BusinessTaskFailure && generation != token) {
                    self.error = "Task stopped: \(String(describing: error))"
                }
                await cleanupFailure()
            }
            isBusy = false; runTask = nil
        }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation, !isClosing, !composition.isClosing else { throw BusinessTaskFailure.cancelled }
        if let run { guard run.authorityHandle.lifecycle.observeAndReduce(reason: "business-task-checkpoint").status == .active else { throw BusinessTaskFailure.cancelled } }
    }
    private func execute(project: URL, runtime: URL, vendor: URL, task: String,
                         configuration: FixedModelConnectionConfiguration, mcpConfiguration: LocalMCPConfiguration?, token: UUID) async throws {
        status = "Verifying runtime and copying the selected project…"
        let bundle = try await Task.detached { try BusinessRuntimeBundle(directory: runtime, vendorDisk: vendor) }.value
        try check(token)
        let parent = composition.businessTaskDirectory
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vmDirectory = root.appendingPathComponent("VM", isDirectory: true)
        try FileManager.default.createDirectory(at: vmDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let owner = TaskWorkspaceOwner()
        let summary = try await owner.prepare(source: project, root: root.appendingPathComponent("Workspace", isDirectory: true))
        try check(token)
        importExclusions = summary.exclusions
        let workspaceConnectionID = UUID(), resource = "workspace:" + summary.id.uuidString
        let modelScopes = try Set(["stream", "complete"].map { try ResourceScope(service: "model", resource: "deepseek-flash", operation: $0) })
        let workspaceScopes = try Set(["read", "write", "execute"].map { try ResourceScope(service: "workspace", resource: resource, operation: $0) })
        let now = Date()
        var connections = try [ConnectionGrant(connectionID: configuration.connectionID, accountBindingVersion: configuration.accountBindingVersion,
                routeVersion: configuration.routeVersion, scopes: modelScopes),
                ConnectionGrant(connectionID: workspaceConnectionID, accountBindingVersion: 1, routeVersion: 1, scopes: workspaceScopes)]
        if let mcpConfiguration {
            var scopes = try Set(["server/discover", "tools/list"].map { try ResourceScope(service: "mcp", resource: "control", operation: $0) })
            scopes.insert(try ResourceScope(service: "mcp", resource: "A", operation: "read"))
            if allowMCPWrite { scopes.insert(try ResourceScope(service: "mcp", resource: "A", operation: "write")) }
            connections.append(try ConnectionGrant(connectionID: mcpConfiguration.connectionID, accountBindingVersion: mcpConfiguration.version,
                routeVersion: mcpConfiguration.version, scopes: scopes))
        }
        let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: now, expiresAt: now.addingTimeInterval(900),
            workloadImageDigest: bundle.imageSHA256, agentAdapterVersion: BusinessRuntimeBundle.profile,
            workspaceSnapshotID: summary.id, policyDigest: bundle.profileSHA256, approvalSnapshotID: UUID(),
            connections: connections,
            explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 2, memoryBytes: 1_073_741_824,
                diskBytes: 536_870_912, messageBytes: 65_536, concurrentRequests: 2))
        let installed = try await composition.install(grant); run = installed
        try check(token)
        let registration = try composition.beginBusinessOwnership(installed)
        var cleanupSucceeded = false
        defer { composition.finishBusinessOwnership(registration, succeeded: cleanupSucceeded) }
        do {
            let workspace = try await owner.bind(authority: composition.authority, handle: installed.authorityHandle, grant: grant)
            self.workspace = workspace; try check(token)
            let vm = try BusinessVMSession(authority: composition.authority, handle: installed.authorityHandle,
                grant: grant, bundle: bundle, sessionDirectory: vmDirectory)
            self.vm = vm
            let events = Task { [weak self] in
                for await event in vm.events {
                    guard let self else { return }
                    if event == .stopping, !self.resultStopRequested {
                        self.status = "VM stopping · settling outstanding requests…"
                        for waiter in self.decisions.values { waiter.resolve(false) }
                    }
                }
            }
            defer { events.cancel() }
            try await Task.detached { try workspace.prepareTransfer(runtimeID: vm.id) }.value
            let display = BusinessDisplayOutput(lifecycle: installed.authorityHandle.lifecycle,
                scope: try installed.authorityHandle.lifecycle.runScope(for: installed.authorityHandle, epoch: grant.epoch), runtimeID: vm.id)
            self.display = display
            let permissionGateway = try HostCLIPermissionGateway(authority: composition.authority, handle: installed.authorityHandle,
                grant: grant, connectionID: workspaceConnectionID, mcpConnectionID: mcpConfiguration?.connectionID)
            status = "Starting Linux VM · \(summary.files) project files, \(summary.bytes) bytes"
            try await vm.start(); try check(token)
            status = "VM running · waiting for the Agent"
            try await withThrowingTaskGroup(of: Void.self) { group in
                for await connection in vm.incoming {
                    try check(token)
                    group.addTask { [self] in
                        do {
                            switch connection.service {
                            case .control: try await control(connection, vm: vm, task: task, mcp: mcpConfiguration != nil, token: token)
                            case .workspace: try await transfer(connection, vm: vm, workspace: workspace, token: token)
                            case .model: try await modelRequest(connection, run: installed, connectionID: configuration.connectionID, token: token)
                            case .permission: try await permission(connection, gateway: permissionGateway, token: token)
                            case .mcp:
                                guard let mcpConfiguration else { throw BusinessTaskFailure.unavailable }
                                try await mcpRequest(connection, run: installed, configuration: mcpConfiguration, token: token)
                            }
                        } catch { connection.retire(); vm.cancel(); throw error }
                    }
                }
                try await group.waitForAll()
            }
            let stopped = await vm.waitUntilStopped()
            stopSummary = "VM stopped: \(stopped.actualStopped) · callbacks settled: \(stopped.callbacksSettled) · private disk removed: \(stopped.diskRemoved)"
            guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved else { throw BusinessTaskFailure.cleanupFailed }
            cleanupSucceeded = true
            try check(token)
            guard guestFinished, transferFinished, guestSucceeded else { throw BusinessTaskFailure.incompleteResult }
            status = "VM stopped · validating and adopting the complete result…"
            let review = try await Task.detached { try workspace.sealAndAdopt(after: stopped) }.value
            try check(token)
            self.review = review
            try await composition.workbench.stop(runID: grant.runID)
            status = "Result ready for review. Run authorization is stopped."
            self.vm = nil
        } catch {
            vm?.cancel(); workspace?.cancel(); display?.cancel()
            if let vm {
                let stopped = await vm.waitUntilStopped()
                cleanupSucceeded = stopped.actualStopped && stopped.callbacksSettled && stopped.diskRemoved
                stopSummary = "VM stopped: \(stopped.actualStopped) · callbacks settled: \(stopped.callbacksSettled) · private disk removed: \(stopped.diskRemoved)"
            } else { cleanupSucceeded = true }
            throw error
        }
    }

    private func control(_ connection: BusinessVMConnection, vm: BusinessVMSession, task: String, mcp: Bool, token: UUID) async throws {
        defer { connection.retire() }
        let reader = BusinessFrameReader(connection)
        guard let first = try await reader.next(), let ready = try ModelJSON.parse(first).object,
              Set(ready.keys) == ["v", "type", "profile"], ready["v"] == .integer(1), ready["type"]?.string == "ready",
              ready["profile"]?.string == BusinessRuntimeBundle.profile else { throw BusinessTaskFailure.invalidFrame }
        try check(token)
        let start = ModelJSON.object(["v": .integer(1), "type": .string("start"), "task": .string(task), "mcp": .bool(mcp)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try await sendFrame(vm, connection, body: encoder.encode(start))
        while let bytes = try await reader.next() {
            try check(token)
            let value = try ModelJSON.parse(bytes)
            guard value["v"] == .integer(1), let fields = value.object else { throw BusinessTaskFailure.invalidFrame }
            switch value["type"]?.string {
            case "output":
                guard !guestFinished, Set(fields.keys) == ["v", "type", "channel", "data", "sha256"],
                      let channel = value["channel"]?.string, let encoded = value["data"]?.string,
                      let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded,
                      value["sha256"]?.string == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined(),
                      let display else { throw BusinessTaskFailure.invalidFrame }
                try display.enqueue(channel: channel, bytes: bytes, runtimeID: vm.id)
                _ = try display.acceptNext()
                let snapshot = display.snapshot; stdout = snapshot.stdout; stderr = snapshot.stderr
            case "finished":
                guard !guestFinished, Set(fields.keys) == ["v", "type", "workspaceSHA256", "exit", "initialized", "isError", "outputBytes", "permissions", "timedOut"],
                      let exit = value["exit"]?.integer, let outputBytes = value["outputBytes"]?.integer,
                      let permissions = value["permissions"]?.integer, (0...131_072).contains(outputBytes), (0...64).contains(permissions),
                      let digest = value["workspaceSHA256"]?.string, digest.utf8.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw BusinessTaskFailure.invalidFrame }
                guestFinished = true
                finishedDigest = digest
                guestSucceeded = exit == 0 && value["initialized"] == .bool(true) && value["isError"] == .bool(false) && value["timedOut"] == .bool(false)
                status = "Agent exited; waiting for sealed files and physical VM stop."
                try requestResultStop(vm)
                return
            default: throw BusinessTaskFailure.invalidFrame
            }
        }
        throw BusinessTaskFailure.incompleteResult
    }
    private func transfer(_ connection: BusinessVMConnection, vm: BusinessVMSession, workspace: WorkspaceRunSession, token: UUID) async throws {
        defer { connection.retire() }
        let reader = BusinessFrameReader(connection)
        while let bytes = try await reader.next() {
            try check(token)
            let next = try await Task.detached { try workspace.receive(bytes) }.value
            if let next { try await sendFrame(vm, connection, body: next) }
            if workspace.transferCompleted {
                let complete = try ModelJSON.parse(bytes)
                guard complete["type"]?.string == "complete", let digest = complete["sha256"]?.string else { throw BusinessTaskFailure.invalidFrame }
                transferredDigest = digest
                transferFinished = true; try requestResultStop(vm); return
            }
        }
        throw BusinessTaskFailure.incompleteResult
    }
    private func requestResultStop(_ vm: BusinessVMSession) throws {
        guard guestFinished, transferFinished, !resultStopRequested else { return }
        guard let finishedDigest, let transferredDigest, finishedDigest == transferredDigest else { throw BusinessTaskFailure.incompleteResult }
        resultStopRequested = true; vm.stopForResult()
    }
    private func sendFrame(_ vm: BusinessVMSession, _ connection: BusinessVMConnection, body: Data) async throws {
        let output = try vm.makeFrameOutput(connection: connection, body: body)
        defer { output.cancel() }
        while !output.completed {
            try Task.checkCancellation()
            if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
    private func modelRequest(_ connection: BusinessVMConnection, run: RunComposition.InstalledRun,
                              connectionID: UUID, token: UUID) async throws {
        defer { connection.retire() }
        var bytes = Data()
        var ingress: BusinessHTTPIngress?
        while ingress == nil {
            let next = try await connection.receive(maxBytes: 4096)
            guard !next.isEmpty, next.count <= BusinessHTTPIngress.maxWireBytes - bytes.count else { throw BusinessTaskFailure.invalidFrame }
            bytes.append(next); ingress = try BusinessHTTPIngress.parse(bytes)
        }
        try check(token)
        let value = ingress!
        let proposal = try await run.modelGateway.proposeVMClaude(handle: run.modelHandle, connectionID: connectionID, ingress: value, connection: connection)
        let request = try value.claudeRequest()
        let messages = request.body["messages"]?.array ?? []
        let results = messages.flatMap { $0["content"]?.array ?? [] }.filter { $0["type"]?.string == "tool_result" }
        let resultBytes = try results.reduce(0) { try $0 + JSONEncoder().encode($1).count }
        guard measurements.count < 256 else { throw BusinessTaskFailure.invalidFrame }
        measurements.append("HTTP \(value.wireBytes) · headers \(value.headerBytes) · body \(value.body.count) · canonical \(request.canonicalBody.count) · approval \(proposal.pendingAction.binding.canonicalRequest.count) bytes · history \(messages.count) · tools \(request.body["tools"]?.array?.count ?? 0) · tool-result bytes \(resultBytes)")
        let approved = await ask(proposal.pendingAction, title: "Send one model request", details: String(decoding: proposal.pendingAction.binding.canonicalRequest, as: UTF8.self))
        try check(token)
        guard approved else { try await run.modelGateway.hostDeny(handle: run.modelHandle, proposal: proposal); throw BusinessTaskFailure.cancelled }
        let approval = try await run.modelGateway.hostApprove(handle: run.modelHandle, proposal: proposal)
        let output = try await run.modelGateway.makeVMNativeOutput(handle: run.modelHandle, approval: approval, connection: connection)
        defer { output.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await run.modelGateway.execute(handle: run.modelHandle, approval: approval, output: output) }
            group.addTask {
                while output.nativeProgress?.closed == false {
                    try Task.checkCancellation()
                    if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
                }
                guard output.nativeProgress?.acceptedFinals == 1 else { throw BusinessTaskFailure.incompleteResult }
            }
            do { try await group.waitForAll() }
            catch { group.cancelAll(); output.cancel(); throw error }
        }
        let sent = try await run.modelGateway.measurements(handle: run.modelHandle)
        try check(token)
        if let received = output.nativeProgress {
            guard measurements.count < 256 else { throw BusinessTaskFailure.invalidFrame }
            measurements.append("Dispatches \(sent.dispatchedRequests) · cumulative outbound body/configured headers \(sent.outboundBodyBytes)/\(sent.configuredHeaderBytes) bytes · peak concurrent \(sent.peakActiveRequests) · response frame max \(received.largestFrameBytes) · queue peak \(received.peakQueuedEvents)/\(received.peakBufferedBytes) bytes · enqueued/sent \(received.cumulativeEnqueuedBytes)/\(received.committedBytes) bytes")
        }
    }
    private func permission(_ connection: BusinessVMConnection, gateway: HostCLIPermissionGateway, token: UUID) async throws {
        defer { connection.retire() }
        let reader = BusinessFrameReader(connection)
        guard let bytes = try await reader.next() else { throw BusinessTaskFailure.invalidFrame }
        try check(token)
        let proposal = try await gateway.propose(connection: connection, body: bytes)
        let allowed = await ask(proposal.pending, title: "Claude wants to use \(proposal.toolName)", details: proposal.argumentsJSON)
        try check(token)
        if allowed { try await gateway.approveAndSend(proposal) }
        else { try await gateway.deny(proposal) }
    }
    private func mcpRequest(_ connection: BusinessVMConnection, run: RunComposition.InstalledRun,
                            configuration: LocalMCPConfiguration, token: UUID) async throws {
        defer { connection.retire() }
        var bytes = Data(), ingress: ClaudeMCPIngress?
        while ingress == nil {
            let next = try await connection.receive(maxBytes: 4096)
            guard !next.isEmpty, next.count <= 81_920 - bytes.count else { throw BusinessTaskFailure.invalidFrame }
            bytes.append(next); ingress = try ClaudeMCPIngress.parse(bytes)
        }
        try check(token)
        let value = ingress!
        let proposal = try await run.mcpGateway.proposeVMClient(handle: run.mcpHandle, connectionID: configuration.connectionID,
            ingress: value, connection: connection)
        guard measurements.count < 256 else { throw BusinessTaskFailure.invalidFrame }
        measurements.append("MCP \(value.selectors.method) · HTTP \(bytes.count) · body \(value.body.count) · approval \(proposal.pendingAction.binding.canonicalRequest.count) bytes")
        let allowed = await ask(proposal.pendingAction, title: "MCP · \(value.selectors.method) · \(proposal.pendingAction.binding.resolvedResource)",
            details: String(decoding: proposal.pendingAction.binding.canonicalRequest, as: UTF8.self))
        try check(token)
        guard allowed else { try await run.mcpGateway.hostDeny(handle: run.mcpHandle, proposal: proposal); return }
        let approval = try await run.mcpGateway.hostApprove(handle: run.mcpHandle, proposal: proposal)
        let output = try await run.mcpGateway.makeVMNativeOutput(handle: run.mcpHandle, approval: approval, connection: connection)
        defer { output.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await run.mcpGateway.execute(handle: run.mcpHandle, approval: approval, output: output) }
            group.addTask {
                while output.nativeProgress?.closed == false {
                    try Task.checkCancellation()
                    if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
                }
                guard output.nativeProgress?.acceptedFinals == 1 else { throw BusinessTaskFailure.incompleteResult }
            }
            do { try await group.waitForAll() }
            catch { group.cancelAll(); output.cancel(); throw error }
        }
        try check(token)
        if let progress = output.nativeProgress {
            guard measurements.count < 256 else { throw BusinessTaskFailure.invalidFrame }
            measurements.append("MCP actual response \(progress.committedBytes) bytes · frame max \(progress.largestFrameBytes) · queue peak \(progress.peakBufferedBytes) bytes")
        }
    }
    private func ask(_ pending: PendingAction, title: String, details: String) async -> Bool {
        guard decisions.count < 4, !isClosing, !Task.isCancelled else { return false }
        let waiter = BusinessDecisionWaiter(); decisions[pending.actionID] = waiter
        let delay = max(0, min(900, pending.expiresAt.timeIntervalSinceNow))
        let expiry = Task {
            do { try await Task.sleep(for: .seconds(delay)); waiter.resolve(false) }
            catch {}
        }
        approvals.append(Approval(id: pending.actionID, title: title, details: details, expiresAt: pending.expiresAt))
        defer { expiry.cancel(); decisions.removeValue(forKey: pending.actionID); approvals.removeAll { $0.id == pending.actionID } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter.install($0) }
        } onCancel: { waiter.resolve(false) }
    }
    package func decide(_ id: UUID, allow: Bool) { decisions[id]?.resolve(allow) }
    package func finishReview() {
        guard !isBusy, !isClosing else { return }
        review = nil; workspace = nil
        status = "Review closed. The task snapshot remains in the private task directory."
    }
    package func expireApprovals() {
        for approval in approvals where approval.expiresAt <= Date() { decisions[approval.id]?.resolve(false) }
    }
    package func cancel() {
        generation = UUID()
        run?.authorityHandle.lifecycle.terminate(.stopped)
        vm?.cancel(); workspace?.cancel(); display?.cancel(); exportCancellation?.cancel()
        for waiter in decisions.values { waiter.resolve(false) }
        runTask?.cancel(); exportTask?.cancel()
        if isBusy { status = "Stopping · waiting for the actual VM and callbacks…" }
    }
    package func retireModelConnections(_ ids: Set<UUID>) {
        guard runTask != nil, let selectedConnectionID, ids.contains(selectedConnectionID) else { return }
        cancel()
    }
    package func retireMCPConnections(_ ids: Set<UUID>) {
        guard runTask != nil, let selectedMCPConnectionID, ids.contains(selectedMCPConnectionID) else { return }
        cancel()
    }
    package func beginClose() { isClosing = true; cancel() }
    package func waitForCleanup() async { await runTask?.value; await exportTask?.value }
    private func cleanupFailure() async {
        run?.authorityHandle.lifecycle.terminate(.stopped)
        if let run { try? await composition.workbench.stop(runID: run.grant.runID) }
        workspace?.discardTransfer()
        if review == nil { status = "Stopped without an adopted result. See the error and cleanup status." }
    }
    package func export(to destination: URL) {
        guard !isBusy, !isClosing, let workspace, let review else { return }
        let cancellation = WorkspaceExportCancellation(); exportCancellation = cancellation; isBusy = true
        exportTask = Task { [self] in
            do {
                try await Task.detached { try workspace.exportReviewedAfterStop(review, toNewDirectory: destination.path, actionCancellation: cancellation) }.value
                status = "Exported the reviewed snapshot to \(destination.lastPathComponent). The original project was not overwritten."
            } catch { self.error = "Export failed: \(String(describing: error))" }
            exportCancellation = nil; isBusy = false; exportTask = nil
        }
    }
}
