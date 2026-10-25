import Foundation
import LocalAuthentication
import Security

package enum FixedModel: String, Codable, Sendable {
    case deepSeekFlash = "deepseek-flash"
}

package enum FixedProtocol: String, Codable, Sendable {
    case openAI
    case anthropic
}

package enum FixedMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

package struct FixedMessage: Codable, Equatable, Sendable {
    package let role: FixedMessageRole
    package let blocks: [ModelBlock]
    package let isLegacyText: Bool
    package var content: String { blocks.map(\.text).joined() }
    private enum CodingKeys: String, CodingKey { case role, content }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let role = try values.decode(FixedMessageRole.self, forKey: .role)
        if let text = try? values.decode(String.self, forKey: .content) {
            try self.init(role: role, content: text)
        } else {
            try self.init(role: role, blocks: values.decode([ModelBlock].self, forKey: .content))
        }
    }
    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if isLegacyText { try c.encode(content, forKey: .content) } else { try c.encode(blocks, forKey: .content) }
    }
    package init(role: FixedMessageRole, content: String) throws {
        guard !content.isEmpty, content.utf8.count <= FixedModelRequest.maxMessageBytes,
            !content.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
            })
        else {
            throw ModelTransportError.invalidRequest("message")
        }
        self.role = role
        blocks = [.text(content)]
        isLegacyText = true
    }
    package init(role: FixedMessageRole, blocks: [ModelBlock]) throws {
        guard !blocks.isEmpty, blocks.count <= 128 else { throw ModelTransportError.invalidRequest("blocks") }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            _ = try ModelJSON.parse(encoder.encode(blocks))
            for block in blocks {
                _ = try ModelBlock(wire: block.wire)
                switch block {
                case .toolUse:
                    guard role == .assistant else { throw ModelTransportError.invalidRequest("tool use role") }
                case .toolResult:
                    guard role == .user else { throw ModelTransportError.invalidRequest("tool result role") }
                case .text: break
                }
            }
        } catch { throw ModelTransportError.invalidRequest("blocks") }
        self.role = role
        self.blocks = blocks
        isLegacyText = false
    }
}

package struct FixedModelRequest: Codable, Equatable, Sendable {
    package static let maxMessageBytes = 64 * 1024
    package static let maxMessages = 128
    package static let maxOutputTokens = 8_192
    package let model: FixedModel
    package let `protocol`: FixedProtocol
    package let messages: [FixedMessage]
    package let maxOutputTokens: Int
    package let tools: [ModelToolDefinition]
    package let toolChoice: ModelToolChoice?
    private enum CodingKeys: String, CodingKey {
        case model, `protocol`, messages, maxOutputTokens, tools
        case toolChoice = "tool_choice"
    }
    /// Raw ingress must use this entry point, not bare JSONDecoder, to reject
    /// duplicate keys, unsupported numbers and pathological nesting first.
    package static func decodeValidated(_ bytes: Data) throws -> FixedModelRequest {
        let root = try ModelJSON.parse(bytes)
        func keys(_ value: ModelJSON, _ allowed: Set<String>) throws {
            guard let object = value.object, Set(object.keys).isSubset(of: allowed) else {
                throw ModelTransportError.invalidRequest("unsupported fields")
            }
        }
        try keys(root, ["model", "protocol", "messages", "maxOutputTokens", "tools", "tool_choice"])
        for message in root["messages"]?.array ?? [] { try keys(message, ["role", "content"]) }
        for tool in root["tools"]?.array ?? [] { try keys(tool, ["name", "description", "input_schema"]) }
        if let choice = root["tool_choice"], choice != .null {
            try keys(choice, ["type", "name", "disable_parallel_tool_use"])
        }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            model: values.decode(FixedModel.self, forKey: .model),
            protocol: values.decode(FixedProtocol.self, forKey: .protocol),
            messages: values.decode([FixedMessage].self, forKey: .messages),
            maxOutputTokens: values.decode(Int.self, forKey: .maxOutputTokens),
            tools: values.decodeIfPresent([ModelToolDefinition].self, forKey: .tools) ?? [],
            toolChoice: values.decodeIfPresent(ModelToolChoice.self, forKey: .toolChoice))
    }
    package init(
        model: FixedModel, protocol: FixedProtocol, messages: [FixedMessage], maxOutputTokens: Int,
        tools: [ModelToolDefinition] = [], toolChoice: ModelToolChoice? = nil
    ) throws {
        guard !messages.isEmpty, messages.count <= Self.maxMessages,
            (1...Self.maxOutputTokens).contains(maxOutputTokens)
        else { throw ModelTransportError.invalidRequest("request") }
        try ModelConversationValidation.validate(
            messages: messages, tools: tools, choice: toolChoice, protocol: `protocol`)
        self.model = model
        self.`protocol` = `protocol`
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.tools = tools
        self.toolChoice = toolChoice
    }
}

package protocol ModelCredentialProvider: Sendable {
    func credential(for model: FixedModel) throws -> String
}

package enum CredentialProviderError: Error, Equatable, Sendable, CustomStringConvertible {
    case missing
    case invalid
    case unavailable
    case storageUnavailable(Int32)

    package var description: String {
        switch self {
        case .missing: return "credential missing"
        case .invalid: return "credential invalid"
        case .unavailable: return "credential unavailable"
        case .storageUnavailable(let status): return "credential storage unavailable (\(status))"
        }
    }
}

package final class KeychainModelCredentialProvider: ModelCredentialProvider, @unchecked Sendable {
    private let service: String
    private let account: String

    package init(service: String = "dev.mini-sandbox.model", account: String = "deepseek") {
        self.service = service
        self.account = account
    }

    private func interactionContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    package func credential(for model: FixedModel) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: interactionContext(),
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw CredentialProviderError.missing }
        guard status == errSecSuccess else { throw CredentialProviderError.storageUnavailable(status) }
        guard let data = result as? Data,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty,
            value.utf8.count <= 16 * 1024,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw CredentialProviderError.unavailable
        }
        return value
    }

    package func setCredential(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16 * 1024,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw CredentialProviderError.invalid
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: interactionContext(),
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw CredentialProviderError.storageUnavailable(addStatus)
        }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else { throw CredentialProviderError.storageUnavailable(updateStatus) }
        }
    }

    package func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: interactionContext(),
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialProviderError.storageUnavailable(status)
        }
    }
}
