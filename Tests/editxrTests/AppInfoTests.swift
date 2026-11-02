import XCTest
@testable import editxr

final class AppInfoTests: XCTestCase {
    func testTaskTabFixReleaseIdentity() {
        XCTAssertEqual(AppInfo.version, "1.9.1")
        XCTAssertTrue(AppInfo.helpText.hasPrefix("editxr 1.9.1 —"))
    }

    func testHelpDocumentsBareVault() {
        XCTAssertTrue(AppInfo.helpText.contains("--vault         Open the configured vault"),
                      "the bare --vault form must be discoverable in the help")
    }
}
