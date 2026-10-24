import SwiftUI
import AppKit
import SandboxHost

@main
struct MiniSandboxEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnostics-json") {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(EnvironmentInspector.inspect()), as: UTF8.self))
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
    var body: some Scene {
        WindowGroup("Mini Sandbox") { EnvironmentView() }
            .defaultSize(width: 720, height: 480)
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct EnvironmentView: View {
    @State private var report = EnvironmentInspector.inspect()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "shield.lefthalf.filled").font(.largeTitle)
                VStack(alignment: .leading) {
                    Text("Mini Sandbox").font(.largeTitle.bold())
                    Text("运行前环境检查").foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检查") { report = EnvironmentInspector.inspect() }
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
            Text("此版本提供真实环境检查。Linux 镜像、隔离运行、服务连接和项目导入尚未接入；环境可用不代表完整安全验收通过。")
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
