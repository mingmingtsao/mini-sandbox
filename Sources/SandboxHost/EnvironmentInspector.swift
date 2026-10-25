import Foundation
import LocalAuthentication
import Security
import Virtualization

public struct EnvironmentReport: Codable, Equatable, Sendable {
    public let operatingSystem: String
    public let architecture: String
    public let logicalCPUCount: Int
    public let physicalMemoryBytes: UInt64
    public let availableDiskBytes: UInt64?
    public let virtualizationSupported: Bool
    public let keychainQueryAvailable: Bool
    public let keychainStatus: Int32
    public let checkedAt: Date

    public var foundationReady: Bool {
        architecture == "arm64" && virtualizationSupported && keychainQueryAvailable
    }
}

public enum EnvironmentInspector {
    /// Checks actual host capabilities without creating a VM or reading any credential value.
    public static func inspect() -> EnvironmentReport {
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "unsupported"
        #endif
        // Query only our own namespace, without reading attributes or credential data.
        // A missing item proves the API is reachable, not that storage/refresh has been verified.
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.mini-sandbox.environment-probe",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: false,
            kSecUseAuthenticationContext as String: context,
        ]
        let keychainStatus = SecItemCopyMatching(query as CFDictionary, nil)
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let available = (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value
        return EnvironmentReport(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableDiskBytes: available,
            virtualizationSupported: VZVirtualMachine.isSupported,
            keychainQueryAvailable: keychainStatus == errSecSuccess || keychainStatus == errSecItemNotFound,
            keychainStatus: keychainStatus,
            checkedAt: Date())
    }
}
