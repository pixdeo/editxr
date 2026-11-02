import Foundation

/// One indexed unit: a heading section of a note. Sections are the same unit the
/// AI edit flow works on, so a hit lands where a whole thought lives rather than
/// on a stray line.
struct VaultChunk: Equatable {
    let path: String        // relative to the vault root
    let title: String       // "Deep Work › Rituals" — file title plus heading trail
    let line: Int           // 0-based line to jump to
    let preview: String     // first non-empty body line, for the results list
    let length: Int         // token count, for BM25 length normalisation
}

/// Where the index is in its lifecycle. Drives the status bar and the Vault
/// settings menu; both read the same value so they can never disagree.
enum VaultIndexState: Equatable {
    case idle
    case indexing(done: Int, total: Int)
    case ready(chunks: Int, files: Int)
    case failed(String)

    /// Compact status-bar form, or nil when there is nothing worth saying.
    var statusText: String? {
        switch self {
        case .idle: return nil
        // Before the scan returns a file count there is no meaningful ratio to
        // show, and "0/0" reads like a failure.
        case .indexing(_, let total) where total == 0: return "indexing vault…"
        case .indexing(let done, let total): return "indexing vault \(done)/\(total)"
        case .ready: return nil
        case .failed(let why): return "vault index failed: \(why)"
        }
    }

    /// Full form for the settings menu, which always says something.
    var detail: String {
        switch self {
        case .idle: return "Not indexed yet"
        case .indexing(let done, let total): return "Indexing \(done)/\(total) files…"
        case .ready(let chunks, let files): return "\(chunks) sections across \(files) files"
        case .failed(let why): return "Failed: \(why)"
        }
    }
}

/// A ranked search hit.
struct VaultHit {
    let chunk: VaultChunk
    let score: Double
}

/// Full-text index over the vault's notes: scan, split into heading sections,
/// and rank with BM25 over an inverted index.
///
/// No model, no network, no consent step — this is the layer that always works.
/// Semantic ranking will fuse into `search` on top of these results rather than
/// replacing them, so search keeps working with the embedder off or absent.
final class VaultIndex {

    private(set) var state: VaultIndexState = .idle

    /// Called on the main queue whenever `state` changes, so the caller can
    /// re-render. Fired at a coarse cadence during a build, not per file.
    var onChange: (() -> Void)?

    /// Everything a query reads, assembled in one piece and then swapped in.
    ///
    /// Inverting the postings and growing the trie is the expensive half of a
    /// build — on a large vault, seconds of it. Doing that where the editor
    /// draws would freeze the cursor for exactly as long, so a build hands over
    /// a finished snapshot and the main thread only assigns it.
    struct Snapshot {
        let chunks: [VaultChunk]
        /// term -> [(chunk index, term frequency)]
        let postings: [String: [(chunk: Int32, tf: Int32)]]
        /// The vocabulary, for prefix completion and near-miss lookup.
        let trie: TermTrie
        let averageLength: Double
        let files: Int

        /// Invert per-chunk term counts into postings and grow the trie. Called
        /// on the index's own queue, never on the main one.
        init(chunks: [VaultChunk] = [], terms: [[String: Int32]] = [], files: Int = 0) {
            var postings: [String: [(chunk: Int32, tf: Int32)]] = [:]
            for (i, counts) in terms.enumerated() {
                for (term, tf) in counts { postings[term, default: []].append((Int32(i), tf)) }
            }
            self.chunks = chunks
            self.files = files
            self.postings = postings
            self.trie = TermTrie(terms: postings.keys.sorted())
            let total = chunks.reduce(0) { $0 + $1.length }
            self.averageLength = chunks.isEmpty ? 1 : Double(total) / Double(chunks.count)
        }
    }

    private var data = Snapshot() {
        didSet { lastResolved = nil }
    }

    /// The panel asks for a keystroke's hits and then for the words to mark, and
    /// a repair is the one expensive step of either, so the answer is kept for
    /// the second question.
    private var lastResolved: (query: String, words: [ResolvedWord])?

    /// Test seams: how often a word went through the repairs, and the most edits
    /// the last one was willing to look for.
    private(set) var repairCountForTest = 0
    private(set) var editBudgetForTest = 0

