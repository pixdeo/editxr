import XCTest
@testable import editxr

/// Resolving what someone types in the "New file…" prompt into a real path.
final class NewFilePathTests: XCTestCase {

    private let root = "/vault"

    func testBareNameLandsInTheVaultAsMarkdown() {
        XCTAssertEqual(NewFilePath.resolve("ideas", root: root), "/vault/ideas.md")
    }

    func testExistingExtensionIsKept() {
        XCTAssertEqual(NewFilePath.resolve("notes/todo.txt", root: root), "/vault/notes/todo.txt")
    }

    func testSubfolderPathIsRelativeToTheVault() {
        XCTAssertEqual(NewFilePath.resolve("2026/august/log", root: root),
                       "/vault/2026/august/log.md")
    }

    func testAbsolutePathPassesThrough() {
        XCTAssertEqual(NewFilePath.resolve("/tmp/scratch", root: root), "/tmp/scratch.md")
    }

    func testTildeExpandsToTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        XCTAssertEqual(NewFilePath.resolve("~/notes/x.md", root: root), home + "/notes/x.md")
    }

    func testDotSegmentsAreResolved() {
        XCTAssertEqual(NewFilePath.resolve("a/../b", root: root), "/vault/b.md")
    }

    func testDotfileKeepsItsName() {
        XCTAssertEqual(NewFilePath.resolve(".gitignore", root: root), "/vault/.gitignore")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(NewFilePath.resolve("  ideas  ", root: root), "/vault/ideas.md")
    }

    func testFolderLikeInputIsRejected() {
        XCTAssertNil(NewFilePath.resolve("", root: root))
        XCTAssertNil(NewFilePath.resolve("   ", root: root))
        XCTAssertNil(NewFilePath.resolve("/", root: root))
        XCTAssertNil(NewFilePath.resolve(".", root: root))
        XCTAssertNil(NewFilePath.resolve("notes/..", root: root))
    }
}
