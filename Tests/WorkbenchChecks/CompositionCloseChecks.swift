import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

final class CloseTraffic: @unchecked Sendable {
    private let lock = NSLock()
    private var hold = false
    private var arrivals = 0, stops = 0
    let entered = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
    func reset(hold: Bool) {
        lock.withLock {
            self.hold = hold
            arrivals = 0
            stops = 0
        }
        while entered.wait(timeout: .now()) == .success {}
        while stopped.wait(timeout: .now()) == .success {}
    }
    func arrive() -> Bool {
        let result = lock.withLock {
            arrivals += 1
            return hold
        }
        entered.signal()
        return result
    }
    func stop() {
        lock.withLock { stops += 1 }
        stopped.signal()
    }
    var counts: (Int, Int) { lock.withLock { (arrivals, stops) } }
    func wait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func waitForStop() -> Bool { stopped.wait(timeout: .now() + 5) == .success }
}

/// Offline protocol boundary only; no provider, Keychain, GUI or VM execution.
final class CloseFixtureProtocol: URLProtocol {
    static let traffic = CloseTraffic()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.traffic.arrive() { return }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"choices\":[{\"message\":{\"content\":\"ordinary output\"}}]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.traffic.stop() }
}

final class CloseCredentials: ModelCredentialProvider, @unchecked Sendable {
    let barrier = CloseBarrier()
    private let lock = NSLock()
    private var reads = 0
    private let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    var count: Int { lock.withLock { reads } }
    func credential(for model: FixedModel) throws -> String {
        lock.withLock { reads += 1 }
        barrier.block()
        if fail { throw CredentialProviderError.unavailable }
        return "synthetic-" + UUID().uuidString
    }
}

final class CloseBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var timeout = false
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { armed = true } }
    func block() {
        let hold = lock.withLock {
            let result = armed
            armed = false
            return result
        }
        if hold {
            entered.signal()
            if release.wait(timeout: .now() + 10) != .success { lock.withLock { timeout = true } }
        }
    }
    var timedOut: Bool { lock.withLock { timeout } }
    func wait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
}