    /// Ceiling on how many completions one prefix contributes, so a two-letter
    /// query can't turn a keystroke into a full-vocabulary scan.
    static let maxPrefixExpansion = 200

    /// Bounds on cutting a glued word back into words. Two characters is the
    /// shortest indexed term, and a word that needs more than four pieces is far
    /// likelier to be noise assembled out of fragments than a real compound.
    static let minSegmentPart = 2
    static let maxSegmentParts = 4
    static let maxSegmentLength = 32

    /// Bounds on matching a misspelled word. Below four characters an edit is
    /// most of the word — "note" and "nope" are one apart — so short words are
    /// only ever matched exactly, and the second edit is earned by length.
    static let minFuzzyLength = 4
    static let twoEditLength = 8

    /// Shortest word that gets a singular or plural form. Below this the forms
    /// are other words entirely: "la" and "las", "lo" and "los", "do" and "dos".
    static let minNumberStem = 3

    /// How many alternatives of one word get marked in the results. A repair can
    /// return a couple of hundred; lighting up that many spellings is noise, and
    /// the row is only a line wide.
    static let maxMarkedTerms = 8

    /// Note lines offered to the search panel's detail pane. The panel takes what
    /// fits; this only bounds how much of a long note is read per keystroke.
    static let previewLines = 60

    /// Bumped on every build so a slow scan of an abandoned vault can't publish
    /// its results over a newer one. Written on the main queue and read from the
    /// build, so the build reads its own copy through `liveGeneration`.
    private var generation = 0
    private let generationLock = NSLock()
    private let queue = DispatchQueue(label: "editxr.vaultindex", qos: .utility)

    /// The current generation, read safely from the build queue.
    private var liveGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    /// How often to report progress.
    ///
    /// Every report costs a full re-render on the main queue, and a scan gets
    /// through small notes far faster than a screen can be drawn. Reporting per
    /// file — or per fixed number of files — queues redraws faster than they
    /// run, and the editor freezes behind a backlog of them even though the
    /// indexing itself is elsewhere. Time is the thing to ration, not files:
    /// four updates a second is more than the eye reads off a status bar.
    private static let progressInterval: TimeInterval = 0.25

    /// Test seam: the cadence a build's progress is rationed to.
    static var progressIntervalForTest: TimeInterval { progressInterval }

    var isReady: Bool { if case .ready = state { return true }; return false }

    // MARK: - Build

    /// Scan `root` and rebuild in the background. Safe to call again mid-build:
    /// the older run's results are discarded when it finishes.
    func build(root: String, includeText: Bool) {
        let generation = bumpGeneration()
        setState(.indexing(done: 0, total: 0))

        queue.async { [weak self] in
            guard let self else { return }
            let paths = VaultIndex.notePaths(root: root, includeText: includeText)
            guard !paths.isEmpty else {
                self.publish(generation: generation, Snapshot())
                return
            }
            self.report(generation: generation, done: 0, total: paths.count)

            var built: [VaultChunk] = []
            var termsPerChunk: [[String: Int32]] = []
            var lastReport = Date()
            for (i, rel) in paths.enumerated() {
                guard self.liveGeneration == generation else { return }   // superseded
                let full = root + "/" + rel
                guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
                for (chunk, terms) in VaultIndex.chunks(of: text, path: rel) {
                    built.append(chunk)
                    termsPerChunk.append(terms)
                }
                if Date().timeIntervalSince(lastReport) >= VaultIndex.progressInterval {
                    lastReport = Date()
                    self.report(generation: generation, done: i + 1, total: paths.count)
                }
            }
            // Still on the build queue: inverting and the trie are the expensive
            // part, and the editor has to stay responsive through them.
            let snapshot = Snapshot(chunks: built, terms: termsPerChunk, files: paths.count)
            self.publish(generation: generation, snapshot)
        }
    }

    func clear() {
        _ = bumpGeneration()
        data = Snapshot()
        setState(.idle)
    }

    // MARK: - Search

    /// One query word after the index has resolved it: the indexed terms to
    /// score, plus what the user actually typed so a hit can show why it matched.
    struct ResolvedWord {
        /// The word as it was typed, folded and lowercased.
        let typed: String
        /// True when it matched as the start of longer words, i.e. it is still
        /// being typed.
        let isPrefix: Bool
        /// Indexed alternatives, scored best-of so a wide prefix can't outscore
        /// an exact hit just by matching many spellings of the same word.
        let terms: [String]
    }

