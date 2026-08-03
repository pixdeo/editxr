import Foundation

/// Prefix tree over an index vocabulary, answering the two questions a live
/// search asks about a word that has no exact match: which terms continue it,
/// and — when nothing does — which terms are a letter or two away from it.
///
/// Both are walks of the same tree. A word and the vocabulary share their
/// prefixes, so one descent settles every term underneath at once; a linear
/// scan re-reads the whole vocabulary per query and re-derives those shared
/// prefixes for each term it looks at.
///
/// Nodes live in one flat array and address each other by index. Children hang
/// off a sibling chain rather than a per-node dictionary: a vault's vocabulary
/// runs to hundreds of thousands of nodes, and almost all of them have a single
/// child, so a hash table each would cost far more than the tree itself.
final class TermTrie {

    private struct Node {
        let scalar: Unicode.Scalar
        var firstChild: Int32 = -1
        var lastChild: Int32 = -1
        var nextSibling: Int32 = -1
        /// Index into `terms` when a term ends here, -1 otherwise.
        var term: Int32 = -1
    }

    private var nodes: [Node]
    private let terms: [String]

    var count: Int { terms.count }
    var isEmpty: Bool { terms.isEmpty }

    init(terms: [String]) {
        self.terms = terms
        nodes = [Node(scalar: " ")]           // root, its scalar is never read
        nodes.reserveCapacity(terms.count * 4)
        for (i, term) in terms.enumerated() { insert(term, index: Int32(i)) }
    }

    private func insert(_ term: String, index: Int32) {
        var current: Int32 = 0
        for scalar in term.unicodeScalars {
            if let existing = child(of: current, scalar: scalar) {
                current = existing
                continue
            }
            nodes.append(Node(scalar: scalar))
            let new = Int32(nodes.count - 1)
            // Append to the tail of the sibling chain. Terms arrive sorted, so
            // the chain stays in scalar order and the walk order is stable.
            if nodes[Int(current)].firstChild < 0 {
                nodes[Int(current)].firstChild = new
            } else {
                nodes[Int(nodes[Int(current)].lastChild)].nextSibling = new
            }
            nodes[Int(current)].lastChild = new
            current = new
        }
        if nodes[Int(current)].term < 0 { nodes[Int(current)].term = index }
    }

    private func child(of node: Int32, scalar: Unicode.Scalar) -> Int32? {
        var i = nodes[Int(node)].firstChild
        while i >= 0 {
            if nodes[Int(i)].scalar == scalar { return i }
            i = nodes[Int(i)].nextSibling
        }
        return nil
    }

    // MARK: - Prefix

    /// Terms starting with `prefix`, shortest first, up to `limit`. Breadth-first
    /// order is what makes the cap keep the closest completions: a half-typed
    /// word is likelier to be the short term than a long one sharing its start.
    func completions(of prefix: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var node: Int32 = 0
        for scalar in prefix.unicodeScalars {
            guard let next = child(of: node, scalar: scalar) else { return [] }
            node = next
        }

        var found: [String] = []
        var queue: [Int32] = [node]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let term = nodes[Int(current)].term
            if term >= 0 {
                found.append(terms[Int(term)])
                if found.count >= limit { return found }
            }
            var child = nodes[Int(current)].firstChild
            while child >= 0 {
                queue.append(child)
                child = nodes[Int(child)].nextSibling
            }
        }
        return found
    }

    // MARK: - Near misses

    /// Terms within `maxDistance` edits of `word`, and how far they are.
    ///
    /// The Levenshtein matrix is filled one row per character of the *tree*, so
    /// every term sharing a prefix shares that prefix's rows. A subtree whose
    /// best row already costs more than the closest match found so far cannot
    /// contain a better one, so it is never entered — which is what keeps this
    /// bounded on a vocabulary a linear scan would have to read end to end.
    ///
    /// Only the nearest distance is returned: once something is one edit away,
    /// the two-edit candidates are noise beside it.
    func nearest(_ word: [Unicode.Scalar], maxDistance: Int, limit: Int) -> (terms: [String], distance: Int)? {
        guard !word.isEmpty, !terms.isEmpty, limit > 0 else { return nil }

        var matches: [String] = []
        var best = maxDistance + 1
        // Row 0: turning the empty prefix into each prefix of the word costs one
        // deletion per character.
        let firstRow = Array(0...word.count)

        var child = nodes[0].firstChild
        while child >= 0 {
            walk(node: child, previous: firstRow, word: word,
                 maxDistance: maxDistance, limit: limit, best: &best, matches: &matches)
            child = nodes[Int(child)].nextSibling
        }
        guard !matches.isEmpty else { return nil }
        return (matches, best)
    }

    private func walk(node: Int32, previous: [Int], word: [Unicode.Scalar],
                      maxDistance: Int, limit: Int, best: inout Int, matches: inout [String]) {
        let scalar = nodes[Int(node)].scalar
        var row = [Int](repeating: 0, count: word.count + 1)
        row[0] = previous[0] + 1
        var rowBest = row[0]
        for j in 1...word.count {
            let substitution = previous[j - 1] + (word[j - 1] == scalar ? 0 : 1)
            row[j] = min(previous[j] + 1, row[j - 1] + 1, substitution)
            rowBest = min(rowBest, row[j])
        }

        let term = nodes[Int(node)].term
        if term >= 0, row[word.count] <= min(best, maxDistance) {
            if row[word.count] < best {
                best = row[word.count]
                matches.removeAll(keepingCapacity: true)
            }
            if matches.count < limit { matches.append(terms[Int(term)]) }
        }

        // Every row below this one is at least `rowBest`, so a subtree that is
        // already further than the best match cannot improve on it.
        guard rowBest <= min(best, maxDistance) else { return }
        var child = nodes[Int(node)].firstChild
        while child >= 0 {
            walk(node: child, previous: row, word: word,
                 maxDistance: maxDistance, limit: limit, best: &best, matches: &matches)
            child = nodes[Int(child)].nextSibling
        }
    }
}
