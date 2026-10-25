import Darwin
import Foundation
import SandboxHost

func emit(_ object: [String: String]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    {
        print(text)
    }
}
func capabilities() -> [String: String] {
    var result = HeadlessVMProbe.capabilities()
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = [
        "--display", "--entitlements", ":-", URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
    ]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        result["virtualizationEntitlement"] = String(
            process.terminationStatus == 0 && plist?["com.apple.security.virtualization"] as? Bool == true)
    } catch { result["virtualizationEntitlement"] = "false" }
    return result
}
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--capabilities"] {
    let result = capabilities()
    emit(result)
    exit(result["virtualizationSupported"] == "true" && result["virtualizationEntitlement"] == "true" ? 0 : 2)
}
guard args.count == 5, args[0] == "--run", args[1] == "--bundle", args[3] == "--evidence-dir", !args[2].hasPrefix("--"),
    !args[4].hasPrefix("--"), !args[2].isEmpty, !args[4].isEmpty
else {
    print("usage: VMProbe --capabilities | --run --bundle PATH --evidence-dir NEW_PATH")
    exit(64)
}
let capability = capabilities()
guard capability["virtualizationSupported"] == "true", capability["virtualizationEntitlement"] == "true" else {
    emit(capability)
    exit(2)
}
do {
    let bundle = try VMVerifiedBundle(directory: URL(fileURLWithPath: args[2], isDirectory: true))
    let evidence = URL(fileURLWithPath: args[4], isDirectory: true).standardizedFileURL
    guard
        evidence.deletingLastPathComponent().resolvingSymlinksInPath().path
            == evidence.deletingLastPathComponent().path,
        mkdir(evidence.path, 0o700) == 0
    else { throw CocoaError(.fileWriteFileExists) }
    let sink = try JSONLAuditSink(newFileAt: evidence.appendingPathComponent("security-events.jsonl"))
    let probe = HeadlessVMProbe()
    let status = probe.run(bundle: bundle, sink: sink)
    let summary: [String: String] = [
        "exitCode": String(status), "workloadSHA256": bundle.workloadDigest,
        "scope": "diagnostic VM only; no Agent or authorization service", "result": status == 0 ? "PASS" : "FAIL",
    ]
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
    try data.write(to: evidence.appendingPathComponent("result.json"), options: [.withoutOverwriting])
    emit(summary)
    exit(status)
} catch {
    print("FAIL: \(error)")
    exit(1)
}
