import Foundation

package struct MCPHTTPSelectors: Codable, Equatable, Sendable {
    package let version: String
    package let method: String
    package let name: String?
}

/// The observed 2.1.309 client uses the 2026 stateless protocol, not the fixture's
/// 2025 initialize handshake. Identity still comes exclusively from the VZ owner.
package struct ClaudeMCPIngress: Sendable {
    package static let maxHeaderBytes = 16_384
    package static let maxBodyBytes = 65_536
    package let body: Data
    package let selectors: MCPHTTPSelectors
    package let headerBytes: Int
    let request: MCPResolved

    package static func parse(_ data: Data) throws -> Self? {
        guard data.count <= maxHeaderBytes + maxBodyBytes else { throw HostMCPGatewayError.denied }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count < maxHeaderBytes else { throw HostMCPGatewayError.denied }
            return nil
        }
        guard boundary.upperBound <= maxHeaderBytes,
            let text = String(data: data[..<boundary.lowerBound], encoding: .ascii)
        else { throw HostMCPGatewayError.denied }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "POST /mcp HTTP/1.1", lines.count <= 33 else { throw HostMCPGatewayError.denied }
        let allowed: Set<String> = [
            "host", "content-length", "content-type", "accept", "accept-encoding", "connection", "user-agent",
            "mcp-protocol-version", "mcp-method", "mcp-name", "origin",
        ]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HostMCPGatewayError.denied }
            let key = String(line[..<colon]).lowercased()
            guard allowed.contains(key), headers[key] == nil else { throw HostMCPGatewayError.denied }
            let value = line[line.index(after: colon)...]
            guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw HostMCPGatewayError.denied
            }
            headers[key] = value.trimmingCharacters(in: .init(charactersIn: " \t"))
        }
        guard headers["host"] == "127.0.0.1:4063",
            headers["content-type"] == "application/json",
            Set((headers["accept"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) == [
                "application/json", "text/event-stream",
            ],
            headers["accept-encoding"] == nil || headers["accept-encoding"] == "identity",
            headers["connection"] == nil || ["close", "keep-alive"].contains(headers["connection"]!),
            headers["origin"] == nil || headers["origin"] == "http://127.0.0.1:4063",
            headers["mcp-protocol-version"] == ClaudeMCPProtocol.version,
            let lengthText = headers["content-length"], !lengthText.isEmpty, lengthText.count <= 5,
            lengthText.first != "0", lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
            let count = Int(lengthText), (1...maxBodyBytes).contains(count),
            data.count - boundary.upperBound <= count
        else { throw HostMCPGatewayError.denied }
        guard data.count - boundary.upperBound == count else { return nil }
        let body = Data(data[boundary.upperBound...])
        let request = try ClaudeMCPProtocol.ingress(body, maxBytes: maxBodyBytes)
        let name = request.payload["params"]?["name"]?.string
        guard headers["mcp-method"] == request.method, headers["mcp-name"] == name else {
            throw HostMCPGatewayError.denied
        }
        return Self(
            body: body, selectors: .init(version: ClaudeMCPProtocol.version, method: request.method, name: name),
            headerBytes: boundary.upperBound, request: request)
    }
}

enum ClaudeMCPProtocol {
    static let version = "2026-07-28"
    static let adapter = "claude-code-2.1.309-local-repository-v1"
    static let server = "mini-sandbox-local-repository/1"
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaClient = "io.modelcontextprotocol/clientInfo"
    static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let metaServer = "io.modelcontextprotocol/serverInfo"
    static let serverInfo: ModelJSON = .object([
        "name": .string("mini-sandbox-local-repository"), "version": .string("1"),
    ])

