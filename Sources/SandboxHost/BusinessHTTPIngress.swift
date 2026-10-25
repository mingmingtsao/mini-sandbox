import Foundation

/// One bounded HTTP/1.1 exchange received from the installed VM's model socket.
/// This parser supplies no identity, route, credential or authorization. The VM
/// owner and gateway derive those independently from the installed host run.
package struct BusinessHTTPIngress: Sendable {
    package enum Failure: Error, Equatable, Sendable {
        case invalidHTTP, headerLimit, bodyLimit, unsupportedProtocol, invalidBody
    }
    package static let maxHeaderBytes = 16_384
    package static let maxBodyBytes = 65_536
    package static let maxWireBytes = maxHeaderBytes + maxBodyBytes
    package static let localPlaceholder = "mini-sandbox-local-only"
    private static let consumedHeaders: Set<String> = [
        "host", "authorization", "content-type", "content-length", "connection", "accept", "accept-encoding",
        "user-agent", "anthropic-version", "anthropic-beta", "anthropic-dangerous-direct-browser-access", "x-app", "x-stainless-lang",
        "x-stainless-package-version", "x-stainless-os", "x-stainless-arch", "x-stainless-runtime",
        "x-stainless-runtime-version", "x-stainless-retry-count", "x-stainless-timeout", "x-stainless-helper-method",
        "x-claude-code-session-id", "x-claude-code-agent-id", "x-claude-code-parent-agent-id"
    ]

    package let body: Data
    package let target: String
    package let version: String
    package let beta: String?
    package let directBrowserAccess: String?
    package let headerBytes: Int
    package var wireBytes: Int { headerBytes + body.count }

    /// Incremental admission returns nil only for a valid but incomplete prefix.
    /// A complete request cannot carry a pipeline, upgrade or ambiguous framing.
    package static func parse(_ data: Data) throws -> Self? {
        guard data.count <= maxWireBytes else { throw Failure.bodyLimit }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count < maxHeaderBytes else { throw Failure.headerLimit }
            return nil
        }
        guard boundary.upperBound <= maxHeaderBytes else { throw Failure.headerLimit }
        guard let text = String(data: data[..<boundary.lowerBound], encoding: .ascii) else { throw Failure.invalidHTTP }
        let lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty, lines.count <= 65 else { throw Failure.headerLimit }
        let request = lines[0].components(separatedBy: " ")
        guard request.count == 3, request[0] == "POST", request[2] == "HTTP/1.1",
              ["/v1/messages", "/v1/messages?beta=true"].contains(request[1]) else { throw Failure.unsupportedProtocol }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.invalidHTTP }
            let keyBytes = line[..<colon].utf8
            guard !keyBytes.isEmpty, keyBytes.allSatisfy(headerToken) else { throw Failure.invalidHTTP }
            let key = String(line[..<colon]).lowercased()
            guard consumedHeaders.contains(key) else { throw Failure.unsupportedProtocol }
            let raw = line[line.index(after: colon)...]
            guard headers[key] == nil, raw.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { throw Failure.invalidHTTP }
            headers[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        guard ["transfer-encoding", "content-encoding", "expect", "upgrade", "proxy-authorization", "x-api-key"].allSatisfy({ headers[$0] == nil }),
              headers["host"] == "127.0.0.1:4061",
              headers["authorization"] == "Bearer " + localPlaceholder,
              ["application/json", "application/json; charset=utf-8"].contains(headers["content-type"] ?? ""),
              headers["accept"] == nil || ["application/json", "text/event-stream", "*/*"].contains(headers["accept"]!),
              headers["connection"] == nil || ["close", "keep-alive"].contains(headers["connection"]!.lowercased()),
              let rawLength = headers["content-length"], !rawLength.isEmpty,
              rawLength.count <= 5, rawLength.first != "0", rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength), length > 0 else { throw Failure.invalidHTTP }
        guard length <= maxBodyBytes else { throw Failure.bodyLimit }
        let count = data.count - boundary.upperBound
        guard count <= length else { throw Failure.invalidHTTP }
        guard count == length else { return nil }
        let version = headers["anthropic-version"] ?? ""
        guard version == "2023-06-01" else { throw Failure.unsupportedProtocol }
        let beta = headers["anthropic-beta"]
        if let beta {
            guard !beta.isEmpty, beta.utf8.count <= 512,
                  beta.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 44 }) else {
                throw Failure.unsupportedProtocol
            }
        }
        return Self(body: Data(data[boundary.upperBound...]), target: request[1], version: version,
                    beta: beta, directBrowserAccess: headers["anthropic-dangerous-direct-browser-access"], headerBytes: boundary.upperBound)
    }

    /// Current native provider contract. Unsupported query/beta selectors are
    /// never silently discarded. No raw header is forwarded to the provider.
    package func nativeRequest() throws -> AnthropicNativeRequest {
        guard target == "/v1/messages", beta == nil, directBrowserAccess == nil else { throw Failure.unsupportedProtocol }
        do {
            let root = try ModelJSON.parse(body)
            guard case .bool(let streaming) = root["stream"] else { throw Failure.invalidBody }
            return try AnthropicNativeRequest.decodeValidated(body, streaming: streaming)
        } catch { throw Failure.invalidBody }
    }

    package var claudeSelectors: ClaudeRequestSelectors {
        get throws {
            let expected = ClaudeRequestSelectors.pinned
            guard target == expected.path + "?" + expected.query,
                  version == expected.version, beta == expected.beta,
                  directBrowserAccess == expected.directBrowserAccess else { throw Failure.unsupportedProtocol }
            return expected
        }
    }
    package func claudeRequest() throws -> AnthropicNativeRequest {
        let selectors = try claudeSelectors
        do {
            let root = try ModelJSON.parse(body)
            guard case .bool(let streaming) = root["stream"] else { throw Failure.invalidBody }
            return try AnthropicNativeRequest.decodeClaude(body, streaming: streaming, selectors: selectors)
        } catch { throw Failure.invalidBody }
    }

    private static func headerToken(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
        Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
    }
}
