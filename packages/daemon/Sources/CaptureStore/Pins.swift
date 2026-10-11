import CryptoKit
import Foundation

/// Pinning a sensor (ADR 0007), exactly as the reference's src/pins.js does: what runs is what
/// was approved. A sensor's pins are the SHA-256 of its executable and of every regular file its
/// command names, keyed by absolute path: an argument that is a path, absolute or relative, and
/// the path in a `--flag=path` argument. Relative paths are resolved against `sensorWorkingDirectory`,
/// where every sensor is started, so a path means the same file when it's pinned as when it runs.
/// Symbolic links are followed: what's hashed is what runs. A directory it watches, or a device,
/// isn't code and isn't pinned.
public enum Pins {
    public enum PinError: Error, Equatable {
        case notAbsolute
        case noExecutable(String)
    }

    /// Every sensor runs here.
    public static let sensorWorkingDirectory = "/"

    /// The pins for a command as it is on disk now.
    public static func compute(_ command: [String], cwd: String = sensorWorkingDirectory) throws -> [String: String] {
        guard let executable = command.first, executable.hasPrefix("/") else { throw PinError.notAbsolute }
        var pins: [String: String] = [:]
        for (index, argument) in command.enumerated() {
            var candidates = [argument]
            if index > 0, let equals = argument.firstIndex(of: "=") { candidates.append(String(argument[argument.index(after: equals)...])) }
            for candidate in candidates where !candidate.isEmpty {
                let path = URL(fileURLWithPath: candidate, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path
                let target = (path as NSString).resolvingSymlinksInPath
                // Only a regular file is code: not a directory, a device, or a pipe, which could block.
                guard let type = try? FileManager.default.attributesOfItem(atPath: target)[.type] as? FileAttributeType else {
                    if index == 0 { throw PinError.noExecutable(argument) }
                    continue
                }
                guard type == .typeRegular else { continue }
                let data = try Data(contentsOf: URL(fileURLWithPath: target), options: .mappedIfSafe)
                pins[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return pins
    }

    /// Nil when the command on disk is what was approved; otherwise what changed.
    public static func error(_ command: [String], approved: [String: String]?, cwd: String = sensorWorkingDirectory) -> String? {
        guard let approved, !approved.isEmpty else { return "not approved" }
        guard let now = try? compute(command, cwd: cwd) else { return "its executable can't be read" }
        for path in Set(now.keys).union(approved.keys).sorted() where now[path] != approved[path] {
            return "\(path) has changed since it was approved"
        }
        return nil
    }
}
