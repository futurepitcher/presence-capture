import AppKit
import Foundation

/// Check for Updates (RELEASING.md's update channel): the latest release on GitHub, compared with
/// this build's version. Asked only when the person chooses it, never on its own: it's the one thing
/// the app sends off this Mac, and it carries nothing but the request.
enum Updates {
    /// The repository whose releases are this app's. A fork changes it.
    static let repository = "futurepitcher/presence-capture"

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    /// The latest published release, from the GitHub Releases API's answer. Drafts and prereleases
    /// aren't returned by `releases/latest`.
    static func release(from data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com", page.path.hasPrefix("/\(repository)/releases/") else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }

    /// Whether `version` is later than `current`, comparing dotted numbers ("0.10.0" after "0.9.1").
    /// A version that isn't dotted numbers is never later: it's not offered.
    static func isNewer(_ version: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let parts = v.split(separator: ".").map { Int($0) }
            return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
        }
        guard let new = parts(version), let old = parts(current) else { return false }
        for i in 0..<max(new.count, old.count) {
            let (a, b) = (i < new.count ? new[i] : 0, i < old.count ? old[i] : 0)
            if a != b { return a > b }
        }
        return false
    }

    /// What a check found.
    enum Outcome: Equatable {
        case newer(Release)
        case upToDate(latest: String)
        /// The repository has no published release yet.
        case noRelease
        /// GitHub couldn't be reached, or answered with something else (a rate limit, say).
        case unknown
    }

    static func outcome(status: Int?, data: Data?, current: String) -> Outcome {
        switch status {
        case 200:
            guard let release = data.flatMap(release(from:)) else { return .unknown }
            return isNewer(release.version, than: current) ? .newer(release) : .upToDate(latest: release.version)
        case 404: return .noRelease
        default: return .unknown
        }
    }

    /// Asks GitHub, then says what it found.
    static func check() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let found = outcome(status: (response as? HTTPURLResponse)?.statusCode, data: data, current: current)
            DispatchQueue.main.async { show(found, current: current) }
        }.resume()
    }

    private static func show(_ outcome: Outcome, current: String) {
        let alert = NSAlert()
        switch outcome {
        case .newer(let release):
            alert.messageText = "Presence Capture \(release.version) is available"
            alert.informativeText = "You have \(current). The release page has the download and what changed."
            alert.addButton(withTitle: "Open the Release Page")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            return
        case .upToDate(let latest):
            alert.messageText = "Presence Capture is up to date"
            alert.informativeText = "You have \(current); the latest release is \(latest)."
        case .noRelease:
            alert.messageText = "No release is published yet"
            alert.informativeText = "You have \(current). Releases will be at github.com/\(repository)/releases."
        case .unknown:
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "GitHub couldn't be reached, or didn't answer. Releases are at github.com/\(repository)/releases."
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
