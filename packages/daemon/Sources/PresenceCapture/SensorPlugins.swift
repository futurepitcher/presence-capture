import CaptureStore
import Foundation

/// Sensor plugins (ADR 0007): executables listed in sensors.json, each run as its own process,
/// writing observations to stdout. Each passes the gate (exclusion, redaction, sealing) as the
/// built-in sensors' do; a plugin never touches the store or sees the master key. While capture
/// is held, or the exclusion list can't be read, what they send is dropped, never queued. A
/// sensor that stops is started again a minute later.
///
///     [{ "name": "git-activity", "command": ["/opt/homebrew/bin/node", "/path/sensor.mjs", "/Users/you/code/repo"] }]
final class SensorPlugins: @unchecked Sendable {
    private struct Config: Decodable {
        let name: String
        let command: [String]
    }

    private let configPath: String
    private let store: CaptureStore
    private let fragments: @Sendable () -> [String]?
    private let held: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var running: [String: Process] = [:]
    private var gates: [String: Gate] = [:]
    private var dropped: [String: Int] = [:]
    private var stopping = false

    init(configPath: String, store: CaptureStore, fragments: @escaping @Sendable () -> [String]?, held: @escaping @Sendable () -> Bool,
         log: @escaping @Sendable (String) -> Void) {
        (self.configPath, self.store, self.fragments, self.held, self.log) = (configPath, store, fragments, held, log)
    }

    func start() {
        guard FileManager.default.fileExists(atPath: configPath) else { return }
        guard let data = FileManager.default.contents(atPath: configPath), let configs = try? JSONDecoder().decode([Config].self, from: data) else {
            log("sensors.config_unreadable")
            return
        }
        for config in configs {
            guard Observations.headerError(["sensor": config.name, "protocol": "1"]) == nil, !config.command.isEmpty else {
                log("sensors.config_invalid")
                continue
            }
            launch(config)
        }
    }

    func stop() {
        let processes = lock.withLock { () -> [Process] in
            stopping = true
            return Array(running.values)
        }
        processes.forEach { $0.terminate() }
        // One that ignores being told to stop is killed, so it can't outlive the app.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Counts for the hourly log line, a sensor at a time: never what was observed.
    func takeCounts() -> [(name: String, stats: Gate.Stats, dropped: Int)] {
        lock.withLock {
            defer { dropped = [:] }
            return Set(gates.keys).union(dropped.keys).sorted().map { ($0, gates[$0]?.takeStats() ?? Gate.Stats(), dropped[$0] ?? 0) }
        }
    }

    private func launch(_ config: Config) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.command[0])
        process.arguments = Array(config.command.dropFirst())
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let gate = Gate(store: store, source: "sensor:\(config.name)")
        var buffer = Data()
        var named = false
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                let value = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
                if !named {
                    // The header must name the sensor it was configured as.
                    guard Observations.headerError(value) == nil, (value as? [String: Any])?["sensor"] as? String == config.name else {
                        self.log("sensors.header_refused name=\(config.name)")
                        process.terminate()
                        return
                    }
                    named = true
                    self.lock.withLock { self.gates[config.name] = gate }
                    continue
                }
                guard !self.held(), let fragments = self.fragments() else {
                    self.lock.withLock { self.dropped[config.name, default: 0] += 1 }
                    continue
                }
                do {
                    try gate.ingest(value, fragments: fragments)
                } catch {
                    self.log("sensors.store_failed name=\(config.name)")
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let again = self.lock.withLock { () -> Bool in
                self.running[config.name] = nil
                return !self.stopping
            }
            self.log("sensors.stopped name=\(config.name)")
            guard again else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, !self.lock.withLock({ self.stopping }) else { return }
                self.launch(config)
            }
        }
        do {
            try process.run()
            lock.withLock { running[config.name] = process }
            log("sensors.started name=\(config.name)")
        } catch {
            log("sensors.launch_failed name=\(config.name)")
        }
    }
}
