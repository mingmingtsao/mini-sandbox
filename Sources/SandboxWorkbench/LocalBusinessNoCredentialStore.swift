#if SANDBOX_TEST_FIXTURES
    import SandboxHost

    /// The fixture composition never constructs a Keychain store. Its transport's
    /// public canary comes only from HostModelConnection.localClaudeFixture.
    struct LocalBusinessNoCredentialStore: FixedModelCredentialStore {
        func credential(for model: FixedModel) throws -> String { throw CredentialProviderError.unavailable }
        func save(_ value: String) throws { throw CredentialProviderError.unavailable }
        func delete() throws { throw CredentialProviderError.unavailable }
        func check() throws -> Bool { throw CredentialProviderError.unavailable }
    }
#endif
