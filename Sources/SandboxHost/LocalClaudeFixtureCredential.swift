#if SANDBOX_TEST_FIXTURES
    import Foundation

    /// Intentionally public test material, never a Keychain or environment lookup.
    /// This type and its only connection constructor do not exist in normal builds.
    struct LocalClaudeFixtureCredential: ModelCredentialProvider {
        func credential(for model: FixedModel) throws -> String {
            "mini-sandbox-local-fixture-canary-86db9bd39f874753"
        }
    }
#endif
