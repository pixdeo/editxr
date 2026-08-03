import Foundation

/// A word a search matched on, ready to be marked in displayed text.
///
/// `text` is folded and lowercased the same way the index folds, so a match
/// found through a repair still marks what is actually on screen: the query
/// "ruben" marks "Rubén", and "tranfomer" marks "Transformer".
struct TextMatch: Equatable {
    let text: String
    /// True when the word was still being typed, so longer words starting with
    /// it count — otherwise only the whole word does.
    let isPrefix: Bool

    func matches(_ word: String) -> Bool {
        isPrefix ? word.hasPrefix(text) : word == text
    }
}

/// Marks matched words inside a line of text, leaving every column where it was.
///
/// Two things make this less trivial than a substring search. Text on screen is
/// already styled, so the marks have to go between escape sequences rather than
/// inside them, and the style that was interrupted has to be put back. And the
/// text is compared folded, so the mark has to be placed by position in the
/// original — a folded word can be a different length than the word it came from.
enum MatchHighlighter {

    /// Wrap each matched word in `style`, restoring whatever styling was in
    /// force at that point afterwards. `base` is the styling the caller applies
    /// to the whole string, re-emitted after a mark in plain (unstyled) text.
    static func mark(_ text: String, matches: [TextMatch], base: String, style: String) -> String {
        guard !matches.isEmpty, !text.isEmpty else { return text }

        var out = ""
        out.reserveCapacity(text.count + 16)
        var scanner = ANSIScanner()
        /// Styling seen since the last reset, put back after a mark.
        var active = ""
        var pending = ""          // escape bytes of the sequence being read
        var word = ""             // visible characters of the run in progress
        var folded = ""           // the same run, folded for comparison

        /// Flush the run in progress, marked if it is one of the matches.
        func flushWord() {
            guard !word.isEmpty else { return }
            if matches.contains(where: { $0.matches(folded) }) {
                out += style + word + Theme.reset + base + active
            } else {
                out += word
            }
            word = ""
            folded = ""
        }

        for char in text {
            if scanner.consume(char) {
                pending.append(char)
                continue
            }
            if !pending.isEmpty {
                // An escape can't land inside a marked word, so close the run
                // first and keep the sequence for restoring the style later.
                flushWord()
                out += pending
                if pending.contains("[0m") { active = "" } else { active += pending }
                pending = ""
            }
            if char.isLetter || char.isNumber {
                word.append(char)
                folded += VaultIndex.fold(String(char).lowercased())
            } else {
                flushWord()
                out.append(char)
            }
        }
        flushWord()
        out += pending
        return out
    }
}
