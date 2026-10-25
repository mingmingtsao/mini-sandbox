import Darwin
import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

/// Real URLSession producer interception plus actual owned AF_UNIX delivery.
/// No external provider, Keychain, GUI, VM, or credential-bearing response.
final class CompositionNativeProtocol: URLProtocol {
    static let traffic = CloseTraffic()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        _ = Self.traffic.arrive()
        let body =
            "{\"content\":[{\"type\":\"text\",\"text\":\"" + String(repeating: "x", count: 60_000)
            + "\"}],\"id\":\"msg_fixture\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"fixture-model\",\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}"
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.traffic.stop() }
}

@MainActor enum CompositionNativeCloseChecks {
    static func run() async throws {
        for closeAfterPrefix in [false, true] { try await check(closeAfterPrefix: closeAfterPrefix) }
    }
    static func check(closeAfterPrefix: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("composition-native-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let credentials = CloseCredentials()
        let id = UUID()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompositionNativeProtocol.self]
        CompositionNativeProtocol.traffic.reset(hold: false)
        let connection = HostModelConnection(
            connectionID: id, accountID: UUID(), accountBindingVersion: 1,
            routeVersion: 1, model: .deepSeekFlash, protocol: .anthropic, credentialProvider: credentials,
            configuration: configuration)
        let clock = RunClock.manual(wall: Date(), elapsed: .zero)
        let root = try RunComposition(
            audit: audit, modelConnections: [connection], credentialStore: SettingsStore(), clock: clock)
        let run = try await root.install(CompositionCloseChecks.modelGrant(id))
        let gateway = run.modelGateway
        let request = try FixedModelRequest(
            model: .deepSeekFlash, protocol: .anthropic,
            messages: [FixedMessage(role: .user, content: "offline native close")], maxOutputTokens: 8)
        let proposal = try await gateway.propose(
            handle: run.modelHandle, connectionID: id, request: request, streaming: false)
        let approval = try await gateway.hostApprove(handle: run.modelHandle, proposal: proposal)
        var fds: [Int32] = [-1, -1]
        try ConnectionSettingsChecks.require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "owned socketpair")
        defer {
            if fds[0] >= 0 { Darwin.close(fds[0]) }
            Darwin.close(fds[1])
        }
        var size: Int32 = 4096
        try ConnectionSettingsChecks.require(
            setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0
                && fcntl(fds[1], F_SETFL, O_NONBLOCK) == 0, "bounded native socket setup")
        let owned = fds[0]
        fds[0] = -1
        let output = try await gateway.makeNativeOutput(
            handle: run.modelHandle, approval: approval, takingAcceptedSocket: owned)
        defer { output.cancel() }
        func readAvailable() throws -> Data {
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<64 {
                let n = Darwin.read(fds[1], &buffer, buffer.count)
                if n > 0 {
                    bytes.append(contentsOf: buffer.prefix(n))
                    continue
                }
                if n == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return bytes }
                if errno == EINTR { continue }
                throw ConnectionSettingsChecks.Failure(message: "native peer read failed")
            }
            throw ConnectionSettingsChecks.Failure(message: "native peer read bound exceeded")
        }
        try await gateway.execute(handle: run.modelHandle, approval: approval, output: output)
        try ConnectionSettingsChecks.require(try readAvailable().isEmpty, "producer enqueue must not write")
        try ConnectionSettingsChecks.require(try output.acceptNext(), "actual native prefix write")
        let before = output.nativeProgress!
        var bytes = try readAvailable()
        try ConnectionSettingsChecks.require(
            before.committedBytes == bytes.count && bytes.count > 0 && before.pendingBytes > 0
                && before.acceptedEvents == 0 && before.acceptedFinals == 0 && before.partialWriteCount > 0,
            "real partial socket write must precede close, without complete business acceptance")
        if closeAfterPrefix {
            root.beginClose()
            var rejected = false
            do { _ = try output.acceptNext() } catch AuthorizationError.runRevoked { rejected = true }
            let after = output.nativeProgress!
            try ConnectionSettingsChecks.require(
                rejected && after.writeCalls == before.writeCalls && after.committedBytes == before.committedBytes
                    && after.acceptedEvents == 0 && after.acceptedFinals == 0 && readAvailable().isEmpty,
                "close blocks every new syscall and late acceptance without retracting committed prefix")
        } else {
            for _ in 0..<128 {
                _ = try output.acceptNext()
                bytes.append(try readAvailable())
                if output.nativeProgress!.closed { break }
            }
            try ConnectionSettingsChecks.require(
                output.nativeProgress!.acceptedFinals == 1 && output.nativeProgress!.acceptedEvents == 1
                    && output.nativeProgress!.committedBytes == bytes.count
                    && String(decoding: bytes, as: UTF8.self).contains(String(repeating: "x", count: 60_000)),
                "positive control drains the same concrete composition-owned response")
        }
        let closed = await root.close()
        let repeated = await root.close()
        var lateDenied = false
        do {
            _ = try await gateway.propose(handle: run.modelHandle, connectionID: id, request: request, streaming: false)
        } catch HostModelGatewayError.revoked { lateDenied = true }
        let resumed = try await gateway.resumedTaskCount(handle: run.modelHandle)
        let completions = audit.snapshot().filter { $0.reason == "dispatch-completion" }
        let pending = root.pendingOwnedWork
        try ConnectionSettingsChecks.require(
            closed && repeated && lateDenied && pending == 0 && run.authorityHandle.lifecycle.currentStatus == .stopped
                && run.authorityHandle.lifecycle.registeredEffectCount == 0 && credentials.count == 1 && resumed == 1
                && CompositionNativeProtocol.traffic.counts.0 == 1 && completions.count == 1
                && completions[0].outcome == .completed
                && audit.snapshot().map(\.reason) == ["dispatch-intent", "dispatch-completion"],
            "one source dispatch and durable settlement, no new work or ownership after repeated close")
        let progress = output.nativeProgress!
        print(
            "OBS composition-native close=\(closeAfterPrefix) prefix_bytes=\(before.committedBytes) peer_bytes=\(bytes.count) committed_bytes=\(progress.committedBytes) write_calls=\(progress.writeCalls) accepted=\(progress.acceptedEvents) finals=\(progress.acceptedFinals) reads=\(credentials.count) resumes=\(resumed) arrivals=\(CompositionNativeProtocol.traffic.counts.0) completions=\(completions.count) audit_sequence=\(completions[0].hostSequence) pending=\(pending) registered=\(run.authorityHandle.lifecycle.registeredEffectCount) clock_samples=\(clock.observation.0)"
        )
        print("PASS composition native socket \(closeAfterPrefix ? "close-prefix" : "drain-control") FIRST_GREEN")
    }
}
