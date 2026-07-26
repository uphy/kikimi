import Foundation
import Testing

@testable import Kikimi

/// Layer 1 (unit) coverage for `CredentialStoring` (`docs/design/26-settings-ui.md` §2/§6). Only
/// `InMemoryCredentialStore` is exercised here -- `KeychainCredentialStore` touches the real
/// Keychain, so it is a separate, CI-skippable integration concern per §6's own note.
@Suite("CredentialStore")
struct CredentialStoreTests {
    @Test("read returns nil for an account that was never written")
    func readReturnsNilForUnknownAccount() {
        let store = InMemoryCredentialStore()
        #expect(store.read(account: "does.not.exist") == nil)
    }

    @Test("write then read round-trips the value for the same account")
    func writeThenReadRoundTrips() throws {
        let store = InMemoryCredentialStore()
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "sk-test")
    }

    @Test("write overwrites a previously-written value for the same account")
    func writeOverwritesExistingValue() throws {
        let store = InMemoryCredentialStore()
        try store.write("first", account: CredentialAccount.openAIAPIKey)
        try store.write("second", account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "second")
    }

    @Test("write accepts an empty string, distinct from having no stored value at all")
    func writeAcceptsEmptyString() throws {
        let store = InMemoryCredentialStore()
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)
        try store.write("", account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "")
    }

    @Test("delete removes a previously-written value")
    func deleteRemovesValue() throws {
        let store = InMemoryCredentialStore()
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)
        try store.delete(account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == nil)
    }

    @Test("delete on an account that was never written is a no-op, not an error")
    func deleteOnUnknownAccountIsNoOp() throws {
        let store = InMemoryCredentialStore()
        try store.delete(account: "does.not.exist")
        #expect(store.read(account: "does.not.exist") == nil)
    }

    @Test("accounts are independent: writing one account does not affect another")
    func accountsAreIndependent() throws {
        let store = InMemoryCredentialStore()
        try store.write("openai-key", account: CredentialAccount.openAIAPIKey)
        try store.write("other-value", account: "some.other.account")
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "openai-key")
        #expect(store.read(account: "some.other.account") == "other-value")
    }
}
