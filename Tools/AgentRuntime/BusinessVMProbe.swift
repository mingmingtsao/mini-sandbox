import Foundation
import SandboxContracts
import Darwin

/// Explicit diagnostic entry point for the production VM owner. Never contacts
/// a provider, reads Keychain, edits task files, or manufactures tool results.
@main struct BusinessVMProbe {
    static func report(_ value: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: bytes, as: UTF8.self)); fflush(stdout)
    }
    static func frame(_ connection: BusinessVMConnection) async throws -> Data {
        var buffer = Data()
        while buffer.count < 4 {
            let part = try await connection.receive(maxBytes: 4 - buffer.count)
            guard !part.isEmpty else { throw BusinessVMError.closed }; buffer.append(part)
        }
        let count = buffer.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 16_384 else { throw BusinessVMError.capacity }
        buffer.removeAll()
        while buffer.count < count {
            let part = try await connection.receive(maxBytes: min(4096, count - buffer.count))
            guard !part.isEmpty else { throw BusinessVMError.closed }; buffer.append(part)
        }
        return buffer
    }
    static func flush(_ output: BusinessVMFrameOutput) async throws {
        while !output.completed {
            if try !output.acceptNext() { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
    static func main() async {
        var vm: BusinessVMSession?
        do {
            let args = CommandLine.arguments
            guard args.count == 5 else { throw BusinessVMError.invalidResource }
            let mode = args[4]
            guard ["ready", "cancel-start", "control-stop", "control-expiry", "control-partial-stop", "control-partial-expiry", "workspace-stop", "workspace-expiry", "model-ingress"].contains(mode)
            else { throw BusinessVMError.invalidProfile }
            let root = URL(fileURLWithPath: args[3], isDirectory: true)
            let bundle = try BusinessRuntimeBundle(directory: URL(fileURLWithPath: args[1], isDirectory: true), vendorDisk: URL(fileURLWithPath: args[2]))
            let wall = Date(), clock = RunClock.manual(wall: Date(), elapsed: .zero)
            let authority = RunAuthorizationController(auditSink: try JSONLAuditSink(newFileAt: root.appendingPathComponent("audit.jsonl")), clock: clock)
            let grant = try RunGrant(runID: UUID(), epoch: 1, createdAt: wall.addingTimeInterval(-1), expiresAt: wall.addingTimeInterval(300),
                workloadImageDigest: bundle.imageSHA256, agentAdapterVersion: BusinessRuntimeBundle.profile,
                workspaceSnapshotID: UUID(), policyDigest: String(repeating: "1", count: 64), approvalSnapshotID: UUID(),
                connections: [], explicitDenies: [], resourceLimits: ResourceLimits(cpuCount: 2, memoryBytes: 1_073_741_824,
                diskBytes: 67_108_864, messageBytes: 65_536, concurrentRequests: 2))
            let handle = try await authority.install(grant: grant)
            let session = try BusinessVMSession(authority: authority, handle: handle, grant: grant, bundle: bundle, sessionDirectory: root)
            vm = session
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { session.cancel() }
            }
            defer { watchdog.cancel() }
            let events = Task {
                for await event in session.events {
                    report(["event": "vm." + event.rawValue])
                    if mode == "cancel-start", event == .starting { session.cancel() }
                }
            }
            if mode == "cancel-start" {
                do { try await session.start(); throw BusinessVMError.invalidOwner }
                catch { report(["event": "start-cancelled", "returnedError": true]) }
            } else {
                try await session.start()
                var incoming = session.incoming.makeAsyncIterator()
                guard let control = await incoming.next(), control.service == .control,
                      try RuntimeJSON.parse(await frame(control)).object == ["v": .integer(1), "type": .string("ready"), "profile": .string(BusinessRuntimeBundle.profile)]
                else { throw BusinessVMError.invalidProfile }
                report(["event": "guest.control-ready", "actualVMOwner": true])
                if mode == "ready" { session.cancel() }
                else {
                    var body = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "start", "task": "Read logic.py and run python3 -B test_logic.py. Do not edit files.", "mcp": false], options: [.sortedKeys])
                    if mode.contains("partial") { body.append(Data(repeating: 32, count: 16_384 - body.count)) }
                    let start = try session.makeFrameOutput(connection: control, body: body)
                    if mode.hasPrefix("control-") {
                        if mode.contains("partial") {
                            guard try start.acceptNext(), start.committedBytes > 0, start.committedBytes < body.count + 4 else { throw BusinessVMError.invalidOwner }
                        }
                        let beforeBytes = start.committedBytes, beforeCalls = start.writeCalls
                        if mode.hasSuffix("expiry") { clock.advance(301) } else { session.cancel() }
                        var denied = false
                        do { _ = try start.acceptNext() }
                        catch { denied = error as? AuthorizationError == .runRevoked || error as? BusinessVMError == .closed }
                        guard denied, start.committedBytes == beforeBytes, start.writeCalls == beforeCalls else { throw BusinessVMError.invalidOwner }
                        report(["event": "control.denied", "priorBytes": beforeBytes, "newBytes": start.committedBytes - beforeBytes, "newWriteCalls": start.writeCalls - beforeCalls])
                    } else {
                        try await flush(start)
                        guard let workspace = await incoming.next(), workspace.service == .workspace else { throw BusinessVMError.invalidOwner }
                        let ready = try await frame(workspace)
                        guard try RuntimeJSON.parse(ready).object == ["v": .integer(1), "type": .string("ready")] else { throw BusinessVMError.invalidProfile }
                        report(["event": "guest.received-start", "controlBytes": start.committedBytes])
                        let files = ["logic.py": Data("def add(a, b):\n    return a - b\n".utf8),
                                     "test_logic.py": Data("from logic import add\nassert add(2, 3) == 5\n".utf8)]
                        let flow = try WorkspaceTransferFlow(files: files)
                        var next = try flow.receive(ready)
                        if mode.hasPrefix("workspace-") {
                            let write = try session.makeFrameOutput(connection: workspace, body: next!)
                            if mode.hasSuffix("expiry") { clock.advance(301) } else { session.cancel() }
                            var denied = false
                            do { _ = try write.acceptNext() }
                            catch { denied = error as? AuthorizationError == .runRevoked || error as? BusinessVMError == .closed }
                            guard denied, write.committedBytes == 0, write.writeCalls == 0 else { throw BusinessVMError.invalidOwner }
                            report(["event": "workspace.denied", "bytes": write.committedBytes, "writeCalls": write.writeCalls])
                        } else {
                            while let body = next {
                                try await flush(session.makeFrameOutput(connection: workspace, body: body))
                                next = try flow.receive(await frame(workspace))
                            }
                            report(["event": "workspace.import-acked", "files": files.count, "sha256": WorkspaceTransferWire.treeHash(files)])
                            guard let model = await incoming.next(), model.service == .model else { throw BusinessVMError.invalidOwner }
                            var request = Data(), expected: Int?
                            while expected == nil || request.count < expected! {
                                let part = try await model.receive(maxBytes: 4096)
                                guard !part.isEmpty, request.count + part.count <= 81_920 else { throw BusinessVMError.capacity }
                                request.append(part)
                                if expected == nil, let delimiter = request.range(of: Data("\r\n\r\n".utf8)) {
                                    let header = String(decoding: request[..<delimiter.lowerBound], as: UTF8.self)
                                    let lengths = header.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("content-length:") }
                                    guard lengths.count == 1, let size = Int(lengths[0].split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)), size > 0, size <= 65_536 else { throw BusinessVMError.capacity }
                                    expected = delimiter.upperBound + size
                                }
                            }
                            guard request.count == expected, request.contains(Data("mini-sandbox-local-only".utf8)) else { throw BusinessVMError.invalidProfile }
                            let evidence = root.appendingPathComponent("request.http")
                            try request.write(to: evidence, options: [.withoutOverwriting]); chmod(evidence.path, 0o600)
                            report(["event": "real-cli.model-ingress", "httpBytes": request.count, "sha256": WorkspaceTransferWire.hash(request), "upstreamRequests": 0, "toolsExecuted": 0])
                            model.retire(); session.cancel()
                        }
                    }
                }
            }
            session.cancel()
            let stopped = await session.waitUntilStopped()
            report(["event": "stop-report", "actualStopped": stopped.actualStopped, "callbacksSettled": stopped.callbacksSettled,
                    "diskRemoved": stopped.diskRemoved, "consoleBytes": stopped.consoleBytes, "runtimeID": stopped.runtimeID.uuidString,
                    "runID": stopped.runID.uuidString, "epoch": stopped.epoch])
            guard stopped.actualStopped, stopped.callbacksSettled, stopped.diskRemoved,
                  stopped.runtimeID == session.id, stopped.runID == grant.runID, stopped.epoch == grant.epoch else { throw BusinessVMError.timeout }
            _ = await events.value
            report(["event": "PASS", "scope": mode, "imageSHA256": bundle.imageSHA256, "provider": "NOT_RUN"])
        } catch {
            vm?.cancel()
            if let vm { _ = await vm.waitUntilStopped() }
            report(["event": "FAIL", "error": String(describing: type(of: error))]); exit(1)
        }
    }
}
