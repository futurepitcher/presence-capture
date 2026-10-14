import Foundation

/// What's said, made into what's typed (R2b): spoken commands by fixed rules, and a tidier text
/// from a model taken only when it changes nothing but by deletion.
public enum DictationText {
    /// "new line", "new paragraph", "period", "comma" and "question mark", said as words, become
    /// what they name. Punctuation joins the word before it; a line break takes the space around it.
    public static func spokenCommands(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var out = ""
        func mark(_ symbol: String) {
            while out.last == " " { out.removeLast() }
            out += symbol
        }
        func word(_ word: String) {
            if !out.isEmpty, out.last != "\n" { out += " " }
            out += word
        }
        var i = 0
        while i < words.count {
            let one = bare(words[i]), two = i + 1 < words.count ? bare(words[i + 1]) : ""
            switch (one, two) {
            case ("new", "paragraph"): mark("\n\n"); i += 2
            case ("new", "line"): mark("\n"); i += 2
            case ("question", "mark"): mark("?"); i += 2
            case ("period", _): mark("."); i += 1
            case ("comma", _): mark(","); i += 1
            default: word(words[i]); i += 1
            }
        }
        return out
    }

    /// A word without its case or the punctuation the transcriber put on it.
    private static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// What tidying may remove, besides a false start: these, and only these.
    public static let fillers: Set = ["um", "uh", "er", "erm", "ah"]

    /// Whether `proposal` is `transcript` changed only by deletions and punctuation: filler words
    /// removed, an immediately repeated word or phrase removed (a false start), punctuation and
    /// capitals changed. Checked by aligning their words, without case or punctuation: the
    /// proposal's must be the transcript's, in order, less those deletions. A word added, dropped,
    /// moved, replaced or doubled is refused, and the transcript is typed as said.
    public static func tidyKeepsMeaning(_ proposal: String, of transcript: String) -> Bool {
        let said = tokens(transcript), tidy = tokens(proposal)
        var memo: [Int: Bool] = [:]
        // Whether said[i...] can become tidy[j...] by those deletions alone.
        func aligns(_ i: Int, _ j: Int) -> Bool {
            let key = i * (tidy.count + 1) + j
            if let known = memo[key] { return known }
            var ok = false
            if i == said.count {
                ok = j == tidy.count
            } else {
                if j < tidy.count, said[i] == tidy[j] { ok = aligns(i + 1, j + 1) }
                if !ok, fillers.contains(said[i]) { ok = aligns(i + 1, j) }
                // A phrase said twice in a row: its first saying goes.
                var length = 1
                while !ok, i + 2 * length <= said.count, length <= 8 {
                    if said[i..<i + length] == said[i + length..<i + 2 * length] { ok = aligns(i + length, j) }
                    length += 1
                }
            }
            memo[key] = ok
            return ok
        }
        return aligns(0, 0)
    }

    /// Words, lower-cased, without punctuation; an apostrophe inside a word is part of it. A symbol
    /// (a currency, a mathematical sign, an emoji) is a word of its own, which must match: "€100"
    /// tidied to "$100" changes what was said.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = [], word = ""
        func end() {
            let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !trimmed.isEmpty { out.append(trimmed) }
            word = ""
        }
        for character in text.lowercased().replacingOccurrences(of: "’", with: "'") {
            if character.isLetter || character.isNumber || character == "'" {
                word.append(character)
            } else if character.isWhitespace || character.isPunctuation {
                end()
            } else {
                end()
                out.append(String(character))
            }
        }
        end()
        return out
    }

    /// Where what's typed is exactly what was said (after the spoken commands): terminals and code
    /// editors, by bundle ID.
    public static let neverTidied: Set = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.microsoft.VSCode", "com.apple.dt.Xcode",
    ]
}