@MainActor enum CompositionCloseChecks {
    static func run() async throws {
        var failures = 0
        for (name, test) in [
            ("hidden queued output", hiddenQueuedOutput),
            ("delayed workbench attachment", delayedWorkbenchAttachment),
            ("install phase close barriers", installationBarriers),
            ("pending gateway attachments", pendingGatewayAttachments),
            ("hidden service operation close", delayedServiceOperations),
            ("queued storage start close", queuedStorageStart),
            ("cleanup failure remains failure", cleanupFailure),
        ] {
            do { try await test() } catch {
                failures += 1
                print("FAIL composition \(name): \(error)")
            }
        }
        for entry in ["model", "MCP", "workbench"] {
            do { try await pendingLocalAttachment(entry) } catch {
                failures += 1
                print("FAIL composition local pending \(entry): \(error)")
            }
            do { try await rejectedForeignAttachment(entry) } catch {
                failures += 1
                print("FAIL composition foreign intake \(entry): \(error)")
            }
            for bound in [true, false] {
                do { try await rejectedGrantMetadata(entry, bound: bound) } catch {
                    failures += 1
                    print("FAIL composition intake metadata \(entry) bound=\(bound): \(error)")
                }
            }
        }
        if failures != 0 { throw ConnectionSettingsChecks.Failure(message: "composition close regressions failed") }
    }
    // Additional protection checks first executed GREEN, not claimed as REDs.
    static func pendingLocalAttachment(_ entry: String) async throws {
        #if DEBUG
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ownership-pending-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: path) }
            let barrier = CloseBarrier()
            let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
            let grant = try ConnectionSettingsChecks.makeGrant(nil)
            let handle = try await root.authority.install(grant: grant)
            barrier.arm()
            let hold = Task { await root.authority.withPreAcquisitionBarrier { barrier.block() } }
            let entered = await Task.detached { barrier.wait() }.value
            let attaching = Task { try await attach(entry, root: root, grant: grant, handle: handle) }
            // Acknowledged ledger admission, not a guessed actor scheduling delay.
            for _ in 0..<5000 {
                if root.pendingOwnedWork == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let registered = root.pendingOwnedWork == 1
            root.beginClose()
            let terminalBeforeRelease = handle.lifecycle.currentStatus == .stopped
            barrier.release.signal()
            var rejected = false
            do { try await attaching.value } catch AuthorizationError.runRevoked { rejected = true }
            await hold.value
            let closed = await root.close()
            let repeated = await root.close()
            try ConnectionSettingsChecks.require(
                entered && registered && !barrier.timedOut && terminalBeforeRelease && rejected && closed && repeated
                    && root.pendingOwnedWork == 0 && root.workbench.grants.isEmpty,
                "genuine local intake must be owned before suspended authority validation and sealed synchronously")
            print("PASS composition local pending \(entry) terminal before validation release")
        #endif
    }
    static func cleanupFailure() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-cleanup-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
        let run = try await root.install(ConnectionSettingsChecks.makeGrant(nil))
        let cleanup = root.workbench.closeOwnedRuns!
        var calls = 0
        var authorityCleaned = false
        root.workbench.closeOwnedRuns = {
            calls += 1
            authorityCleaned = await cleanup()
            return false  // Synthetic resource-cleanup failure, not a foreign handle.
        }
        let closed = await root.close()
        let repeated = await root.close()
        try ConnectionSettingsChecks.require(
            !closed && !repeated && !root.isClosed && calls == 1 && authorityCleaned
                && run.authorityHandle.lifecycle.currentStatus == .stopped,
            "idempotence must preserve an actual cleanup callback's failure, not turn every close into success")
        print("PASS composition injected cleanup failure remains false on repeated close")
    }
    static func attach(_ entry: String, root: RunComposition, grant: RunGrant, handle: HostRunHandle) async throws {
        switch entry {
        case "model": _ = try await root.model.install(grant: grant, authorityHandle: handle)
        case "MCP": _ = try await root.mcp.install(grant: grant, authorityHandle: handle)
        default: try await root.workbench.installTrustedGrant(grant, authorityHandle: handle)
        }
    }
    static func rejectedForeignAttachment(_ entry: String) async throws {
        let pathA = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-A-\(UUID()).jsonl")
        let pathB = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-B-\(UUID()).jsonl")
        defer {
            try? FileManager.default.removeItem(at: pathA)
            try? FileManager.default.removeItem(at: pathB)
        }
        let connectionID = UUID()
        let credentials = CloseCredentials()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloseFixtureProtocol.self]
        CloseFixtureProtocol.traffic.reset(hold: false)
        let audit = try WorkbenchAuditSink(newFileAt: pathA)
        let connection = HostModelConnection(
            connectionID: connectionID, accountID: UUID(), accountBindingVersion: 1,
            routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials,
            configuration: configuration)
        let source = try RunComposition(audit: audit, modelConnections: [connection], credentialStore: SettingsStore())
        let receiving = try RunComposition(
            audit: WorkbenchAuditSink(newFileAt: pathB), credentialStore: SettingsStore())
        let installed = try await source.install(modelGrant(connectionID))
        var rejected = false
        do {
            try await attach(entry, root: receiving, grant: installed.grant, handle: installed.authorityHandle)
        } catch AuthorizationError.invalidHandle { rejected = true }
        let activeBefore = installed.authorityHandle.lifecycle.currentStatus == .active
        receiving.beginClose()
        let activeAfter = installed.authorityHandle.lifecycle.currentStatus == .active
        let closed = await receiving.close()
        let repeated = await receiving.close()
        var executed = false
        do {
            let request = try FixedModelRequest(
                model: .deepSeekFlash, protocol: .openAI,
                messages: [FixedMessage(role: .user, content: "ordinary fixture")], maxOutputTokens: 8)
            let proposal = try await source.model.propose(
                handle: installed.modelHandle, connectionID: connectionID, request: request, streaming: false)
            let approval = try await source.model.hostApprove(handle: installed.modelHandle, proposal: proposal)
            let output = try await source.model.makeOutput(handle: installed.modelHandle, approval: approval)
            try await source.model.execute(handle: installed.modelHandle, approval: approval, output: output)
            executed = try output.acceptNext() && output.summary.acceptedEvents == 1
        } catch HostModelGatewayError.revoked { /* Witness the old defect without skipping cleanup. */  }
        let resumes = try await source.model.resumedTaskCount(handle: installed.modelHandle)
        let sourceClosed = await source.close()
        let completions = audit.snapshot().filter { $0.reason == "dispatch-completion" }
        print(
            "OWNERSHIP_FOREIGN entry=\(entry) rejected=\(rejected) active_before=\(activeBefore) active_after=\(activeAfter) receiving_close=\(closed) repeated=\(repeated) executed=\(executed) reads=\(credentials.count) resumes=\(resumes) arrivals=\(CloseFixtureProtocol.traffic.counts.0) source_close=\(sourceClosed)"
        )
        try ConnectionSettingsChecks.require(
            rejected && activeBefore && activeAfter && closed && repeated && sourceClosed
                && receiving.workbench.grants.isEmpty && executed && credentials.count == 1 && resumes == 1
                && CloseFixtureProtocol.traffic.counts.0 == 1 && completions.count == 1
                && completions.first?.outcome == .completed,
            "rejected foreign intake must not own or stop source authority, poison receiving close, or prevent source execution"
        )
        print("PASS composition foreign intake \(entry) preserves source execution and idempotent receiving close")
    }
    static func rejectedGrantMetadata(_ entry: String, bound: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-metadata-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let connectionID = UUID()
        let credentials = CloseCredentials()
        let connection = HostModelConnection(
            connectionID: connectionID, accountID: UUID(), accountBindingVersion: 1,
            routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials)
        let root = try RunComposition(
            audit: WorkbenchAuditSink(newFileAt: path), modelConnections: [connection], credentialStore: SettingsStore()
        )
        let withConnection = try modelGrant(connectionID)
        let withoutConnection = try ConnectionSettingsChecks.makeGrant(nil)
        let actual = bound ? withConnection : withoutConnection
        let supplied = try RunGrant(
            runID: actual.runID, epoch: actual.epoch, createdAt: actual.createdAt,
            expiresAt: actual.expiresAt, workloadImageDigest: actual.workloadImageDigest,
            agentAdapterVersion: actual.agentAdapterVersion, workspaceSnapshotID: actual.workspaceSnapshotID,
            policyDigest: actual.policyDigest, approvalSnapshotID: actual.approvalSnapshotID,
            connections: bound ? [] : withConnection.connections, explicitDenies: actual.explicitDenies,
            resourceLimits: actual.resourceLimits)
        let handle = try await root.authority.install(grant: actual)
        var rejected = false
        do { try await attach(entry, root: root, grant: supplied, handle: handle) } catch AuthorizationError
            .grantBindingMismatch
        { rejected = true }
        let activeAfterRejection = handle.lifecycle.currentStatus == .active
        await root.connectionSettings.save("synthetic-" + UUID().uuidString)
        let retired = handle.lifecycle.currentStatus != .active
        let closed = await root.close()
        let repeated = await root.close()
        print(
            "OWNERSHIP_METADATA entry=\(entry) bound=\(bound) rejected=\(rejected) active_after_rejection=\(activeAfterRejection) retired=\(retired) closed=\(closed) repeated=\(repeated)"
        )
        try ConnectionSettingsChecks.require(
            rejected && activeAfterRejection && retired == bound && closed && repeated
                && handle.lifecycle.currentStatus != .active && root.workbench.grants.isEmpty && credentials.count == 0,
            "only authoritative installed connection metadata may decide retirement; genuine local intake remains close-owned"
        )
        print(
            "PASS composition intake metadata \(entry) bound=\(bound) authoritative retirement and local close ownership"
        )
    }
    static func queuedStorageStart() async throws {
        #if DEBUG
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                "composition-storage-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: path) }
            let store = SettingsStore()
            let barrier = CloseBarrier()
            let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: store)
            root.connectionSettings.storageStartBarrier = {
                barrier.arm()
                barrier.block()
            }
            let checking = Task { await root.connectionSettings.checkStoredCredential() }
            let entered = await Task.detached { barrier.wait() }.value
            root.beginClose()
            let closed = await root.close()
            barrier.release.signal()
            await checking.value
            try ConnectionSettingsChecks.require(
                entered && !barrier.timedOut && closed && store.count == 0
                    && root.connectionSettings.configuration == nil,
                "a queued credential check must not start storage after close")
            print("PASS composition queued storage check cancelled before credential read")
        #endif
    }
    static func delayedServiceOperations() async throws {
        for preparing in [true, false] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                "composition-service-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: path) }
            let audit = try WorkbenchAuditSink(newFileAt: path)
            let credentials = CloseCredentials()
            let connectionID = UUID()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CloseFixtureProtocol.self]
            CloseFixtureProtocol.traffic.reset(hold: !preparing)
            let connection = HostModelConnection(
                connectionID: connectionID, accountID: UUID(), accountBindingVersion: 1,
                routeVersion: 1, model: .deepSeekFlash, protocol: .openAI, credentialProvider: credentials,
                configuration: configuration)
            let root = try RunComposition(
                audit: audit, modelConnections: [connection], credentialStore: SettingsStore())
            let gateway = root.model
            let grant = try modelGrant(connectionID)
            let handle = try await gateway.install(grant: grant)
            let lifecycle = try await gateway.lifecycle(handle: handle)
            let request = try FixedModelRequest(
                model: .deepSeekFlash, protocol: .openAI,
                messages: [FixedMessage(role: .user, content: "fixture")], maxOutputTokens: 8)
            let proposal = try await gateway.propose(
                handle: handle, connectionID: connectionID, request: request, streaming: false)
            let approval = try await gateway.hostApprove(handle: handle, proposal: proposal)
            let output = try await gateway.makeOutput(handle: handle, approval: approval)
            if preparing { credentials.barrier.arm() }
            let operation = Task { try await gateway.execute(handle: handle, approval: approval, output: output) }
            let entered = await Task.detached {
                preparing ? credentials.barrier.wait() : CloseFixtureProtocol.traffic.wait()
            }.value
            #if DEBUG
                let resourceRegistered = root.pendingOwnedWork == 1
            #else
                let resourceRegistered = true
            #endif
            root.beginClose()
            let terminalBeforeRelease = lifecycle.currentStatus != .active
            let readsAtClose = credentials.count
            let cleanupSignal = CloseBarrier()
            let cleanup = root.workbench.closeOwnedRuns!
            root.workbench.closeOwnedRuns = {
                cleanupSignal.entered.signal()
                return await cleanup()
            }
            let closing = Task { await root.close() }
            var cleanupWaited = true
            if preparing {
                let cleanupStarted = await Task.detached { cleanupSignal.wait() }.value
                cleanupWaited = cleanupStarted && !root.isClosed
            }
            credentials.barrier.release.signal()
            do {
                try await operation.value
                throw ConnectionSettingsChecks.Failure(message: "service operation delivered late success")
            } catch let error as HostModelGatewayError {
                try ConnectionSettingsChecks.require(
                    error == (preparing ? .notStarted : .outcomeUnknown), "truthful pre-start versus started failure")
            }
            let closed = await closing.value
            let repeated = await root.close()
            if !preparing {
                let stopped = await Task.detached { CloseFixtureProtocol.traffic.waitForStop() }.value
                try ConnectionSettingsChecks.require(
                    stopped && CloseFixtureProtocol.traffic.counts.1 == 1, "started transport cancellation exactly once"
                )
            }
            do {
                try await gateway.execute(handle: handle, approval: approval, output: output)
                throw ConnectionSettingsChecks.Failure(message: "closed operation reused")
            } catch HostModelGatewayError.revoked {}
            do {
                _ = try await gateway.install(grant: modelGrant(connectionID))
                throw ConnectionSettingsChecks.Failure(message: "closed gateway installed")
            } catch AuthorizationError.runRevoked {}
            let completions = audit.snapshot().filter { $0.reason == "dispatch-completion" }
            let resumes = try await gateway.resumedTaskCount(handle: handle)
            try ConnectionSettingsChecks.require(
                resourceRegistered, "in-flight hidden service resource is not owned for close settlement")
            try ConnectionSettingsChecks.require(cleanupWaited, "close acknowledged before pending service settlement")
            try ConnectionSettingsChecks.require(
                entered && !credentials.barrier.timedOut && terminalBeforeRelease && closed && repeated
                    && credentials.count == readsAtClose && readsAtClose == 1 && resumes == (preparing ? 0 : 1)
                    && CloseFixtureProtocol.traffic.counts.0 == (preparing ? 0 : 1)
                    && output.summary.acceptedEvents == 0 && completions.count == 1
                    && completions.first?.outcome == (preparing ? .failed : .unknown),
                "hidden service close seals read/start/resume/acceptance and settles exactly once")
            print(
                "PASS composition hidden service \(preparing ? "preparation" : "started") close reads=\(readsAtClose) resumes=\(resumes) completions=\(completions.count)"
            )
        }
    }
    static func modelGrant(_ connectionID: UUID) throws -> RunGrant {
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        return try RunGrant(
            runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64),
            agentAdapterVersion: "close-fixture", workspaceSnapshotID: UUID(),
            policyDigest: String(repeating: "b", count: 64),
            approvalSnapshotID: UUID(),
            connections: [
                ConnectionGrant(
                    connectionID: connectionID,
                    accountBindingVersion: 1, routeVersion: 1, scopes: [scope])
            ], explicitDenies: [],
            resourceLimits: ResourceLimits(
                cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
    }
    static func installationBarriers() async throws {
        #if DEBUG
            for phase in RunComposition.InstallationPhase.allCases {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "composition-phase-\(UUID()).jsonl")
                defer { try? FileManager.default.removeItem(at: path) }
                let store = SettingsStore()
                let barrier = CloseBarrier()
                let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: store)
                root.installationBarrier = { observed in
                    if observed == phase {
                        await Task.detached {
                            barrier.arm()
                            barrier.block()
                        }.value
                    }
                }
                let grant = try ConnectionSettingsChecks.makeGrant(nil)
                let installing = Task { try await root.install(grant) }
                let entered = await Task.detached { barrier.wait() }.value
                root.beginClose()
                let sealedBeforeRelease = root.isClosing && root.workbench.isClosing && root.connectionSettings.isClosed
                barrier.release.signal()
                var rejected = false
                do { _ = try await installing.value } catch HostModelGatewayError.revoked { rejected = true }
                let closed = await root.close()
                let repeated = await root.close()
                do {
                    _ = try await root.install(ConnectionSettingsChecks.makeGrant(nil))
                    throw ConnectionSettingsChecks.Failure(message: "post-close install")
                } catch HostModelGatewayError.revoked {}
                try ConnectionSettingsChecks.require(
                    entered && !barrier.timedOut && sealedBeforeRelease && rejected && closed && repeated
                        && store.count == 0,
                    "phase barrier must reject late installation without credential access")
                for visible in root.workbench.grants {
                    try ConnectionSettingsChecks.require(
                        try root.workbench.lifecycle(runID: visible.runID).currentStatus != .active,
                        "already-projected phase is terminal, never revived")
                }
                print("PASS composition close phase \(phase.rawValue)")
            }
        #endif
    }
    static func pendingGatewayAttachments() async throws {
        for model in [true, false] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(
                "composition-gateway-\(UUID()).jsonl")
            defer { try? FileManager.default.removeItem(at: path) }
            let barrier = CloseBarrier()
            let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
            let grant = try ConnectionSettingsChecks.makeGrant(nil)
            // Hold actor acquisition, not the data-only final clock. Gateway
            // reservations enter before awaiting authority installation.
            barrier.arm()
            let hold = Task { await root.authority.withPreAcquisitionBarrier { barrier.block() } }
            let entered = await Task.detached { barrier.wait() }.value
            let attaching = Task { () throws -> Void in
                if model {
                    _ = try await root.model.install(grant: grant)
                } else {
                    _ = try await root.mcp.install(grant: grant)
                }
            }
            for _ in 0..<5000 {
                if root.pendingOwnedWork == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            let registered = root.pendingOwnedWork == 1
            root.beginClose()
            barrier.release.signal()
            await hold.value
            var rejected = false
            do { try await attaching.value } catch AuthorizationError.runRevoked { rejected = true }
            let closed = await root.close()
            try ConnectionSettingsChecks.require(
                entered && registered && !barrier.timedOut && rejected && closed && root.workbench.grants.isEmpty,
                "pending implicit gateway installation must retire before exposing its handle")
            print("PASS composition pending \(model ? "model" : "MCP") attachment close")
        }
    }
    static func delayedWorkbenchAttachment() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("composition-attach-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let barrier = CloseBarrier()
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: SettingsStore())
        let grant = try ConnectionSettingsChecks.makeGrant(nil)
        let handle = try await root.authority.install(grant: grant)
        barrier.arm()
        let hold = Task { await root.authority.withPreAcquisitionBarrier { barrier.block() } }
        let entered = await Task.detached { barrier.wait() }.value
        var attachment: Task<Void, Error>?
        await withCheckedContinuation { ack in
            attachment = Task { @MainActor in
                ack.resume()
                try await root.workbench.installTrustedGrant(grant, authorityHandle: handle)
            }
        }
        let attachmentPending = root.workbench.isBusy
        root.workbench.beginClose()
        let terminalBeforeRelease = handle.lifecycle.currentStatus != .active
        barrier.release.signal()
        var rejected = false
        do { try await attachment!.value } catch AuthorizationError.runRevoked { rejected = true }
        await hold.value
        let closed = await root.close()
        print(
            "COMPOSITION_ATTACH entered=\(entered) timeout=\(barrier.timedOut) pending=\(attachmentPending) terminal_before_release=\(terminalBeforeRelease) rejected=\(rejected) closed=\(closed) grants=\(root.workbench.grants.count)"
        )
        try ConnectionSettingsChecks.require(
            entered && !barrier.timedOut && attachmentPending && terminalBeforeRelease && rejected && closed
                && root.workbench.grants.isEmpty,
            "close must own pending workbench attachment before authority validation and reject late publication")
        print("PASS composition delayed workbench attachment terminal before barrier release")
    }
    static func hiddenQueuedOutput() async throws {
        CloseFixtureProtocol.traffic.reset(hold: false)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("composition-close-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let audit = try WorkbenchAuditSink(newFileAt: path)
        let store = SettingsStore()
        try store.save("synthetic-" + UUID().uuidString)
        let connectionID = UUID()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CloseFixtureProtocol.self]
        let connection = HostModelConnection(
            connectionID: connectionID, accountID: UUID(),
            accountBindingVersion: 1, routeVersion: 1, model: .deepSeekFlash, protocol: .openAI,
            credentialProvider: store, configuration: session)
        let root = try RunComposition(audit: audit, modelConnections: [connection], credentialStore: store)
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        let grant = try RunGrant(
            runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64),
            agentAdapterVersion: "close-fixture", workspaceSnapshotID: UUID(),
            policyDigest: String(repeating: "b", count: 64),
            approvalSnapshotID: UUID(),
            connections: [
                ConnectionGrant(
                    connectionID: connectionID,
                    accountBindingVersion: 1, routeVersion: 1, scopes: [scope])
            ], explicitDenies: [],
            resourceLimits: ResourceLimits(
                cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
        let authority = try await root.authority.install(grant: grant)
        let gateway = root.model
        let hidden = try await gateway.install(grant: grant, authorityHandle: authority)
        let request = try FixedModelRequest(
            model: .deepSeekFlash, protocol: .openAI,
            messages: [FixedMessage(role: .user, content: "ordinary fixture")], maxOutputTokens: 8)
        let proposal = try await gateway.propose(
            handle: hidden, connectionID: connectionID, request: request, streaming: false)
        let approval = try await gateway.hostApprove(handle: hidden, proposal: proposal)
        let output = try await gateway.makeOutput(handle: hidden, approval: approval)
        try await gateway.execute(handle: hidden, approval: approval, output: output)
        try ConnectionSettingsChecks.require(
            output.summary.queuedEvents == 1 && root.workbench.grants.isEmpty,
            "real completed output is queued on an unprojected attachment")
        let reads = store.count
        let resumes = try await gateway.resumedTaskCount(handle: hidden)
        let closed = await root.workbench.close()
        var accepted = false
        do { accepted = try output.acceptNext() } catch is AuthorizationError {}
        let terminal = authority.lifecycle.currentStatus != .active
        // Cleanup is explicit even on RED; never leave an active fixture behind.
        authority.lifecycle.terminate(.stopped)
        try await gateway.stop(handle: hidden)
        let repeated = await root.workbench.close()
        try ConnectionSettingsChecks.require(
            closed && repeated && terminal && !accepted && output.summary.acceptedEvents == 0,
            "composition close must synchronously retire hidden attachments and deny queued business acceptance")
        let finalResumes = try await gateway.resumedTaskCount(handle: hidden)
        try ConnectionSettingsChecks.require(
            store.count == reads && finalResumes == resumes,
            "close performs no credential read or new resume")
        try ConnectionSettingsChecks.require(
            audit.snapshot().filter { $0.reason == "dispatch-completion" }.count == 1,
            "completed operation settles exactly once across repeated close")
        print("PASS composition hidden attachment queued output close exact-once settlement")
    }
}
