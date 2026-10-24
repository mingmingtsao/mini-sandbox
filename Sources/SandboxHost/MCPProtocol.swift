import Foundation
import CryptoKit

package enum MCPDiscoveryState: String, Sendable { case unknown, knownEmpty, knownReady }
struct MCPResolved: Sendable {
    let payload: ModelJSON
    let method: String
    let resource: String
    let operation: String
}
enum MCPProtocol {
    static let version = "2025-03-26"
    static let adapter = "fixture-repository-v1"
    static let server = "host-loopback-fixture/1"
    static func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func ingress(_ data: Data, maxBytes: Int) throws -> MCPResolved {
        let value = try ModelJSON.parse(data, maxBytes: maxBytes)
        guard let o = value.object, value["jsonrpc"] == .string("2.0"), let method = value["method"]?.string else { throw HostMCPGatewayError.denied }
        let notification = method == "notifications/initialized"
        guard Set(o.keys) == Set(notification ? ["jsonrpc", "method", "params"] : ["jsonrpc", "id", "method", "params"]),
              notification || (value["id"]?.string.map { !$0.isEmpty && $0.utf8.count <= 128 } == true),
              let params = value["params"]?.object else { throw HostMCPGatewayError.denied }
        switch method {
        case "initialize":
            guard Set(params.keys) == ["protocolVersion", "capabilities", "clientInfo"], params["protocolVersion"] == .string(version), params["capabilities"] == .object([:]), params["clientInfo"] == .object(["name": .string("bounded-host-fixture"), "version": .string("1")]) else { throw HostMCPGatewayError.denied }
        case "notifications/initialized", "tools/list":
            guard params.isEmpty else { throw HostMCPGatewayError.denied }
        case "tools/call":
            let resolved = try MCPRepositoryAdapter.resolve(params)
            return MCPResolved(payload: value, method: method, resource: resolved.0, operation: resolved.1)
        default: throw HostMCPGatewayError.denied
        }
        return MCPResolved(payload: value, method: method, resource: "control", operation: method)
    }
    static func response(_ data: Data, request: ModelJSON) throws -> ModelJSON {
        if request["method"] == .string("notifications/initialized") {
            guard data.isEmpty else { throw HostMCPGatewayError.invalidResponse }; return .object([:])
        }
        let value = try ModelJSON.parse(data)
        guard let o = value.object, Set(o.keys) == ["jsonrpc", "id", "result"], value["jsonrpc"] == .string("2.0"), value["id"] == request["id"], let result = value["result"], result.object != nil else { throw HostMCPGatewayError.invalidResponse }
        return result
    }
    static func validateInitialization(_ result: ModelJSON) throws {
        guard result == .object(["protocolVersion": .string(version), "capabilities": .object(["tools": .object([:]), "resources": .object([:])]), "serverInfo": .object(["name": .string("host-loopback-fixture"), "version": .string("1")])]) else { throw HostMCPGatewayError.invalidResponse }
    }
    static func catalog(_ result: ModelJSON) throws -> (MCPDiscoveryState, String) {
        guard let o = result.object, Set(o.keys) == ["tools"], let tools = result["tools"]?.array, tools.count <= 2 else { throw HostMCPGatewayError.invalidResponse }
        var names = Set<String>()
        for tool in tools {
            guard let item = tool.object, Set(item.keys) == ["name", "description", "inputSchema", "annotations"], let name = tool["name"]?.string, ["repo_read", "repo_write"].contains(name), names.insert(name).inserted,
                  tool["description"]?.string != nil, tool["inputSchema"] == .object(["type": .string("object")]), tool["annotations"] == .object(["readOnlyHint": .bool(true)]) else { throw HostMCPGatewayError.invalidResponse }
        }
        guard tools.isEmpty || names == ["repo_read", "repo_write"] else { throw HostMCPGatewayError.invalidResponse }
        let ordered = tools.sorted { $0["name"]!.string! < $1["name"]!.string! }
        return (tools.isEmpty ? .knownEmpty : .knownReady, digest(try canonical(ModelJSON.array(ordered))))
    }
    static func toolText(_ result: ModelJSON) throws -> String {
        guard let o = result.object, Set(o.keys).isSubset(of: ["content", "isError"]), result["isError"] == nil || result["isError"] == .bool(false), let content = result["content"]?.array, content.count <= 16 else { throw HostMCPGatewayError.invalidResponse }
        var text = ""
        for part in content {
            guard let item = part.object, Set(item.keys) == ["type", "text"], part["type"] == .string("text"), let value = part["text"]?.string else { throw HostMCPGatewayError.invalidResponse }
            text += value; guard text.utf8.count <= 32768 else { throw HostMCPGatewayError.invalidResponse }
        }
        return text
    }
}
