import Foundation
import SandboxContracts
import SandboxHost
import SandboxWorkbench

/// Synthetic storage only. Never touches any OS Keychain item.
final class SettingsStore: FixedModelCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var calls = 0
    private var hold = false
    private var fail = false
    private var mainThreadIO = false
    private var gateTimeout = false
    var gateTimedOut: Bool { lock.withLock { gateTimeout } }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var count: Int { lock.withLock { calls } }
    var storageWasOnMainThread: Bool { lock.withLock { mainThreadIO } }
    func blockNext() { lock.withLock { hold = true } }
    func failNext() { lock.withLock { fail = true } }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    private func beforeWrite() throws {
        let flags = lock.withLock { () -> (Bool, Bool) in
            calls += 1
            mainThreadIO = mainThreadIO || Thread.isMainThread
            let result = (hold, fail)
            hold = false
            fail = false
            return result
        }
        if flags.0 {
            entered.signal()
            if release.wait(timeout: .now() + 10) != .success { lock.withLock { gateTimeout = true } }
        }
        if flags.1 { throw CredentialProviderError.storageUnavailable(-60008) }
    }
    func credential(for model: FixedModel) throws -> String {
        try lock.withLock {
            calls += 1
            guard let value else { throw CredentialProviderError.missing }
            return value
        }
    }
    func save(_ value: String) throws {
        try beforeWrite()
        lock.withLock { self.value = value }
    }
    func delete() throws {
        try beforeWrite()
        lock.withLock { value = nil }
    }
    func check() throws -> Bool {
        do {
            _ = try credential(for: .deepSeekFlash)
            return true
        } catch CredentialProviderError.missing { return false }
    }
}

