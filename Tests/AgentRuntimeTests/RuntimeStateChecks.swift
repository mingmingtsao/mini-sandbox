import Foundation
import CryptoKit
import Darwin
@testable import SandboxHost

func runtimeStateChecks() throws {
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: message, code: 1) }
    }
    let payload = Data("cancel-fixture".utf8)
    let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    func frame(_ type: String, id: Int, extra: [String: Any]) throws -> Data {
        var object = extra; object["v"] = 1; object["id"] = id; object["type"] = type
        return try JSONSerialization.data(withJSONObject: object)
    }
    let probe = AgentRuntimeProbe()
    probe.command = 5
    let stdout = try frame("stdout", id: 5, extra: ["data": payload.base64EncodedString(), "sha256": hash])
    try probe.receive(stdout)
    try check(probe.didCancel && probe.command == 5 && probe.outputBytes == payload.count, "first cancel output state")
    let size = probe.output.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    let cancel = try JSONSerialization.jsonObject(with: probe.output.dropFirst(4)) as? [String: Any]
    try check(size == probe.output.count - 4 && cancel?["type"] as? String == "cancel" && cancel?["id"] as? Int == 5, "cancel wire framing")
    let queued = probe.output
    try probe.receive(stdout)
    try check(probe.output == queued && probe.outputBytes == payload.count * 2, "duplicate stdout sent another cancel")
    try probe.receive(frame("exit", id: 5, extra: ["code": -9, "cancelled": true]))
    try check(probe.command == 6, "cancelled command did not advance")
    let completed = AgentRuntimeProbe()
    completed.command = completed.commands.count
    try completed.receive(frame("exit", id: completed.command, extra: ["code": 0, "cancelled": false]))
    try check(completed.stopping && completed.finished && !completed.failed, "complete command sequence not retired")
    for mode in ["oversize", "queue", "stopped"] {
        let p = AgentRuntimeProbe()
        if mode == "queue" { p.output = Data(repeating: 0, count: 32768) }
        if mode == "stopped" { p.stopping = true }
        do {
            try p.send("launch", 1, mode == "oversize" ? ["argv": [String(repeating: "x", count: 16384)]] : [:])
            throw NSError(domain: "unbounded send accepted", code: 1)
        } catch is AgentRuntimeProbe.Failure {}
        try check(p.output.count == (mode == "queue" ? 32768 : 0), "rejected send changed queued bytes")
    }
    let console = AgentRuntimeProbe()
    let pipe = Pipe()
    console.console = pipe
    console.end = ProcessInfo.processInfo.systemUptime + 10
    let fd = pipe.fileHandleForReading.fileDescriptor
    try check(fcntl(fd, F_SETFL, O_NONBLOCK) == 0, "nonblocking fixture pipe")
    try pipe.fileHandleForWriting.write(contentsOf: payload)
    console.tick()
    try check(console.consoleBytes == payload.count && !console.stopping, "console accounting changed protocol state")
    console.end = 0
    console.tick()
    try check(console.finished && console.failed && console.stopping, "runtime deadline did not terminate")
    console.tick()
    try check(console.finished && console.output.isEmpty && console.input.isEmpty, "finished runtime revived")
    try pipe.fileHandleForReading.close(); try pipe.fileHandleForWriting.close()
    print("PASS runtime cancel wire exact-once, command completion, send bounds, console accounting and terminal deadline")
}
