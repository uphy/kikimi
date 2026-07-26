import Foundation
import Testing

@testable import Kikimi

// MARK: - Test doubles

/// Stand-in for `SecureEnclaveCipher` that keeps the context binding (so tests can prove a
/// ciphertext written for one account cannot be opened as another) without touching the real Secure
/// Enclave, which is unavailable in CI and would persist hardware-backed state
/// (`docs/design/35-secure-enclave-credentials.md` §5).
private struct FakeCipher: CredentialCipher {
    struct ContextMismatch: Error {}

    func seal(_ plaintext: Data, context: String) throws -> Data {
        Data("\(context)|".utf8) + plaintext
    }

    func open(_ ciphertext: Data, context: String) throws -> Data {
        let prefix = Data("\(context)|".utf8)
        guard ciphertext.starts(with: prefix) else {
            throw ContextMismatch()
        }
        return ciphertext.dropFirst(prefix.count)
    }
}

/// Fails every `seal`, standing in for a Secure Enclave that refuses to produce a key.
private struct FailingCipher: CredentialCipher {
    struct SealFailed: Error {}

    func seal(_ plaintext: Data, context: String) throws -> Data { throw SealFailed() }
    func open(_ ciphertext: Data, context: String) throws -> Data { ciphertext }
}

/// Records whether the legacy Keychain item was actually deleted after a migration.
private final class SpyLegacyStore: CredentialStoring, @unchecked Sendable {
    private let inner: InMemoryCredentialStore
    private(set) var readCount = 0

    init(seeded: [String: String] = [:]) {
        inner = InMemoryCredentialStore(seeded: seeded)
    }

    func read(account: String) -> String? {
        readCount += 1
        return inner.read(account: account)
    }

    func write(_ value: String, account: String) throws { try inner.write(value, account: account) }
    func delete(account: String) throws { try inner.delete(account: account) }
}

// MARK: - Tests

/// Layer 1 coverage for `EncryptedFileCredentialStore` and `CredentialFileLayout`
/// (`docs/design/35-secure-enclave-credentials.md` §5). The cipher is faked, so no Secure Enclave
/// key is ever created and no real Keychain item is ever read.
@Suite("EncryptedFileCredentialStore")
struct EncryptedFileCredentialStoreTests {
    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeStore(
        directory: URL,
        cipher: CredentialCipher = FakeCipher(),
        legacyStore: CredentialStoring? = nil
    ) -> EncryptedFileCredentialStore {
        EncryptedFileCredentialStore(cipher: cipher, directory: directory, legacyStore: legacyStore)
    }

    // MARK: Basic store semantics

    @Test("read returns nil for an account that was never written")
    func readReturnsNilForUnknownAccount() {
        let store = makeStore(directory: makeTemporaryDirectory())
        #expect(store.read(account: "does.not.exist") == nil)
    }

