import Foundation
import SandboxContracts
import Darwin

/// Actual VM/CLI negative fixture. Its fixed synthetic model tool_use only
/// obtains a real permission channel; it is not provider/product acceptance.
@main struct PermissionClockProbe {
    static func report(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
    static func frame(_ connection: BusinessVMConnection) async throws -> Data {
        var bytes = Data()
        while bytes.count < 4 {
            let part = try await connection.receive(maxBytes: 4 - bytes.count)
            guard !part.isEmpty else { throw BusinessVMError.closed }; bytes.append(part)
        }
        let size = bytes.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...16_384).contains(size) else { throw BusinessVMError.capacity }
        bytes.removeAll()
        while bytes.count < size {
            let part = try await connection.receive(maxBytes: min(4096, size - bytes.count))
            guard !part.isEmpty else { throw BusinessVMError.closed }; bytes.append(part)
        }
        return bytes
    }
    static func send(_ writer: BusinessVMFrameOutput) async throws {
        while !writer.completed {
            if try !writer.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
    static func http(_ connection: BusinessVMConnection) async throws -> BusinessHTTPIngress {
        var bytes = Data()
        while true {
            let part = try await connection.receive(maxBytes: 4096)
            guard !part.isEmpty, part.count <= BusinessHTTPIngress.maxWireBytes - bytes.count else { throw BusinessVMError.capacity }
            bytes.append(part)
            if let request = try BusinessHTTPIngress.parse(bytes) { _ = try request.claudeRequest(); return request }
        }
    }
    static func injectSyntheticTool(_ connection: BusinessVMConnection, handle: HostRunHandle, modelID: UUID) async throws {
        let output = try ControlledRunOutput(lifecycle: handle.lifecycle, scope: handle.lifecycle.effectScope(connectionID: modelID),
            actionID: UUID(), takingVMConnection: connection, streaming: true)
        defer { output.cancel() }
        let input = ModelJSON.object(["file_path": .string("/work/project/permission-canary.txt"), "content": .string("permission-fixture")])
        let block = ModelBlock.toolUse(id: "tool_permission_clock", name: "Write", input: input)
        let empty = ModelBlock.toolUse(id: "tool_permission_clock", name: "Write", input: .object([:]))
        let usage = try ModelUsage(wire: .object(["input_tokens": .integer(1), "output_tokens": .integer(2)]))
        let start = ModelMetadata(messageID: "msg_permission_clock", model: "deepseek-flash", usage: usage)
        let end = ModelMetadata(messageID: "msg_permission_clock", model: "deepseek-flash", usage: usage, stopReason: "tool_use")
        let completion = ModelCompletion(blocks: [block], metadata: end)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let events: [ModelStreamEvent] = [.messageStart(start), .blockStart(index: 0, block: empty),
            .inputJSONDelta(index: 0, partialJSON: String(decoding: try encoder.encode(input), as: UTF8.self)),
            .blockStop(index: 0, block: block), .messageDelta(end), .messageStop(completion)]
        for event in events { try output.enqueue(.modelChunk(ModelStreamChunk(event: event))) }
        while output.nativeProgress?.closed == false {
            if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard output.nativeProgress?.acceptedFinals == 1 else { throw BusinessVMError.io }
        report(["event": "synthetic-tool-model-delivered", "actualVZ": true, "bytes": output.nativeProgress!.committedBytes, "provider": "NOT_RUN"])
    }
    final class LockedAttempt: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        private let resultLock = NSLock()
        private var error: Error?
        func run(_ writer: BusinessVMFrameOutput) {
            ready.signal()
            do { _ = try writer.acceptNext() } catch { resultLock.withLock { self.error = error } }
            done.signal()
        }
        func hold(_ lifecycle: RunLifecycle, clock: RunClock, writer: BusinessVMFrameOutput) throws -> Error? {
            guard let mutex = Mirror(reflecting: lifecycle).children.first(where: { $0.label == "lock" })?.value as? NSLock else { throw BusinessVMError.invalidOwner }
            mutex.lock()
            DispatchQueue.global().async { self.run(writer) }
            let reached = ready.wait(timeout: .now() + 5) == .success
            guard let writerMutex = Mirror(reflecting: writer).children.first(where: { $0.label == "lock" })?.value as? NSLock else { mutex.unlock(); throw BusinessVMError.invalidOwner }
            var writerOwned = false
            let limit = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < limit {
                if writerMutex.try() { writerMutex.unlock(); Thread.sleep(forTimeInterval: 0.001) }
                else { writerOwned = true; break }
            }
            let blocked = done.wait(timeout: .now() + 0.05) == .timedOut
            clock.advance(300); mutex.unlock()
            guard reached, writerOwned, blocked, done.wait(timeout: .now() + 5) == .success else { throw BusinessVMError.timeout }
            return resultLock.withLock { error }
        }
    }
    static func main() async {
        var vm: BusinessVMSession?
        do {
            let args = CommandLine.arguments
            guard args.count == 5, ["expiry", "lock-expiry", "not-before", "stop", "deny"].contains(args[4]) else { throw BusinessVMError.invalidResource }
            let mode = args[4], root = URL(fileURLWithPath: args[3], isDirectory: true)
            let bundle = try BusinessRuntimeBundle(directory: URL(fileURLWithPath: args[1]), vendorDisk: URL(fileURLWithPath: args[2]))
            let source = root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("permission-clock synthetic project\n".utf8).write(to: source.appendingPathComponent("README.txt"), options: [.withoutOverwriting])
            let store = try WorkspaceStore(newRoot: root.appendingPathComponent("workspace", isDirectory: true).path)
            let snapshot = try store.importTree(from: source.path)
            let now = Date(), clock = RunClock.manual(wall: now, elapsed: .zero), modelID = UUID(), workspaceID = UUID()
            let authority = RunAuthorizationController(auditSink: try JSONLAuditSink(newFileAt: root.appendingPathComponent("audit.jsonl")), clock: clock)
            let scope = try ResourceScope(service: "workspace", resource: "workspace:" + snapshot.id.grantSnapshotID.uuidString, operation: "write")
            let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(600),
                workloadImageDigest: bundle.imageSHA256, agentAdapterVersion: BusinessRuntimeBundle.profile,
                workspaceSnapshotID: snapshot.id.grantSnapshotID, policyDigest: bundle.profileSHA256, approvalSnapshotID: UUID(),
                connections: [ConnectionGrant(connectionID: workspaceID, accountBindingVersion: 1, routeVersion: 1, scopes: [scope]),
                    ConnectionGrant(connectionID: modelID, accountBindingVersion: 1, routeVersion: 1, scopes: [try ResourceScope(service: "model", resource: "deepseek-flash", operation: "stream")])],
                explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 2, memoryBytes: 1_073_741_824, diskBytes: 67_108_864, messageBytes: 65_536, concurrentRequests: 2))
            let handle = try await authority.install(grant: grant)
            let workspace = try WorkspaceRunSession.bind(store: store, snapshot: snapshot, authority: authority, handle: handle, grant: grant,
                limits: WorkspaceTaskLimits(retainedPayloadBytes: 65_536, diskBytes: 65_536, cumulativeInputBytes: 65_536))
            let session = try BusinessVMSession(authority: authority, handle: handle, grant: grant, bundle: bundle, sessionDirectory: root); vm = session
            try workspace.prepareTransfer(runtimeID: session.id)
            let watchdog = Task { try? await Task.sleep(for: .seconds(90)); if !Task.isCancelled { session.cancel() } }
            defer { watchdog.cancel() }
            try await session.start()
            var incoming = session.incoming.makeAsyncIterator()
            guard let control = await incoming.next(), control.service == .control,
                  try RuntimeJSON.parse(await frame(control)).object == ["v": .integer(1), "type": .string("ready"), "profile": .string(BusinessRuntimeBundle.profile)] else { throw BusinessVMError.invalidOwner }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let start = try encoder.encode(ModelJSON.object(["v": .integer(1), "type": .string("start"), "task": .string("Create permission-canary.txt with the text permission-fixture."), "mcp": .bool(false)]))
            try await send(session.makeFrameOutput(connection: control, body: start))
            guard let transfer = await incoming.next(), transfer.service == .workspace else { throw BusinessVMError.invalidOwner }
            var next = try workspace.receive(await frame(transfer))
            while let body = next {
                try await send(session.makeFrameOutput(connection: transfer, body: body))
                next = try workspace.receive(await frame(transfer))
            }
            guard let model = await incoming.next(), model.service == .model else { throw BusinessVMError.invalidOwner }
            let request = try await http(model)
            report(["event": "actual-cli-request", "bytes": request.wireBytes, "credentialReads": 0])
            try await injectSyntheticTool(model, handle: handle, modelID: modelID)
            guard let permission = await incoming.next(), permission.service == .permission else { throw BusinessVMError.invalidOwner }
            let body = try await frame(permission)
            try body.write(to: root.appendingPathComponent("permission-request.json"), options: [.withoutOverwriting])
            let parsed = try CLIPermissionRequest.parse(body)
            guard parsed.toolName == "Write", parsed.input["file_path"]?.string == "/work/project/permission-canary.txt" else { throw BusinessVMError.invalidOwner }
            let binding = try ActionBinding(runID: grant.runID, epoch: grant.epoch, grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: workspaceID,
                operation: "write", schemaDigest: String(repeating: "a", count: 64), resolvedResource: scope.resource, canonicalRequest: body)
            let pending = try await authority.propose(handle: handle, binding: binding, display: "Synthetic permission clock fixture")
            let response: Data
            var ticket: DispatchTicket?
            if mode == "deny" {
                try await authority.deny(handle: handle, actionID: pending.actionID)
                response = Data(#"{"behavior":"deny","message":"permission-clock-denial"}"#.utf8)
            } else {
                let approved = try await authority.hostApprove(handle: handle, actionID: pending.actionID, nonce: pending.nonce)
                ticket = try await authority.consume(handle: handle, approved: approved)
                response = try encoder.encode(ModelJSON.object(["behavior": .string("allow"), "updatedInput": parsed.input]))
            }
            let writer = try BusinessVMFrameOutput(connection: permission, handle: handle, scope: handle.lifecycle.effectScope(connectionID: workspaceID),
                body: response, actionID: pending.actionID, notBefore: grant.createdAt, startDeadline: pending.expiresAt)
            var caught: Error?
            if mode == "deny" {
                try await send(writer)
                guard let followup = await incoming.next(), followup.service == .model else { throw BusinessVMError.invalidOwner }
                let actual = try await http(followup)
                guard actual.body.contains(Data("permission-clock-denial".utf8)) else { throw BusinessVMError.invalidOwner }
                report(["event": "actual-cli-observed-denial", "replyBytes": writer.committedBytes, "followupHTTPBytes": actual.wireBytes])
                followup.retire()
            } else if mode == "lock-expiry" { caught = try LockedAttempt().hold(handle.lifecycle, clock: clock, writer: writer) }
            else {
                if mode == "expiry" { clock.advance(300) }
                if mode == "not-before" { clock.set(wall: grant.createdAt.addingTimeInterval(-1), elapsed: .zero) }
                if mode == "stop" { session.cancel() }
                do { _ = try writer.acceptNext() } catch { caught = error }
            }
            if mode != "deny" {
                let expected: AuthorizationError = mode == "stop" ? .runRevoked : mode == "not-before" ? .grantNotYetValid : .actionExpired
                let denied = caught as? AuthorizationError == expected || (mode == "stop" && caught as? BusinessVMError == .closed)
                report(["event": "permission-final-observation", "mode": mode, "writeCalls": writer.writeCalls, "committedBytes": writer.committedBytes,
                    "expectedDenial": denied, "runStillActive": handle.lifecycle.currentStatus == .active, "actualPermissionOwner": true])
                guard denied, writer.committedBytes == 0, writer.writeCalls == 0 else { throw BusinessVMError.invalidOwner }
                if mode == "expiry" || mode == "lock-expiry" { guard handle.lifecycle.currentStatus == .active else { throw BusinessVMError.invalidOwner } }
            }
            if let ticket { try await authority.complete(handle: handle, ticket: ticket, outcome: .failed) }
            writer.cancel(); workspace.cancel(); workspace.discardTransfer(); session.cancel()
            let stopped = await session.waitUntilStopped()
            guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved else { throw BusinessVMError.timeout }
            report(["event": "PASS", "mode": mode, "actualStopped": true, "callbacksSettled": true, "diskRemoved": true,
                "provider": "NOT_RUN", "imageSHA256": bundle.imageSHA256])
        } catch {
            vm?.cancel()
            if let vm { _ = await vm.waitUntilStopped() }
            report(["event": "FAIL", "errorType": String(describing: type(of: error)), "error": String(describing: error)]); exit(1)
        }
    }
}
