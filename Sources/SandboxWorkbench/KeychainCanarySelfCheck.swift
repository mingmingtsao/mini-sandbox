import Foundation
import SandboxHost

/// Opt-in fixture only. No credential input, default item, environment fallback,
/// or secret output. The packaged command creates its own random namespace.
package enum KeychainCanarySelfCheck {
    package struct Report: Codable, Sendable {
        package var verdict = "BLOCKED"
        package var packagedIdentity = false
        package var offMainThread = false
        package var added = false
        package var read = false
        package var updated = false
        package var deleted = false
        package var cleanup = false
        package var osStatus: Int32?
    }
    package static func runPackaged() -> Report {
        let identity = Bundle.main.bundleIdentifier == "dev.mini-sandbox.app" && Bundle.main.bundleURL.pathExtension == "app"
        let provider = KeychainModelCredentialProvider(service: "dev.mini-sandbox.canary." + UUID().uuidString,
            account: "owned-fixture-" + UUID().uuidString)
        return exercise(store: KeychainFixedModelStore(provider: provider), packagedIdentity: identity)
    }
    /// Injection exists for offline runner checks, not a general credential CLI.
    package static func exercise(store: any FixedModelCredentialStore, packagedIdentity: Bool) -> Report {
        var result = Report()
        result.packagedIdentity = packagedIdentity
        result.offMainThread = !Thread.isMainThread
        guard packagedIdentity else { return result }
        var owned = false
        do {
            // Never alter a pre-existing item, even in the random namespace.
            guard try !store.check() else { return result }
            owned = true
            let first = "synthetic-canary-" + UUID().uuidString
            let second = "synthetic-canary-" + UUID().uuidString
            try store.save(first)
            result.added = true
            result.read = try store.credential(for: .deepSeekFlash) == first
            try store.save(second)
            result.updated = try store.credential(for: .deepSeekFlash) == second
            try store.delete()
            result.deleted = try !store.check()
            result.verdict = result.read && result.updated && result.deleted ? "PASS" : "FAIL"
        } catch CredentialProviderError.storageUnavailable(let status) {
            result.osStatus = status
            result.verdict = "BLOCKED"
        } catch { result.verdict = "FAIL" }
        if owned {
            do { try store.delete(); result.cleanup = try !store.check() }
            catch CredentialProviderError.storageUnavailable(let status) { result.osStatus = status; result.verdict = "BLOCKED" }
            catch { result.verdict = "FAIL" }
        }
        if result.verdict == "PASS" && !result.cleanup { result.verdict = "FAIL" }
        return result
    }
}
