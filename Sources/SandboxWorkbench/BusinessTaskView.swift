import AppKit
import SwiftUI
import SandboxHost

/// Emergency Stop remains outside all scrolling approval and result content.
@MainActor package struct BusinessTaskView: View {
    @ObservedObject private var controller: BusinessTaskController
    @ObservedObject private var connections: ConnectionSettingsController
    @State private var closeReview = false
    package init(controller: BusinessTaskController, connections: ConnectionSettingsController) {
        self.controller = controller; self.connections = connections
    }
    package var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project task").font(.title.bold())
                    Text(verbatim: controller.status).font(.callout)
                }
                Spacer()
                Button("Stop", role: .destructive) { controller.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!controller.isBusy)
                    .controlSize(.large)
            }
            if let error = controller.error { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
            if let stopped = controller.stopSummary { Text(verbatim: stopped).font(.caption).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !controller.activationAvailable {
                        Label("Business model egress is disabled in this build. The task cannot start until the reviewed route is enabled.", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                    }
                    setup
                    ForEach(controller.approvals) { approval in
                        GroupBox(approval.title) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("One action · expires \(approval.expiresAt.formatted(date: .omitted, time: .standard))").font(.caption)
                                ScrollView([.horizontal, .vertical]) {
                                    Text(verbatim: approval.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(minHeight: 100, maxHeight: 280)
                                HStack {
                                    Button("Deny", role: .destructive) { controller.decide(approval.id, allow: false) }
                                    Button("Approve this action") { controller.decide(approval.id, allow: true) }
                                }
                            }.padding(8)
                        }
                    }
                    if !controller.importExclusions.isEmpty {
                        DisclosureGroup("Excluded from the imported project (\(controller.importExclusions.count))") {
                            ForEach(Array(controller.importExclusions.enumerated()), id: \.offset) { _, item in Text(verbatim: item).font(.caption) }
                        }
                    }
                    output("Agent standard output", controller.stdout)
                    output("Agent standard error", controller.stderr)
                    if let review = controller.review { result(review) }
                    if !controller.measurements.isEmpty {
                        DisclosureGroup("Request sizes") {
                            ForEach(Array(controller.measurements.enumerated()), id: \.offset) { _, value in
                                Text(verbatim: value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(.trailing, 8)
            }
        }.padding(20)
        .task {
            while !Task.isCancelled {
                controller.expireApprovals()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog("Close this result review?", isPresented: $closeReview) {
            Button("Close review") { controller.finishReview() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Export the reviewed result first if you want a separate project directory. The private task snapshot is retained.") }
    }
    private var setup: some View {
        GroupBox("Task and permissions") {
            VStack(alignment: .leading, spacing: 12) {
                path("Project", controller.project, button: "Choose project…") { chooseDirectory(controller.selectProject) }
                path("Linux runtime", controller.runtimeDirectory, button: "Choose runtime…") { chooseDirectory(controller.selectRuntime) }
                path("Pinned CLI disk", controller.vendorDisk, button: "Choose CLI disk…") { chooseVendor() }
                Picker("Agent", selection: $controller.agent) {
                    ForEach(BusinessTaskController.Agent.allCases) { agent in Text(agent.rawValue).tag(agent) }
                }.disabled(controller.isBusy)
                if controller.agent != .claude { Text("This Agent is not implemented. Select Claude Code to run a supported task.").foregroundStyle(.orange) }
                Text("Task").font(.headline)
                TextEditor(text: $controller.task).font(.body).frame(minHeight: 95, maxHeight: 180)
                    .border(.quaternary).disabled(controller.isBusy)
                Text("\(controller.task.utf8.count) / 8192 UTF-8 bytes").font(.caption).foregroundStyle(.secondary)
                Text("The VM receives a project copy and has no network device. Claude may request file reads, edits and commands in that copy. You approve each model request and tool permission. Limits: 2 CPUs, 1 GiB memory, 15 minutes. MCP is unavailable in this build.")
                    .font(.callout)
                Toggle("I authorize this task in the isolated project copy and will review each requested action.", isOn: $controller.permissionsConfirmed)
                    .disabled(controller.isBusy)
                HStack {
                    Button("Start task") { controller.start() }.disabled(!controller.canStart)
                    if connections.configuration == nil { Text("Configure a model connection below.").font(.caption) }
                    if controller.review != nil { Text("Export or close the current review before starting another task.").font(.caption) }
                }
                DisclosureGroup("Model connection") { ConnectionSettingsView(controller: connections) }
            }.padding(8)
        }
    }
    private func path(_ title: String, _ value: URL?, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Text(verbatim: value?.path ?? "Not selected").font(.caption).textSelection(.enabled)
            Spacer()
            Button(button, action: action).disabled(controller.isBusy)
        }
    }
    @ViewBuilder private func output(_ title: String, _ value: String) -> some View {
        if !value.isEmpty {
            GroupBox(title) {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 80, maxHeight: 260).padding(8)
            }
        }
    }
    private func result(_ review: WorkspaceReview) -> some View {
        GroupBox("Stopped VM result · \(review.changes.count) changes") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Snapshot SHA-256: \(review.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in
                    DisclosureGroup("\(change.kind.rawValue): \(change.path)") {
                        HStack(alignment: .top) {
                            preview("Before", change.before)
                            preview("After", change.after)
                        }
                    }
                }
                HStack {
                    Button("Export reviewed result…") { chooseExport() }.disabled(controller.isBusy)
                    Button("Close review…") { closeReview = true }.disabled(controller.isBusy)
                }
                Text("Export creates a new directory. It never overwrites the selected project.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private func preview(_ title: String, _ value: WorkspacePreview?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            switch value {
            case .text(let text): Text(verbatim: text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            case .noPreview(let reason): Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
            case nil: Text("No file").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func chooseDirectory(_ selected: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, let url = panel.url { selected(url) } }
    }
    private func chooseVendor() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, let url = panel.url { controller.selectVendor(url) } }
    }
    private func chooseExport() {
        let panel = NSSavePanel(); panel.title = "Export reviewed project to a new directory"
        panel.nameFieldStringValue = "ReviewedProject"; panel.canCreateDirectories = true
        panel.begin { response in if response == .OK, let url = panel.url { controller.export(to: url) } }
    }
}
