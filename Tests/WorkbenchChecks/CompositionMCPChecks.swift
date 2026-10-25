import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

/// Authenticated real loopback fixture only; no external provider or Keychain.
@MainActor enum CompositionMCPChecks {
    static func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    static func handshake(_ line: String) async throws {
        say(line)
        let response = await Task.detached { readLine() }.value
        try ConnectionSettingsChecks.require(response == "go", "fixture handshake")
    }
    static func run() async throws {
        guard let input = readLine(),
            let config = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
            let number = config["port"] as? Int, let port = UInt16(exactly: number),
            let token = config["token"] as? String
        else {
            throw ConnectionSettingsChecks.Failure(message: "loopback driver input required")
        }
        var failures = 0
        for name in ["queued", "running", "completion-failure", "unknown-failure"] {
            do {
                try await check(name, port: port, token: token)
                say("PASS composition MCP \(name)")
            } catch {
                failures += 1
                say("FAIL composition MCP \(name): \(error)")
            }
        }
        if failures != 0 { throw ConnectionSettingsChecks.Failure(message: "MCP composition checks failed") }
    }
    static func check(_ name: String, port: UInt16, token: String) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("composition-mcp-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let credentials = CloseMCPCredentials(token: token)
        let id = UUID()
        let connection = try HostMCPConnection.testOnlyLoopback(
            connectionID: id, accountID: UUID(), port: port, provider: credentials)
        let root = try RunComposition(audit: audit, credentialStore: SettingsStore(), mcpConnections: [connection])
        let gateway = root.mcp
        let handle = try await gateway.install(grant: CompositionSettlementChecks.mcpGrant(id))
        let lifecycle = try await gateway.lifecycle(handle: handle)
        try await handshake("BEGIN " + name)
        for method in ["initialize", "notifications/initialized", "tools/list"] {
            let proposal = try await gateway.propose(
                handle: handle, connectionID: id, raw: CompositionSettlementChecks.control(method))
            let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
            _ = try await gateway.execute(handle: handle, approval: approval)
        }
        try await handshake("ARM " + name)
        let raw = Data(
            #"{"jsonrpc":"2.0","id":"read","method":"tools/call","params":{"name":"repo_read","arguments":{"repo":"A"}}}"#
                .utf8)
        let proposal = try await gateway.propose(
            handle: handle, connectionID: id, raw: raw, sourceToolUseID: "composition_tool_1")
        let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
        let output = try await gateway.makeOutput(handle: handle, approval: approval)
        let operation = Task { try await gateway.execute(handle: handle, approval: approval, output: output) }
        var owned = true
        var rejected = false
        var queued = true
        if name == "queued" {
            try await operation.value
            queued = output.summary.queuedEvents == 1 && output.summary.acceptedEvents == 0
            root.beginClose()
            do { _ = try output.acceptNext() } catch is AuthorizationError { rejected = true }
        } else {
            // The original authenticated handler has acknowledged arrival before
            // close; the test never uses assumed FIFO scheduling or a sleep.
            try await handshake("WAIT " + name)
            owned = root.pendingOwnedWork == 1 && !root.isClosed && root.workbench.grants.isEmpty
            if name == "running" {
                root.beginClose()
                do { try await operation.value } catch HostMCPGatewayError.outcomeUnknown { rejected = true }
                try await handshake("RELEASE " + name)
            } else {
                try await WorkbenchChecks.withWritesBlocked {
                    if name == "unknown-failure" { root.beginClose() } else { try await handshake("RELEASE " + name) }
                    do { try await operation.value } catch HostMCPGatewayError.auditFailed { rejected = true }
                }
                if name == "unknown-failure" { try await handshake("RELEASE " + name) }
            }
        }
        let closed = await root.close()
        let repeated = await root.close()
        let resumes = try await gateway.resumedTaskCount(handle: handle)
        let completions = audit.snapshot().filter { $0.reason == "dispatch-completion" }
        let failure = name.hasSuffix("failure")
        let expected: DispatchOutcome = name == "running" ? .unknown : .completed
        var replayDenied = false
        do { try await gateway.execute(handle: handle, approval: approval, output: output) } catch HostMCPGatewayError
            .revoked
        { replayDenied = true }
        say(
            "OBS MCP \(name) reads=\(credentials.count) resumes=\(resumes) completions=\(completions.count) pending=\(root.pendingOwnedWork) accepted=\(output.summary.acceptedEvents) closed=\(closed) repeated=\(repeated)"
        )
        try ConnectionSettingsChecks.require(
            owned && queued && rejected && replayDenied && credentials.count == 4 && resumes == 4
                && root.pendingOwnedWork == 0 && lifecycle.currentStatus != .active
                && output.summary.acceptedEvents == 0 && closed == !failure && repeated == !failure
                && root.isClosed == !failure && completions.count == (failure ? 3 : 4)
                && (failure || completions.last?.outcome == expected),
            "real MCP close must suppress queued output, retain running ownership, and preserve exact truthful settlement"
        )
    }
}
