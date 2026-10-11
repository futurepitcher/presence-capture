import CryptoKit
import Foundation

/// AES-256-GCM in the combined form SCHEMA.md defines: nonce(12) ‖ ciphertext ‖ tag(16), with
/// additional authenticated data binding a sealed value to its capture. CryptoKit's
/// `SealedBox.combined` is that layout, so stores written here open in the reference and back.
public enum Seal {
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: String) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: Data(aad.utf8)).combined else {
            throw StoreError.sealing
        }
        return combined
    }

    /// Throws when the key, the AAD or the bytes are wrong.
    public static func open(_ sealed: Data, key: SymmetricKey, aad: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data(aad.utf8))
    }

    public static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
}
