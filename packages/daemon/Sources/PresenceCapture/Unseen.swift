import Foundation

/// Warnings the person hasn't seen yet: that a grant is still able to read when it was meant to be
/// withdrawn. Kept in the defaults from the moment they arise, before anything is shown, and let go
/// only once the person has seen them, so quitting (or a window closing) never loses one: what's left
/// is shown at the next launch.
enum Unseen {
    static let key = "unseenWarnings"
    private static let lock = NSLock()

    static func keep(_ warning: String, in defaults: UserDefaults = .standard) {
        lock.withLock { defaults.set((defaults.stringArray(forKey: key) ?? []) + [warning], forKey: key) }
    }

    static func seen(_ warning: String, in defaults: UserDefaults = .standard) {
        lock.withLock {
            var all = defaults.stringArray(forKey: key) ?? []
            if let index = all.firstIndex(of: warning) { all.remove(at: index) }
            defaults.set(all, forKey: key)
        }
    }

    static func all(in defaults: UserDefaults = .standard) -> [String] {
        lock.withLock { defaults.stringArray(forKey: key) ?? [] }
    }
}
