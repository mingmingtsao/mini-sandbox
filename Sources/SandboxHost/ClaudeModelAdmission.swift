import CryptoKit
import Foundation
import SandboxContracts

/// Pure admission and immutable approval-byte construction for the pinned CLI.
/// This value cannot dispatch, read credentials, or enable the business route.
/// The product route remains disabled pending independent credential review.
package struct ClaudeModelAdmission: Sendable {
    package struct Measurements: Sendable {
        package let httpBytes: Int
        package let headerBytes: Int
        package let bodyBytes: Int
        package let canonicalBodyBytes: Int
        package let approvalEnvelopeBytes: Int
        package let historyMessages: Int
        package let toolDefinitions: Int
        package let toolResultBytes: Int
    }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let runID: UUID
        let epoch: UInt64
        let connectionID: UUID
        let accountID: UUID
        let accountBindingVersion: UInt64
        let routeVersion: UInt64
        let claudeSelectors: ClaudeRequestSelectors
        let nativeBody: ModelJSON
        let streaming: Bool
    }
    package let binding: ActionBinding
    package let measurements: Measurements
    package let selectors: ClaudeRequestSelectors
    package let request: AnthropicNativeRequest

    package static func prepare(
        ingress: BusinessHTTPIngress, authority: RunAuthorizationController,
        handle: HostRunHandle, connection: HostModelConnection
    ) throws -> Self {
        let grant = try authority.installedGrantForOwnership(of: handle)
        let observation = handle.lifecycle.observeAndReduce(reason: "claude-business-admission")
        guard observation.status == .active, observation.generation == grant.epoch else {
            throw HostModelGatewayError.revoked
        }
        guard grant.createdAt <= observation.wallTime else { throw AuthorizationError.grantNotYetValid }
        let request = try ingress.claudeRequest()
        let selectors = try ingress.claudeSelectors
        guard connection.model == request.model, connection.protocol == .anthropic,
            let installed = grant.connections.first(where: { $0.connectionID == connection.connectionID }),
            installed.accountBindingVersion == connection.accountBindingVersion,
            installed.routeVersion == connection.routeVersion
        else { throw HostModelGatewayError.invalidConnection }
        let scope = try ResourceScope(
            service: "model", resource: request.model.rawValue, operation: request.streaming ? "stream" : "complete")
        guard handle.lifecycle.permitsConnection(connection.connectionID),
            grant.decision(for: scope, connectionID: connection.connectionID, at: observation.effectiveTime) == .allowed
        else {
            throw HostModelGatewayError.denied
        }
        let envelope = Envelope(
            schemaVersion: 4, runID: grant.runID, epoch: grant.epoch,
            connectionID: connection.connectionID, accountID: connection.accountID,
            accountBindingVersion: connection.accountBindingVersion, routeVersion: connection.routeVersion,
            claudeSelectors: selectors, nativeBody: request.body, streaming: request.streaming)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(envelope)
        guard canonical.count <= min(grant.resourceLimits.messageBytes, ModelJSON.maxBytes) else {
            throw HostModelGatewayError.messageTooLarge
        }
        let schema = SHA256.hash(data: Data("host-model-claude-envelope-v4".utf8)).map { String(format: "%02x", $0) }
            .joined()
        let binding = try ActionBinding(
            runID: grant.runID, epoch: grant.epoch,
            grantDigest: RunAuthorizationController.grantDigest(for: grant), connectionID: connection.connectionID,
            operation: scope.operation, schemaDigest: schema, resolvedResource: scope.resource,
            canonicalRequest: canonical)
        let messages = request.body["messages"]?.array ?? []
        let results = messages.flatMap { $0["content"]?.array ?? [] }.filter { $0["type"]?.string == "tool_result" }
        let resultBytes = try results.reduce(0) { try $0 + encoder.encode($1).count }
        return Self(
            binding: binding,
            measurements: Measurements(
                httpBytes: ingress.wireBytes,
                headerBytes: ingress.headerBytes, bodyBytes: ingress.body.count,
                canonicalBodyBytes: request.canonicalBody.count, approvalEnvelopeBytes: canonical.count,
                historyMessages: messages.count, toolDefinitions: request.body["tools"]?.array?.count ?? 0,
                toolResultBytes: resultBytes),
            selectors: selectors, request: request)
    }
}
