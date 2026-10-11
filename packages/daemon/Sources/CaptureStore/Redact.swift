import Foundation

/// Redaction before disk (CONTRACT step 3): secrets first, then personal identifiers, each
/// replaced by a bracketed label. The same patterns as the reference (src/redact.js);
/// packages/schema/cases/redaction.json holds both to the same answers.
public enum Redact {
    private static let rules: [(NSRegularExpression, String)] = {
        let secret: [(String, NSRegularExpression.Options, String)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, [], "[PRIVATE_KEY]"),
            // A key whose end isn't there (cut off where reading stopped): all of it from its start.
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*$"#, [], "[PRIVATE_KEY]"),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, [], "[JWT]"),
            (#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}"#, [], "[API_KEY]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, [], "[GITHUB_TOKEN]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, [], "[AWS_KEY]"),
            (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, [], "[SLACK_TOKEN]"),
            (#"\b(?:api[_-]?key|secret|token|password|passwd)\s*[:=]\s*\S{6,}"#, [.caseInsensitive], "[CREDENTIAL]"),
        ]
        let personal: [(String, NSRegularExpression.Options, String)] = [
            // Starts only where a run of its characters starts, so a long run is linear, not square.
            (#"(?<![a-zA-Z0-9._%+-])[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, [], "[EMAIL]"),
            (#"/Users/[^/\s]+"#, [], "/Users/[USER]"),
            (#"C:\\Users\\[^\\]+"#, [.caseInsensitive], #"C:\Users\[USER]"#),
            (#"\b\d{3}-\d{2}-\d{4}\b"#, [], "[SSN]"),
            (#"\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b"#, [], "[CREDIT_CARD]"),
            (#"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, [], "[IP]"),
            (#"(?:\+?1[-.\s]?)?\(?\b\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#, [], "[PHONE]"),
            (#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, [.caseInsensitive], "[UUID]"),
        ]
        return (secret + personal).map { pattern, options, label in
            // ASCII digits and word boundaries, as the reference's patterns mean them.
            (try! NSRegularExpression(pattern: pattern, options: options), NSRegularExpression.escapedTemplate(for: label))
        }
    }()

    public static func redact(_ text: String) -> String {
        rules.reduce(text) { out, rule in
            rule.0.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: rule.1)
        }
    }
}
