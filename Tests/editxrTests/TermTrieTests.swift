import XCTest
@testable import editxr

/// The vocabulary structure behind live search: prefix completion while a word
/// is being typed, and nearest-terms lookup when it matches nothing.
final class TermTrieTests: XCTestCase {

    private func trie(_ terms: [String]) -> TermTrie {
        TermTrie(terms: terms.sorted())
    }

    // MARK: - Prefix

    func testCompletionsReturnEveryTermUnderThePrefix() {
        let trie = self.trie(["deploy", "deployment", "deploys", "deputy", "roll"])
        XCTAssertEqual(Set(trie.completions(of: "deploy", limit: 10)),
                       ["deploy", "deployment", "deploys"])
    }

    func testCompletionsAreShortestFirst() {
        // The cap has to keep the closest completions: a half-typed word is
        // likelier to be the short term than a long one sharing its start.
        let trie = self.trie(["deployment", "deploy", "deployments"])
        XCTAssertEqual(trie.completions(of: "dep", limit: 2), ["deploy", "deployment"])
    }

    func testCompletionsOfAnUnknownPrefixAreEmpty() {
        let trie = self.trie(["deploy", "rollback"])
        XCTAssertTrue(trie.completions(of: "zz", limit: 10).isEmpty)
        XCTAssertTrue(trie.completions(of: "deployx", limit: 10).isEmpty)
    }

    func testTheWholeVocabularyIsReachableFromAnEmptyPrefix() {
        let trie = self.trie(["a", "ab", "b"])
        XCTAssertEqual(Set(trie.completions(of: "", limit: 10)), ["a", "ab", "b"])
    }

    func testSharedPrefixesDoNotSwallowEachOther() {
        let trie = self.trie(["car", "cart", "carton", "cat"])
        XCTAssertEqual(Set(trie.completions(of: "car", limit: 10)), ["car", "cart", "carton"])
        XCTAssertEqual(trie.completions(of: "cat", limit: 10), ["cat"])
    }

    // MARK: - Near misses

    private func nearest(_ trie: TermTrie, _ word: String, max: Int = 2) -> (terms: [String], distance: Int)? {
        trie.nearest(Array(word.unicodeScalars), maxDistance: max, limit: 50)
    }

    func testEverySingleEditIsMatched() {
        let trie = self.trie(["transformer", "attention", "embedding"])
        for typo in ["transfomer", "transformmer", "transforme", "transfarmer"] {
            XCTAssertEqual(nearest(trie, typo)?.terms, ["transformer"], "“\(typo)” missed")
            XCTAssertEqual(nearest(trie, typo)?.distance, 1)
        }
    }

    func testTwoEditsAreMatchedWhenAllowed() {
        let trie = self.trie(["transformer"])
        XCTAssertEqual(nearest(trie, "tranfomer")?.terms, ["transformer"])
        XCTAssertEqual(nearest(trie, "tranfomer")?.distance, 2)
        XCTAssertNil(nearest(trie, "tranfomer", max: 1))
    }

    func testOnlyTheNearestTermsAreReturned() {
        // "attention" is one edit away and "attentional" is two; once something
        // is one edit away the farther candidates are noise beside it.
        let trie = self.trie(["attention", "attentional", "attenuation"])
        let hit = nearest(trie, "attenton")
        XCTAssertEqual(hit?.terms, ["attention"])
        XCTAssertEqual(hit?.distance, 1)
    }

    func testTermsAtTheSameDistanceAreAllReturned() {
        let trie = self.trie(["cat", "cot", "cut", "dog"])
        let hit = nearest(trie, "cit", max: 1)
        XCTAssertEqual(Set(hit?.terms ?? []), ["cat", "cot", "cut"])
        XCTAssertEqual(hit?.distance, 1)
    }

    func testAFarWordMatchesNothing() {
        let trie = self.trie(["transformer", "attention"])
        XCTAssertNil(nearest(trie, "elephant"))
    }

    func testAnExactTermIsItsOwnNearestMatch() {
        let trie = self.trie(["transformer", "transformers"])
        let hit = nearest(trie, "transformer")
        XCTAssertEqual(hit?.terms, ["transformer"])
        XCTAssertEqual(hit?.distance, 0)
    }

    func testNearestOnAnEmptyVocabularyOrWord() {
        XCTAssertNil(nearest(trie([]), "anything"))
        XCTAssertNil(nearest(trie(["anything"]), ""))
    }

    func testAccentedAndNonLatinTermsWalkTheSameTree() {
        // The trie is keyed by scalar, so nothing about it assumes ASCII.
        let trie = self.trie(["mañana", "反応", "reunión"])
        XCTAssertEqual(trie.completions(of: "ma", limit: 5), ["mañana"])
        XCTAssertEqual(nearest(trie, "manana", max: 1)?.terms, ["mañana"])
        XCTAssertEqual(trie.completions(of: "反", limit: 5), ["反応"])
    }

    func testNearestAgreesWithTheFullMatrixOnRandomWords() {
        var seed: UInt64 = 42
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        func word(_ maxLength: Int) -> String {
            String((0...next(maxLength)).map { _ in Array("abc")[next(3)] })
        }
        func distance(_ a: [Character], _ b: [Character]) -> Int {
            var row = Array(0...b.count)
            for i in 0..<a.count {
                var diagonal = row[0]
                row[0] = i + 1
                for j in 0..<b.count {
                    let cost = min(row[j + 1] + 1, row[j] + 1, diagonal + (a[i] == b[j] ? 0 : 1))
                    diagonal = row[j + 1]
                    row[j + 1] = cost
                }
            }
            return row[b.count]
        }

        let vocabulary = (0..<150).map { _ in word(9) }
        let trie = self.trie(vocabulary)
        for _ in 0..<500 {
            let query = word(11)
            let budget = 1 + next(3)
            let distances = Set(vocabulary).map { ($0, distance(Array(query), Array($0))) }
            let closest = distances.map(\.1).min() ?? 0
            let hit = trie.nearest(Array(query.unicodeScalars), maxDistance: budget, limit: 1000)
            if closest > budget {
                XCTAssertNil(hit, "“\(query)” within \(budget)")
            } else {
                XCTAssertEqual(hit?.distance, closest, "“\(query)” within \(budget)")
                XCTAssertEqual(Set(hit?.terms ?? []),
                               Set(distances.filter { $0.1 == closest }.map(\.0)),
                               "“\(query)” within \(budget)")
            }
        }
    }

    func testNearestOnlyFillsTheCellsItsBudgetCanReach() {
        // Cells further from the diagonal than the budget can't hold a match, so
        // a long word must cost the width of the band rather than its own length.
        let trie = self.trie(["abcdefghijklmnopqrstuvwxyz", "abcdefghijklmnopqrstuvwxyy"])
        _ = nearest(trie, "abcdefghijklmnopqrstuvwxyq", max: 1)
        XCTAssertLessThanOrEqual(trie.cellCountForTest, trie.nodeCountForTest * 3)
    }

    func testDuplicateTermsAreStoredOnce() {
        let trie = self.trie(["deploy", "deploy", "deploys"])
        XCTAssertEqual(trie.completions(of: "deploy", limit: 10), ["deploy", "deploys"])
    }
}
