import SwiftUI
import SandboxContracts
import SandboxHost

@MainActor public struct WorkbenchView: View {
    @ObservedObject private var model: WorkbenchModel
    @StateObject private var approval: WorkbenchApprovalController
    private let connectionSettings: ConnectionSettingsController?
    public init(model: WorkbenchModel) {
        self.model = model
        connectionSettings = nil
        _approval = StateObject(wrappedValue: WorkbenchApprovalController(model: model))
    }

    package init(model: WorkbenchModel, connectionSettings: ConnectionSettingsController?) {
        self.model = model
        self.connectionSettings = connectionSettings
        _approval = StateObject(wrappedValue: WorkbenchApprovalController(model: model))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Authorization workbench").font(.largeTitle.bold())
                Text("Runtime producer / VM not connected. No workload is running.").foregroundStyle(.secondary)
                if let error = model.errorMessage {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }.foregroundStyle(.red)
                }
                if !model.authorityAvailable { Text("Authority disabled").font(.headline) }
                if let connectionSettings { ConnectionSettingsView(controller: connectionSettings) }
                GroupBox("Run grants") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.grants.isEmpty { Text("No trusted host grants received.") }
                        ForEach(model.grants, id: \.runID) { grant in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: "Run \(grant.runID)").font(.headline)
                                Text(verbatim: model.runStatus[grant.runID] ?? "Unavailable")
                                Text("Immutable granted scopes (not proof of current connection availability)").font(.caption)
                                ForEach(grant.connections, id: \.connectionID) { connection in
                                    Text(verbatim: "Connection \(connection.connectionID)").font(.caption)
                                    ForEach(Array(connection.scopes).sorted { ($0.service, $0.resource, $0.operation) < ($1.service, $1.resource, $1.operation) }, id: \.self) { scope in
                                        Text(verbatim: "\(scope.service) · \(scope.resource) · \(scope.operation)\(grant.explicitDenies.contains(scope) ? " — explicitly denied" : "")")
                                    }
                                }
                                stopControl(runID: grant.runID)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Pending approval") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.pending.isEmpty { Text("No actions awaiting approval. Default decision: deny.") }
                        ForEach(model.pending, id: \.actionID) { action in
                            HStack {
                                Text(verbatim: action.safeDisplaySnapshot)
                                Spacer()
                                Button("Review") { approval.present(action) }
                                    .disabled(model.isBusy || model.isClosing || !model.authorityAvailable)
                            }
                        }
                        Text("\(model.approvedActions.count) approved capability(s) awaiting trusted host integration. Nothing is automatically dispatched.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Activity · bounded to the latest 200 durable events") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Trusted host denials in this view: \(model.trustedDenialCount)")
                        eventSection("Host enforcement", origin: .hostEnforcement)
                        eventSection("Guest diagnostics · untrusted observations", origin: .guestDiagnostic)
                        Text(verbatim: "Audit: \(model.auditURL.path)").font(.caption).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Text("Partial native approval increment. VM execution, broker dispatch, G1/U01 and full F10 acceptance are not established.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .sheet(item: $approval.presentation, onDismiss: {
            Task { await approval.didDismiss() }
        }) { value in
            approvalSheet(value.action)
        }
        .task {
            while !Task.isCancelled {
                await model.expirePending()
                approval.reconcile()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        .frame(minWidth: 720, minHeight: 540)
    }
    private func eventSection(_ title: String, origin: EventOrigin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            let events = model.activity.filter { $0.origin == origin }
            if events.isEmpty { Text("No recorded events.").foregroundStyle(.secondary) }
            ForEach(events, id: \.eventID) { event in
                Text(verbatim: "#\(event.hostSequence) · \(event.decision.rawValue) · \(event.operation) · \(event.resourceSummary) · \(event.reason) · \(event.outcome.rawValue)")
                    .font(.callout).textSelection(.enabled)
            }
        }
    }
    private func approvalSheet(_ action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Approve one immutable action?").font(.title2.bold())
            Text("Deny is the default. Approval alone does not execute anything.").foregroundStyle(.secondary)
            Grid(alignment: .leading, verticalSpacing: 10) {
                field("Run", action.binding.runID.uuidString)
                field("Action", action.actionID.uuidString)
                field("Connection", action.binding.connectionID.uuidString)
                field("Service", model.service(for: action))
                field("Resource", action.binding.resolvedResource)
                field("Operation", action.binding.operation)
                field("Display snapshot", action.safeDisplaySnapshot)
                field("Expires", action.expiresAt.formatted())
            }
            HStack {
                Button("Deny") { Task { await approval.dismiss(action) } }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel / deny") { Task { await approval.dismiss(action) } }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve once") {
                    Task {
                        do { try await approval.approve(action) } catch { /* Model publishes the real rejection. */ }
                    }
                }
            }.disabled(approval.ordinaryControlsDisabled)
            stopControl(runID: action.binding.runID)
        }.padding(28).frame(width: 620)
    }
    private func field(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(verbatim: value).textSelection(.enabled) }
    }
    private func stopControl(runID: UUID) -> some View {
        Button("Stop and revoke") {
            Task {
                do { try await approval.stop(runID: runID) } catch { /* Model publishes cleanup failure. */ }
            }
        }.disabled(!model.canStop(runID: runID))
    }
}
