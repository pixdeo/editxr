import Foundation

/// An LLM-proposed edit to a section, awaiting accept/reject. The section is a
/// whole-line range [startLine, endLine]; the diff is shown inline in the doc
/// and only applied on accept.
struct PendingEdit {
    let startLine: Int
    let endLine: Int
    let proposedLines: [String]
    let diff: [DiffLine]
}