    /// BM25 over the inverted index: only chunks containing a query term are
    /// touched, so this stays sub-millisecond on a large vault.
    ///
    /// Hits are ordered by how many query words they hold before their score: a
    /// section holding every word is what was asked for, and one short section
    /// holding just the rarest word must not bury it.
    func search(_ rawQuery: String, limit: Int) -> [VaultHit] {
        let words = resolve(rawQuery)
        guard !words.isEmpty, !data.chunks.isEmpty else { return [] }

        let k1 = 1.2, b = 0.75
        let n = Double(data.chunks.count)
        var totals: [Int32: (score: Double, words: Int)] = [:]

        for word in words {
            var best: [Int32: Double] = [:]
            for term in word.terms {
                guard let plist = data.postings[term] else { continue }
                let df = Double(plist.count)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                for (chunkIndex, tf) in plist {
                    let f = Double(tf)
                    let len = Double(data.chunks[Int(chunkIndex)].length)
                    let norm = f * (k1 + 1) / (f + k1 * (1 - b + b * len / data.averageLength))
                    let score = idf * norm
                    if score > best[chunkIndex, default: 0] { best[chunkIndex] = score }
                }
            }
            for (chunkIndex, score) in best {
                totals[chunkIndex, default: (0, 0)].score += score
                totals[chunkIndex, default: (0, 0)].words += 1
            }
        }

        return totals
            .sorted {
                if $0.value.words != $1.value.words { return $0.value.words > $1.value.words }
                return $0.value.score == $1.value.score ? $0.key < $1.key : $0.value.score > $1.value.score
            }
            .prefix(limit)
            .map { VaultHit(chunk: data.chunks[Int($0.key)], score: $0.value.score) }
    }

    /// Turn a raw query into the words to score.
    ///
    /// Each word is tried as itself first. Only when the index holds nothing for
    /// it do the repairs run — a word run together with its neighbour, or a
    /// misspelling — so an ordinary query never pays for either.
    func resolve(_ rawQuery: String) -> [ResolvedWord] {
        if let last = lastResolved, last.query == rawQuery { return last.words }
        let terms = VaultIndex.tokenize(rawQuery)
        guard !terms.isEmpty, !data.chunks.isEmpty else { return [] }

        // Only the trailing word expands, and only while the query still ends
        // mid-word: a word finished with a space is a word the user means.
        let isTyping = rawQuery.unicodeScalars.last.map(CharacterSet.alphanumerics.contains) ?? false
        var words: [ResolvedWord] = []
        for (i, term) in terms.enumerated() {
            let typing = isTyping && i == terms.count - 1
            if let word = typing ? prefixWord(term) : exactWord(term) {
                words.append(word)
            } else {
                words.append(contentsOf: repair(term, typing: typing))
            }
        }
        lastResolved = (rawQuery, words)
        return words
    }

    /// `term` as a word still being typed: everything it could become, plus its
    /// other number, which it can't become by adding letters ("verticals" holds
    /// "vertical" only that way).
    private func prefixWord(_ term: String) -> ResolvedWord? {
        let terms = expand(prefix: term) + inflections(of: term).filter { !$0.hasPrefix(term) }
        return terms.isEmpty ? nil : ResolvedWord(typed: term, isPrefix: true, terms: terms)
    }

    /// `term` as a finished word, in either number.
    private func exactWord(_ term: String) -> ResolvedWord? {
        let forms = inflections(of: term)
        return forms.isEmpty ? nil : ResolvedWord(typed: term, isPrefix: false, terms: forms)
    }