    static func validID(_ value: ModelJSON?) -> Bool {
        if case .integer = value { return true }
        guard let text = value?.string else { return false }
        return !text.isEmpty && text.utf8.count <= 128
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func ingress(_ data: Data, maxBytes: Int) throws -> MCPResolved {
        let value = try ModelJSON.parse(data, maxBytes: maxBytes)
        guard let fields = value.object, Set(fields.keys) == ["jsonrpc", "id", "method", "params"],
            value["jsonrpc"] == .string("2.0"), validID(value["id"]),
            let method = value["method"]?.string, let params = value["params"]?.object,
            let meta = params["_meta"]?.object,
            Set(meta.keys).isSubset(of: [
                metaVersion, metaClient, metaCapabilities, "progressToken", "claudecode/toolUseId",
            ]),
            meta[metaVersion] == .string(version),
            let info = meta[metaClient]?.object,
            Set(info.keys) == ["name", "title", "version", "description", "websiteUrl"],
            info["name"] == .string("claude-code"), info["version"] == .string("2.1.309"),
            info["title"] == .string("Claude Code"),
            info["description"] == .string("Anthropic's agentic coding tool"),
            info["websiteUrl"] == .string("https://claude.com/claude-code"),
            meta[metaCapabilities]
                == .object([
                    "roots": .object(["listChanged": .bool(true)]),
                    "elicitation": .object(["form": .object([:]), "url": .object([:])]),
                ]),
            meta["progressToken"] == nil || validID(meta["progressToken"])
        else { throw HostMCPGatewayError.denied }
        if let correlation = meta["claudecode/toolUseId"] {
            guard method == "tools/call", let text = correlation.string, !text.isEmpty, text.utf8.count <= 128,
                text.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                })
            else { throw HostMCPGatewayError.denied }
        }
        switch method {
        case "server/discover", "tools/list":
            guard Set(params.keys) == ["_meta"] else { throw HostMCPGatewayError.denied }
            return MCPResolved(payload: value, method: method, resource: "control", operation: method)
        case "tools/call":
            guard Set(params.keys) == ["_meta", "name", "arguments"] else { throw HostMCPGatewayError.denied }
            var tool = params
            tool.removeValue(forKey: "_meta")
            let resolved = try MCPRepositoryAdapter.resolve(tool)
            return MCPResolved(payload: value, method: method, resource: resolved.0, operation: resolved.1)
        default: throw HostMCPGatewayError.denied
        }
    }
    static func response(_ data: Data, request: ModelJSON) throws -> (
        wire: ModelJSON, result: ModelJSON?, isError: Bool
    ) {
        let value = try ModelJSON.parse(data)
        guard let object = value.object, value["jsonrpc"] == .string("2.0"), value["id"] == request["id"] else {
            throw HostMCPGatewayError.invalidResponse
        }
        if Set(object.keys) == ["jsonrpc", "id", "error"] {
            guard let error = value["error"]?.object, Set(error.keys) == ["code", "message"],
                case .integer = error["code"], let message = error["message"]?.string,
                !message.isEmpty, message.utf8.count <= 1024
            else { throw HostMCPGatewayError.invalidResponse }
            return (value, nil, true)
        }
        guard Set(object.keys) == ["jsonrpc", "id", "result"], let result = value["result"],
            result.object != nil, result["resultType"] == .string("complete")
        else { throw HostMCPGatewayError.invalidResponse }
        if let meta = result["_meta"] {
            guard meta == .object([metaServer: serverInfo]) else { throw HostMCPGatewayError.invalidResponse }
        }
        return (value, result, result["isError"] == .bool(true))
    }
    static func discovery(_ result: ModelJSON) throws {
        guard let fields = result.object,
            Set(fields.keys).isSubset(of: ["resultType", "supportedVersions", "capabilities", "_meta"]),
            result["supportedVersions"] == .array([.string(version)]),
            result["capabilities"] == .object(["tools": .object([:])])
        else { throw HostMCPGatewayError.invalidResponse }
    }
    static func schema(write: Bool) -> ModelJSON {
        var properties: [String: ModelJSON] = [
            "repo": .object(["type": .string("string"), "enum": .array([.string("A"), .string("B")])])
        ]
        if write { properties["content"] = .object(["type": .string("string"), "maxLength": .integer(16_384)]) }
        return .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array((write ? ["repo", "content"] : ["repo"]).map(ModelJSON.string)),
            "additionalProperties": .bool(false),
        ])
    }
    static func catalog(_ result: ModelJSON) throws -> (MCPDiscoveryState, String) {
        guard let fields = result.object, Set(fields.keys).isSubset(of: ["resultType", "tools", "_meta"]),
            let tools = result["tools"]?.array, tools.count <= 2
        else { throw HostMCPGatewayError.invalidResponse }
        var names = Set<String>()
        for tool in tools {
            guard let item = tool.object, Set(item.keys) == ["name", "description", "inputSchema", "annotations"],
                let name = tool["name"]?.string, ["repo_read", "repo_write"].contains(name),
                names.insert(name).inserted,
                let description = tool["description"]?.string, description.utf8.count <= 1024,
                tool["inputSchema"] == schema(write: name == "repo_write"),
                tool["annotations"] == .object(["readOnlyHint": .bool(true)])
            else { throw HostMCPGatewayError.invalidResponse }
        }
        guard tools.isEmpty || names == ["repo_read", "repo_write"] else { throw HostMCPGatewayError.invalidResponse }
        return (
            tools.isEmpty ? .knownEmpty : .knownReady,
            MCPProtocol.digest(
                try MCPProtocol.canonical(ModelJSON.array(tools.sorted { $0["name"]!.string! < $1["name"]!.string! })))
        )
    }
    static func toolText(_ result: ModelJSON) throws -> String {
        guard let fields = result.object, Set(fields.keys).isSubset(of: ["resultType", "content", "isError", "_meta"]),
            result["isError"] == nil || result["isError"] == .bool(true) || result["isError"] == .bool(false)
        else { throw HostMCPGatewayError.invalidResponse }
        var legacy = fields
        legacy.removeValue(forKey: "resultType")
        legacy.removeValue(forKey: "_meta")
        legacy.removeValue(forKey: "isError")
        return try MCPProtocol.toolText(.object(legacy))
    }
}
