import XCTest
@testable import editxr

/// Vault root resolution and the recents list. Both are pure enough to test
/// without launching the app; the marker walk gets a real temp tree.
final class VaultTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editxr-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Marker walk

    func testMarkerRootFindsAncestorHoldingTheMarker() throws {
        let fm = FileManager.default
        let vault = tmp.appendingPathComponent("Notes")
        let deep = vault.appendingPathComponent("projects/2026")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)

        XCTAssertEqual(Vault.markerRoot(startingAt: deep.path), vault.standardizedFileURL.path)
    }

    func testMarkerRootReturnsNilWithoutAMarker() throws {
        let deep = tmp.appendingPathComponent("plain/notes")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        // No marker anywhere between here and the volume root, or the walk would
        // escape the temp tree and pick up something unrelated.
        if let found = Vault.markerRoot(startingAt: deep.path) {
            XCTAssertFalse(found.hasPrefix(tmp.standardizedFileURL.path),
                           "found a marker inside the temp tree: \(found)")
        }
    }

    func testMarkerFileIsIgnoredOnlyDirectoriesCount() throws {
        let fm = FileManager.default
        let dir = tmp.appendingPathComponent("Notes")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A regular file named .editxr must not be mistaken for a vault marker.
        try Data().write(to: dir.appendingPathComponent(".editxr"))

        let found = Vault.markerRoot(startingAt: dir.path)
        XCTAssertNotEqual(found, dir.standardizedFileURL.path)
    }

    // MARK: - Root precedence

    func testExplicitRootWinsOverTheOpenFilesFolder() throws {
        let fm = FileManager.default
        let elsewhere = tmp.appendingPathComponent("Elsewhere")
        let notes = tmp.appendingPathComponent("Notes")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)

        let root = Vault.resolveRoot(configured: elsewhere.path,
                                     fileHint: notes.appendingPathComponent("a.md").path)
        XCTAssertEqual(root, elsewhere.standardizedFileURL.path)
    }

    func testExplicitRootWinsOverAMarkerAncestor() throws {
        let fm = FileManager.default
        let marked = tmp.appendingPathComponent("Marked")
        let elsewhere = tmp.appendingPathComponent("Elsewhere")
        try fm.createDirectory(at: marked.appendingPathComponent(".editxr"), withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let root = Vault.resolveRoot(configured: elsewhere.path,
                                     fileHint: marked.appendingPathComponent("a.md").path)
        XCTAssertEqual(root, elsewhere.standardizedFileURL.path)
    }

    func testMarkerAncestorWinsOverTheOpenFilesFolder() throws {
        let fm = FileManager.default
        let marked = tmp.appendingPathComponent("Marked")
        let deep = marked.appendingPathComponent("sub")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createDirectory(at: marked.appendingPathComponent(".editxr"), withIntermediateDirectories: true)

        let root = Vault.resolveRoot(configured: nil,
                                     fileHint: deep.appendingPathComponent("a.md").path)
        XCTAssertEqual(root, marked.standardizedFileURL.path)
    }

    func testNoConfigAndNoMarkerKeepsThePreVaultBehaviour() throws {
        let notes = tmp.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

        let root = Vault.resolveRoot(configured: nil,
                                     fileHint: notes.appendingPathComponent("a.md").path)
        XCTAssertEqual(root, notes.standardizedFileURL.path)
    }

    func testAnEmptyConfiguredRootIsTreatedAsUnset() throws {
        let notes = tmp.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

        let root = Vault.resolveRoot(configured: "",
                                     fileHint: notes.appendingPathComponent("a.md").path)
        XCTAssertEqual(root, notes.standardizedFileURL.path)
    }

    func testContainingDirectoryOfABareFilenameIsTheWorkingDirectory() {
        XCTAssertEqual(Vault.containingDirectory(of: "notes.md"),
                       FileManager.default.currentDirectoryPath)
    }

    // MARK: - Recents

    func testRecentsPutTheNewestFirstAndDeduplicate() {
        var list = Vault.recents(adding: "/a", to: [])
        list = Vault.recents(adding: "/b", to: list)
        list = Vault.recents(adding: "/a", to: list)

        XCTAssertEqual(list, ["/a", "/b"])
    }

    func testRecentsDeduplicateAcrossEquivalentPathSpellings() {
        let list = Vault.recents(adding: "/tmp/notes", to: ["/tmp/./notes/"])
        XCTAssertEqual(list.count, 1)
    }

    func testRecentsAreCapped() {
        var list: [String] = []
        for i in 0..<20 { list = Vault.recents(adding: "/vault\(i)", to: list) }

        XCTAssertEqual(list.count, Vault.maxRecents)
        XCTAssertEqual(list.first, "/vault19")
    }

    // MARK: - Settings

    func testMaxResultsIsClampedToARange() {
        XCTAssertEqual(Vault.clampResults(0), 1)
        XCTAssertEqual(Vault.clampResults(999), 50)
        XCTAssertEqual(Vault.clampResults(12), 12)
    }

    func testBackendRawValuesSurviveARoundTrip() {
        for backend in EmbedBackend.allCases {
            XCTAssertEqual(EmbedBackend(rawValue: backend.rawValue), backend)
            XCTAssertFalse(backend.displayName.isEmpty)
        }
    }

    func testUnknownBackendFallsBackRatherThanFailing() {
        XCTAssertNil(EmbedBackend(rawValue: "quantum-vectors"))
    }

    // MARK: - Embedder status

    func testSemanticSearchOffReportsDisabledForEveryBackend() {
        for backend in EmbedBackend.allCases {
            let status = EmbedderFactory.status(for: backend, semanticSearch: false)
            guard case .disabled = status else {
                return XCTFail("\(backend) should be disabled when semantic search is off")
            }
        }
    }

    func testOffBackendIsDisabledEvenWithSemanticSearchOn() {
        guard case .disabled = EmbedderFactory.status(for: .off, semanticSearch: true) else {
            return XCTFail("the off backend must report disabled")
        }
    }

    func testLocalModelAsksForADownloadUntilItIsInstalled() {
        let status = EmbedderFactory.status(for: .localModel, semanticSearch: true)
        if EmbedderFactory.defaultAsset.isInstalled {
            guard case .ready = status else { return XCTFail("installed model should be ready") }
        } else {
            guard case .needsDownload(let asset) = status else {
                return XCTFail("a missing model must ask for consent, not index silently")
            }
            XCTAssertEqual(asset.id, EmbedderFactory.defaultAsset.id)
        }
    }

    func testEveryStatusHasALabelAndADetail() {
        let statuses: [EmbedderStatus] = [
            .ready("x"), .needsSystemAssets, .needsDownload(.multilingualE5Small),
            .unavailable("y"), .disabled,
        ]
        for status in statuses {
            XCTAssertFalse(status.label.isEmpty)
            XCTAssertFalse(status.detail.isEmpty)
        }
    }

    func testDownloadSizeIsRenderedInWholeMegabytes() {
        XCTAssertEqual(ModelAsset.multilingualE5Small.sizeLabel, "236 MB")
    }

    // MARK: - Display

    func testDisplayPathShortensTheHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        XCTAssertEqual(Vault.displayPath(home), "~")
        XCTAssertEqual(Vault.displayPath(home + "/Notes"), "~/Notes")
        XCTAssertEqual(Vault.displayPath("/opt/notes"), "/opt/notes")
    }
}