    /// A word the index has nothing for is one of two mistakes: words run
    /// together ("cancerruben") or a misspelling ("tranfomer"). Both are
    /// measured in edits to what was typed — spaces to insert, or letters to
    /// fix — and the cheaper explanation wins.
    ///
    /// A tie goes to the misspelling: a split that needs as many cuts as a typo
    /// needs edits is usually an accident of short pieces, and "tran" + "fo" +
    /// "mer" is exactly the kind of debris that would otherwise bury
    /// "transformer".
    private func repair(_ term: String, typing: Bool) -> [ResolvedWord] {
        repairCountForTest += 1
        let split = segment(term, typing: typing)
        let cuts = split.map { $0.count - 1 } ?? Int.max

        // The cuts are what a misspelling has to beat, so looking further than
        // that can't change the answer, and each extra edit is most of the cost.
        if let near = nearest(term, atMost: cuts) {
            return [ResolvedWord(typed: term, isPrefix: false, terms: near.terms)]
        }
        return split ?? []
    }

    /// The words a query resolved to, for marking them in the results.
    ///
    /// A word still being typed is represented by the prefix itself rather than
    /// by its completions — there can be two hundred of those, and the whole
    /// word on screen is what the eye is looking for anyway.
    func matchTokens(for rawQuery: String) -> [TextMatch] {
        var tokens: [TextMatch] = []
        var seen = Set<String>()
        for word in resolve(rawQuery) {
            if word.isPrefix {
                guard seen.insert(word.typed).inserted else { continue }
                tokens.append(TextMatch(text: word.typed, isPrefix: true))
                for term in inflections(of: word.typed)
                where !term.hasPrefix(word.typed) && seen.insert(term).inserted {
                    tokens.append(TextMatch(text: term, isPrefix: false))
                }
            } else {
                for term in word.terms.prefix(VaultIndex.maxMarkedTerms)
                where seen.insert(term).inserted {
                    tokens.append(TextMatch(text: term, isPrefix: false))
                }
            }
        }
        return tokens
    }

    /// Indexed terms starting with `prefix`, shortest first so the closest
    /// completions win when the cap bites. A two-letter prefix can match
    /// thousands of terms; the cap keeps a keystroke bounded.
    private func expand(prefix: String) -> [String] {
        data.trie.completions(of: prefix, limit: VaultIndex.maxPrefixExpansion)
    }

    /// The indexed singular and plural forms of `term`, itself included. Empty
    /// when the index holds none of them.
    ///
    /// Number is the one variation typing can't get around: "vertical" and
    /// "verticals" are the same word to whoever is searching. The set comes out
    /// the same from either form, so both queries find the same notes.
    private func inflections(of term: String) -> [String] {
        VaultIndex.numberForms(of: term).filter { data.postings[$0] != nil }
    }

    /// Candidate singular and plural spellings of a word, for Spanish and English
    /// alike: a vowel takes -s ("nota", "notas"), a consonant -s or -es ("app",
    /// "apps"; "reunion", "reuniones"). Spellings no note holds fall away when
    /// they are looked up, so a wrong guess here costs nothing.
    static func numberForms(of term: String) -> [String] {
        let takesEs: Set<Character> = ["n", "r", "l", "d", "z", "x", "s", "h", "j", "y"]
        func isStem(_ word: Substring) -> Bool { word.count >= minNumberStem }

        var stems = [term]
        if term.hasSuffix("s"), !term.hasSuffix("ss") {
            let single = term.dropLast()
            if isStem(single) { stems.append(String(single)) }
            // "notes" is "note", never "not": -es only comes off where -es goes on.
            if term.hasSuffix("es"), let last = single.dropLast().last,
               takesEs.contains(last), isStem(single.dropLast()) {
                stems.append(String(single.dropLast()))
            }
        }

        var forms = stems
        for stem in stems where stem.count >= minNumberStem && !stem.hasSuffix("s") {
            forms.append(stem + "s")
            if let last = stem.last, takesEs.contains(last) { forms.append(stem + "es") }
        }
        var seen = Set<String>()
        return forms.filter { seen.insert($0).inserted }
    }

