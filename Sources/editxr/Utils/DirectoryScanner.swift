import Foundation

/// Recursively lists the editable files under a root directory, for the
/// quick-switcher. Skips hidden entries, noisy build/dependency folders, and
/// obvious binaries, and is capped so a huge tree can't stall the picker.
enum DirectoryScanner {
    /// Directories never worth descending into (in addition to dotfolders,
    /// which `.skipsHiddenFiles` already drops).
    private static let skipDirs: Set<String> = [
        "node_modules", ".build", ".swiftpm", "DerivedData", "Pods",
        "dist", "build", "out", "target", "vendor", ".next", "__pycache__",
    ]

    /// File extensions we can't meaningfully edit as text, so we hide them.
    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "icns", "pdf",
        "zip", "gz", "tar", "tgz", "bz2", "7z", "rar",
        "mp4", "mov", "avi", "mkv", "webm", "mp3", "wav", "flac", "aac", "ogg",
        "ttf", "otf", "woff", "woff2", "eot",
        "exe", "dll", "dylib", "so", "o", "a", "bin", "class", "jar",
        "sqlite", "db", "pyc",
    ]

    /// Returns paths relative to `root`, sorted, capped at `limit` entries.
    static func scan(root: String, limit: Int = 2000) -> [String] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let rootPath = rootURL.path

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        for case let url as URL in enumerator {
            if results.count >= limit { break }

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if skipDirs.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if binaryExtensions.contains(url.pathExtension.lowercased()) { continue }

            let full = url.standardizedFileURL.path
            let rel = full.hasPrefix(rootPath + "/")
                ? String(full.dropFirst(rootPath.count + 1))
                : full
            results.append(rel)
        }
        return results.sorted()
    }

    /// The file to open when a directory is opened with no explicit file (e.g.
    /// `editxr .`): a root-level README (any casing or extension) if one exists,
    /// else the first editable file in scan order. Nil when the scan is empty.
    static func primaryFile(in scan: [String]) -> String? {
        if let readme = scan.first(where: { path in
            guard !path.contains("/") else { return false }   // root level only
            return (path as NSString).deletingPathExtension.lowercased() == "readme"
        }) { return readme }
        return scan.first
    }
}
