import CryptoKit
import Foundation

/// Pinning a sensor (ADR 0007), as the reference's src/pins.js does: what runs is what was
/// approved. A sensor's pins are the SHA-256 of its executable and of every file its command names
/// (a script), keyed by absolute path. A directory it's given (a repository to watch) is data, not
/// code, and isn't pinned.
public enum Pins {
    public enum PinError: Error, Equatable {
        case notAbsolute
        case noExecutable(String)
    }

    /// The pins for a command as it is on disk now.
    public static func compute(_ command: [String]) throws -> [String: String] {
        guard let executable = command.first, executable.hasPrefix("/") else { throw PinError.notAbsolute }
        var pins: [String: String] = [:]
        for (index, argument) in command.enumerated() where argument.hasPrefix("/") {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: argument, isDirectory: &directory) else {
                if index == 0 { throw PinError.noExecutable(argument) }
                continue
            }
            guard !directory.boolValue else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: argument), options: .mappedIfSafe)
            pins[argument] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return pins
    }

    /// Nil when the command on disk is what was approved; otherwise what changed.
    public static func error(_ command: [String], approved: [String: String]?) -> String? {
        guard let approved, !approved.isEmpty else { return "not approved" }
        guard let now = try? compute(command) else { return "its executable can't be read" }
        for path in Set(now.keys).union(approved.keys).sorted() where now[path] != approved[path] {
            return "\(path) has changed since it was approved"
        }
        return nil
    }
}
