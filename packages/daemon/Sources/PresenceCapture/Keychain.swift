import CaptureStore
import CryptoKit
import Foundation
import Security

/// The store's master key, kept in this Mac's Keychain and nowhere else: never in the store,
/// never beside it, never synced to other devices. Made on first launch.
///
/// Changing the bundle ID orphans the key, and with it every store it sealed.
///
/// The key is kept in the current version of a shared item (`MasterKeyItem`), made with an access
/// list trusting the app and the readers in its bundle (ADR 0008), so an agent's MCP server opens
/// the store with no prompt. An item's access list is set when the item is made, never changed:
/// when the trusted set changes, the version is bumped, and at its next launch the app makes the
/// new version from the newest older item, with the same key. Older items are left as they are.
///
/// Trust is recorded by each program's code signature, so a rebuild signed by the same identity
/// keeps it. This is the file-based Keychain's access list, which Apple has deprecated but still
/// honours; a shared access group replaces it once releases carry a provisioning profile.
enum Keychain {
    private static let service = MasterKeyItem.service(bundleIdentifier: Bundle.main.bundleIdentifier)

    /// The programs in the bundle the current version trusts, beside the app. Adding one is a new
    /// `MasterKeyItem.version`.
    private static let readers = ["pcap-mcp"]

    static func masterKey(log: (String) -> Void = { _ in }) throws -> SymmetricKey {
        if let key = try MasterKeyItem.read(service: service, account: MasterKeyItem.current) { return SymmetricKey(data: key) }
        for account in MasterKeyItem.older {
            guard let key = try MasterKeyItem.read(service: service, account: account) else { continue }
            // A key from an older item: the current version is made beside it, with the same key.
            if share(key, log: log) { log("keychain.upgraded from=\(account)") }
            return SymmetricKey(data: key)
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard share(key, log: log) else {
            // Outside a bundle (a development run): there are no readers, so the app alone.
            try add("store", key, access: nil)
            log("keychain.created shared=false")
            return SymmetricKey(data: key)
        }
        log("keychain.created shared=true")
        return SymmetricKey(data: key)
    }

    /// Makes the current version. False, and nothing made, outside a bundle or when it can't be.
    private static func share(_ key: Data, log: (String) -> Void) -> Bool {
        guard let access = access() else { return false }
        do {
            try add(MasterKeyItem.current, key, access: access)
            return true
        } catch {
            log("keychain.share_failed \(error)")
            return false
        }
    }

    private static func add(_ account: String, _ key: Data, access: SecAccess?) throws {
        var item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: key,
            kSecAttrSynchronizable: false,
        ]
        if let access { item[kSecAttrAccess] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw MasterKeyError.status(status) }
    }

    /// An access list naming this app and every reader in its bundle, for an item being made; nil
    /// outside a bundle, or when a reader is missing from it.
    private static func access() -> SecAccess? {
        var trusted: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me else { return nil }
        trusted.append(me)
        for name in readers {
            let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path
            var reader: SecTrustedApplication?
            guard FileManager.default.isExecutableFile(atPath: path),
                  SecTrustedApplicationCreateFromPath(path, &reader) == errSecSuccess, let reader else { return nil }
            trusted.append(reader)
        }
        var access: SecAccess?
        guard SecAccessCreate("Presence Capture store key" as CFString, trusted as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
