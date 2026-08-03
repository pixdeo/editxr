import Foundation

/// Per-grapheme widths measured from the live terminal at startup, keyed by the
/// exact grapheme. Consulted before the static heuristic so on-screen glyphs are
/// laid out at the width THIS terminal (and the user's settings) actually draw —
/// the only portable answer, since emoji / ambiguous-symbol width varies between
/// Terminal.app, iTerm2, Ghostty, tmux, … See PlatformTerminal.probeWidths.
/// Written once at startup on the main thread, before any rendering.
private var measuredWidths: [Character: Int] = [:]

/// Record widths measured from the terminal. Only 1- and 2-column results are
/// trusted; anything else is treated as noise and left to the heuristic.
func registerMeasuredWidths(_ measured: [Character: Int]) {
    for (ch, w) in measured where w == 1 || w == 2 { measuredWidths[ch] = w }
}

/// Whether this grapheme already has a measured width (skip re-probing it).
func hasMeasuredWidth(_ char: Character) -> Bool { measuredWidths[char] != nil }

/// Reset the measured-width cache (tests, so cases stay independent).
func resetMeasuredWidths() { measuredWidths.removeAll() }

/// Everything measured so far, for persisting between runs.
func allMeasuredWidths() -> [Character: Int] { measuredWidths }

/// On-disk memo of what the probe learned, so only the very first run in a
/// given terminal pays for the CSI 6n round-trips (and shows their flicker).
/// Keyed by a signature of the terminal identity: a different terminal — or a
/// different iTerm2/tmux build, which may draw emoji differently — starts over
/// rather than trusting stale numbers.
enum GlyphWidthCache {
    private struct Payload: Codable {
        var terminal: String
        var widths: [String: Int]
    }

    /// `var` only so tests can redirect it to a temp file instead of the real one.
    static var path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/editxr/glyph-widths.json"
    }()

    /// What the measurements depend on: the emulator, its version, and whether
    /// we're inside tmux (which re-implements width itself).
    static var signature: String {
        let env = ProcessInfo.processInfo.environment
        let keys = ["TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "LC_TERMINAL",
                    "LC_TERMINAL_VERSION", "COLORTERM"]
        var parts = keys.map { "\($0)=\(env[$0] ?? "")" }
        parts.append("TMUX=\(env["TMUX"] != nil)")
        return parts.joined(separator: "|")
    }

    /// Seed the in-memory table from disk. Ignores a cache written by another
    /// terminal, and never throws — a missing or corrupt file just means we probe.
    static func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.terminal == signature else { return }
        var widths: [Character: Int] = [:]
        for (s, w) in payload.widths { if let c = s.first, s.count == 1 { widths[c] = w } }
        registerMeasuredWidths(widths)
    }

    /// Persist everything measured so far. Best-effort: a failure only costs the
    /// next run another probe.
    static func save() {
        var widths: [String: Int] = [:]
        for (c, w) in allMeasuredWidths() { widths[String(c)] = w }
        guard !widths.isEmpty else { return }
        let payload = Payload(terminal: signature, widths: widths)
        let dir = (path as NSString).deletingLastPathComponent
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try encoder.encode(payload).write(to: URL(fileURLWithPath: path))
        } catch { }
    }
}

/// Number of terminal columns a character occupies (0, 1 or 2).
/// Prefers a width measured live from this terminal; otherwise approximates
/// wcwidth: combining marks are zero-width, CJK/emoji are wide.
func displayWidth(_ char: Character) -> Int {
    if let measured = measuredWidths[char] { return measured }

    guard let scalar = char.unicodeScalars.first else { return 1 }
    let v = scalar.value

    if v == 0 { return 0 }
    // Combining marks / zero-width joiner / lone variation selectors.
    if (0x0300...0x036F).contains(v) || v == 0x200D || (0xFE00...0xFE0F).contains(v) {
        return 0
    }
    // Unambiguously wide blocks (CJK, Hangul, fullwidth, dedicated emoji planes).
    if (0x1100...0x115F).contains(v) ||
       (0x2E80...0xA4CF).contains(v) ||
       (0xAC00...0xD7A3).contains(v) ||
       (0xF900...0xFAFF).contains(v) ||
       (0xFE30...0xFE4F).contains(v) ||
       (0xFF00...0xFF60).contains(v) ||
       (0xFFE0...0xFFE6).contains(v) ||
       (0x1F000...0x1FAFF).contains(v) {
        return 2
    }
    // Miscellaneous Symbols + Dingbats (0x2600–0x27BF) and Miscellaneous
    // Technical (0x2300–0x23FF) are *ambiguous width*: terminals like
    // Terminal.app render most of them narrow (★ U+2605, ✓ U+2713, ⚠ U+26A0,
    // ⌥ U+2325) and only those with default emoji presentation wide (✅ ⛔ ⏰ ⌚).
    // Deferring to the Unicode property matches that — a blanket wide range here
    // over-counts the narrow symbols and shifts every table column that uses one.
    // A trailing U+FE0F (⚠️) does NOT widen them: Terminal.app draws the narrow
    // text glyph regardless, so we let the base symbol's presentation decide.
    if char.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
        return 2
    }
    return 1
}

extension StringProtocol {
    /// Visible terminal width, ignoring ANSI escape sequences.
    var displayWidth: Int {
        var width = 0
        var scanner = ANSIScanner()
        for ch in self where !scanner.consume(ch) {
            width += editxr_displayWidth(ch)
        }
        return width
    }
}

// Internal alias so the extension can call the free function unambiguously.
@inline(__always)
func editxr_displayWidth(_ char: Character) -> Int { displayWidth(char) }
