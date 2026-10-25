import Darwin
import Foundation

/// A bare `swift run MCPGatewayChecks` has no loopback fixture on stdin. Re-run
/// this same binary under its repository driver, which starts the fixture and
/// supplies the synthetic token over a pipe. The marker variable is inherited by
/// the driver's child, so a delegated run can never delegate again.
enum DriverDelegation {
    static let marker = "MINI_SANDBOX_MCP_DRIVER_DELEGATED"

    /// Reads the driver configuration line, or delegates when stdin is a
    /// terminal (reading would block) or already at end of input.
    static func configurationLine(selector: [String]) -> String {
        if isatty(STDIN_FILENO) == 0, let line = readLine() { return line }
        run(selector: selector)
    }

    private static func run(selector: [String]) -> Never {
        guard ProcessInfo.processInfo.environment[marker] == nil else {
            output("FAIL MCP loopback driver input required")
            exit(1)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script: URL
        let arguments: [String]
        guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            output("FAIL cannot resolve MCPGatewayChecks executable path")
            exit(1)
        }
        if selector == ["--claude-native"] {
            script = root.appendingPathComponent("Tests/MCPGatewayChecks/claude_loopback.py")
            arguments = ["--binary", binary]
        } else {
            script = root.appendingPathComponent("Tests/MCPIntegrationTests/test_loopback.py")
            arguments = ["--binary", binary, "--scope", selector == ["--independent"] ? "independent" : "default"]
        }
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            output("FAIL loopback driver not found at \(script.path); run it from a repository checkout")
            exit(1)
        }
        output("INFO no driver input; running \(script.lastPathComponent) with this binary")
        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            output("FAIL cannot start python3 loopback driver: \(error)")
            exit(1)
        }
        process.waitUntilExit()
        exit(process.terminationReason == .exit ? process.terminationStatus : 1)
    }
}
