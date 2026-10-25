import Combine
import Foundation
import SandboxHost

package struct LocalMCPConfiguration: Equatable, Sendable {
    package let connectionID: UUID
    package let accountID: UUID
    package let version: UInt64
    package let port: UInt16
    package var binding: MCPCredentialBinding {
        MCPCredentialBinding(connectionID: connectionID, accountID: accountID, accountBindingVersion: version,
                             audience: "http://127.0.0.1:\(port)")
    }
    package func connection(provider: any MCPCredentialProvider) throws -> HostMCPConnection {
        try .claudeLocalRepository(connectionID: connectionID, accountID: accountID, accountBindingVersion: version,
            routeVersion: version, port: port, provider: provider)
    }
}

struct MemoryMCPCredential: MCPCredentialProvider {
    let binding: MCPCredentialBinding
    let bearer: String
    func credential(for requested: MCPCredentialBinding) throws -> MCPCredential {
        guard requested == binding else { throw HostMCPGatewayError.invalidConnection }
        return MCPCredential(binding: binding, bearer: bearer)
    }
}
package struct MCPConfigurationRetirement: Sendable {
    let gateway: HostMCPGateway
    let connectionIDs: Set<UUID>
    func revoke() async throws { for id in connectionIDs { try await gateway.revokeConnection(id) } }
}

/// One fixed local profile. The temporary bearer stays in the host provider;
/// no process command, remote host, filesystem credential or guest key is accepted.
@MainActor package final class MCPConnectionSettingsController: ObservableObject {
    @Published package private(set) var configuration: LocalMCPConfiguration?
    @Published package private(set) var isBusy = false
    @Published package private(set) var isClosed = false
    @Published package private(set) var isLocalFixture = false
    @Published package private(set) var status = "No local MCP connection."
    package var invalidate: (() throws -> MCPConfigurationRetirement)?
    package var publish: ((LocalMCPConfiguration, any MCPCredentialProvider) throws -> Void)?
    package var willClose: (() -> Void)?
    private let connectionID = UUID(), accountID = UUID()
    private var version: UInt64 = 0

    package func connect(port: String, bearer: String) async {
        guard !isBusy, !isClosed, !isLocalFixture else { return }
        guard let port = UInt16(port), port > 0, !bearer.isEmpty, bearer.utf8.count <= 4096,
              bearer.utf8.allSatisfy({ (33...126).contains($0) }) else {
            status = "Enter a local port from 1–65535 and a bearer of 1–4096 ASCII characters without spaces."; return
        }
        isBusy = true; defer { isBusy = false }
        do {
            guard version < UInt64.max, let invalidate, let publish else { throw HostMCPGatewayError.invalidConnection }
            configuration = nil; version += 1
            let retired = try invalidate(); try await retired.revoke()
            guard !isClosed else { return }
            let value = LocalMCPConfiguration(connectionID: connectionID, accountID: accountID, version: version, port: port)
            try publish(value, MemoryMCPCredential(binding: value.binding, bearer: bearer))
            configuration = value
            status = "Configured 127.0.0.1:\(port). Connection not tested; each request requires approval. Bearer is not saved."
        } catch { if !isClosed { status = "Local MCP configuration unavailable." } }
    }
    package func disconnect() async {
        guard !isBusy, !isClosed, !isLocalFixture else { return }
        isBusy = true; defer { isBusy = false }
        configuration = nil
        do {
            if let retired = try invalidate?() { try await retired.revoke() }
            if !isClosed { status = "Disconnected." }
        } catch { if !isClosed { status = "Disconnected; cleanup failed." } }
    }
    package func close() {
        guard !isClosed else { return }; isClosed = true; configuration = nil
        willClose?()
        if let retired = try? invalidate?() { Task { try? await retired.revoke() } }
        status = "Closed."
    }
#if SANDBOX_TEST_FIXTURES
    package static let publicFixtureBearer = "mini-sandbox-local-mcp-fixture-canary-39f2e5b7"
    package func installLocalFixture(_ value: LocalMCPConfiguration) throws {
        guard configuration == nil, !isBusy, !isClosed else { throw HostMCPGatewayError.invalidConnection }
        isLocalFixture = true; configuration = value
        status = "Local MCP fixture · 127.0.0.1:\(value.port) · public fake bearer"
    }
#endif
}
