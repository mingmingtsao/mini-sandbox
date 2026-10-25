import Foundation
import Combine
import SandboxHost

/// Synchronous storage boundary. Only detached tasks call its storage methods.
package protocol FixedModelCredentialStore: ModelCredentialProvider {
    func save(_ value: String) throws
    func delete() throws
    func check() throws -> Bool
}

package final class KeychainFixedModelStore: FixedModelCredentialStore, @unchecked Sendable {
    private let provider: KeychainModelCredentialProvider
    package init(provider: KeychainModelCredentialProvider = KeychainModelCredentialProvider()) { self.provider = provider }
    package func credential(for model: FixedModel) throws -> String { try provider.credential(for: model) }
    package func save(_ value: String) throws { try provider.setCredential(value) }
    package func delete() throws { try provider.remove() }
    package func check() throws -> Bool {
        do { _ = try provider.credential(for: .deepSeekFlash); return true }
        catch CredentialProviderError.missing { return false }
    }
}

/// Availability metadata, never a grant or a cached credential. Fresh identities
/// per application composition mean old grants cannot bind after a restart.
package struct FixedModelConnectionConfiguration: Equatable, Sendable {
    package let connectionID: UUID
    package let accountID: UUID
    package let accountBindingVersion: UInt64
    package let routeVersion: UInt64
    package func connection(provider: any ModelCredentialProvider) -> HostModelConnection {
        HostModelConnection(connectionID: connectionID, accountID: accountID,
            accountBindingVersion: accountBindingVersion, routeVersion: routeVersion,
            model: .deepSeekFlash, protocol: .anthropic, credentialProvider: provider)
    }
}

/// Permanently revoke the detached registry before storage may change. This also
/// catches trusted attachments not yet projected in the workbench.
package struct ModelConfigurationRetirement: Sendable {
    package let gateway: HostModelGateway
    package let connectionIDs: Set<UUID>
    package func revoke() async throws {
        for id in connectionIDs { try await gateway.revokeConnection(id) }
    }
}

@MainActor package final class ConnectionSettingsController: ObservableObject {
    @Published package private(set) var configuration: FixedModelConnectionConfiguration?
    @Published package private(set) var isBusy = false
    @Published package private(set) var isClosed = false
    @Published package private(set) var status = "Not checked. Routing unavailable."
    private let store: any FixedModelCredentialStore
    private let connectionID = UUID(), accountID = UUID()
    private var version: UInt64 = 0
    private var storageTask: Task<Bool, Error>?
#if DEBUG
    package var storageStartBarrier: (@Sendable () async -> Void)?
#endif
    package var invalidate: (() throws -> ModelConfigurationRetirement)?
    package var publish: ((FixedModelConnectionConfiguration, any ModelCredentialProvider) throws -> Void)?
    package var willClose: (() -> Void)?
    package init(store: any FixedModelCredentialStore) { self.store = store }
    package func close() {
        guard !isClosed else { return }
        isClosed = true
        configuration = nil
        storageTask?.cancel()
        willClose?()
        if let retired = try? invalidate?() { Task { try? await retired.revoke() } }
        status = "Closed. Routing unavailable."
    }
    package func checkStoredCredential() async {
        let store = store
        await perform({ try store.check() }, success: "Stored credential available for future runs. Provider not tested.")
    }
    package func deleteStoredCredential() async {
        let store = store
        await perform({ try store.delete(); return false }, success: "Deleted. Routing unavailable.")
    }
    package func save(_ value: String) async {
        guard !isBusy, !isClosed else { return }
        guard !value.isEmpty, value.utf8.count <= 16 * 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            status = "Invalid credential input. Existing configuration unchanged."
            return
        }
        let store = store
        await perform({ try store.save(value); return true }, success: "Saved for future runs. No approval or provider test performed.")
    }
    private func perform(_ operation: @escaping @Sendable () throws -> Bool, success: String) async {
        guard !isBusy, !isClosed else { return }
        isBusy = true
        defer { isBusy = false; storageTask = nil }
        configuration = nil
        status = "Keychain operation in progress. Routing unavailable; Stop and Quit remain available."
        do {
            guard version < UInt64.max, let invalidate, let publish else { throw CredentialProviderError.unavailable }
            version += 1
            let retired = try invalidate()
            try await retired.revoke()
            guard !isClosed else { return }
#if DEBUG
            let barrier = storageStartBarrier
#endif
            let task = Task.detached {
#if DEBUG
                if let barrier { await barrier() }
#endif
                try Task.checkCancellation()
                return try operation()
            }
            storageTask = task
            let available = try await task.value
            guard !isClosed else { return }
            guard available else { status = "No stored credential. Routing unavailable."; return }
            let configuration = FixedModelConnectionConfiguration(connectionID: connectionID, accountID: accountID,
                accountBindingVersion: version, routeVersion: version)
            try publish(configuration, store)
            self.configuration = configuration
            status = success
        } catch { if !isClosed { status = "Storage unavailable. Routing unavailable." } }
    }
}
