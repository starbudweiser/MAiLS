import Foundation
import Security

public enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Coffre des mots de passe. Seule implémentation de production : le Trousseau macOS.
public protocol SecretStore: Sendable {
    func password(for key: String) throws -> String?
    func setPassword(_ password: String, for key: String) throws
    func deletePassword(for key: String) throws
}

/// Trousseau macOS (`Security.framework`), un élément « mot de passe générique » par compte.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func password(for key: String) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for key: String) throws {
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "MAiLS"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    public func deletePassword(for key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// Coffre en mémoire : tests et essais seulement.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func password(for key: String) throws -> String? { lock.withLock { values[key] } }
    public func setPassword(_ password: String, for key: String) throws { lock.withLock { values[key] = password } }
    public func deletePassword(for key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}