    @Test("write then read round-trips the value through the cipher")
    func writeThenReadRoundTrips() throws {
        let store = makeStore(directory: makeTemporaryDirectory())
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "sk-test")
    }

    @Test("write overwrites a previously-written value for the same account")
    func writeOverwritesExistingValue() throws {
        let store = makeStore(directory: makeTemporaryDirectory())
        try store.write("first", account: CredentialAccount.openAIAPIKey)
        try store.write("second", account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "second")
    }

    @Test("write accepts an empty string, distinct from having no stored value at all")
    func writeAcceptsEmptyString() throws {
        let store = makeStore(directory: makeTemporaryDirectory())
        try store.write("", account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "")
    }

    @Test("delete removes a previously-written value")
    func deleteRemovesValue() throws {
        let store = makeStore(directory: makeTemporaryDirectory())
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)
        try store.delete(account: CredentialAccount.openAIAPIKey)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == nil)
    }

    @Test("delete on an account that was never written is a no-op, not an error")
    func deleteOnUnknownAccountIsNoOp() throws {
        let store = makeStore(directory: makeTemporaryDirectory())
        try store.delete(account: "does.not.exist")
        #expect(store.read(account: "does.not.exist") == nil)
    }

    @Test("accounts are independent: writing one account does not affect another")
    func accountsAreIndependent() throws {
        let store = makeStore(directory: makeTemporaryDirectory())
        try store.write("openai-key", account: CredentialAccount.openAIAPIKey)
        try store.write("other-value", account: "some.other.account")
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "openai-key")
        #expect(store.read(account: "some.other.account") == "other-value")
    }

    // MARK: On-disk layout (design §3.2)

    @Test("write creates a 0600 ciphertext file inside a 0700 directory")
    func writeAppliesRestrictivePermissions() throws {
        let directory = makeTemporaryDirectory()
        let store = makeStore(directory: directory)
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)

        let fileURL = directory.appendingPathComponent(
            CredentialFileLayout.fileName(forAccount: CredentialAccount.openAIAPIKey)
        )
        let filePermissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(filePermissions?.int16Value == 0o600)
        #expect(directoryPermissions?.int16Value == 0o700)
    }

    @Test("fileName sanitizes path separators so an account can never escape the directory")
    func fileNameSanitizesPathSeparators() {
        #expect(CredentialFileLayout.fileName(forAccount: "llm.openai.api_key") == "llm.openai.api_key.enc")
        #expect(CredentialFileLayout.fileName(forAccount: "../../etc/passwd") == ".._.._etc_passwd.enc")
        #expect(CredentialFileLayout.fileName(forAccount: "a/b") == "a_b.enc")
    }

    // MARK: Decryption failures degrade to "unset" (design §3.3)

    @Test("a ciphertext that fails to decrypt reads as nil rather than throwing")
    func undecryptableCiphertextReadsAsNil() throws {
        let directory = makeTemporaryDirectory()
        let store = makeStore(directory: directory)
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)

        let fileURL = directory.appendingPathComponent(
            CredentialFileLayout.fileName(forAccount: CredentialAccount.openAIAPIKey)
        )
        try Data("corrupted".utf8).write(to: fileURL)

        #expect(store.read(account: CredentialAccount.openAIAPIKey) == nil)
    }

    @Test("a ciphertext sealed for one account does not open as another")
    func ciphertextIsBoundToItsAccount() throws {
        let directory = makeTemporaryDirectory()
        let store = makeStore(directory: directory)
        try store.write("sk-test", account: CredentialAccount.openAIAPIKey)

        // Move the ciphertext into the other account's file. The context binding must reject it.
        let source = directory.appendingPathComponent(
            CredentialFileLayout.fileName(forAccount: CredentialAccount.openAIAPIKey)
        )
        let destination = directory.appendingPathComponent(CredentialFileLayout.fileName(forAccount: "other.account"))
        try FileManager.default.moveItem(at: source, to: destination)

        #expect(store.read(account: "other.account") == nil)
    }

    // MARK: Keychain migration (design §3.4)

    @Test("read migrates a value out of the legacy store and deletes the legacy item")
    func readMigratesFromLegacyStore() throws {
        let legacy = SpyLegacyStore(seeded: [CredentialAccount.openAIAPIKey: "sk-legacy"])
        let store = makeStore(directory: makeTemporaryDirectory(), legacyStore: legacy)

        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "sk-legacy")
        #expect(legacy.read(account: CredentialAccount.openAIAPIKey) == nil)
    }

    @Test("after migrating once, subsequent reads never touch the legacy store again")
    func migrationHappensOnlyOnce() throws {
        let legacy = SpyLegacyStore(seeded: [CredentialAccount.openAIAPIKey: "sk-legacy"])
        let store = makeStore(directory: makeTemporaryDirectory(), legacyStore: legacy)

        _ = store.read(account: CredentialAccount.openAIAPIKey)
        let readsAfterMigration = legacy.readCount
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "sk-legacy")
        #expect(legacy.readCount == readsAfterMigration)
    }

    @Test("a value already present locally wins over the legacy store, which is never consulted")
    func localValueShortCircuitsMigration() throws {
        let legacy = SpyLegacyStore(seeded: [CredentialAccount.openAIAPIKey: "sk-legacy"])
        let store = makeStore(directory: makeTemporaryDirectory(), legacyStore: legacy)
        try store.write("sk-local", account: CredentialAccount.openAIAPIKey)

        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "sk-local")
        #expect(legacy.readCount == 0)
    }

    @Test("an empty legacy store migrates nothing and reads as nil")
    func emptyLegacyStoreMigratesNothing() {
        let legacy = SpyLegacyStore()
        let store = makeStore(directory: makeTemporaryDirectory(), legacyStore: legacy)
        #expect(store.read(account: CredentialAccount.openAIAPIKey) == nil)
    }

    /// If the local write fails the legacy item must survive, so the next `read` retries the
    /// migration instead of losing the credential (design §3.4).
    @Test("a failed migration returns the legacy value and leaves the legacy item in place")
    func failedMigrationPreservesLegacyValue() throws {
        let legacy = SpyLegacyStore(seeded: [CredentialAccount.openAIAPIKey: "sk-legacy"])
        let store = makeStore(directory: makeTemporaryDirectory(), cipher: FailingCipher(), legacyStore: legacy)

        #expect(store.read(account: CredentialAccount.openAIAPIKey) == "sk-legacy")
        #expect(legacy.read(account: CredentialAccount.openAIAPIKey) == "sk-legacy")
    }
}
