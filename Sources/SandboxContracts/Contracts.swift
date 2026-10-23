import Foundation
import CryptoKit

public enum ContractError: Error, Equatable {
    case invalidField(String)
}

private func requireText(_ value: String, _ name: String, maximum: Int = 512) throws {
    guard !value.isEmpty, value.utf8.count <= maximum,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ContractError.invalidField(name)
    }
}

private func requireDigest(_ value: String, _ name: String) throws {
    guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw ContractError.invalidField(name)
    }
}

public struct ResourceScope: Codable, Hashable, Sendable {
    public let service: String
    public let resource: String
    public let operation: String

    public init(service: String, resource: String, operation: String) throws {
        for (name, value) in [("service", service), ("resource", resource), ("operation", operation)] {
            try requireText(value, name)
            guard !value.contains("*") else { throw ContractError.invalidField(name) }
        }
        self.service = service; self.resource = resource; self.operation = operation
    }

    private enum CodingKeys: String, CodingKey { case service, resource, operation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(service: c.decode(String.self, forKey: .service), resource: c.decode(String.self, forKey: .resource), operation: c.decode(String.self, forKey: .operation))
    }
}

public struct ResourceLimits: Codable, Equatable, Sendable {
    public let cpuCount: Int
    public let memoryBytes: UInt64
    public let diskBytes: UInt64
    public let messageBytes: Int
    public let concurrentRequests: Int

    public init(cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64, messageBytes: Int, concurrentRequests: Int) throws {
        guard (1...64).contains(cpuCount), memoryBytes > 0, diskBytes > 0,
              (1...1_048_576).contains(messageBytes), (1...64).contains(concurrentRequests) else {
            throw ContractError.invalidField("resourceLimits")
        }
        self.cpuCount = cpuCount; self.memoryBytes = memoryBytes; self.diskBytes = diskBytes
        self.messageBytes = messageBytes; self.concurrentRequests = concurrentRequests
    }

    private enum CodingKeys: String, CodingKey { case cpuCount, memoryBytes, diskBytes, messageBytes, concurrentRequests }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(cpuCount: c.decode(Int.self, forKey: .cpuCount), memoryBytes: c.decode(UInt64.self, forKey: .memoryBytes), diskBytes: c.decode(UInt64.self, forKey: .diskBytes), messageBytes: c.decode(Int.self, forKey: .messageBytes), concurrentRequests: c.decode(Int.self, forKey: .concurrentRequests))
    }
}

public struct ConnectionGrant: Codable, Equatable, Sendable {
    public let connectionID: UUID
    public let accountBindingVersion: UInt64
    public let routeVersion: UInt64
    public let scopes: Set<ResourceScope>

    public init(connectionID: UUID, accountBindingVersion: UInt64, routeVersion: UInt64, scopes: Set<ResourceScope>) throws {
        guard accountBindingVersion > 0, routeVersion > 0, !scopes.isEmpty, scopes.count <= 128 else {
            throw ContractError.invalidField("connectionGrant")
        }
        self.connectionID = connectionID; self.accountBindingVersion = accountBindingVersion
        self.routeVersion = routeVersion; self.scopes = scopes
    }

    private enum CodingKeys: String, CodingKey { case connectionID, accountBindingVersion, routeVersion, scopes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(connectionID: c.decode(UUID.self, forKey: .connectionID), accountBindingVersion: c.decode(UInt64.self, forKey: .accountBindingVersion), routeVersion: c.decode(UInt64.self, forKey: .routeVersion), scopes: c.decode(Set<ResourceScope>.self, forKey: .scopes))
    }
}

public enum DenialReason: String, Codable, Sendable {
    case explicitDeny, connectionNotGranted, resourceNotGranted, expired, notYetValid
}
public enum ScopeDecision: Equatable, Sendable {
    case allowed
    case denied(DenialReason)
}

/// Immutable host-side snapshot. Decoding a snapshot never installs it as a live grant.
public struct RunGrant: Codable, Equatable, Sendable {
    public let runID: UUID
    public let epoch: UInt64
    public let createdAt: Date
    public let expiresAt: Date
    public let workloadImageDigest: String
    public let agentAdapterVersion: String
    public let workspaceSnapshotID: UUID
    public let policyDigest: String
    public let approvalSnapshotID: UUID
    public let connections: [ConnectionGrant]
    public let explicitDenies: Set<ResourceScope>
    public let resourceLimits: ResourceLimits

    public init(runID: UUID, epoch: UInt64, createdAt: Date, expiresAt: Date, workloadImageDigest: String, agentAdapterVersion: String, workspaceSnapshotID: UUID, policyDigest: String, approvalSnapshotID: UUID, connections: [ConnectionGrant], explicitDenies: Set<ResourceScope>, resourceLimits: ResourceLimits) throws {
        guard epoch > 0, createdAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > createdAt, connections.count <= 32, explicitDenies.count <= 256,
              Set(connections.map(\.connectionID)).count == connections.count else {
            throw ContractError.invalidField("runGrant")
        }
        try requireDigest(workloadImageDigest, "workloadImageDigest")
        try requireDigest(policyDigest, "policyDigest")
        try requireText(agentAdapterVersion, "agentAdapterVersion")
        self.runID = runID; self.epoch = epoch; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.workloadImageDigest = workloadImageDigest; self.agentAdapterVersion = agentAdapterVersion
        self.workspaceSnapshotID = workspaceSnapshotID; self.policyDigest = policyDigest
        self.approvalSnapshotID = approvalSnapshotID; self.connections = connections
        self.explicitDenies = explicitDenies; self.resourceLimits = resourceLimits
    }

