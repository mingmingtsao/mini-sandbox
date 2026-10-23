import Foundation
import SandboxContracts

private func requireEventText(_ value: String, _ name: String) throws {
    guard !value.isEmpty, value.utf8.count <= 512,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ContractError.invalidField(name)
    }
}
private func requireEventDigest(_ value: String, _ name: String) throws {
    guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw ContractError.invalidField(name)
    }
}

public enum EventOrigin: String, Encodable, Sendable { case hostEnforcement, guestDiagnostic }
public enum EventDecision: String, Encodable, Sendable { case allow, deny, observe }
public enum DispatchOutcome: String, Encodable, Sendable { case notDispatched, completed, failed, unknown }

/// Host-owned event for storage/display; not Decodable from the guest wire.
/// Guest diagnostics must be wrapped by the host using guestDiagnostic, never their claimed origin.
public struct SecurityEvent: Encodable, Equatable, Sendable {
    public let eventID: UUID
    public let hostSequence: UInt64
    public let runID: UUID
    public let actionID: UUID?
    public let time: Date
    public let origin: EventOrigin
    public let operation: String
    public let resourceSummary: String
    public let decision: EventDecision
    public let reason: String
    public let grantDigest: String
    public let outcome: DispatchOutcome

    internal init(eventID: UUID, hostSequence: UInt64, runID: UUID, actionID: UUID?, time: Date, origin: EventOrigin, operation: String, resourceSummary: String, decision: EventDecision, reason: String, grantDigest: String, outcome: DispatchOutcome) throws {
        guard hostSequence > 0, time.timeIntervalSince1970.isFinite else { throw ContractError.invalidField("event") }
        try requireEventText(operation, "operation"); try requireEventText(resourceSummary, "resourceSummary")
        try requireEventText(reason, "reason"); try requireEventDigest(grantDigest, "grantDigest")
        self.eventID = eventID; self.hostSequence = hostSequence; self.runID = runID; self.actionID = actionID
        self.time = time; self.origin = origin; self.operation = operation; self.resourceSummary = resourceSummary
        self.decision = decision; self.reason = reason; self.grantDigest = grantDigest; self.outcome = outcome
    }

    public var isHostRejection: Bool { origin == .hostEnforcement && decision == .deny && outcome == .notDispatched }
}
