import Foundation

/// One line of a line-level diff.
enum DiffLine {
    case same(String)
    case del(String)
    case add(String)
}

/// Minimal line diff via longest-common-subsequence. Good enough for prose and
/// markdown sections; intra-line (word) diffing can come later.
enum Diff {
    static func lines(_ a: [String], _ b: [String]) -> [DiffLine] {
        let n = a.count, m = b.count

        // dp[i][j] = LCS length of a[i...] and b[j...]
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                            : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(.same(a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                result.append(.del(a[i])); i += 1
            } else {
                result.append(.add(b[j])); j += 1
            }
        }
        while i < n { result.append(.del(a[i])); i += 1 }
        while j < m { result.append(.add(b[j])); j += 1 }
        return result
    }
}
