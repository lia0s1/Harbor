import XCTest
@testable import HarborKit

final class ArchiveKindTests: XCTestCase {
    private func cmd(_ name: String, into dir: String = "/root") -> String? {
        ArchiveKind.extractCommand(archivePath: "/up/" + name, into: dir)
    }

    func testTarFamilyUsesAutoDetectingTarXf() {
        for name in ["a.tar.gz", "a.tgz", "a.tar.bz2", "a.tbz", "a.tar.xz",
                     "a.txz", "a.tar.zst", "a.tar", "BIG.TAR.GZ"] {
            let c = cmd(name)
            XCTAssertNotNil(c, name)
            XCTAssertTrue(c!.contains("tar xf '/up/\(name)'"), name)
            XCTAssertTrue(c!.hasPrefix("mkdir -p '/root' && cd '/root' && "), name)
        }
    }

    func testZip7zRar() {
        XCTAssertTrue(cmd("x.zip")!.contains("unzip -o '/up/x.zip'"))
        XCTAssertTrue(cmd("x.7z")!.contains("7z x -y '/up/x.7z'"))
        XCTAssertTrue(cmd("x.rar")!.contains("unrar x -o+ '/up/x.rar'"))
    }

    func testSingleFileCompressorsRedirectToStrippedName() {
        // single-file → decompress to stdout, redirect under the stripped name.
        XCTAssertTrue(cmd("data.txt.gz")!.contains("gunzip -c '/up/data.txt.gz' > 'data.txt'"))
        XCTAssertTrue(cmd("x.bz2")!.contains("bunzip2 -c '/up/x.bz2' > 'x'"))
        XCTAssertTrue(cmd("x.xz")!.contains("unxz -c '/up/x.xz' > 'x'"))
        XCTAssertTrue(cmd("x.zst")!.contains("unzstd -c '/up/x.zst' > 'x'"))
    }

    func testExtractToOtherDirectory() {
        let c = ArchiveKind.extractCommand(archivePath: "/up/a.tar.gz", into: "/var/www")
        XCTAssertEqual(c, "mkdir -p '/var/www' && cd '/var/www' && tar xf '/up/a.tar.gz'")
    }

    func testTarGzBeatsGz() {
        XCTAssertTrue(cmd("x.tar.gz")!.contains("tar xf"))
        XCTAssertFalse(cmd("x.tar.gz")!.contains("gunzip"))
    }

    func testNonArchiveReturnsNil() {
        for name in ["readme.txt", "photo.png", "script.sh", "noext", "archive.zip.txt"] {
            XCTAssertNil(cmd(name), name)
            XCTAssertFalse(ArchiveKind.isArchive(name), name)
        }
    }

    func testIsArchive() {
        XCTAssertTrue(ArchiveKind.isArchive("backend.tar.gz"))
        XCTAssertTrue(ArchiveKind.isArchive("data.7z"))
        XCTAssertFalse(ArchiveKind.isArchive("deploy-vps.sh"))
    }

    func testRequiredTool() {
        XCTAssertEqual(ArchiveKind.requiredTool(for: "a.zip")?.tool, "unzip")
        XCTAssertEqual(ArchiveKind.requiredTool(for: "a.7z")?.package, "p7zip-full")
        XCTAssertEqual(ArchiveKind.requiredTool(for: "a.tar.gz")?.tool, "tar")
        XCTAssertEqual(ArchiveKind.requiredTool(for: "a.xz")?.package, "xz-utils")
        XCTAssertNil(ArchiveKind.requiredTool(for: "readme.txt"))
    }

    func testPathsShellQuotedAgainstInjection() {
        let c = ArchiveKind.extractCommand(archivePath: "/up/a; rm -rf ~.zip", into: "/d")!
        XCTAssertTrue(c.contains("'/up/a; rm -rf ~.zip'"))
        // the only unquoted "&&" is our own mkdir/cd join, never the payload
        XCTAssertFalse(c.contains("&& rm -rf ~"))
    }
}
