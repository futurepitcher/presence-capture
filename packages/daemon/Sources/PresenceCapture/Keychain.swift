import CaptureStore
import CryptoKit
import Foundation
import Security

/// The store's master key, kept in this Mac's Keychain and nowhere else: never in the store,
/// never beside it, never synced to other devices. Made on first launch.
///
/// Changing the bundle ID orphans the key, and with it every store it sealed.
///
/// The key is made once, as the app's own item, `store`, and kept for readers in the current
/// version of a shared item (`MasterKeyItem`), made with an access list trusting the app and the
/// readers in its bundle (ADR 0008), so an agent's MCP server opens the store with no prompt. An
/// item's access list is set when the item is made, never changed: when the trusted set changes,
/// the version is bumped, and at its next launch the app makes the new version from the newest
/// older item, with the same key. Older items are left as they are.
///
/// Trust is recorded by each program's code signature, so a rebuild signed by the same identity
/// keeps it. This is the file-based Keychain's access list, which Apple has deprecated but still
/// honours; a shared access group replaces it once releases carry a provisioning profile.
enum Keychain {
    private static let service = MasterKeyItem.service(bundleIdentifier: Bundle.main.bundleIdentifier)

    /// The programs in the bundle the current version trusts, beside the app. Adding one is a new
    /// `MasterKeyItem.version`.
    private static let readers = ["pcap-mcp", "pcap"]

    /// Run from an app bundle. A development build run from the command line isn't, and has no
    /// readers to share the key with.
    private static var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// The key, made or upgraded as needed. In a bundle, a key readers can't be given is an error,
    /// not a quiet fallback: the app would capture while every agent's server failed to open.
    static func masterKey(log: (String) -> Void = { _ in }) throws -> SymmetricKey {
        if let key = try MasterKeyItem.read(service: service, account: MasterKeyItem.current) { return SymmetricKey(data: key) }
        var found: (account: String, key: Data)?
        for account in MasterKeyItem.older {
            if let key = try MasterKeyItem.read(service: service, account: account) {
                found = (account, key)
                break
            }
        }
        // One key, whichever launch makes it: added as the app's own item, or, when another launch
        // added it a moment before, read back from there.
        let key = try found?.key ?? addOrRead("store", SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, access: nil)
        guard bundled else { return SymmetricKey(data: key) }
        let shared = try addOrRead(MasterKeyItem.current, key, access: try access())
        log(found.map { "keychain.upgraded from=\($0.account)" } ?? "keychain.created")
        return SymmetricKey(data: shared)
    }

    /// Adds the item; when it already exists (another launch made it between the lookup and now),
    /// reads its key back instead, so every process ends up holding the same one.
    private static func addOrRead(_ account: String, _ key: Data, access: SecAccess?) throws -> Data {
        var item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: key,
            kSecAttrSynchronizable: false,
        ]
        if let access { item[kSecAttrAccess] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return key }
        guard status == errSecDuplicateItem, let existing = try MasterKeyItem.read(service: service, account: account) else {
            throw MasterKeyError.status(status)
        }
        return existing
    }

    /// An access list naming this app and every reader in its bundle. A reader missing from the
    /// bundle is a broken build, and an error.
    private static func access() throws -> SecAccess {
        var trusted: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &me)
        guard status == errSecSuccess, let me else { throw MasterKeyError.status(status) }
        trusted.append(me)
        for name in readers {
            let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path
            guard FileManager.default.isExecutableFile(atPath: path) else { throw MasterKeyError.missingReader(name) }
            var reader: SecTrustedApplication?
            status = SecTrustedApplicationCreateFromPath(path, &reader)
            guard status == errSecSuccess, let reader else { throw MasterKeyError.status(status) }
            trusted.append(reader)
        }
        var access: SecAccess?
        status = SecAccessCreate("Presence Capture store key" as CFString, trusted as CFArray, &access)
        guard status == errSecSuccess, let access else { throw MasterKeyError.status(status) }
        return access
    }
}
