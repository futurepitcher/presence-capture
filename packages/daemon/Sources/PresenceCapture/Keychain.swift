import CryptoKit
import Foundation
import Security

/// The store's master key, kept in this Mac's Keychain and nowhere else: never in the store,
/// never beside it, never synced to other devices. Made on first launch.
enum Keychain {
    private static let service = "org.presence-capture.master-key"
    private static let account = "store"

    static func masterKey() throws -> SymmetricKey {
        if let existing = try read() { return existing }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: bytes,
            // Readable once this Mac has been unlocked since starting, on this device only.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return key
    }

    private static func read() throws -> SymmetricKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw KeychainError.status(status) }
        return SymmetricKey(data: data)
    }
}

enum KeychainError: Error {
    case status(OSStatus)
}
