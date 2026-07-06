import Foundation

/// A computed row of the docked outline sidebar. Plain text only — the view
/// layer adds colour/styling. `isCurrent` marks the section the cursor is in.
struct OutlineSidebarRow: Equatable {
    let text: String
    let isCurrent: Bool
}

/// Pure layout for the docked outline sidebar: turns the heading list into a
/// fixed width × height column, indenting by level, highlighting the section
/// under the cursor, and scrolling to keep that section visible.
enum OutlineSidebar {

    static func rows(items: [OutlineItem], cursorLine: Int, width: Int, height: Int) -> [OutlineSidebarRow] {
        guard width > 0, height > 0 else { return [] }

        if items.isEmpty {
            return padded([OutlineSidebarRow(text: truncate("No headings", to: width), isCurrent: false)],
                          to: height)
        }

        // Current section: the last heading at or above the cursor line.
        let current = items.lastIndex(where: { $0.line <= cursorLine })
        let start = windowStart(count: items.count, current: current ?? 0, height: height)

        var rows: [OutlineSidebarRow] = []
        for i in start..<min(items.count, start + height) {
            let item = items[i]
            let indent = String(repeating: "  ", count: max(0, item.level - 1))
            rows.append(OutlineSidebarRow(text: truncate(indent + label(item.title), to: width),
                                          isCurrent: i == current))
        }
        return padded(rows, to: height)
    }

    /// Scroll a window of `height` items so `current` stays roughly centred.
    private static func windowStart(count: Int, current: Int, height: Int) -> Int {
        guard count > height else { return 0 }
        return max(0, min(current - height / 2, count - height))
    }

    private static func label(_ title: String) -> String {
        String(title.filter { $0 != "*" && $0 != "`" })
    }

    /// Truncate to `width` display columns, adding an ellipsis when cut.
    static func truncate(_ s: String, to width: Int) -> String {
        guard width >= 1 else { return "" }
        if s.displayWidth <= width { return s }
        var out = ""
        var used = 0
        for ch in s {
            let w = max(1, displayWidth(ch))
            if used + w > width - 1 { break }
            out.append(ch)
            used += w
        }
        return out + "…"
    }

    private static func padded(_ rows: [OutlineSidebarRow], to height: Int) -> [OutlineSidebarRow] {
        var rows = rows
        if rows.count > height { return Array(rows.prefix(height)) }
        while rows.count < height { rows.append(OutlineSidebarRow(text: "", isCurrent: false)) }
        return rows
    }
}