    /// Cut a glued word back into the words it was typed from, so that it reads
    /// exactly as if the spaces were there.
    ///
    /// Any piece may be unfinished ("appvertic" is "app" + "vertic…"), which
    /// makes almost every string cuttable somehow, so the letters alone can't
    /// choose. The notes do: fewest pieces first, keeping only cuts whose pieces
    /// occur together in some section, and among those the one with the most
    /// whole words, then the most sections.
    ///
    /// With no such cut, the fewest whole words still explain a query spanning
    /// two notes ("cancerruben" with each word on its own). Nil when not even
    /// those do.
    private func segment(_ term: String, typing: Bool) -> [ResolvedWord]? {
        let chars = Array(term)
        let n = chars.count
        let minPart = VaultIndex.minSegmentPart
        guard n >= 2 * minPart, n <= VaultIndex.maxSegmentLength else { return nil }
        // A piece being typed can be a single letter so far.
        let minTail = typing ? 1 : minPart

        var pieces: [String: ResolvedWord?] = [:]
        var holders: [String: [UInt64]] = [:]

        func word(_ start: Int, _ end: Int) -> ResolvedWord? {
            let text = String(chars[start..<end])
            let key = end == n ? text + "$" : text
            if let known = pieces[key] { return known }
            let found = end == n && typing ? prefixWord(text) : exactWord(text) ?? prefixWord(text)
            pieces[key] = found
            return found
        }

        /// Sections holding all of `cut`, by intersecting one bitset per piece.
        func together(_ cut: [ResolvedWord]) -> Int {
            var shared: [UInt64]?
            for piece in cut {
                let key = piece.typed + (piece.isPrefix ? "$" : "")
                let bits = holders[key] ?? chunkBits(of: piece.terms)
                holders[key] = bits
                shared = shared.map { zip($0, bits).map { $0 & $1 } } ?? bits
            }
            return shared?.reduce(0) { $0 + $1.nonzeroBitCount } ?? 0
        }

        /// Visit every way of cutting `start...` into exactly `parts` pieces.
        func walk(_ start: Int, parts: Int, cut: [ResolvedWord], visit: ([ResolvedWord]) -> Void) {
            if parts == 1 {
                if n - start >= minTail, let last = word(start, n) { visit(cut + [last]) }
                return
            }
            let latest = n - minTail - (parts - 2) * minPart
            guard start + minPart <= latest else { return }
            for end in (start + minPart)...latest {
                guard let piece = word(start, end) else { continue }
                walk(end, parts: parts - 1, cut: cut + [piece], visit: visit)
            }
        }

        var wholeWords: [ResolvedWord]?
        for parts in 2...VaultIndex.maxSegmentParts {
            var best: (cut: [ResolvedWord], whole: Int, sections: Int)?
            walk(0, parts: parts, cut: []) { cut in
                let whole = cut.filter { !$0.isPrefix }.count
                if wholeWords == nil, whole >= parts - (typing ? 1 : 0) { wholeWords = cut }
                let sections = together(cut)
                guard sections > 0 else { return }
                if best.map({ (whole, sections) > ($0.whole, $0.sections) }) ?? true {
                    best = (cut, whole, sections)
                }
            }
            if let best { return best.cut }
        }
        return wholeWords
    }

    /// Bitset over chunk indexes of the sections holding any of `terms`.
    private func chunkBits(of terms: [String]) -> [UInt64] {
        var bits = [UInt64](repeating: 0, count: data.chunks.count / 64 + 1)
        for term in terms {
            for (chunk, _) in data.postings[term] ?? [] {
                bits[Int(chunk) >> 6] |= 1 << (UInt64(chunk) & 63)
            }
        }
        return bits
    }

    /// Indexed terms closest to a word that matched nothing — the last resort
    /// before an empty results list. One dropped or swapped letter is the most
    /// common way a search misses, and it is indistinguishable from a term the
    /// vault simply doesn't hold unless the distance is measured.
    private func nearest(_ term: String, atMost edits: Int) -> (terms: [String], distance: Int)? {
        let scalars = Array(term.unicodeScalars)
        guard scalars.count >= VaultIndex.minFuzzyLength else { return nil }
        let budget = min(edits, scalars.count >= VaultIndex.twoEditLength ? 2 : 1)
        editBudgetForTest = budget
        return data.trie.nearest(scalars, maxDistance: budget, limit: VaultIndex.maxPrefixExpansion)
    }

    // MARK: - Pure helpers

    /// Ceiling on indexed notes. The quick-switcher's default cap of 2000 exists
    /// to keep a picker responsive; applying it here would silently drop notes
    /// out of search, which is worse than a slower background scan.
    static let maxNotes = 50_000

