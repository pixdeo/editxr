import XCTest
@testable import editxr

/// Deciding what an `editxr` invocation opens: a positional directory argument
/// (e.g. `editxr .`) becomes the file-sidebar root instead of a document, a
/// lone directory opens the project's primary file (README preferred), and the
/// file-explorer sidebar turns on for that run.
final class LaunchArgumentsTests: XCTestCase {

    private func makeProject() -> String {
        let root = NSTemporaryDirectory() + "editxr-launch-\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try? "hello".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try? "code".write(toFile: root + "/src/a.swift", atomically: true, encoding: .utf8)
        return root
    }

    // MARK: - parse

    func testDirectoryArgumentBecomesRootNotFile() {
        let root = makeProject()
        let parse = LaunchArguments.parse(arguments: ["editxr", root], vaultArgIndex: nil)
        XCTAssertEqual(parse.directoryRoot, root)
        XCTAssertTrue(parse.filePaths.isEmpty, "a directory is not opened as a document")
    }

    func testDotArgumentUsesCurrentDirectory() {
        let parse = LaunchArguments.parse(arguments: ["editxr", "."], vaultArgIndex: nil)
        XCTAssertEqual(parse.directoryRoot, Vault.standardized("."))
    }

    func testFileArgumentsStayFiles() {
        let root = makeProject()
        let parse = LaunchArguments.parse(arguments: ["editxr", root + "/README.md"], vaultArgIndex: nil)
        XCTAssertNil(parse.directoryRoot)
        XCTAssertEqual(parse.filePaths, [root + "/README.md"])
    }

    func testDirectoryPlusFilesKeepsBoth() {
        let root = makeProject()
        let file = root + "/src/a.swift"
        let parse = LaunchArguments.parse(arguments: ["editxr", root, file], vaultArgIndex: nil)
        XCTAssertEqual(parse.directoryRoot, root)
        XCTAssertEqual(parse.filePaths, [file])
    }

    func testExplicitVaultWinsOverDirectoryArgument() {
        let root = makeProject()
        let vaultDir = NSTemporaryDirectory() + "editxr-vault-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)
        let parse = LaunchArguments.parse(arguments: ["editxr", root, "--vault", vaultDir], vaultArgIndex: 3)
        XCTAssertNil(parse.directoryRoot, "--vault pins the root; a positional dir is not special")
        XCTAssertEqual(parse.filePaths, [root])
    }

    func testUnknownPathIsTreatedAsFileToCreate() {
        let root = makeProject()
        let missing = root + "/new.md"
        let parse = LaunchArguments.parse(arguments: ["editxr", missing], vaultArgIndex: nil)
        XCTAssertNil(parse.directoryRoot)
        XCTAssertEqual(parse.filePaths, [missing])
    }

    // MARK: - primaryFile

    func testPrimaryPrefersRootReadme() {
        let root = makeProject()
        let scan = DirectoryScanner.scan(root: root)
        XCTAssertEqual(DirectoryScanner.primaryFile(in: scan), "README.md")
    }

    func testPrimaryMatchesAnyReadmeCasingAndExtension() {
        let root = makeProject()
        let fm = FileManager.default
        try? fm.removeItem(atPath: root + "/README.md")
        try? "x".write(toFile: root + "/readme.markdown", atomically: true, encoding: .utf8)
        let scan = DirectoryScanner.scan(root: root)
        XCTAssertEqual(DirectoryScanner.primaryFile(in: scan), "readme.markdown")
    }

    func testPrimaryIgnoresReadmeInSubfolders() {
        let root = makeProject()
        let fm = FileManager.default
        try? fm.removeItem(atPath: root + "/README.md")
        try? "x".write(toFile: root + "/src/README.md", atomically: true, encoding: .utf8)
        let scan = DirectoryScanner.scan(root: root)
        XCTAssertEqual(DirectoryScanner.primaryFile(in: scan), scan.first, "a nested README is not the project primary")
    }

    func testPrimaryFallsBackToFirstFile() {
        let root = makeProject()
        let fm = FileManager.default
        try? fm.removeItem(atPath: root + "/README.md")
        let scan = DirectoryScanner.scan(root: root)
        XCTAssertEqual(DirectoryScanner.primaryFile(in: scan), scan.first)
    }

    func testPrimaryNilForEmptyScan() {
        XCTAssertNil(DirectoryScanner.primaryFile(in: []))
    }

    // MARK: - makeStates

    func testDirectoryOnlyOpensPrimaryFileWithFileSidebar() {
        let root = makeProject()
        let parse = LaunchArguments.parse(arguments: ["editxr", root], vaultArgIndex: nil)
        let states = LaunchArguments.makeStates(from: parse)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].filePath, root + "/README.md")
        XCTAssertEqual(states[0].sidebarMode, .files)
    }

    func testDirectoryWithFilesOpensThemWithFileSidebar() {
        let root = makeProject()
        let file = root + "/src/a.swift"
        let parse = LaunchArguments.parse(arguments: ["editxr", root, file], vaultArgIndex: nil)
        let states = LaunchArguments.makeStates(from: parse)
        XCTAssertEqual(states.map(\.filePath), [file])
        XCTAssertTrue(states.allSatisfy { $0.sidebarMode == .files })
    }

    func testPlainFilesKeepConfiguredSidebar() {
        let root = makeProject()
        let file = root + "/README.md"
        let parse = LaunchArguments.parse(arguments: ["editxr", file], vaultArgIndex: nil)
        let states = LaunchArguments.makeStates(from: parse)
        let baseline = EditorState(filePath: file).sidebarMode   // whatever the config says
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].sidebarMode, baseline, "no directory arg → the configured sidebar is left untouched")
    }
}
