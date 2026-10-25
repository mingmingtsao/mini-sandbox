import Foundation

/// The protocol tuple emitted by the pinned Claude Code 2.1.309 business profile.
/// Closed values prevent a guest from choosing another route or activating an
/// unimplemented beta. The complete tuple is included in the approved envelope.
package struct ClaudeRequestSelectors: Codable, Equatable, Sendable {
    package let method: String
    package let path: String
    package let query: String
    package let version: String
    package let beta: String
    package static let pinned = Self(method: "POST", path: "/v1/messages", query: "beta=true",
        version: "2023-06-01",
        beta: "claude-code-20250219,interleaved-thinking-2025-05-14,effort-2025-11-24")
    private init(method: String, path: String, query: String, version: String, beta: String) {
        self.method = method; self.path = path; self.query = query
        self.version = version; self.beta = beta
    }
    package func validate() throws {
        guard self == Self.pinned else { throw BusinessHTTPIngress.Failure.unsupportedProtocol }
    }
}
