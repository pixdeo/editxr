import XCTest
@testable import editxr

/// Clipboard helpers are other people's programs, and `wl-copy`, `xclip` and
/// `xsel` all stay behind to own the selection. Copying must not wait on them.
/// Stub helpers stand in here so tests never touch the real clipboard.
final class SystemClipboardTests: XCTestCase {

    private var directory = ""

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "editxr-clipboard-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        SystemClipboard.waitForPendingWrites()
        try? FileManager.default.removeItem(atPath: directory)
        super.tearDown()
    }

    private func helper(_ name: String, _ body: String) -> (path: String, args: [String]) {
        let path = "\(directory)/\(name)"
        try? "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return (path, [])
    }

    /// Long enough for a just-written script's first launch, which macOS checks.
    private let patient: TimeInterval = 5

    private func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    func testCopyDoesNotWaitForAHelperThatStaysBehind() {
        let stays = helper("stays", "cat > /dev/null; sleep 2")
        XCTAssertLessThan(elapsed { SystemClipboard.write("text", using: [stays]) }, 0.5)
    }

    func testCopyDoesNotWaitForAHelperThatNeverReadsItsInput() {
        // More than a pipe holds, so writing it would block until the helper reads.
        let deaf = helper("deaf", "sleep 2")
        let text = String(repeating: "x", count: 1 << 20)
        XCTAssertLessThan(elapsed { SystemClipboard.write(text, using: [deaf]) }, 0.5)
    }

    func testCopyDoesNotWaitForADaemonTheHelperLeavesBehind() {
        let daemon = helper("daemon", "cat > /dev/null; sleep 2 & exit 0")
        XCTAssertLessThan(elapsed { SystemClipboard.write("text", using: [daemon]) }, 0.5)
    }

    func testAHelperThatFailsFallsThroughToTheNextOne() {
        let output = "\(directory)/copied"
        let failing = helper("failing", "exit 1")
        let working = helper("working", "cat > '\(output)'")
        SystemClipboard.write("text", using: [failing, working], grace: patient)
        SystemClipboard.waitForPendingWrites()
        XCTAssertEqual(try? String(contentsOfFile: output, encoding: .utf8), "text")
    }

    func testAHelperThatDiesBeforeReadingDoesNotTakeTheEditorWithIt() {
        // Writing to a closed pipe raises SIGPIPE, which would end the process.
        let output = "\(directory)/copied"
        let dead = helper("dead", "exit 1")
        let working = helper("working", "cat > '\(output)'")
        let text = String(repeating: "x", count: 1 << 20)
        SystemClipboard.write(text, using: [dead, working], grace: patient)
        SystemClipboard.waitForPendingWrites()
        XCTAssertEqual(try? String(contentsOfFile: output, encoding: .utf8), text)
    }

    func testPasteSeesAWriteThatIsStillInFlight() {
        let output = "\(directory)/copied"
        let slow = helper("slow", "sleep 0.1; cat > '\(output)'")
        SystemClipboard.write("text", using: [slow], grace: patient)
        SystemClipboard.waitForPendingWrites()
        XCTAssertEqual(try? String(contentsOfFile: output, encoding: .utf8), "text")
    }
}
