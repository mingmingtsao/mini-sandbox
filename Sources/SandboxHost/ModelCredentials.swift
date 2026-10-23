import Foundation
import Security
import LocalAuthentication

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
    package let content: String

    private enum CodingKeys: String, CodingKey { case role, content }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(role: values.decode(FixedMessageRole.self, forKey: .role), content: values.decode(String.self, forKey: .content))
    }

    package init(role: FixedMessageRole, content: String) throws {
        guard !content.isEmpty, content.utf8.count <= FixedModelRequest.maxMessageBytes,
              !content.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            throw ModelTransportError.invalidRequest("message")
        }
        self.role = role
        self.content = content
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

    private enum CodingKeys: String, CodingKey { case model, `protocol`, messages, maxOutputTokens }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(model: values.decode(FixedModel.self, forKey: .model), protocol: values.decode(FixedProtocol.self, forKey: .protocol), messages: values.decode([FixedMessage].self, forKey: .messages), maxOutputTokens: values.decode(Int.self, forKey: .maxOutputTokens))
    }

    package init(model: FixedModel, protocol: FixedProtocol, messages: [FixedMessage], maxOutputTokens: Int) throws {
        guard !messages.isEmpty, messages.count <= Self.maxMessages,
              (1...Self.maxOutputTokens).contains(maxOutputTokens) else {
            throw ModelTransportError.invalidRequest("request")
        }
        self.model = model
        self.`protocol` = `protocol`
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
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
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw CredentialProviderError.missing }
        guard status == errSecSuccess else { throw CredentialProviderError.storageUnavailable(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty,
              value.utf8.count <= 16 * 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CredentialProviderError.unavailable
        }
        return value
    }

    package func setCredential(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16 * 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CredentialProviderError.invalid
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: interactionContext(),
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
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
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialProviderError.storageUnavailable(status)
        }
    }
}
