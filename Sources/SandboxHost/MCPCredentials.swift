import Foundation

/// Synthetic fixture credentials only. No Keychain, OAuth flow, or external connector.
package struct MCPCredentialBinding: Equatable, Sendable {
    package let connectionID: UUID
    package let accountID: UUID
    package let accountBindingVersion: UInt64
    package let audience: String
    package init(connectionID: UUID, accountID: UUID, accountBindingVersion: UInt64, audience: String) {
        self.connectionID = connectionID; self.accountID = accountID
        self.accountBindingVersion = accountBindingVersion; self.audience = audience
    }
}
package struct MCPCredential: Sendable {
    package let binding: MCPCredentialBinding
    package let bearer: String
    package init(binding: MCPCredentialBinding, bearer: String) { self.binding = binding; self.bearer = bearer }
}
package protocol MCPCredentialProvider: Sendable {
    func credential(for binding: MCPCredentialBinding) throws -> MCPCredential
}
enum MCPConnectionProfile: Sendable {
    case fixture, claudeRepository
    var version: String { self == .fixture ? MCPProtocol.version : ClaudeMCPProtocol.version }
    var adapter: String { self == .fixture ? MCPProtocol.adapter : ClaudeMCPProtocol.adapter }
    var server: String { self == .fixture ? MCPProtocol.server : ClaudeMCPProtocol.server }
}
package struct HostMCPConnection: Sendable {
    package let connectionID: UUID
    package let accountID: UUID
    package let accountBindingVersion: UInt64
    package let routeVersion: UInt64
    package let audience: String
    let endpoint: URL
    let provider: any MCPCredentialProvider
    let profile: MCPConnectionProfile
    var binding: MCPCredentialBinding { MCPCredentialBinding(connectionID: connectionID, accountID: accountID, accountBindingVersion: accountBindingVersion, audience: audience) }
    /// The sole endpoint constructor: explicitly test-only, literal loopback, fixed POST /mcp.
    package static func testOnlyLoopback(connectionID: UUID, accountID: UUID, accountBindingVersion: UInt64 = 1, routeVersion: UInt64 = 1, port: UInt16, provider: any MCPCredentialProvider) throws -> Self {
        guard port > 0, accountBindingVersion > 0, routeVersion > 0 else { throw HostMCPGatewayError.invalidConnection }
        let audience = "http://127.0.0.1:\(port)"
        return Self(connectionID: connectionID, accountID: accountID, accountBindingVersion: accountBindingVersion, routeVersion: routeVersion, audience: audience, endpoint: URL(string: audience + "/mcp")!, provider: provider, profile: .fixture)
    }
    /// Explicit bounded local repository service, with the actual modern client
    /// protocol. This does not select an arbitrary URL or run a host command.
    package static func claudeLocalRepository(connectionID: UUID, accountID: UUID,
        accountBindingVersion: UInt64 = 1, routeVersion: UInt64 = 1,
        port: UInt16, provider: any MCPCredentialProvider) throws -> Self {
        guard port > 0, accountBindingVersion > 0, routeVersion > 0 else { throw HostMCPGatewayError.invalidConnection }
        let audience = "http://127.0.0.1:\(port)"
        return Self(connectionID: connectionID, accountID: accountID, accountBindingVersion: accountBindingVersion,
                    routeVersion: routeVersion, audience: audience, endpoint: URL(string: audience + "/mcp")!,
                    provider: provider, profile: .claudeRepository)
    }
}
