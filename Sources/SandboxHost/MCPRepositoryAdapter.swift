import Foundation

/// Trusted mappings, never inferred from readOnlyHint or server descriptions.
enum MCPRepositoryAdapter {
    static func resolve(_ params: [String: ModelJSON]) throws -> (String, String) {
        guard Set(params.keys) == ["name", "arguments"], let name = params["name"]?.string,
            let args = params["arguments"]?.object, let repo = args["repo"]?.string,
            ["A", "B"].contains(repo)
        else { throw HostMCPGatewayError.denied }
        switch name {
        case "repo_read":
            guard Set(args.keys) == ["repo"] else { throw HostMCPGatewayError.denied }
            return (repo, "read")
        case "repo_write":
            guard Set(args.keys) == ["repo", "content"], let content = args["content"]?.string,
                content.utf8.count <= 16384
            else { throw HostMCPGatewayError.denied }
            return (repo, "write")
        default: throw HostMCPGatewayError.denied
        }
    }
}
