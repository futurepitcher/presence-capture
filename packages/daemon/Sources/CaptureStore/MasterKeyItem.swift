import Foundation
import Security

/// Where the store's master key is kept in the Keychain, as the app and its readers name it.
///
/// The app keeps the key in items under one service, named after its bundle ID, so a build under
/// another ID (a fork) has a key of its own. Which programs may read an item without a prompt is
/// set when the item is made and never changed: changing an item's access list takes an
/// authorization macOS asks the person for, and on current macOS it can ask again and again. So a
/// change to who's trusted (a new reader in the bundle) is a new version of the item, made by the
/// app from the newest older one, with the same key. Readers ask for the current version only.
public enum MasterKeyItem {
    /// Bumped whenever the set of trusted programs changes. v1: the app and `pcap-mcp`. v2: and `pcap`.
    public static let version = 2

    /// The item every reader asks for.
    public static var current: String { account(version) }

    /// What the current version is made from when it's missing, newest first: earlier versions, the
    /// unversioned shared item of the first test builds, and the app's own item from before readers.
    public static var older: [String] { (1..<version).reversed().map(account) + ["store.shared", "store"] }

    static func account(_ version: Int) -> String { "store.shared.v\(version)" }

    /// The service the items are under, from the app's bundle ID. A reader in the app's bundle
    /// (`Contents/MacOS`) has the app's bundle as its own main bundle, so it names the same one.
    public static func service(bundleIdentifier: String?) -> String {
        (bundleIdentifier ?? "ai.presenceos.capture") + ".master-key"
    }

    /// Only the person's own default (login) keychain is searched. Left to the search list, a query
    /// also asks every other keychain on it, and a locked one (a build's signing keychain left
    /// behind) prompts for a password the person doesn't know, again and again. No default keychain
    /// is an error, never an empty list: searching nothing would find nothing, and a missing key
    /// would be made anew.
    public static func searchList() throws -> [Any] {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDefault(&keychain)
        guard status == errSecSuccess, let keychain else { throw MasterKeyError.status(status == errSecSuccess ? errSecNoDefaultKeychain : status) }
        return [keychain]
    }

    /// The key a program in the app's bundle opens the store with: from `keyFile` when one is given
    /// (tests, other stores), as 32 raw bytes or 64 hex characters; otherwise the current shared
    /// item, which the app makes trusting the programs in its bundle.
    public static func load(keyFile: String?, bundleIdentifier: String?) throws -> Data {
        if let keyFile {
            guard let data = FileManager.default.contents(atPath: keyFile) else { throw MasterKeyError.file("can't be read") }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count == 64, text.allSatisfy(\.isHexDigit) {
                return Data(stride(from: 0, to: 64, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! })
            }
            guard data.count == 32 else { throw MasterKeyError.file("must be 32 bytes, raw or as 64 hex characters") }
            return data
        }
        let service = service(bundleIdentifier: bundleIdentifier)
        guard let key = try read(service: service, account: current) else { throw MasterKeyError.notMade(service: service, account: current) }
        return key
    }

    /// One item's key; nil when there's no such item. Anything else, an item that isn't 32 bytes
    /// included, is an error rather than a key.
    public static func read(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecMatchSearchList: try searchList(),
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else { throw MasterKeyError.status(status) }
        return data
    }
}

public enum MasterKeyError: Error, CustomStringConvertible {
    case status(OSStatus)
    /// A reader the key is to be shared with isn't in the app's bundle: a broken build.
    case missingReader(String)
    /// A key file that can't be used.
    case file(String)
    /// The app hasn't made the current item yet: it does at its next launch.
    case notMade(service: String, account: String)

    public var description: String {
        switch self {
        case .status(let status): return "Keychain status \(status)"
        case .missingReader(let name): return "\(name) isn't in the app's bundle"
        case .file(let why): return "the master key file \(why)"
        case .notMade(let service, let account):
            return "the store's key isn't in the Keychain yet (\(service) \(account)): open Presence Capture once, or pass --master-key-file"
        }
    }
}
