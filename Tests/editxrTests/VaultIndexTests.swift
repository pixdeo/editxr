import XCTest
@testable import editxr

/// Chunking, tokenizing and BM25 ranking. All of it runs off in-memory notes via
/// `indexForTest`, so nothing here touches the filesystem or the build queue.
final class VaultIndexTests: XCTestCase {

    // MARK: - Tokenizer

    func testTokenizerLowercasesAndDropsSingleCharacterRuns() {
        XCTAssertEqual(VaultIndex.tokenize("Deep Work, a Guide!"), ["deep", "work", "guide"])
    }

    func testTokenizerFoldsAccentsSoTypingWithoutThemWorks() {
        // Spanish notes have to tokenize like English ones, not shatter on
        // accents — and nobody types the accents into a search box.
        XCTAssertEqual(VaultIndex.tokenize("sesión de programación"),
                       ["sesion", "de", "programacion"])
    }

    func testFoldingIsScriptAgnostic() {
        // One rule for every mark, not a list of letters that happens to fit one
        // language. A few unrelated words collide ("año" with "ano"); that is
        // cheaper than a query with an accent in it finding nothing.
        XCTAssertEqual(VaultIndex.tokenize("El niño cumplió un año"),
                       ["el", "nino", "cumplio", "un", "ano"])
        XCTAssertEqual(VaultIndex.tokenize("MAÑANA"), ["manana"])
        // ß is a letter rather than an accented one, so folding leaves it alone;
        // a query typed "grusse" reaches it through the edit-distance pass.
        XCTAssertEqual(VaultIndex.tokenize("Grüße naïve Genève"), ["gruße", "naive", "geneve"])
    }

    func testTokenizerSplitsOnPunctuationAndMarkup() {
        XCTAssertEqual(VaultIndex.tokenize("**bold** `code` [link](x.md)"),
                       ["bold", "code", "link", "md"])
    }

    func testTokenizerOnEmptyInput() {
        XCTAssertTrue(VaultIndex.tokenize("   \n\t ").isEmpty)
    }

    // MARK: - Chunking

    func testEachHeadingBecomesItsOwnSection() {
        let text = """
        # Alpha
        one
        ## Beta
        two
        # Gamma
        three
        """
        let chunks = VaultIndex.chunks(of: text, path: "notes/Doc.md").map(\.0)
        XCTAssertEqual(chunks.map(\.title),
                       ["Doc › Alpha", "Doc › Alpha › Beta", "Doc › Gamma"])
        XCTAssertEqual(chunks.map(\.line), [0, 2, 4])
    }

    func testContentBeforeTheFirstHeadingBecomesAnIntroSection() {
        let text = """
        loose intro text
        # Alpha
        body
        """
        let chunks = VaultIndex.chunks(of: text, path: "Doc.md").map(\.0)
        XCTAssertEqual(chunks.first?.title, "Doc")
        XCTAssertEqual(chunks.first?.line, 0)
    }

