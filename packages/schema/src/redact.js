/**
 * Redaction before disk (CONTRACT step 3): secrets first, then personal
 * identifiers, each replaced by a bracketed label. The rules come from
 * PresenceOS and PresenceVoice, where they scrub captured text today.
 * `cases/redaction.json` holds every implementation to the same answers.
 */

const SECRET_RULES = [
  // To its end, or, where its end isn't there (cut off where reading or capture stopped), to the
  // end of the text: one pass, so many starts with no end take time growing with the text, not its
  // square.
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|(?![\s\S]))/g, '[PRIVATE_KEY]'],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, '[JWT]'],
  [/\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}/g, '[API_KEY]'],
  [/\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/g, '[API_KEY]'],
  [/\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, '[GITHUB_TOKEN]'],
  [/\bgithub_pat_[A-Za-z0-9_]{20,}/g, '[GITHUB_TOKEN]'],
  [/\bBearer\s+[A-Za-z0-9._~+/-]{16,}=*/gi, '[CREDENTIAL]'],
  [/\bAKIA[0-9A-Z]{16}\b/g, '[AWS_KEY]'],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}/g, '[SLACK_TOKEN]'],
  [/\b(?:api[_-]?key|secret|token|password|passwd)["']?\s*[:=]\s*\S{6,}/gi, '[CREDENTIAL]'],
];

const PII_RULES = [
  // Starts only where a run of its characters starts: tried at every place in
  // a long run (a base64 blob), it took time growing with the run's square.
  [/(?<![a-zA-Z0-9._%+-])[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g, '[EMAIL]'],
  [/\/Users\/[^/\s]+/g, '/Users/[USER]'],
  [/C:\\Users\\[^\\]+/gi, 'C:\\Users\\[USER]'],
  [/\b\d{3}-\d{2}-\d{4}\b/g, '[SSN]'],
  [/\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b/g, '[CREDIT_CARD]'],
  [/\b3[47]\d{2}[- ]?\d{6}[- ]?\d{5}\b/g, '[CREDIT_CARD]'],
  [/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g, '[IP]'],
  [/(?:\+?1[-.\s]?)?\(?\b\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/g, '[PHONE]'],
  [/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '[UUID]'],
];

/** Redact secrets first, then personal identifiers. */
export function redact(text) {
  let out = text;
  for (const [pattern, label] of [...SECRET_RULES, ...PII_RULES]) out = out.replace(pattern, label);
  return out;
}

const URL_MAX = 2048;

/**
 * A page's address as it's kept (in plain metadata, which Forget leaves): its scheme, host and
 * path only. Userinfo, query and fragment go, as do control characters; what's left is redacted
 * like text and cut to URL_MAX characters. An address with no scheme://host form (data:,
 * javascript:, blob:, about:, or anything malformed) can carry the page itself, so none of it is
 * kept. `cases/source-url.json` holds every implementation to the same answers. Null for nothing.
 */
export function cleanSourceUrl(url) {
  if (url == null) return null;
  let out = String(url).replace(/[\u0000-\u001f\u007f]/g, '');
  out = out.split('#')[0].split('?')[0];
  const parts = out.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)([^/]*)([\s\S]*)$/);
  if (!parts) return null;
  out = parts[1] + parts[2].slice(parts[2].lastIndexOf('@') + 1) + parts[3];
  out = [...redact(out)].slice(0, URL_MAX).join('');
  return out === '' ? null : out;
}
