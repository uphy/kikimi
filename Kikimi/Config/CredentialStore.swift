import CryptoKit
import Foundation
import os
import Security

// MARK: - CredentialStoring

/// Abstraction over a single-value secure credential store, keyed by an opaque account string.
/// Exists so `AppConfig`/UI code never touches the storage backend directly and so tests can
/// inject an in-memory fake (mirrors `HTTPTransporting`/`LLMProcessRunner`'s protocol-seam pattern,
/// `docs/design/26-settings-ui.md` §2).
protocol CredentialStoring: Sendable {
    func read(account: String) -> String?
    /// Writes (or overwrites) the value for `account`. Empty string is a valid write (clears the
    /// stored secret while leaving the entry present with an empty value) -- callers that
    /// want to remove the entry entirely use `delete(account:)` instead.
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

// MARK: - CredentialStoreError

enum CredentialStoreError: Error, Equatable {
    case unhandledStatus(OSStatus)
    /// The stored value could not be decoded as UTF-8 text (the backend stores arbitrary `Data`).
    case invalidEncoding
    /// The ciphertext is shorter than the ephemeral public key it must carry, so it cannot have been
    /// produced by `SecureEnclaveCipher.seal`.
    case malformedCiphertext
}

// MARK: - CredentialCipher

/// Authenticated encryption over an opaque context string (the credential's account). Exists so
/// `EncryptedFileCredentialStore`'s file I/O and migration logic can be unit-tested without touching
/// the real Secure Enclave, which is unavailable in CI and would persist hardware-backed state
/// (`docs/design/35-secure-enclave-credentials.md` §3).
protocol CredentialCipher: Sendable {
    func seal(_ plaintext: Data, context: String) throws -> Data
    func open(_ ciphertext: Data, context: String) throws -> Data
}

// MARK: - SecureEnclaveCipher

/// Production `CredentialCipher`: ECIES over a Secure Enclave P-256 key (design §3.1).
///
/// The SE key cannot encrypt directly -- it only does key agreement -- so each `seal` mints an
/// ephemeral software key, agrees with the SE key's public key, derives a symmetric key via HKDF,
/// and seals with ChaChaPoly. The ephemeral public key is prepended to the ciphertext so `open` can
/// re-derive the same symmetric key from the SE private key.
///
/// No `accessControl` is attached to the SE key, so decryption never prompts for Touch ID or a
/// password (design §2). Its `dataRepresentation` is a blob only this Mac's Secure Enclave can
/// rehydrate, which is what makes a stolen ciphertext file useless elsewhere.
final class SecureEnclaveCipher: CredentialCipher, @unchecked Sendable {
    /// Fixed HKDF salt. Domain-separates this app's derived keys from anything else that might agree
    /// with the same SE key in the future.
    private static let hkdfSalt = Data("io.github.uphy.Kikimi.credentials.v1".utf8)
    /// x9.63 uncompressed P-256 public keys are `0x04` + 32-byte X + 32-byte Y.
    private static let ephemeralPublicKeyByteCount = 65

    private let keyURL: URL
    private let lock = NSLock()
    /// Rehydrating the SE key costs a Secure Enclave round-trip, so keep it once loaded. Guarded by
    /// `lock` because `CredentialCipher` is `Sendable` and CryptoKit's SE key type is not.
    private var cachedKey: SecureEnclave.P256.KeyAgreement.PrivateKey?

    init(keyURL: URL) {
        self.keyURL = keyURL
    }

    func seal(_ plaintext: Data, context: String) throws -> Data {
        let key = try loadOrCreateKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let symmetricKey = try Self.deriveSymmetricKey(
            agreeing: ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey), context: context
        )
        let box = try ChaChaPoly.seal(plaintext, using: symmetricKey)
        return ephemeral.publicKey.x963Representation + box.combined
    }

