import SwiftUI
import AppKit
import SandboxHost
import SandboxWorkbench

@main
struct MiniSandboxEntry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--keychain-canary-selfcheck") {
            let report = await Task.detached { KeychainCanarySelfCheck.runPackaged() }.value
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            do { print(String(decoding: try encoder.encode(report), as: UTF8.self)) }
            catch { print("{\"verdict\":\"FAIL\"}"); exit(1) }
            exit(report.verdict == "PASS" ? 0 : (report.verdict == "BLOCKED" ? 2 : 1))
        } else if CommandLine.arguments.contains("--diagnostics-json") {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let report = await Task.detached { EnvironmentInspector.inspect() }.value
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data("Diagnostics failed: \(error)\n".utf8))
                exit(1)
            }
        } else {
            MiniSandboxApplication.main()
        }
    }
}

struct MiniSandboxApplication: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @State private var selectedTab = "tasks"
    var body: some Scene {
        Window("Mini Sandbox", id: "workbench") {
            TabView(selection: $selectedTab) {
                if let taskController = delegate.taskController, let connections = delegate.connectionSettings {
                    BusinessTaskView(controller: taskController, connections: connections)
                        .tabItem { Label("Tasks", systemImage: "folder") }.tag("tasks")
                }
                WorkbenchView(model: delegate.model, connectionSettings: delegate.connectionSettings).tabItem { Label("Workbench", systemImage: "checkmark.shield") }.tag("workbench")
                EnvironmentView().tabItem { Label("Environment", systemImage: "desktopcomputer") }.tag("environment")
            }
            .background(WindowCloseGuard())
        }
            .defaultSize(width: 940, height: 720)
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let composition: RunComposition?
    let model: WorkbenchModel
    let connectionSettings: ConnectionSettingsController?
    let taskController: BusinessTaskController?
    override init() {
        let composition = try? RunComposition.application()
        self.composition = composition
        self.connectionSettings = composition?.connectionSettings
        self.taskController = composition?.business
        self.model = composition?.workbench ?? WorkbenchModel(unavailable: "App composition unavailable; authority disabled")
        super.init()
    }
    private var terminationPending = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isClosed { return .terminateNow }
        if !terminationPending {
            if let composition { composition.beginClose() }
            else { connectionSettings?.close(); model.beginClose() }
            terminationPending = true
            Task { @MainActor in
                let revoked: Bool
                if let composition { revoked = await composition.close() }
                else { revoked = await model.close() }
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: revoked)
            }
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Route the red close button through the same awaited termination handshake.
private struct WindowCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ nsView: GuardView, context: Context) {}
    final class GuardView: NSView, NSWindowDelegate {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.delegate = self }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApplication.shared.terminate(nil)
            return false
        }
    }
}

struct EnvironmentView: View {
    @State private var report: EnvironmentReport?
    @State private var isChecking = false
    var body: some View {
        Group {
            if let report { content(report) }
            else {
                VStack(spacing: 20) {
                    Text("Environment not checked").font(.title)
                    Text("Model settings are separate. Environment readiness is not VM / Agent readiness.")
                    Button("Run environment check") { refresh() }.disabled(isChecking)
                }.padding(28).frame(minWidth: 640, minHeight: 440)
            }
        }
    }
    private func refresh() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            report = await Task.detached { EnvironmentInspector.inspect() }.value
            isChecking = false
        }
    }
    private func content(_ report: EnvironmentReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "shield.lefthalf.filled").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("Mini Sandbox").font(.largeTitle.bold())
                    Text("运行前环境检查").foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检查") { refresh() }.disabled(isChecking)
            }
            GroupBox("本机状态") {
                Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                    row("系统", report.operatingSystem)
                    row("架构", report.architecture)
                    row("虚拟化能力", report.virtualizationSupported ? "可用" : "不可用")
                    row("钥匙串查询", report.keychainQueryAvailable ? "可达（未验证凭据写入）" : "不可达：\(report.keychainStatus)")
                    row("CPU / 内存", "\(report.logicalCPUCount) 核 / \(ByteCountFormatter.string(fromByteCount: Int64(report.physicalMemoryBytes), countStyle: .memory))")
                    row("可用磁盘", report.availableDiskBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "无法读取")
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Label(report.foundationReady ? "基础环境检查通过" : "请先处理不可用的基础环境", systemImage: report.foundationReady ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(report.foundationReady ? .green : .orange)
            Text("环境检查仅验证本机条件。项目导入、任务授权、Agent 运行、停止与结果审阅请在 Tasks 中操作；环境通过不代表任务执行或模型请求成功。")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("检查时间：\(report.checkedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(minWidth: 640, minHeight: 440)
    }
    @ViewBuilder private func row(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