@MainActor enum ConnectionSettingsChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func run() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = SettingsStore()
        let root = try RunComposition(audit: WorkbenchAuditSink(newFileAt: path), credentialStore: store)
        let settings = root.connectionSettings
        try require(settings.configuration == nil && store.count == 0, "initial settings deny without preload")
        try require(root.workbench.grants.isEmpty && root.workbench.approvedActions.isEmpty, "settings create no grant")
        await settings.save("synthetic-" + UUID().uuidString)
        try require(
            settings.configuration != nil && store.count == 1, "explicit save publishes a future-run configuration")
        try require(root.workbench.grants.isEmpty && root.workbench.approvedActions.isEmpty, "saving is not approval")
        print("PASS connection settings defaults deny and explicit save publishes without approval")
        try await replacement(root, store)
        try await checkAndDelete(root, store)
        try await closeAndLateCompletion(root, store)
        try require(!store.gateTimedOut, "all blocking-storage barriers stayed held until explicit release")
        try nativeBindings()
        try canaryFixture()
    }
    static func canaryFixture() throws {
        let store = SettingsStore()
        let result = KeychainCanarySelfCheck.exercise(store: store, packagedIdentity: true)
        try require(
            result.verdict == "PASS" && result.added && result.read && result.updated && result.deleted
                && result.cleanup,
            "owned synthetic canary verifies CRUD and cleanup")
        let failing = SettingsStore()
        failing.failNext()
        let blocked = KeychainCanarySelfCheck.exercise(store: failing, packagedIdentity: true)
        try require(
            blocked.verdict == "BLOCKED" && blocked.osStatus == -60008, "OS storage denial must not become fixture PASS"
        )
        let noIdentity = SettingsStore()
        let rejected = KeychainCanarySelfCheck.exercise(store: noIdentity, packagedIdentity: false)
        try require(rejected.verdict == "BLOCKED" && noIdentity.count == 0, "unpackaged selfcheck touches no storage")
        for mode in [
            CanaryFaultStore.Mode.preexisting, .mismatch, .readFailure, .cleanupFailure, .cleanupBlocked,
            .cleanupRetained,
        ] {
            let store = CanaryFaultStore(mode: mode)
            let report = KeychainCanarySelfCheck.exercise(store: store, packagedIdentity: true)
            if mode == .preexisting {
                try require(
                    report.verdict == "BLOCKED" && store.writes == 0 && store.deletions == 0,
                    "preexisting item was modified")
            } else if mode == .cleanupBlocked {
                try require(
                    report.verdict == "BLOCKED" && report.osStatus == -25308 && !report.cleanup,
                    "cleanup OS denial became PASS")
            } else {
                try require(
                    report.verdict == "FAIL" && report.cleanup == (mode == .mismatch || mode == .readFailure),
                    "readback or cleanup fault became PASS")
            }
        }
        print("PASS synthetic canary runner statuses cleanup and identity gate (not actual Keychain)")
    }
    static func nativeBindings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewPath = root.appendingPathComponent("Sources/SandboxWorkbench/ConnectionSettingsView.swift")
        try require(FileManager.default.fileExists(atPath: viewPath.path), "native secure settings view is integrated")
        let view = try String(contentsOf: viewPath, encoding: .utf8)
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/MiniSandboxApp/MiniSandboxApp.swift"), encoding: .utf8)
        let workbench = try String(
            contentsOf: root.appendingPathComponent("Sources/SandboxWorkbench/WorkbenchView.swift"), encoding: .utf8)
        try require(
            view.contains("SecureField(") && view.contains("input = \"\"") && view.contains(".onDisappear")
                && !view.contains(".sheet("), "secure transient input and nonmodal settings")
        try require(
            app.contains("connectionSettings: delegate.connectionSettings")
                && app.contains("connectionSettings?.close()"),
            "application wires settings and closes without awaiting storage")
        try require(
            workbench.contains("ConnectionSettingsView(controller:")
                && workbench.contains(".disabled(!model.canStop(runID: runID))"),
            "settings do not change actual Stop binding")
        try require(
            app.contains("--keychain-canary-selfcheck") && app.contains("KeychainCanarySelfCheck.runPackaged()"),
            "packaged canary mode is explicitly wired")
        try require(
            !app.contains("@State private var report = EnvironmentInspector.inspect()"),
            "environment Keychain query is not preloaded on MainActor")
        print("PASS native settings secure input composition and Stop source bindings (not GUI clicks)")
    }
    static func checkAndDelete(_ root: RunComposition, _ store: SettingsStore) async throws {
        let settings = root.connectionSettings
        await settings.checkStoredCredential()
        guard let checked = settings.configuration else {
            throw Failure(message: "explicit check publishes stored credential availability")
        }
        try require(
            checked.accountBindingVersion == 4 && checked.routeVersion == 4,
            "failed attempt consumes version; no rollback")
        let typed = checked.connection(provider: store)
        try require(
            typed.accountID == checked.accountID && typed.connectionID == checked.connectionID
                && typed.accountBindingVersion == 4 && typed.routeVersion == 4 && typed.model == .deepSeekFlash
                && typed.protocol == .anthropic,
            "typed host factory binds exact identity version and fixed route")
        let model = root.model
        let run = try await root.install(makeGrant(checked))
        let wrongProtocol = try FixedModelRequest(
            model: .deepSeekFlash, protocol: .openAI,
            messages: [FixedMessage(role: .user, content: "fixture")], maxOutputTokens: 1)
        do {
            _ = try await model.propose(
                handle: run.modelHandle, connectionID: checked.connectionID, request: wrongProtocol, streaming: false)
            throw Failure(message: "wrong protocol accepted")
        } catch HostModelGatewayError.denied {}
        store.blockNext()
        let deletion = Task { await settings.deleteStoredCredential() }
        let entered = await Task.detached { store.waitForEntry() }.value
        let retired = run.authorityHandle.lifecycle.currentStatus != .active && settings.configuration == nil
        store.release.signal()
        await deletion.value
        try require(
            entered && retired && settings.configuration == nil, "delete invalidates before storage and cannot publish")
        await settings.checkStoredCredential()
        try require(settings.configuration == nil, "missing credential stays unavailable after explicit check")
        let calls = store.count
        await settings.save("")
        try require(store.count == calls && settings.configuration == nil, "invalid input never enters storage")
        try require(try await model.resumedTaskCount(handle: run.modelHandle) == 0, "check and delete never dispatch")
        try require(
            !root.workbench.activity.contains { $0.reason == "dispatch-intent" }, "settings issue no dispatch intent")
        print("PASS connection check delete fixed binding missing and invalid input stay fail closed")
    }
    static func closeAndLateCompletion(_ root: RunComposition, _ store: SettingsStore) async throws {
        let settings = root.connectionSettings
        store.blockNext()
        let pending = Task { await settings.save("synthetic-" + UUID().uuidString) }
        let entered = await Task.detached { store.waitForEntry() }.value
        settings.close()
        let closed = await root.workbench.close()
        let unavailableAtClose = settings.configuration == nil
        store.release.signal()
        await pending.value
        try require(
            entered && closed && unavailableAtClose && settings.configuration == nil,
            "quit does not wait for storage and late completion cannot publish")
        let calls = store.count
        await settings.save("synthetic-" + UUID().uuidString)
        try require(store.count == calls, "closed settings reject later intent")
        print("PASS connection settings close ignores late storage publication without delaying quit")
    }
    static func makeGrant(_ configuration: FixedModelConnectionConfiguration?) throws -> RunGrant {
        let scope = try ResourceScope(service: "model", resource: "deepseek-flash", operation: "complete")
        let connections =
            try configuration.map {
                [
                    try ConnectionGrant(
                        connectionID: $0.connectionID,
                        accountBindingVersion: $0.accountBindingVersion, routeVersion: $0.routeVersion, scopes: [scope])
                ]
            } ?? []
        return try RunGrant(
            runID: UUID(), epoch: 1, createdAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(900), workloadImageDigest: String(repeating: "a", count: 64),
            agentAdapterVersion: "settings-fixture", workspaceSnapshotID: UUID(),
            policyDigest: String(repeating: "b", count: 64),
            approvalSnapshotID: UUID(), connections: connections, explicitDenies: [],
            resourceLimits: ResourceLimits(
                cpuCount: 1, memoryBytes: 1, diskBytes: 1, messageBytes: 8192, concurrentRequests: 1))
    }
    static func replacement(_ root: RunComposition, _ store: SettingsStore) async throws {
        let settings = root.connectionSettings
        guard let first = settings.configuration else { throw Failure(message: "missing first configuration") }
        let oldGateway = root.model
        let old = try await root.install(makeGrant(first))
        let unrelated = try await root.install(makeGrant(nil))
        let request = try FixedModelRequest(
            model: .deepSeekFlash, protocol: .anthropic,
            messages: [FixedMessage(role: .user, content: "synthetic")], maxOutputTokens: 1)
        let proposal = try await oldGateway.propose(
            handle: old.modelHandle, connectionID: first.connectionID, request: request, streaming: false)
        let approval = try await oldGateway.hostApprove(handle: old.modelHandle, proposal: proposal)
        let attachedGrant = try makeGrant(first)
        let attachedAuthority = try await root.authority.install(grant: attachedGrant)
        _ = try await oldGateway.install(grant: attachedGrant, authorityHandle: attachedAuthority)
        store.blockNext()
        let save = Task { await settings.save("synthetic-" + UUID().uuidString) }
        let entered = await Task.detached { store.waitForEntry() }.value
        let terminalBeforeStorageReturns = old.authorityHandle.lifecycle.currentStatus != .active
        let allAttachmentsInvalidated = !attachedAuthority.lifecycle.permitsConnection(first.connectionID)
        let routingUnavailable = settings.configuration == nil && settings.isBusy
        let stopEnabled = root.workbench.canStop(runID: unrelated.grant.runID)
        try await root.workbench.stop(runID: unrelated.grant.runID)
        let stoppedWhileStorageBlocked = unrelated.authorityHandle.lifecycle.currentStatus == .stopped
        let calls = store.count
        await settings.save("ignored-" + UUID().uuidString)
        let busyIgnored = store.count == calls
        store.release.signal()
        await save.value
        try require(
            entered && terminalBeforeStorageReturns,
            "replacement invalidates old bound run BEFORE blocked storage returns")
        try require(allAttachmentsInvalidated, "replacement retires every old gateway attachment before storage")
        try require(routingUnavailable, "new routing stays unavailable while storage is busy")
        try require(
            stopEnabled && stoppedWhileStorageBlocked && busyIgnored,
            "busy settings never block emergency Stop or admit a second operation")
        try require(!store.storageWasOnMainThread, "storage I/O is off MainActor")
        do {
            _ = try await oldGateway.execute(handle: old.modelHandle, approval: approval)
            throw Failure(message: "old authorization survived replacement")
        } catch HostModelGatewayError.revoked {}
        try require(
            try await oldGateway.resumedTaskCount(handle: old.modelHandle) == 0,
            "replacement dispatches no model request")
        guard let second = settings.configuration else { throw Failure(message: "replacement missing") }
        try require(
            second.connectionID == first.connectionID && second.accountID == first.accountID
                && second.accountBindingVersion > first.accountBindingVersion
                && second.routeVersion > first.routeVersion,
            "exact stable account identity with strictly advanced versions")
        let stale = try await root.install(makeGrant(first))
        do {
            _ = try await root.model.propose(
                handle: stale.modelHandle, connectionID: first.connectionID, request: request, streaming: false)
            throw Failure(message: "old versions accepted by future gateway")
        } catch HostModelGatewayError.invalidConnection {}
        let revivedGrant = try makeGrant(first)
        let revivedAuthority = try await root.authority.install(grant: revivedGrant)
        let revived = try await oldGateway.install(grant: revivedGrant, authorityHandle: revivedAuthority)
        do {
            _ = try await oldGateway.propose(
                handle: revived, connectionID: first.connectionID, request: request, streaming: false)
            throw Failure(message: "retired registry revived")
        } catch HostModelGatewayError.invalidConnection {}
        try await oldGateway.stop(handle: revived)
        store.failNext()
        await settings.save("synthetic-" + UUID().uuidString)
        try require(settings.configuration == nil, "failed replacement cannot restore previous routing")
        print("PASS connection replacement retires old authority before storage and keeps busy Stop reachable")
    }
}

private final class CanaryFaultStore: FixedModelCredentialStore, @unchecked Sendable {
    enum Mode { case preexisting, mismatch, readFailure, cleanupFailure, cleanupBlocked, cleanupRetained }
    enum Fault: Error { case read, cleanup }
    let mode: Mode
    private var value: String?
    private(set) var writes = 0, deletions = 0
    init(mode: Mode) { self.mode = mode }
    func check() throws -> Bool { mode == .preexisting || value != nil }
    func save(_ value: String) throws {
        writes += 1
        self.value = value
    }
    func credential(for model: FixedModel) throws -> String {
        if mode == .readFailure { throw Fault.read }
        return mode == .mismatch ? "synthetic-wrong-readback" : value ?? ""
    }
    func delete() throws {
        deletions += 1
        if deletions == 2 {
            if mode == .cleanupFailure { throw Fault.cleanup }
            if mode == .cleanupBlocked { throw CredentialProviderError.storageUnavailable(-25308) }
            if mode == .cleanupRetained {
                value = "synthetic-retained"
                return
            }
        }
        value = nil
    }
}
