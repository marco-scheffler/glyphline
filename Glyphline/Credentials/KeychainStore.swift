import Foundation
import Security

protocol CredentialStore {
    func save(secret: String, for reference: String) throws
    func readSecret(for reference: String) throws -> String?
    func deleteSecret(for reference: String) throws
}

final class InMemoryCredentialStore: CredentialStore {
    private var secrets: [String: String] = [:]

    func save(secret: String, for reference: String) throws {
        secrets[reference] = secret
    }

    func readSecret(for reference: String) throws -> String? {
        secrets[reference]
    }

    func deleteSecret(for reference: String) throws {
        secrets.removeValue(forKey: reference)
    }
}

enum KeychainError: Error, Equatable {
    case status(OSStatus)
}

final class KeychainStore: CredentialStore {
    private let service: String

    init(service: String = "com.marcoscheffler.glyphline.credentials") {
        self.service = service
    }

    func save(secret: String, for reference: String) throws {
        try deleteSecret(for: reference)

        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    func readSecret(for reference: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }

        return String(data: data, encoding: .utf8)
    }

    func deleteSecret(for reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
