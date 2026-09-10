import Foundation
import Security

enum KeychainStore {
    private static let service = "com.nineghost.lostbot"
    private static let account = "authorized-segway-ble-key"
    private static let profTokenAccount = "authorized-urent-prof-token"

    struct AuditSnapshot {
        let itemPresent: Bool
        let usesAfterFirstUnlockThisDeviceOnly: Bool
        let synchronizable: Bool
        let status: OSStatus

        var protectionSummary: String {
            guard itemPresent else { return "No Keychain item" }
            guard usesAfterFirstUnlockThisDeviceOnly else { return "Unexpected accessibility class" }
            return synchronizable ? "Unexpected iCloud synchronization" : "AfterFirstUnlockThisDeviceOnly"
        }
    }

    static func saveBLEKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { throw StoreError.encoding }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw StoreError.status(updateStatus) }

        var insertion = identity
        insertion.merge(update) { _, replacement in replacement }
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insertion[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.status(addStatus) }
    }

    static func loadBLEKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteBLEKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveProfToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw StoreError.encoding }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profTokenAccount
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw StoreError.status(updateStatus) }

        var insertion = identity
        insertion.merge(update) { _, replacement in replacement }
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insertion[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.status(addStatus) }
    }

    static func loadProfToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profTokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteProfToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profTokenAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func auditBLEKeyAttributes() -> AuditSnapshot {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let attributes = result as? [String: Any] else {
            return AuditSnapshot(
                itemPresent: false,
                usesAfterFirstUnlockThisDeviceOnly: false,
                synchronizable: false,
                status: status
            )
        }
        let accessible = attributes[kSecAttrAccessible as String] as? String
        let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false
        return AuditSnapshot(
            itemPresent: true,
            usesAfterFirstUnlockThisDeviceOnly: accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
            synchronizable: synchronizable,
            status: status
        )
    }

    enum StoreError: LocalizedError {
        case encoding
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encoding: "Не удалось закодировать тестовый ключ"
            case .status(let status): "Ошибка Keychain: \(status)"
            }
        }
    }
}
