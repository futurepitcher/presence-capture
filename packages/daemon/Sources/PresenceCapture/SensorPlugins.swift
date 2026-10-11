import CaptureStore
import Foundation

/// Sensor plugins (ADR 0007): executables listed in sensors.json, each run as its own process,
/// writing observations to stdout. Each passes the gate (exclusion, redaction, sealing) as the
/// built-in sensors' do; a plugin never touches the store or sees the master key. While capture
/// is held, or the exclusion list can't be read, what they send is dropped, never queued. A
/// sensor that stops is started again a minute later.
///
/// A sensor runs with the person's own permissions, so it runs only as approved: its pins (the
/// SHA-256 of its executable and scripts) are written when the person approves it from the menu,
/// and a sensor whose files have changed since isn't run until it's approved again.
///
///     [{ "name": "git-activity", "command": ["/opt/homebrew/bin/node", "/path/sensor.mjs", "/Users/you/code/repo"],
///        "pins": { "/opt/homebrew/bin/node": "…", "/path/sensor.mjs": "…" } }]
final class SensorPlugins: @unchecked Sendable {
    private struct Config: Decodable {
        let name: String
        let command: [String]
        let pins: [String: String]?
    }

    /// A sensor waiting for the person's approval: what it would run, and why it's waiting.
    struct Waiting: Sendable {
        let name: String
        let command: [String]
        let reason: String
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
    private var waiting: [String: Waiting] = [:]
    private var configs: [String: Config] = [:]
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
            lock.withLock { self.configs[config.name] = config }
            launch(config)
        }
    }

    /// Sensors not run because they aren't approved, or changed since they were.
    var unapproved: [Waiting] { lock.withLock { waiting.values.sorted { $0.name < $1.name } } }

    /// The person approved a sensor as it is on disk now: its pins are written to sensors.json and
    /// it's run.
    func approve(_ name: String) throws {
        guard let config = lock.withLock({ configs[name] }) else { return }
        let pins = try Pins.compute(config.command)
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        guard var entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for index in entries.indices where entries[index]["name"] as? String == name { entries[index]["pins"] = pins }
        try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: configPath), options: .atomic)
        let approved = Config(name: config.name, command: config.command, pins: pins)
        lock.withLock {
            configs[name] = approved
            waiting[name] = nil
        }
        log("sensors.approved name=\(name)")
        launch(approved)
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
        // Checked at every launch, a relaunch too: a file changed while it ran stops it here.
        if let reason = Pins.error(config.command, approved: config.pins) {
            lock.withLock { waiting[config.name] = Waiting(name: config.name, command: config.command, reason: reason) }
            log("sensors.unapproved name=\(config.name)")
            return
        }
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
                self.launch(self.lock.withLock { self.configs[config.name] } ?? config)
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
