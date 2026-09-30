import XCTest
@testable import HarborKit

final class POSIXPermissionModeTests: XCTestCase {
    func testParsesUppercaseSpecialBitsWithoutInventingExecutePermission() {
        let mode = POSIXPermissionMode(lsPermissions: "-rwSr-Sr-T")

        XCTAssertEqual(mode.rwx, [true, true, false, true, false, false, true, false, false])
        XCTAssertTrue(mode.setUserID)
        XCTAssertTrue(mode.setGroupID)
        XCTAssertTrue(mode.sticky)
        XCTAssertEqual(mode.octal, "7644")
    }

    func testParsesLowercaseSpecialBitsWhileKeepingExecutePermission() {
        let mode = POSIXPermissionMode(lsPermissions: "-rwsr-sr-t")

        XCTAssertEqual(mode.rwx, [true, true, true, true, false, true, true, false, true])
        XCTAssertTrue(mode.setUserID)
        XCTAssertTrue(mode.setGroupID)
        XCTAssertTrue(mode.sticky)
        XCTAssertEqual(mode.octal, "7755")
    }

    func testNormalModeRetainsLeadingSpecialDigit() {
        let mode = POSIXPermissionMode(lsPermissions: "-rwxr-xr-x")

        XCTAssertFalse(mode.setUserID)
        XCTAssertFalse(mode.setGroupID)
        XCTAssertFalse(mode.sticky)
        XCTAssertEqual(mode.octal, "0755")
    }
}
