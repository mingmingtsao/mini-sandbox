import Darwin
import Foundation
@testable import SandboxHost
import SandboxContracts

final class R3LocalListener {
    let descriptor: Int32
    let port: UInt16
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "R3 listener socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard bound == 0, named == 0, listen(fd, 2) == 0 else { Darwin.close(fd); throw Failure(message: "R3 owned loopback listener") }
        descriptor = fd; port = UInt16(bigEndian: address.sin_port)
    }
    deinit { Darwin.close(descriptor) }
}

final class R3Attempt: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    private var result: Result<Void, Error>?
    func run(_ body: () throws -> Void) {
        entered.signal()
        let result = Result { try body() }
        lock.withLock { self.result = result }; done.signal()
    }
    func wait() throws {
        try check(done.wait(timeout: .now() + 4) == .success, "R3 worker timeout")
    }
    func denied() throws -> Bool {
        try lock.withLock {
            guard let result else { throw Failure(message: "R3 no result") }
            switch result {
            case .success: return false
            case .failure(let error):
                guard error is AuthorizationError else { throw error }
                return true
            }
        }
    }
}
func r3ExpiryWait(_ target: String) throws {
    let clock = Clock(), life = lifecycle(clock), id = UUID()
    let scope = life.effectScope(connectionID: id)
    let attempt = R3Attempt()
    if target == "compatibility-writer" || target == "compatibility-lifecycle" {
        let output = ControlledRunOutput(lifecycle: life, scope: scope)
        try output.enqueue(.modelCompletion(ModelCompletion(text: "must not adopt")))
        let mutex = try r3Mutex(target == "compatibility-writer" ? output as Any : life as Any)
        mutex.lock()
        DispatchQueue.global().async { attempt.run { _ = try output.acceptNext() } }
        let entered = attempt.entered.wait(timeout: .now() + 2) == .success
        let blocked = attempt.done.wait(timeout: .now() + 0.03) == .timedOut
        clock.advance(600); mutex.unlock()
        try attempt.wait()
        try check(entered && blocked && (try attempt.denied()) && output.summary.acceptedEvents == 0 && output.summary.queuedEvents == 1, "R3 compatibility stale adoption")
        try check(life.lastObservation?.wallTime == life.expiresAt && life.currentStatus == .expired, "R3 compatibility final sample")
        print("OBS R3-B target=\(target) adoptions=\(output.summary.acceptedEvents) queued=\(output.summary.queuedEvents) sequence=\(life.lastObservation!.sequence) final_wall=\(life.lastObservation!.wallTime.timeIntervalSince1970) deadline=\(life.expiresAt.timeIntervalSince1970) status=\(life.currentStatus.rawValue)")
    } else {
        let effect: RunPreparedEffect
        let op: Any
        let credentials = Credentials(), mcpCredentials = LoopbackCredentials("synthetic-r3-mcp")
        if target.hasPrefix("model") {
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OfflineProtocol.self]
            let operation = try ModelTransport(credentialProvider: credentials, configuration: configuration).prepare(transportRequest(), streaming: false)
            effect = .model(operation); op = operation
        } else {
            let connection = try HostMCPConnection.testOnlyLoopback(connectionID: id, accountID: UUID(), port: 1, provider: mcpCredentials)
            let operation = try MCPPreparedOperation(connection: connection, payload: ModelJSON.parse(mcpControl("tools/list")), limit: 65536)
            effect = .mcp(operation); op = operation
        }
        defer { effect.cancel() }
        let mutex = try r3Mutex(target.hasSuffix("operation") ? op : life)
        mutex.lock()
        let start = clock.source.wall
        DispatchQueue.global().async { attempt.run { try life.start(effect, id: UUID(), scope: scope, notBefore: start, startDeadline: start.addingTimeInterval(600)) } }
        let entered = attempt.entered.wait(timeout: .now() + 2) == .success
        let blocked = attempt.done.wait(timeout: .now() + 0.03) == .timedOut
        clock.advance(600); mutex.unlock()
        try attempt.wait()
        let resumes: Int
        switch effect {
        case .model(let operation): resumes = operation.resumeCalls
        case .mcp(let operation): resumes = operation.resumeCalls
        case .businessVM: throw Failure(message: "R3 fixture requires model or MCP effect")
        }
        try check(entered && blocked && (try attempt.denied()) && resumes == 0 && life.registeredEffectCount == 0 && life.currentStatus == .expired, "R3 stale concrete resume")
        try check(life.lastObservation?.wallTime == life.expiresAt, "R3 resume final time")
        print("OBS R3-A-C-D-E target=\(target) resumes=\(resumes) registered=\(life.registeredEffectCount) credential_reads=\(credentials.count + mcpCredentials.count) sequence=\(life.lastObservation!.sequence) final_wall=\(life.lastObservation!.wallTime.timeIntervalSince1970) deadline=\(life.expiresAt.timeIntervalSince1970) status=\(life.currentStatus.rawValue)")
    }
    print("PASS r3-expiry-wait-\(target)")
}
func r3NativeRetryExpiry(eagain: Bool) throws {
    let pair = try NativeSocketPair(), clock = Clock(), life = lifecycle(clock)
    try pair.smallSendBuffer()
    let output = try nativeOutput(pair, life)
    try output.enqueue(.modelCompletion(nativeCompletion(String(repeating: "x", count: 60_000))))
    try check(try output.acceptNext(), "R3 first partial")
    if eagain { try check(try !output.acceptNext(), "R3 EAGAIN not reached") }
    let before = output.nativeProgress!
    let prefix = try pair.readAvailable()
    try check(before.partialWriteCount > 0 && prefix.count == before.committedBytes && (!eagain || before.wouldBlockCount > 0), "R3 partial fixture")
    clock.advance(600)
    do { _ = try output.acceptNext(); throw Failure(message: "R3 stale retry") } catch is AuthorizationError {}
    let after = output.nativeProgress!
    try check(try pair.readAvailable().isEmpty && after.writeCalls == before.writeCalls && after.committedBytes == before.committedBytes && after.acceptedFinals == 0, "R3 retry made new syscall")
    output.cancel()
    try check(output.nativeProgress!.bufferedBytes == 0 && output.nativeProgress!.closed, "R3 cleanup not released")
    print("OBS R3-G eagain=\(eagain) prefix_bytes=\(prefix.count) write_calls=\(before.writeCalls) calls_after_expiry=\(after.writeCalls) extra_bytes=0 buffered_after_cancel=0")
    print("PASS r3-\(eagain ? "eagain" : "partial")-retry-expiry")
}
func r3ClockTransitions() throws {
    for kind in ["monotonic-rollback", "wall-pulse-rollback", "sleep"] {
        let clock = Clock(), start = clock.source.wall, life = lifecycle(clock)
        let output = ControlledRunOutput(lifecycle: life, scope: life.effectScope(connectionID: UUID()))
        try output.enqueue(.modelCompletion(ModelCompletion(text: "not accepted")))
        if kind == "wall-pulse-rollback" {
            clock.source.set(wall: start.addingTimeInterval(600), elapsed: .seconds(1))
            _ = life.observeAndReduce(reason: "fixture-pulse")
            clock.source.set(wall: start, elapsed: .seconds(2))
        } else { clock.source.set(wall: start.addingTimeInterval(-100), elapsed: .seconds(kind == "sleep" ? 3600 : 600)) }
        do { _ = try output.acceptNext(); throw Failure(message: "R3 clock revival") } catch is AuthorizationError {}
        try check(life.currentStatus == .expired && output.summary.acceptedEvents == 0 && life.currentGeneration == 2, "R3 clock terminal latch")
        let sequence = life.lastObservation!.sequence
        _ = life.observeAndReduce(reason: "repeat")
        try check(life.currentGeneration == 2 && life.lastObservation!.sequence > sequence, "R3 repeated terminal")
        print("OBS R3-F kind=\(kind) adoptions=0 generation=\(life.currentGeneration) sequence=\(life.lastObservation!.sequence) final_wall=\(life.lastObservation!.wallTime.timeIntervalSince1970) deadline=\(life.expiresAt.timeIntervalSince1970) status=\(life.currentStatus.rawValue)")
        print("PASS r3-clock-\(kind)")
    }
}
func r3StopOrders() throws {
    for native in [false, true] { for connection in [false, true] { for effectFirst in [false, true] {
        let clock = Clock(), life = lifecycle(clock), id = UUID(), pair = try NativeSocketPair()
        let scope = life.effectScope(connectionID: id)
        let output = try native ? ControlledRunOutput(lifecycle: life, scope: scope, takingAcceptedSocket: pair.takeWriter(), streaming: false) : ControlledRunOutput(lifecycle: life, scope: scope)
        try output.enqueue(.modelCompletion(nativeCompletion()))
        if effectFirst { try check(try output.acceptNext(), "R3 earlier effect absent") }
        if connection { life.invalidateConnection(id) } else { life.terminate(.stopped) }
        do { _ = try output.acceptNext(); throw Failure(message: "R3 terminal accepted") } catch is AuthorizationError {}
        let bytes = try pair.readAvailable().count
        let accepted = native ? output.nativeProgress!.acceptedFinals : output.summary.acceptedEvents
        try check(accepted == (effectFirst ? 1 : 0) && (!native || (bytes > 0) == effectFirst), "R3 order observation")
        output.cancel()
        print("OBS R3-H native=\(native) connection=\(connection) effect_first=\(effectFirst) adoptions=\(accepted) peer_bytes=\(bytes) registered=\(life.registeredEffectCount)")
        print("PASS r3-order-\(native)-\(connection)-\(effectFirst)")
    } } }
}
func r3RegistrationAndStress() throws {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OfflineProtocol.self]
    let credentials = Credentials(), transport = ModelTransport(credentialProvider: credentials, configuration: configuration)
    var resumes = 0
    for index in 0..<128 {
        let clock = Clock(), life = lifecycle(clock), id = UUID(), operationID = UUID()
        let operation = try transport.prepare(transportRequest(), streaming: false)
        let scope = life.effectScope(connectionID: id), done = DispatchGroup()
        let output = ControlledRunOutput(lifecycle: life, scope: scope)
        try output.enqueue(.modelCompletion(ModelCompletion(text: "bounded")))
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            try? life.start(.model(operation), id: operationID, scope: scope, notBefore: clock.source.wall, startDeadline: clock.source.wall.addingTimeInterval(300))
        }
        done.enter()
        DispatchQueue.global().async { defer { done.leave() }; _ = try? output.acceptNext() }
        done.enter()
        DispatchQueue.global().async { defer { done.leave() }; life.terminate(.stopped) }
        try check(done.wait(timeout: .now() + 4) == .success, "R3 interlock timeout at \(index)")
        life.finishEffect(operationID); life.finishEffect(operationID); operation.cancel()
        try check(life.registeredEffectCount == 0 && life.currentStatus == .stopped && operation.resumeCalls <= 1 && output.summary.acceptedEvents <= 1, "R3 terminal registration")
        resumes += operation.resumeCalls
    }
    // Reusing the same transport after every cancellation observes limiter release.
    let final = try transport.prepare(transportRequest(), streaming: false); final.cancel()
    try check(credentials.count == 129, "R3 resource reuse count")
    print("OBS R3-I-J races=128 actual_resumes=\(resumes) final_registered=0 credential_reads=\(credentials.count) capacity_reuses=128 duplicate_finish=128 stopped=128")
    print("PASS r3-registration-release-interlock-stress")
}
func r3RegisteredTerminal() throws {
    for mcp in [false, true] {
        let clock = Clock(), life = lifecycle(clock), id = UUID(), operationID = UUID()
        let credentials = Credentials(), mcpCredentials = LoopbackCredentials("synthetic-r3-mcp-terminal")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [OfflineProtocol.self]
        let transport = ModelTransport(credentialProvider: credentials, configuration: configuration)
        let effect: RunPreparedEffect
        let listener = try R3LocalListener()
        defer { withExtendedLifetime(listener) {} }
        if mcp {
            let connection = try HostMCPConnection.testOnlyLoopback(connectionID: id, accountID: UUID(), port: listener.port, provider: mcpCredentials)
            effect = .mcp(try MCPPreparedOperation(connection: connection, payload: ModelJSON.parse(mcpControl("tools/list")), limit: 65536))
        } else { effect = .model(try transport.prepare(transportRequest(), streaming: false)) }
        let scope = life.effectScope(connectionID: id), start = clock.source.wall
        try life.start(effect, id: operationID, scope: scope, notBefore: start, startDeadline: start.addingTimeInterval(300))
        let registered = life.registeredEffectCount
        clock.advance(600)
        _ = life.observeAndReduce(reason: "terminal-fixture")
        life.finishEffect(operationID); life.finishEffect(operationID); effect.cancel(); effect.cancel()
        do { try life.start(effect, id: operationID, scope: scope, notBefore: start, startDeadline: start.addingTimeInterval(900)); throw Failure(message: "R3 effect revived") } catch is AuthorizationError {}
        let resumes: Int
        switch effect {
        case .model(let operation): resumes = operation.resumeCalls
        case .mcp(let operation): resumes = operation.resumeCalls
        case .businessVM: throw Failure(message: "R3 fixture requires model or MCP effect")
        }
        try check(registered == 1 && life.registeredEffectCount == 0 && resumes == 1, "R3 registration settlement")
        if !mcp {
            var held: [ModelPreparedOperation] = []
            defer { held.forEach { $0.cancel() } }
            for _ in 0..<ModelTransport.maxConcurrentRequests { held.append(try transport.prepare(transportRequest(), streaming: false)) }
            do { let extra = try transport.prepare(transportRequest(), streaming: false); extra.cancel(); throw Failure(message: "R3 duplicate release expanded capacity") } catch ModelTransportError.busy {}
            try check(credentials.count == ModelTransport.maxConcurrentRequests + 1, "R3 release capacity observed")
        }
        print("OBS R3-I mcp=\(mcp) registered_before=\(registered) registered_after=\(life.registeredEffectCount) resumes=\(resumes) repeated_settlement=2 generation=\(life.currentGeneration) sequence=\(life.lastObservation!.sequence)")
        print("PASS r3-registered-terminal-\(mcp)")
    }
}
func r3StopWhileWriterWaits() throws {
    let clock = Clock(), life = lifecycle(clock)
    let output = ControlledRunOutput(lifecycle: life, scope: life.effectScope(connectionID: UUID()))
    try output.enqueue(.modelCompletion(ModelCompletion(text: "not accepted")))
    let mutex = try r3Mutex(output), attempt = R3Attempt(), stopped = DispatchSemaphore(value: 0)
    mutex.lock()
    DispatchQueue.global().async { attempt.run { _ = try output.acceptNext() } }
    let entered = attempt.entered.wait(timeout: .now() + 2) == .success
    let waiting = attempt.done.wait(timeout: .now() + 0.05) == .timedOut
    DispatchQueue.global().async { life.terminate(.stopped); stopped.signal() }
    let reachable = stopped.wait(timeout: .now() + 1) == .success
    mutex.unlock()
    try attempt.wait()
    try check(entered && waiting && reachable && (try attempt.denied()) && output.summary.acceptedEvents == 0, "R3 inverse lock path blocks Stop")
    print("OBS R3-J writer_held=true stop_returned_before_writer_unlock=\(reachable) adoptions=0")
    print("PASS r3-stop-reachable-during-writer-wait")
}
func r3ExpandedChecks() throws {
    for target in ["compatibility-writer", "compatibility-lifecycle", "model-operation", "mcp-operation", "model-lifecycle", "mcp-lifecycle"] { try r3ExpiryWait(target) }
    try r3NativeRetryExpiry(eagain: false); try r3NativeRetryExpiry(eagain: true)
    try r3ClockTransitions(); try r3StopOrders(); try r3RegisteredTerminal()
    try r3StopWhileWriterWaits(); try r3RegistrationAndStress()
}
