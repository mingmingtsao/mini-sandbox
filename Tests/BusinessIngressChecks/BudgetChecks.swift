import Foundation
import SandboxContracts
@testable import SandboxHost

func businessBudgetChecks(authority: RunAuthorizationController, handle: HostRunHandle, connection: HostModelConnection) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func payload(_ text: String) throws -> String {
        String(decoding: try encoder.encode(ModelJSON.object([
            "model": .string("deepseek-flash"), "max_tokens": .integer(512), "stream": .bool(true),
            "thinking": .object(["type": .string("disabled")]),
            "messages": .array([.object(["role": .string("user"), "content": .string(text)])])
        ])), as: UTF8.self)
    }
    func admit(_ text: String) throws -> ClaudeModelAdmission {
        let ingress = try BusinessHTTPIngress.parse(wire(text))!
        return try ClaudeModelAdmission.prepare(ingress: ingress, authority: authority, handle: handle, connection: connection)
    }
    let baseline = try admit(payload("x"))
    for target in [65_535, 65_536, 65_537] {
        let text = try payload(String(repeating: "x", count: 1 + target - baseline.binding.canonicalRequest.count))
        if target <= 65_536 {
            let result = try admit(text)
            try check(result.binding.canonicalRequest.count == target, "exact complete envelope \(target)")
            print("OBS business envelope=\(target) raw=\(text.utf8.count) canonical=\(result.request.canonicalBody.count) accepted=true")
        } else {
            try rejected("full envelope over limit") { _ = try admit(text) }
            print("OBS business envelope=\(target) raw=\(text.utf8.count) accepted=false")
        }
    }
    for target in [65_535, 65_536, 65_537] {
        let text = String(repeating: "x", count: target)
        if target <= 65_536 { try check(try BusinessHTTPIngress.parse(wire(text))?.body.count == target, "raw body exact limit") }
        else { try rejected("raw body above limit") { _ = try BusinessHTTPIngress.parse(wire(text)) } }
    }
    let raw = String(repeating: "x", count: 65_536)
    let base = try BusinessHTTPIngress.parse(wire(raw, headers: "User-Agent: a\r\n"))!
    for target in [16_383, 16_384, 16_385] {
        let value = wire(raw, headers: "User-Agent: " + String(repeating: "a", count: 1 + target - base.headerBytes) + "\r\n")
        if target <= 16_384 {
            let parsed = try BusinessHTTPIngress.parse(value)!
            try check(parsed.headerBytes == target && parsed.wireBytes == target + 65_536, "exact combined wire budget")
        } else { try rejected("header/wire above limit") { _ = try BusinessHTTPIngress.parse(value) } }
    }
    for turns in [1, 8, 16, 24, 32] {
        var messages: [ModelJSON] = [.object(["role": .string("user"), "content": .string("Read the file")])]
        for index in 0..<turns {
            let id = "tool-\(index)"
            messages.append(.object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("tool_use"), "id": .string(id), "name": .string("Read"), "input": .object(["file_path": .string("/work/project/file.txt")])])
            ])]))
            messages.append(.object(["role": .string("user"), "content": .array([
                .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(String(repeating: "r", count: 2048))])
            ])]))
        }
        let request = ModelJSON.object(["model": .string("deepseek-flash"), "max_tokens": .integer(512), "stream": .bool(true),
            "messages": .array(messages), "tools": .array([.object(["name": .string("Read"), "input_schema": .object(["type": .string("object")])])])])
        let body = String(decoding: try encoder.encode(request), as: UTF8.self)
        if turns < 32 {
            let admitted = try admit(body)
            try check(admitted.measurements.historyMessages == 1 + 2 * turns && admitted.measurements.toolResultBytes > turns * 2048,
                "multi-turn exact history counts")
            try check(admitted.request.body["messages"] == .array(messages), "no history truncation")
            print("OBS business turns=\(turns) raw=\(body.utf8.count) canonical=\(admitted.request.canonicalBody.count) envelope=\(admitted.binding.canonicalRequest.count) history=\(admitted.measurements.historyMessages) toolResultBytes=\(admitted.measurements.toolResultBytes) accepted=true")
        } else {
            try rejected("growing history over budget") { _ = try admit(body) }
            print("OBS business turns=\(turns) raw=\(body.utf8.count) accepted=false truncated=false")
        }
    }
    print("PASS business exact raw/header/wire/envelope and growing multi-turn budgets; credential_reads=0 network_starts=0")
}
