import XCTest
@testable import HarborKit

final class LocalTransferStagingTests: XCTestCase {
    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-local-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func testDanglingSymlinkIsOccupiedAndNotFollowed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let dangling = root.appendingPathComponent("report.txt")
        let missingTarget = root.appendingPathComponent("outside-target.txt")
        try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: missingTarget.path)

        XCTAssertTrue(LocalTransferStaging.entryExists(at: dangling))
        XCTAssertFalse(manager.fileExists(atPath: dangling.path), "Foundation hides dangling symlinks")

        let staging = try LocalTransferStaging.createPrivateDirectory(in: root, label: "test")
        defer { try? manager.removeItem(at: staging) }
        let source = staging.appendingPathComponent("payload")
        try Data("safe contents".utf8).write(to: source)

        let installed = try LocalTransferStaging.moveStagedItem(
            at: source,
            named: "report.txt",
            into: root
        )

        XCTAssertEqual(installed.lastPathComponent, "report-2.txt")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: dangling.path), missingTarget.path)
        XCTAssertFalse(manager.fileExists(atPath: missingTarget.path))
        XCTAssertEqual(try Data(contentsOf: installed), Data("safe contents".utf8))
    }

    func testPrivateStagingDirectoryUses0700Permissions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let staging = try LocalTransferStaging.createPrivateDirectory(in: root, label: "mode")
        let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue

        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o700)
    }

    func testValidatedInstallNameRejectsTraversalAndDotSegments() {
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName(""))
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName("."))
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName(".."))
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName("../../.ssh/authorized_keys"))
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName("../Library/LaunchAgents/com.harbor.update.plist"))
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName("foo/bar"))
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName("foo\\bar"))
        XCTAssertThrowsError(try LocalTransferStaging.validatedInstallName("evil\nname"))
        XCTAssertEqual(try LocalTransferStaging.validatedInstallName("report.txt"), "report.txt")
        XCTAssertEqual(try LocalTransferStaging.validatedInstallName(".hidden"), ".hidden")
    }

    func testTraversalNameCannotLeaveDestinationDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)

        let staging = try LocalTransferStaging.createPrivateDirectory(in: downloads, label: "escape")
        defer { try? FileManager.default.removeItem(at: staging) }
        let source = staging.appendingPathComponent("payload")
        try Data("evil".utf8).write(to: source)

        XCTAssertThrowsError(
            try LocalTransferStaging.moveStagedItem(
                at: source,
                named: "../../.ssh/authorized_keys",
                into: downloads
            )
        )

        let escaped = root.appendingPathComponent(".ssh/authorized_keys")
        XCTAssertFalse(LocalTransferStaging.entryExists(at: escaped))
        XCTAssertTrue(LocalTransferStaging.entryExists(at: source))
    }
}