    func testANoteWithoutHeadingsIsOneSection() {
        let chunks = VaultIndex.chunks(of: "just some prose", path: "Doc.md").map(\.0)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].title, "Doc")
    }

    func testEmptyAndWhitespaceOnlySectionsAreDropped() {
        let text = """
        # Alpha

        # Beta
        real content
        """
        let chunks = VaultIndex.chunks(of: text, path: "Doc.md").map(\.0)
        // "# Alpha" still carries its own heading words, so it survives; a note
        // that is nothing but blank lines must not produce a chunk at all.
        XCTAssertTrue(VaultIndex.chunks(of: "\n\n  \n", path: "Empty.md").isEmpty)
        XCTAssertEqual(chunks.count, 2)
    }

    func testDeeperHeadingTrailUnwindsWhenTheLevelDrops() {
        let text = """
        # A
        x
        ## B
        y
        ### C
        z
        ## D
        w
        """
        let chunks = VaultIndex.chunks(of: text, path: "Doc.md").map(\.0)
        XCTAssertEqual(chunks.map(\.title), [
            "Doc › A", "Doc › A › B", "Doc › A › B › C", "Doc › A › D",
        ])
    }

    func testPreviewSkipsTheHeadingLine() {
        let chunks = VaultIndex.chunks(of: "# Title\nfirst body line", path: "Doc.md").map(\.0)
        XCTAssertEqual(chunks[0].preview, "first body line")
    }

    // MARK: - Search

    private func index(_ notes: [(String, String)]) -> VaultIndex {
        let index = VaultIndex()
        index.indexForTest(notes: notes.map { (path: $0.0, text: $0.1) })
        return index
    }

    func testSearchRanksTheMatchingSectionFirst() {
        let index = self.index([
            ("Cooking.md", "# Pasta\nboil water and add salt"),
            ("Work.md", "# Deploy\nthe rollback script failed on staging"),
            ("Trip.md", "# Packing\nsocks and a toothbrush"),
        ])
        let hits = index.search("rollback staging", limit: 5)
        XCTAssertEqual(hits.first?.chunk.path, "Work.md")
    }

    func testSearchMatchesTheNoteTitleNotJustTheBody() {
        // The file title is indexed with every section, which is what makes a
        // section reading "it didn't work" reachable at all.
        let index = self.index([
            ("Spaced Repetition.md", "# Notes\nit did not work for me"),
            ("Other.md", "# Notes\nunrelated content here"),
        ])
        let hits = index.search("spaced repetition", limit: 5)
        XCTAssertEqual(hits.first?.chunk.path, "Spaced Repetition.md")
    }

    func testSearchIgnoresCaseAndAccents() {
        let index = self.index([("Diario.md", "# Sesión\nprogramación por la mañana")])
        XCTAssertEqual(index.search("PROGRAMACIÓN", limit: 5).count, 1)
        // The point of folding: the accents live in the note, not in the query.
        XCTAssertEqual(index.search("programacion", limit: 5).count, 1)
        XCTAssertEqual(index.search("sesion", limit: 5).count, 1)
    }

    func testSearchFindsAnAccentedNameTypedWithoutItsAccent() {
        let index = self.index([
            ("Salud.md", "# Cáncer de Rubén\ncontrol en marzo"),
            ("Other.md", "# Notes\nunrelated content"),
        ])
        for query in ["ruben", "rubén", "RUBEN", "cancer ruben"] {
            XCTAssertEqual(index.search(query, limit: 5).first?.chunk.path, "Salud.md",
                           "“\(query)” did not find the note")
        }
    }

    // MARK: - What a hit matched on

    func testMatchTokensReportTheWordsAQueryResolvedTo() {
        let index = self.index([("Salud.md", "# Cáncer de Rubén\ncontrol en marzo")])

        // A finished word stands for itself, folded the way the index folds it.
        XCTAssertEqual(index.matchTokens(for: "rubén "),
                       [TextMatch(text: "ruben", isPrefix: false)])

        // A word still being typed stands for its prefix, not for the two
        // hundred completions it might have.
        XCTAssertEqual(index.matchTokens(for: "rub"),
                       [TextMatch(text: "rub", isPrefix: true)])

        // A repaired word reports what it was repaired to — that is how the
        // results show the typo was forgiven.
        XCTAssertEqual(index.matchTokens(for: "contol "),
                       [TextMatch(text: "control", isPrefix: false)])

        // A split reports each piece.
        XCTAssertEqual(index.matchTokens(for: "cancerruben "),
                       [TextMatch(text: "cancer", isPrefix: false),
                        TextMatch(text: "ruben", isPrefix: false)])
    }

    func testMatchTokensAreCappedPerWord() {
        let notes = (0..<50).map { ("n\($0).md", "# X\nprefixword\($0)") }
        let tokens = index(notes).matchTokens(for: "prefixwordx ")
        XCTAssertLessThanOrEqual(tokens.count, VaultIndex.maxMarkedTerms)
    }

    // MARK: - Words typed without their spaces

    func testAGluedQueryIsCutIntoIndexedWords() {
        // "cancerruben" is one unknown term; it only resolves once it is split.
        let index = self.index([
            ("Salud.md", "# Cáncer de Rubén\ncontrol en marzo"),
            ("Other.md", "# Notes\nunrelated content"),
        ])
        for query in ["cancerruben ", "cancerde ", "rubencancer "] {
            XCTAssertEqual(index.search(query, limit: 5).first?.chunk.path, "Salud.md",
                           "“\(query)” did not find the note")
        }
    }

    func testAGluedQueryResolvesWhileTheSecondWordIsStillBeingTyped() {
        // Mid-typing the tail is a prefix, so the split has to allow one.
        let index = self.index([("Salud.md", "# Cáncer de Rubén\ncontrol en marzo")])
        for typed in ["cancerr", "cancerru", "cancerrub", "cancerruben"] {
            XCTAssertEqual(index.search(typed, limit: 5).count, 1, "typing “\(typed)” found nothing")
        }
    }

    func testAWordThatSplitsIntoNothingIndexedStillFindsNothing() {
        // Splitting must not turn every miss into a hit made of fragments.
        let index = self.index([("A.md", "# X\nhello world")])
        XCTAssertTrue(index.search("zzzznotpresent ", limit: 5).isEmpty)
    }

    // MARK: - Misspelled words

    func testAMisspelledWordStillFindsTheNote() {
        let index = self.index([
            ("ML.md", "# Transformer\nattention is all you need"),
            ("Other.md", "# Notes\nunrelated content"),
        ])
        // A dropped letter, a doubled one, a swap, a wrong one.
        for query in ["transfomer", "transformmer", "transfromer", "transfarmer"] {
            XCTAssertEqual(index.search(query, limit: 5).first?.chunk.path, "ML.md",
                           "“\(query)” did not find the note")
        }
    }

    func testAnExactMatchIsNeverReplacedByANearOne() {
        let index = self.index([
            ("Exact.md", "# X\nattention"),
            ("Near.md", "# X\nattenction attenction attenction"),
        ])
        XCTAssertEqual(index.search("attention ", limit: 5).first?.chunk.path, "Exact.md")
    }

    func testShortWordsAreMatchedExactlyOnly() {
        // At three characters an edit is a third of the word: "cat" would reach
        // "car", "can" and "cut", which is not a search any more.
        let index = self.index([("A.md", "# X\nthe car is red")])
        XCTAssertTrue(index.search("cat ", limit: 5).isEmpty)
    }

    func testOnlyTheClosestSpellingsAreUsed() {
        // "attention" is one edit from the query and "attentional" is two; once
        // something is one edit away the farther candidates are noise.
        let index = self.index([
            ("One.md", "# X\nattention"),
            ("Two.md", "# X\nattentional attentional attentional"),
        ])
        let hits = index.search("attenton ", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.chunk.path, "One.md")
    }

    func testAMisspellingBeatsASplitIntoFragments() {
        // The whole reason the two repairs are compared: a vault holding "tran",
        // "fo" and "mer" as words can split "tranfomer" cleanly, and that debris
        // must not bury the note the user meant.
        let index = self.index([
            ("ML.md", "# Transformer\nattention is all you need"),
            ("Misc.md", "# Notas\ntran fo mer transporte forma merienda"),
        ])
        XCTAssertEqual(index.search("tranfomer", limit: 5).first?.chunk.path, "ML.md")
        XCTAssertEqual(index.search("tranfomer ", limit: 5).first?.chunk.path, "ML.md")
    }

    func testASplitStillWinsWhenItIsTheCheaperExplanation() {
        // One space to insert beats two letters to fix, so a real compound is
        // not re-read as a misspelling of one of its halves.
        let index = self.index([
            ("Salud.md", "# Cáncer de Rubén\ncontrol en marzo"),
            ("Otro.md", "# Cancion\nletra"),
        ])
        XCTAssertEqual(index.search("cancerruben ", limit: 5).first?.chunk.path, "Salud.md")
    }

    func testAnIndexedWordIsNeverSplitApart() {
        // "rollback" is a term of its own; it must not be scored as roll + back.
        let index = self.index([
            ("Exact.md", "# X\nrollback"),
            ("Parts.md", "# X\nroll back roll back"),
        ])
        XCTAssertEqual(index.search("rollback ", limit: 5).first?.chunk.path, "Exact.md")
    }

    func testSearchRespectsTheResultLimit() {
        let notes = (0..<20).map { ("n\($0).md", "# Section\nshared keyword here") }
        let hits = index(notes).search("shared keyword", limit: 5)
        XCTAssertEqual(hits.count, 5)
    }

    func testSearchReturnsNothingForAnUnknownTerm() {
        let index = self.index([("A.md", "# X\nhello world")])
        XCTAssertTrue(index.search("zzzznotpresent", limit: 5).isEmpty)
    }

    func testSearchOnAnEmptyIndexIsEmptyRatherThanACrash() {
        XCTAssertTrue(VaultIndex().search("anything", limit: 5).isEmpty)
    }

    func testEmptyQueryReturnsNothing() {
        let index = self.index([("A.md", "# X\nhello world")])
        XCTAssertTrue(index.search("   ", limit: 5).isEmpty)
    }

    // MARK: - Prefix matching while typing

    func testAPartiallyTypedWordMatchesAsAPrefix() {
        // Without this a live search shows "no matches" for most of the typing.
        let index = self.index([("Work.md", "# Deploy\nthe rollback failed")])
        for typed in ["ro", "rol", "roll", "rollb", "rollbac", "rollback"] {
            XCTAssertEqual(index.search(typed, limit: 5).count, 1, "typing “\(typed)” found nothing")
        }
    }

    func testOnlyTheTrailingWordIsTreatedAsAPrefix() {
        // "roll" completed by a space is a finished word, so it must match
        // exactly — otherwise every earlier word silently widens too.
        let index = self.index([("A.md", "# X\nrollback notes")])
        XCTAssertTrue(index.search("roll ", limit: 5).isEmpty)
        XCTAssertEqual(index.search("roll", limit: 5).count, 1)
    }

    func testPrefixHitsDoNotOutrankAnExactHit() {
        // One chunk holds several words sharing the prefix; taking the best
        // alternative rather than summing them keeps the exact match on top.
        let index = self.index([
            ("Spread.md", "# X\ndeploying deployment deployer deploys"),
            ("Exact.md", "# Deploy\ndeploy"),
        ])
        XCTAssertEqual(index.search("deploy", limit: 5).first?.chunk.path, "Exact.md")
    }

    func testPrefixExpansionIsCapped() {
        // A two-letter prefix in a real vault matches thousands of terms; the cap
        // is what keeps one keystroke bounded.
        let notes = (0..<300).map { ("n\($0).md", "# X\nprefixword\($0)") }
        let hits = index(notes).search("prefixword", limit: 400)
        XCTAssertLessThanOrEqual(hits.count, VaultIndex.maxPrefixExpansion)
        XCTAssertGreaterThan(hits.count, 0)
    }

    func testRareTermOutranksACommonOne() {
        // IDF has to do its job: every note mentions "meeting", one mentions
        // "escalation", so the query should land on the latter.
        var notes = (0..<10).map { ("common\($0).md", "# Notes\nmeeting notes here") }
        notes.append(("rare.md", "# Notes\nmeeting about the escalation"))
        let hits = index(notes).search("meeting escalation", limit: 3)
        XCTAssertEqual(hits.first?.chunk.path, "rare.md")
    }

    func testClearingResetsToIdle() {
        let index = self.index([("A.md", "# X\nhello world")])
        XCTAssertTrue(index.isReady)
        index.clear()
        XCTAssertFalse(index.isReady)
        XCTAssertEqual(index.state, .idle)
        XCTAssertTrue(index.search("hello", limit: 5).isEmpty)
    }

    // MARK: - State reporting

    func testIndexingStateReportsProgressOnTheStatusBar() {
        XCTAssertEqual(VaultIndexState.indexing(done: 3, total: 10).statusText, "indexing vault 3/10")
        XCTAssertEqual(VaultIndexState.indexing(done: 3, total: 10).detail, "Indexing 3/10 files…")
    }

    func testReadyAndIdleStayQuietOnTheStatusBar() {
        // A permanent "indexed" badge would be noise; the settings menu carries it.
        XCTAssertNil(VaultIndexState.ready(chunks: 10, files: 2).statusText)
        XCTAssertNil(VaultIndexState.idle.statusText)
    }

    func testEveryStateHasADetailForTheSettingsMenu() {
        let states: [VaultIndexState] = [
            .idle, .indexing(done: 1, total: 2), .ready(chunks: 3, files: 1), .failed("nope"),
        ]
        for state in states { XCTAssertFalse(state.detail.isEmpty) }
    }

    func testFailureSurfacesOnTheStatusBar() {
        XCTAssertEqual(VaultIndexState.failed("disk").statusText, "vault index failed: disk")
    }

    // MARK: - Background build

    func testBuildScansRealFilesAndReportsReady() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editxr-build-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("# Deploy\nthe rollback failed".utf8)
            .write(to: root.appendingPathComponent("Work.md"))
        try Data("# Pasta\nboil water".utf8)
            .write(to: root.appendingPathComponent("sub/Cooking.md"))
        try Data("not a note".utf8).write(to: root.appendingPathComponent("ignore.json"))
        defer { try? fm.removeItem(at: root) }

        let index = VaultIndex()
        let done = expectation(description: "index ready")
        index.onChange = { if index.isReady { done.fulfill() } }
        index.build(root: root.path, includeText: true)
        wait(for: [done], timeout: 5)

        XCTAssertEqual(index.state, .ready(chunks: 2, files: 2))
        XCTAssertEqual(index.search("rollback", limit: 5).first?.chunk.path, "Work.md")
        XCTAssertEqual(index.search("boil", limit: 5).first?.chunk.path, "sub/Cooking.md")
    }

    func testIndexingLeavesTheMainQueueFreeForKeystrokes() throws {
        // Two things used to freeze the editor while a vault indexed, and both
        // are about the main queue rather than the indexing: the postings and
        // the trie were assembled there, and every progress report redrew the
        // screen — dozens of redraws queued faster than they could run, with
        // keystrokes waiting behind them.
        //
        // So `onChange` here costs what a redraw costs, and what is measured is
        // how long a keystroke waits to be handled, which is the thing the user
        // feels.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editxr-latency-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for i in 0..<1000 {
            let body = "# Nota \(i)\n"
                + (0..<40).map { "palabra\(i)x\($0) reunion\(i % 97)" }.joined(separator: " ")
            try Data(body.utf8).write(to: root.appendingPathComponent("n\(i).md"))
        }

        let index = VaultIndex()
        let ready = expectation(description: "index ready")
        var updates = 0
        index.onChange = {
            updates += 1
            let redrawEnds = Date().addingTimeInterval(0.015)   // a full-screen draw
            while Date() < redrawEnds {}
            if index.isReady { ready.fulfill() }
        }

        var worstWait = 0.0
        let keystrokes = DispatchSource.makeTimerSource(queue: .main)
        keystrokes.schedule(deadline: .now(), repeating: .milliseconds(30))
        keystrokes.setEventHandler {
            let pressed = Date()
            DispatchQueue.main.async { worstWait = max(worstWait, Date().timeIntervalSince(pressed)) }
        }
        keystrokes.resume()

        let started = Date()
        index.build(root: root.path, includeText: false)
        wait(for: [ready], timeout: 60)
        keystrokes.cancel()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(worstWait, 0.15, "a keystroke waited \(Int(worstWait * 1000))ms")
        // Progress is rationed by time, so the count follows how long the build
        // took — not how many notes it happened to contain.
        XCTAssertLessThanOrEqual(Double(updates), elapsed / VaultIndex.progressIntervalForTest + 4,
                                 "\(updates) updates in \(Int(elapsed * 1000))ms is a redraw storm")
    }

    func testBuildingAnEmptyFolderEndsReadyRatherThanStuck() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editxr-empty-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let index = VaultIndex()
        let done = expectation(description: "index ready")
        index.onChange = { if index.isReady { done.fulfill() } }
        index.build(root: root.path, includeText: true)
        wait(for: [done], timeout: 5)

        XCTAssertEqual(index.state, .ready(chunks: 0, files: 0))
    }

    // MARK: - File selection

    func testOnlyNoteExtensionsAreIndexed() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editxr-index-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        for name in ["a.md", "b.txt", "c.swift", "d.markdown", "e.json"] {
            try? Data("x".utf8).write(to: root.appendingPathComponent(name))
        }

        let withText = VaultIndex.notePaths(root: root.path, includeText: true).sorted()
        XCTAssertEqual(withText, ["a.md", "b.txt", "d.markdown"])

        let withoutText = VaultIndex.notePaths(root: root.path, includeText: false).sorted()
        XCTAssertEqual(withoutText, ["a.md", "d.markdown"])
    }

    func testScanIsNotCappedAtTheQuickSwitchersLimit() throws {
        // A real vault runs past 2000 notes. The picker's cap is a UI decision;
        // reusing it here would drop notes out of search with no warning.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editxr-cap-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let count = 2050
        let body = Data("# Note\nbody".utf8)
        for i in 0..<count {
            try body.write(to: root.appendingPathComponent("note\(i).md"))
        }

        XCTAssertEqual(VaultIndex.notePaths(root: root.path, includeText: true).count, count)
    }
}
