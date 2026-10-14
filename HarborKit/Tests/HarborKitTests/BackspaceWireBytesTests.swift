import XCTest
@testable import HarborKit

final class BackspaceWireBytesTests: XCTestCase {
    func testAutoLeavesTerminalDefaultUntouched() {
        XCTAssertNil(SSHHost.BackspaceBehavior.auto.wireBytes)
    }

    func testASCIIBackspaceSendsBS() {
        XCTAssertEqual(SSHHost.BackspaceBehavior.asciiBackspace.wireBytes, [0x08])
    }

    func testASCIIDeleteSendsDEL() {
        XCTAssertEqual(SSHHost.BackspaceBehavior.asciiDelete.wireBytes, [0x7F])
    }

    func testVT220DeleteSendsEscapeSequence() {
        XCTAssertEqual(SSHHost.BackspaceBehavior.vt220Delete.wireBytes, [0x1B, 0x5B, 0x33, 0x7E])
    }

    func testResolvePerHostOverrideWins() {
        // A per-host choice other than .auto always beats the global default.
        XCTAssertEqual(
            SSHHost.BackspaceBehavior.resolve(perHost: .asciiBackspace, globalRawValue: "vt220Delete"),
            .asciiBackspace
        )
        XCTAssertEqual(
            SSHHost.BackspaceBehavior.resolve(perHost: .vt220Delete, globalRawValue: nil),
            .vt220Delete
        )
    }

    func testResolveFallsThroughToGlobalDefault() {
        XCTAssertEqual(
            SSHHost.BackspaceBehavior.resolve(perHost: .auto, globalRawValue: "asciiDelete"),
            .asciiDelete
        )
    }

    func testResolveAutoWhenGlobalMissingOrInvalid() {
        XCTAssertEqual(SSHHost.BackspaceBehavior.resolve(perHost: .auto, globalRawValue: nil), .auto)
        XCTAssertEqual(SSHHost.BackspaceBehavior.resolve(perHost: .auto, globalRawValue: ""), .auto)
        XCTAssertEqual(SSHHost.BackspaceBehavior.resolve(perHost: .auto, globalRawValue: "bogus"), .auto)
    }

    func testAllCasesCoveredByWireBytes() {
        // Guard against a future enum case silently falling through the mapper.
        for behavior in SSHHost.BackspaceBehavior.allCases {
            if behavior == .auto {
                XCTAssertNil(behavior.wireBytes)
            } else {
                XCTAssertFalse(behavior.wireBytes?.isEmpty ?? true, "\(behavior) must produce bytes")
            }
        }
    }
}