    /// Notes worth indexing, relative to `root`.
    static func notePaths(root: String, includeText: Bool) -> [String] {
        var extensions: Set<String> = ["md", "markdown"]
        if includeText { extensions.insert("txt") }
        return DirectoryScanner.scan(root: root, limit: maxNotes).filter {
            extensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    /// Lowercased, accent-folded alphanumeric runs of 2+ characters. Accented
    /// Latin letters are alphanumeric, so Spanish and English notes tokenize the
    /// same way.
    static func tokenize(_ text: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var accented = false

        func flush() {
            defer { current = ""; accented = false }
            guard current.count >= 2 else { return }
            let lowered = current.lowercased()
            terms.append(accented ? fold(lowered) : lowered)
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
                if !scalar.isASCII { accented = true }
            } else if !current.isEmpty {
                flush()
            }
        }
        flush()
        return terms
    }

    /// Strip accents, so a note about "Rubén" is reachable by typing "ruben".
    /// Index and query both fold, so the two always meet. Every mark goes, in
    /// every script — a per-letter exception list would only be right for the
    /// language it was written for.
    static func fold(_ term: String) -> String {
        guard term.unicodeScalars.contains(where: { !$0.isASCII }) else { return term }
        return term.folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Split a note into heading sections, each carrying its file title and
    /// heading trail. Prepending that context is what makes a section reading
    /// "it didn't work" findable — on its own it is unrecoverable noise.
    static func chunks(of text: String, path: String) -> [(VaultChunk, [String: Int32])] {
        let lines = text.components(separatedBy: "\n")
        let docTitle = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let headings = Outline.items(from: lines)

        // (startLine, endLine, heading trail) per section; content before the
        // first heading becomes the note's intro section.
        var sections: [(start: Int, end: Int, trail: String)] = []
        if headings.first?.line != 0 {
            sections.append((0, headings.first?.line ?? lines.count, docTitle))
        }
        var trail: [String] = []
        for (i, h) in headings.enumerated() {
            trail.removeSubrange(min(trail.count, max(0, h.level - 1))...)
            trail.append(h.title)
            let end = i + 1 < headings.count ? headings[i + 1].line : lines.count
            sections.append((h.line, end, ([docTitle] + trail).joined(separator: " › ")))
        }

        return sections.compactMap { section in
            let body = lines[section.start..<min(section.end, lines.count)]
            let joined = body.joined(separator: "\n")
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            // The trail is indexed alongside the body, so a query matching the
            // note or heading name ranks its sections.
            var counts: [String: Int32] = [:]
            for term in tokenize(section.trail) + tokenize(joined) { counts[term, default: 0] += 1 }
            guard !counts.isEmpty else { return nil }

            let preview = body.first(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            })?.trimmingCharacters(in: .whitespaces) ?? ""

            let total = counts.values.reduce(0, +)
            let chunk = VaultChunk(path: path, title: section.trail, line: section.start,
                                   preview: String(preview.prefix(120)), length: Int(total))
            return (chunk, counts)
        }
    }

    // MARK: - State plumbing

    private func report(generation: Int, done: Int, total: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.state = .indexing(done: done, total: total)
            self.onChange?()
        }
    }

    /// Hand a finished snapshot to the main queue. All that happens there is an
    /// assignment, so a build never competes with the editor for the thread the
    /// cursor is drawn on.
    private func publish(generation: Int, _ snapshot: Snapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.data = snapshot
            self.state = .ready(chunks: snapshot.chunks.count, files: snapshot.files)
            self.onChange?()
        }
    }

    /// Test seam: index in-memory notes, skipping the filesystem scan and the
    /// background queue, so ranking can be asserted deterministically.
    func indexForTest(notes: [(path: String, text: String)]) {
        var built: [VaultChunk] = []
        var terms: [[String: Int32]] = []
        for note in notes {
            for (chunk, counts) in VaultIndex.chunks(of: note.text, path: note.path) {
                built.append(chunk)
                terms.append(counts)
            }
        }
        data = Snapshot(chunks: built, terms: terms, files: notes.count)
        state = .ready(chunks: built.count, files: notes.count)
    }

    private func setState(_ new: VaultIndexState) {
        if Thread.isMainThread {
            state = new
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.state = new
                self?.onChange?()
            }
        }
    }
}
