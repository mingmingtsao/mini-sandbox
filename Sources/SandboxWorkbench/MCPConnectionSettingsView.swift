import SwiftUI

@MainActor package struct MCPConnectionSettingsView: View {
    @ObservedObject private var controller: MCPConnectionSettingsController
    @State private var port = ""
    @State private var bearer = ""
    package init(controller: MCPConnectionSettingsController) { self.controller = controller }
    package var body: some View {
        GroupBox("Bounded local repository MCP") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Only the fixed 2026-07-28 repository profile (repo_read / repo_write) is supported. This is not a general MCP or GitHub connection.").font(.callout)
                if !controller.isLocalFixture {
                    TextField("127.0.0.1 port", text: $port)
                    SecureField("Temporary host bearer", text: $bearer).privacySensitive()
                    HStack {
                        Button("Configure local connection") {
                            let value = bearer; bearer = ""
                            Task { await controller.connect(port: port, bearer: value) }
                        }.disabled(bearer.isEmpty)
                        Button("Disconnect", role: .destructive) { bearer = ""; Task { await controller.disconnect() } }
                    }
                    Text("Changing this connection stops runs bound to it. The bearer stays on this host and is not saved between launches.").font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: controller.status).font(.caption)
            }.padding(8).disabled(controller.isBusy || controller.isClosed)
        }.onDisappear { bearer = "" }.onChange(of: controller.isClosed) { _, _ in bearer = "" }
    }
}
