import Foundation

/// A page's address as it's kept (in plain metadata, which Forget leaves): its scheme, host and
/// path only. Userinfo, query and fragment go, as do control characters; what's left is redacted
/// like text and cut to `maxLength` characters. The same as the reference (src/redact.js,
/// cleanSourceUrl); packages/schema/cases/source-url.json holds both to the same answers.
public enum SourceURL {
    public static let maxLength = 2048
    private static let control = try! NSRegularExpression(pattern: #"[\u0000-\u001f\u007f]"#)
    private static let authority = try! NSRegularExpression(pattern: #"^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/]*)([\s\S]*)$"#)

    public static func clean(_ url: String?) -> String? {
        guard let url else { return nil }
        var out = control.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "")
        out = String(out.prefix { $0 != "#" })
        out = String(out.prefix { $0 != "?" })
        if let match = authority.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
           let scheme = Range(match.range(at: 1), in: out), let host = Range(match.range(at: 2), in: out),
           let rest = Range(match.range(at: 3), in: out) {
            let hostPart = out[host]
            let withoutUser = hostPart.lastIndex(of: "@").map { hostPart[hostPart.index(after: $0)...] } ?? hostPart
            out = String(out[scheme]) + withoutUser + String(out[rest])
        }
        out = String(String.UnicodeScalarView(Redact.redact(out).unicodeScalars.prefix(maxLength)))
        return out.isEmpty ? nil : out
    }
}