    /// Pure scope check, not permission to dispatch: Host Core must also validate live identity/epoch,
    /// revocation, adapter bounds, upstream permissions and any required action approval.
    public func decision(for scope: ResourceScope, connectionID: UUID, at time: Date) -> ScopeDecision {
        if explicitDenies.contains(scope) { return .denied(.explicitDeny) }
        guard time >= createdAt else { return .denied(.notYetValid) }
        guard time < expiresAt else { return .denied(.expired) }
        guard let connection = connections.first(where: { $0.connectionID == connectionID }) else { return .denied(.connectionNotGranted) }
        guard connection.scopes.contains(scope) else { return .denied(.resourceNotGranted) }
        return .allowed
    }

    private enum CodingKeys: String, CodingKey {
        case runID, epoch, createdAt, expiresAt, workloadImageDigest, agentAdapterVersion
        case workspaceSnapshotID, policyDigest, approvalSnapshotID, connections, explicitDenies, resourceLimits
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(runID: c.decode(UUID.self, forKey: .runID), epoch: c.decode(UInt64.self, forKey: .epoch), createdAt: c.decode(Date.self, forKey: .createdAt), expiresAt: c.decode(Date.self, forKey: .expiresAt), workloadImageDigest: c.decode(String.self, forKey: .workloadImageDigest), agentAdapterVersion: c.decode(String.self, forKey: .agentAdapterVersion), workspaceSnapshotID: c.decode(UUID.self, forKey: .workspaceSnapshotID), policyDigest: c.decode(String.self, forKey: .policyDigest), approvalSnapshotID: c.decode(UUID.self, forKey: .approvalSnapshotID), connections: c.decode([ConnectionGrant].self, forKey: .connections), explicitDenies: c.decode(Set<ResourceScope>.self, forKey: .explicitDenies), resourceLimits: c.decode(ResourceLimits.self, forKey: .resourceLimits))
    }
}

/// Host-created binding to already validated canonical bytes, not a decoder for guest JSON.
/// Adapters must reject duplicate JSON keys and resolve actual resources before constructing this.
public struct ActionBinding: Equatable, Sendable {
    public let runID: UUID
    public let epoch: UInt64
    public let grantDigest: String
    public let connectionID: UUID
    public let operation: String
    public let schemaDigest: String
    public let resolvedResource: String
    public let canonicalRequest: Data
    public let canonicalParametersDigest: String

    public init(runID: UUID, epoch: UInt64, grantDigest: String, connectionID: UUID, operation: String, schemaDigest: String, resolvedResource: String, canonicalRequest: Data) throws {
        guard epoch > 0, !canonicalRequest.isEmpty, canonicalRequest.count <= 65_536 else { throw ContractError.invalidField("actionBinding") }
        try requireDigest(grantDigest, "grantDigest"); try requireDigest(schemaDigest, "schemaDigest")
        try requireText(operation, "operation"); try requireText(resolvedResource, "resolvedResource")
        self.runID = runID; self.epoch = epoch; self.grantDigest = grantDigest; self.connectionID = connectionID
        self.operation = operation; self.schemaDigest = schemaDigest; self.resolvedResource = resolvedResource
        self.canonicalRequest = canonicalRequest
        self.canonicalParametersDigest = SHA256.hash(data: canonicalRequest).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PendingActionState: String, Codable, Sendable { case pending, denied, expired, consumed }

/// Only a pending proposal. Lifecycle, atomic consumption and durable dispatch belong to Host Core.
/// Deliberately not Decodable: an untrusted message cannot deserialize a host approval object.
public struct PendingAction: Equatable, Sendable {
    public let actionID: UUID
    public let binding: ActionBinding
    public let safeDisplaySnapshot: String
    public let nonce: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let state: PendingActionState = .pending

    public init(binding: ActionBinding, safeDisplaySnapshot: String, createdAt: Date, expiresAt: Date) throws {
        guard createdAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= 300 else {
            throw ContractError.invalidField("actionExpiry")
        }
        try requireText(safeDisplaySnapshot, "safeDisplaySnapshot", maximum: 4096)
        self.actionID = UUID(); self.binding = binding; self.safeDisplaySnapshot = safeDisplaySnapshot
        self.nonce = UUID(); self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    public func matches(binding candidate: ActionBinding, nonce: UUID, at time: Date) -> Bool {
        candidate == binding && nonce == self.nonce && time >= createdAt && time < expiresAt
    }
}
