import SwiftUI

/// Inline, never modal: credential storage work cannot cover emergency Stop.
@MainActor package struct ConnectionSettingsView: View {
    @ObservedObject private var controller: ConnectionSettingsController
    @State private var input = ""
    package init(controller: ConnectionSettingsController) { self.controller = controller }
    package var body: some View {
        GroupBox("Model connection · partial native increment") {
            VStack(alignment: .leading, spacing: 12) {
                Text("DeepSeek flash · Anthropic protocol").font(.headline)
                Text("Host Keychain only. No custom endpoint, guest credential, or provider test.").foregroundStyle(.secondary)
                SecureField("Enter replacement API key", text: $input)
                    .privacySensitive()
                    .disabled(controller.isBusy || controller.isClosed)
                HStack {
                    Button("Save to Keychain") {
                        let value = input
                        input = ""
                        Task { await controller.save(value) }
                    }.disabled(input.isEmpty)
                    Button("Check stored credential") {
                        input = ""
                        Task { await controller.checkStoredCredential() }
                    }
                    Button("Delete stored credential", role: .destructive) {
                        input = ""
                        Task { await controller.deleteStoredCredential() }
                    }
                }.disabled(controller.isBusy || controller.isClosed)
                Text(verbatim: controller.status).font(.callout)
                if let configuration = controller.configuration {
                    Text("Future-run configuration · account version \(configuration.accountBindingVersion) · route version \(configuration.routeVersion)")
                        .font(.caption)
                }
                Text("Save, Check and Delete retire existing model-bound runs first. A successful Save or Check configures future runs only; it creates no grant, approval, or request. VM / Agent execution is not connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onDisappear { input = "" }
        .onChange(of: controller.isClosed) { _, _ in input = "" }
    }
}
