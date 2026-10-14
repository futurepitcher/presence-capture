import Foundation

/// A page's address as it's kept (in plain metadata, which Forget leaves): its scheme, host and
/// path only. Userinfo, query and fragment go, as do control characters; what's left is redacted
/// like text and cut to `maxLength` characters. An address with no scheme://host form (data:,
/// javascript:, blob:, about:, or anything malformed) can carry the page itself, so none of it is
/// kept. The same as the reference (src/redact.js, cleanSourceUrl);
/// packages/schema/cases/source-url.json holds both to the same answers.
public enum SourceURL {
    public static let maxLength = 2048
    private static let control = try! NSRegularExpression(pattern: #"[\u0000-\u001f\u007f]"#)
    private static let authority = try! NSRegularExpression(pattern: #"^([a-zA-Z][a-zA-Z0-9+.-]*://)([^/]*)([\s\S]*)$"#)

    public static func clean(_ url: String?) -> String? {
        guard let url else { return nil }
        var out = control.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "")
        // Cut by scalar, as the reference cuts by code unit: a mark combined with "?" or "#" makes
        // another Character, but it's still where the query or fragment begins.
        out = String(String.UnicodeScalarView(out.unicodeScalars.prefix { $0 != "#" }))
        out = String(String.UnicodeScalarView(out.unicodeScalars.prefix { $0 != "?" }))
        guard let match = authority.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let scheme = Range(match.range(at: 1), in: out), let host = Range(match.range(at: 2), in: out),
              let rest = Range(match.range(at: 3), in: out) else { return nil }
        let hostPart = out[host].unicodeScalars
        let withoutUser = hostPart.lastIndex(of: "@").map { String(String.UnicodeScalarView(hostPart[hostPart.index(after: $0)...])) } ?? String(hostPart)
        out = String(out[scheme]) + withoutUser + String(out[rest])
        out = String(String.UnicodeScalarView(Redact.redact(out).unicodeScalars.prefix(maxLength)))
        return out.isEmpty ? nil : out
    }
}
