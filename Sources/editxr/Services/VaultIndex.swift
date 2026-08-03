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

    private var data = Snapshot()

    /// Ceiling on how many completions one prefix contributes, so a two-letter
    /// query can't turn a keystroke into a full-vocabulary scan.
    static let maxPrefixExpansion = 200

    /// Bounds on cutting a glued word back into indexed terms. Two characters is
    /// the shortest indexed term, and a word that needs more than four pieces is
    /// far likelier to be noise assembled out of fragments than a real compound.
    static let minSegmentPart = 2
    static let maxSegmentParts = 4
    static let maxSegmentLength = 32

    /// Bounds on matching a misspelled word. Below four characters an edit is
    /// most of the word — "note" and "nope" are one apart — so short words are
    /// only ever matched exactly, and the second edit is earned by length.
    static let minFuzzyLength = 4
    static let twoEditLength = 8

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
    func search(_ rawQuery: String, limit: Int) -> [VaultHit] {
        let words = resolve(rawQuery)
        guard !words.isEmpty, !data.chunks.isEmpty else { return [] }

        let k1 = 1.2, b = 0.75
        let n = Double(data.chunks.count)
        var scores: [Int32: Double] = [:]

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
            for (chunkIndex, score) in best { scores[chunkIndex, default: 0] += score }
        }

        return scores
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { VaultHit(chunk: data.chunks[Int($0.key)], score: $0.value) }
    }

    /// Turn a raw query into the words to score.
    ///
    /// Each word is tried as itself first. Only when the index holds nothing for
    /// it do the repairs run — a word run together with its neighbour, or a
    /// misspelling — so an ordinary query never pays for either.
    func resolve(_ rawQuery: String) -> [ResolvedWord] {
        let terms = VaultIndex.tokenize(rawQuery)
        guard !terms.isEmpty, !data.chunks.isEmpty else { return [] }

        // Only the trailing word expands, and only while the query still ends
        // mid-word: a word finished with a space is a word the user means.
        let isTyping = rawQuery.unicodeScalars.last.map(CharacterSet.alphanumerics.contains) ?? false
        var words: [ResolvedWord] = []
        for (i, term) in terms.enumerated() {
            let typing = isTyping && i == terms.count - 1
            if typing {
                let completions = expand(prefix: term)
                if !completions.isEmpty {
                    words.append(ResolvedWord(typed: term, isPrefix: true, terms: completions))
                    continue
                }
            } else if data.postings[term] != nil {
                words.append(ResolvedWord(typed: term, isPrefix: false, terms: [term]))
                continue
            }
            words.append(contentsOf: repair(term, typing: typing))
        }
        return words
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
        let split = segment(term, prefixTail: typing)
        let near = nearest(term)

        if let near, near.distance <= (split.map { $0.count - 1 } ?? Int.max) {
            return [ResolvedWord(typed: term, isPrefix: false, terms: near.terms)]
        }
        guard let split else { return [] }
        return split.map {
            ResolvedWord(typed: $0.typed, isPrefix: $0.isPrefix, terms: $0.terms)
        }
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

    /// Cut a glued word into indexed terms, fewest pieces first — "cancerruben"
    /// into "cancer" + "ruben" — or nil when no clean cut exists.
    ///
    /// `prefixTail` lets the last piece match as a prefix, so a compound still
    /// resolves while its second half is being typed ("cancerrub").
    private func segment(_ term: String, prefixTail: Bool) -> [ResolvedWord]? {
        let chars = Array(term)
        let n = chars.count
        let minPart = VaultIndex.minSegmentPart
        guard n >= 2 * minPart, n <= VaultIndex.maxSegmentLength else { return nil }

        // best[i] = fewest-piece split of the first i characters, nil if none.
        // Every prefix it reads is already final: pieces are at least minPart
        // long, so `start` was settled on an earlier pass.
        var best: [[String]?] = Array(repeating: nil, count: n + 1)
        best[0] = []
        for end in minPart...n {
            for start in 0...(end - minPart) {
                guard let head = best[start], head.count < VaultIndex.maxSegmentParts else { continue }
                let piece = String(chars[start..<end])
                guard data.postings[piece] != nil else { continue }
                if best[end] == nil || head.count + 1 < best[end]!.count { best[end] = head + [piece] }
            }
        }
        if let whole = best[n], whole.count >= 2 {
            return whole.map { ResolvedWord(typed: $0, isPrefix: false, terms: [$0]) }
        }
        guard prefixTail else { return nil }

        // Longest head that splits cleanly, so the prefix left over is the
        // shortest — and therefore the least ambiguous — tail. A one-character
        // tail is allowed here: it is a prefix of a real term, not a term.
        for cut in stride(from: n - 1, through: minPart, by: -1) {
            guard let head = best[cut], !head.isEmpty else { continue }
            let typed = String(chars[cut...])
            let tail = expand(prefix: typed)
            guard !tail.isEmpty else { continue }
            return head.map { ResolvedWord(typed: $0, isPrefix: false, terms: [$0]) }
                + [ResolvedWord(typed: typed, isPrefix: true, terms: tail)]
        }
        return nil
    }

    /// Indexed terms closest to a word that matched nothing — the last resort
    /// before an empty results list. One dropped or swapped letter is the most
    /// common way a search misses, and it is indistinguishable from a term the
    /// vault simply doesn't hold unless the distance is measured.
    private func nearest(_ term: String) -> (terms: [String], distance: Int)? {
        let scalars = Array(term.unicodeScalars)
        guard scalars.count >= VaultIndex.minFuzzyLength else { return nil }
        let budget = scalars.count >= VaultIndex.twoEditLength ? 2 : 1
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