    func open(_ ciphertext: Data, context: String) throws -> Data {
        guard ciphertext.count > Self.ephemeralPublicKeyByteCount else {
            throw CredentialStoreError.malformedCiphertext
        }
        let key = try loadOrCreateKey()
        let split = ciphertext.index(ciphertext.startIndex, offsetBy: Self.ephemeralPublicKeyByteCount)
        let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: ciphertext[..<split]
        )
        let symmetricKey = try Self.deriveSymmetricKey(
            agreeing: key.sharedSecretFromKeyAgreement(with: ephemeralPublicKey), context: context
        )
        let box = try ChaChaPoly.SealedBox(combined: ciphertext[split...])
        return try ChaChaPoly.open(box, using: symmetricKey)
    }

    /// Binding `context` (the account) into `sharedInfo` means a ciphertext moved to another
    /// account's file fails its authentication tag rather than decrypting into the wrong slot.
    private static func deriveSymmetricKey(agreeing secret: SharedSecret, context: String) throws -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: Data(context.utf8),
            outputByteCount: 32
        )
    }

    private func loadOrCreateKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey {
            return cachedKey
        }
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        if let blob = try? Data(contentsOf: keyURL) {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        } else {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            try CredentialFileLayout.writePrivate(key.dataRepresentation, to: keyURL)
        }
        cachedKey = key
        return key
    }
}

// MARK: - CredentialFileLayout

/// Filesystem conventions shared by `SecureEnclaveCipher` (the SE key blob) and
/// `EncryptedFileCredentialStore` (the ciphertexts): 0700 directory, 0600 files (design §3.2).
enum CredentialFileLayout {
    static let defaultDirectory = FileManager.realHomeDirectory
        .appendingPathComponent(".local/state/kikimi/credentials", isDirectory: true)

    static let secureEnclaveKeyFileName = "se-key"

    /// `account` is a config.yaml key path (`llm.openai.api_key`), so it never contains a path
    /// separator -- sanitizing anyway makes directory escape structurally impossible rather than
    /// merely unlikely.
    static func fileName(forAccount account: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = String(account.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return sanitized + ".enc"
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: [.atomic])
        // `.atomic` replaces the file via a rename, so permissions must be applied after the write
        // rather than passed to `createFile` -- the rename would discard them.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - EncryptedFileCredentialStore

/// Production `CredentialStoring`: ciphertexts under `~/.local/state/kikimi/credentials/`, encrypted
/// by a `CredentialCipher` (design §3). Replaces `KeychainCredentialStore`, whose per-item ACL
/// partition list re-prompts on every rebuild of a self-signed binary (design §1).
final class EncryptedFileCredentialStore: CredentialStoring {
    private let cipher: CredentialCipher
    private let directory: URL
    /// Read-only migration source. `nil` once nothing is left to migrate from (and in tests that
    /// don't exercise migration).
    private let legacyStore: CredentialStoring?
    private let logger = Logger(subsystem: "io.github.uphy.Kikimi", category: "CredentialStore")

    init(cipher: CredentialCipher, directory: URL = CredentialFileLayout.defaultDirectory, legacyStore: CredentialStoring? = nil) {
        self.cipher = cipher
        self.directory = directory
        self.legacyStore = legacyStore
    }

    func read(account: String) -> String? {
        if let value = readEncrypted(account: account) {
            return value
        }
        return migrateFromLegacyStore(account: account)
    }

    func write(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }
        let ciphertext = try cipher.seal(data, context: account)
        try CredentialFileLayout.writePrivate(ciphertext, to: url(forAccount: account))
    }

    func delete(account: String) throws {
        let target = url(forAccount: account)
        guard FileManager.default.fileExists(atPath: target.path) else {
            // Deleting an already-absent credential is a no-op success, matching Keychain's
            // `errSecItemNotFound` handling.
            return
        }
        try FileManager.default.removeItem(at: target)
    }

    private func url(forAccount account: String) -> URL {
        directory.appendingPathComponent(CredentialFileLayout.fileName(forAccount: account), isDirectory: false)
    }

    /// A credential is regenerable (the user can paste the API key again), so an undecryptable or
    /// corrupt file degrades to "not set" rather than throwing or discarding the SE key (design §3.3).
    private func readEncrypted(account: String) -> String? {
        guard let ciphertext = try? Data(contentsOf: url(forAccount: account)) else {
            return nil
        }
        do {
            return String(data: try cipher.open(ciphertext, context: account), encoding: .utf8)
        } catch {
            logger.error(
                "Failed to decrypt credential for \(account, privacy: .public); treating it as unset: \(error, privacy: .public)"
            )
            return nil
        }
    }

    /// Moves a value written by the old `KeychainCredentialStore` into this store, then removes the
    /// Keychain item (design §3.4). The Keychain read shows the OS access dialog one last time.
    /// Failures are swallowed so the next `read` retries, matching `AppConfig`'s migration policy.
    private func migrateFromLegacyStore(account: String) -> String? {
        guard let legacyStore, let value = legacyStore.read(account: account) else {
            return nil
        }
        do {
            try write(value, account: account)
        } catch {
            logger.error(
                "Failed to migrate \(account, privacy: .public) out of the Keychain; will retry: \(error, privacy: .public)"
            )
            return value
        }
        do {
            try legacyStore.delete(account: account)
            logger.info("Migrated \(account, privacy: .public) from the Keychain to Secure Enclave storage")
        } catch {
            logger.warning(
                "Migrated \(account, privacy: .public) but could not remove the stale Keychain item: \(error, privacy: .public)"
            )
        }
        return value
    }
}

// MARK: - DefaultCredentialStore

/// The production composition point (design §3). Secure Enclave is unavailable on some Intel Macs;
/// there we keep using the Keychain, which prompts on self-signed rebuilds but works correctly for
/// Team-ID-signed builds (design §3.5).
enum DefaultCredentialStore {
    static let shared: CredentialStoring = make()

