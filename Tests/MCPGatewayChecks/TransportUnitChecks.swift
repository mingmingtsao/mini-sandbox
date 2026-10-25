import Foundation

#if DEBUG
    @testable import SandboxHost
#else
    import SandboxHost
#endif

func transportUnitChecks() async throws {
    #if DEBUG
        let token = UUID().uuidString  // runtime-only; never logged
        let audit = Audit()
        let credentials = Credentials(token, audit)
        let connection = try HostMCPConnection.testOnlyLoopback(
            connectionID: UUID(), accountID: UUID(), port: 1, provider: credentials)
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let dummy = session.dataTask(with: URL(string: "http://127.0.0.1:1/mcp")!)  // never resumed
        let bytes = Data("unit-body".utf8)
        for mode in ["cancel-first", "finish-first", "validate-twice", "reflection-twice"] {
            let op = try MCPPreparedOperation(
                connection: connection, payload: ModelJSON.parse(control("tools/list")), limit: 65536)
            if mode == "cancel-first" {
                op.cancel()
                op.cancel()
            }
            op.urlSession(session, dataTask: dummy, didReceive: bytes)
            op.urlSession(session, task: dummy, didCompleteWithError: nil)
            op.urlSession(session, task: dummy, didCompleteWithError: URLError(.cancelled))
            var received: [Data] = []
            if mode == "cancel-first" {
                try await denied(.outcomeUnknown) { for try await _ in op.chunks {} }
                try await denied(.notStarted) { try op.start() }
            } else {
                for try await value in op.chunks { received.append(value) }
                try check(received == [bytes], "manual finish must yield exactly once")
            }
            if mode == "finish-first" {
                op.cancel()
                op.cancel()
            }
            if mode == "validate-twice" {
                try op.validateOutboundText("ordinary")
            } else {
                try await denied(.invalidResponse) {
                    try op.validateOutboundText(mode == "reflection-twice" ? token : "ordinary")
                }
            }
            try await denied(.invalidResponse) { try op.validateOutboundText("ordinary") }
            op.cancel()
            output("UNIT PASS transport-" + mode + " gateway_http=0 manual_callbacks=3")
        }
        try check(credentials.count == 4, "unit preparation reads")
        output("UNIT SUMMARY cases=4 credential_reads=4 gateway_http=0; full suite known RED pulse-deny-2")
    #else
        throw Failure(message: "transport unit mode requires Debug")
    #endif
}
