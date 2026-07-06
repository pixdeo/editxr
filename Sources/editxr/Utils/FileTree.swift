import Foundation

/// A visible row of the file-explorer sidebar.
struct FileTreeRow: Equatable {
    let name: String        // basename (folder or file)
    let depth: Int          // 0 for top-level entries
    let isDir: Bool
    let path: String        // path relative to the project root
    let isCollapsed: Bool   // dirs only; false for files
}

/// Pure tree builder for the file explorer: turns DirectoryScanner's flat list
/// of relative paths into an indented, folders-first row list, hiding the
/// descendants of any collapsed folder. No filesystem or styling concerns.
enum FileTree {

    private final class Node {
        var children: [String: Node] = [:]
        var isDir = false
    }

    static func rows(paths: [String], collapsed: Set<String>) -> [FileTreeRow] {
        let root = Node()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            for (i, part) in parts.enumerated() {
                let child = node.children[part] ?? {
                    let n = Node()
                    node.children[part] = n
                    return n
                }()
                if i < parts.count - 1 { child.isDir = true }
                node = child
            }
        }
        var rows: [FileTreeRow] = []
        emit(node: root, prefix: "", depth: 0, collapsed: collapsed, into: &rows)
        return rows
    }

    private static func emit(node: Node, prefix: String, depth: Int,
                             collapsed: Set<String>, into rows: inout [FileTreeRow]) {
        // Folders first, then files; each group alphabetical (case-insensitive).
        let entries = node.children.sorted { a, b in
            if a.value.isDir != b.value.isDir { return a.value.isDir && !b.value.isDir }
            return a.key.lowercased() < b.key.lowercased()
        }
        for (name, child) in entries {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if child.isDir {
                let isCollapsed = collapsed.contains(path)
                rows.append(FileTreeRow(name: name, depth: depth, isDir: true,
                                        path: path, isCollapsed: isCollapsed))
                if !isCollapsed {
                    emit(node: child, prefix: path, depth: depth + 1, collapsed: collapsed, into: &rows)
                }
            } else {
                rows.append(FileTreeRow(name: name, depth: depth, isDir: false,
                                        path: path, isCollapsed: false))
            }
        }
    }
}