    private static func make() -> CredentialStoring {
        guard SecureEnclave.isAvailable else {
            Logger(subsystem: "io.github.uphy.Kikimi", category: "CredentialStore")
                .warning("Secure Enclave unavailable; falling back to Keychain credential storage")
            return KeychainCredentialStore.shared
        }
        let directory = CredentialFileLayout.defaultDirectory
        let cipher = SecureEnclaveCipher(
            keyURL: directory.appendingPathComponent(CredentialFileLayout.secureEnclaveKeyFileName, isDirectory: false)
        )
        return EncryptedFileCredentialStore(cipher: cipher, directory: directory, legacyStore: KeychainCredentialStore.shared)
    }
}

// MARK: - KeychainCredentialStore

/// Legacy store, kept only as `EncryptedFileCredentialStore`'s migration source and as the Secure
/// Enclave fallback (design §3.4/§3.5). New credentials are never written here on Apple Silicon.
/// `service` is fixed to the app's bundle id so items are namespaced away from any other app's
/// Keychain entries (`docs/design/26-settings-ui.md` §2).
final class KeychainCredentialStore: CredentialStoring {
    static let shared = KeychainCredentialStore()
    private let service = "io.github.uphy.Kikimi"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unhandledStatus(addStatus)
        }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        // `errSecItemNotFound` is not an error: deleting an already-absent item is a no-op success.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unhandledStatus(status)
        }
    }
}

// MARK: - InMemoryCredentialStore

/// Test double: an in-memory dictionary, no Keychain and no Secure Enclave. Used by every test that
/// touches `AppConfig`'s API-key migration/resolution so no real credential storage is written to
/// during `swift test` (mirrors `AppConfig.init(directory:)`'s existing temp-directory DI pattern
/// for config.yaml).
final class InMemoryCredentialStore: CredentialStoring {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    init(seeded: [String: String] = [:]) {
        storage = seeded
    }

    func read(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    func write(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = value
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}

// MARK: - CredentialAccount

/// `account` strings are config.yaml key paths, so future credentials never collide on naming
/// (`docs/design/26-settings-ui.md` §2).
enum CredentialAccount {
    static let openAIAPIKey = "llm.openai.api_key"
}
