import XCTest
@testable import HarborKit

final class ArchiveKindTests: XCTestCase {
    private func cmd(_ name: String, into dir: String = "/root") -> String? {
        ArchiveKind.extractCommand(archivePath: "/up/" + name, into: dir)
    }

    func testTarFamilyUsesGuardedTarExtract() {
        for name in ["a.tar.gz", "a.tgz", "a.tar.bz2", "a.tbz", "a.tar.xz",
                     "a.txz", "a.tar.zst", "a.tar", "BIG.TAR.GZ"] {
            let c = cmd(name)
            XCTAssertNotNil(c, name)
            XCTAssertTrue(c!.contains("tar --no-absolute-filenames -xf -- '/up/\(name)'"), name)
            XCTAssertTrue(c!.contains("tar tf -- '/up/\(name)'"), name)
            XCTAssertTrue(c!.contains("harbor_check_members"), name)
            XCTAssertTrue(c!.contains("mktemp -d --"), name)
            XCTAssertFalse(c!.contains("&& tar xf "), name)
        }
    }

    func testZip7zRarUseStagingAndMemberGate() {
        let zip = cmd("x.zip")!
        XCTAssertTrue(zip.contains("unzip -Z1 -- '/up/x.zip'"))
        XCTAssertTrue(zip.contains("unzip -o -d \"$staging\" -- '/up/x.zip'"))
        XCTAssertTrue(zip.contains("harbor_check_members"))

        let seven = cmd("x.7z")!
        XCTAssertTrue(seven.contains("7z l -slt -- '/up/x.7z'"))
        XCTAssertTrue(seven.contains("7z x -y \"-o$staging\" -- '/up/x.7z'"))

        let rar = cmd("x.rar")!
        XCTAssertTrue(rar.contains("unrar lb -- '/up/x.rar'"))
        XCTAssertTrue(rar.contains("unrar x -o+ -- '/up/x.rar' \"$staging/\""))
    }

    func testSingleFileCompressorsRedirectToStrippedName() {
        let gz = cmd("data.txt.gz")!
        XCTAssertTrue(gz.contains("gunzip -c -- '/up/data.txt.gz' > \"$staging/$stem\""))
        XCTAssertTrue(gz.contains("stem='data.txt'"))
        XCTAssertTrue(cmd("x.bz2")!.contains("bunzip2 -c --"))
        XCTAssertTrue(cmd("x.xz")!.contains("unxz -c --"))
        XCTAssertTrue(cmd("x.zst")!.contains("unzstd -c --"))
    }

    func testExtractToOtherDirectory() {
        let c = ArchiveKind.extractCommand(archivePath: "/up/a.tar.gz", into: "/var/www")
        XCTAssertNotNil(c)
        XCTAssertTrue(c!.contains("target='/var/www'"))
        XCTAssertTrue(c!.contains("tar --no-absolute-filenames -xf -- '/up/a.tar.gz'"))
        XCTAssertFalse(c!.contains("cd '/var/www' && tar xf"))
    }

    func testTarGzBeatsGz() {
        XCTAssertTrue(cmd("x.tar.gz")!.contains("tar --no-absolute-filenames"))
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
        XCTAssertFalse(c.contains("&& rm -rf ~"))
    }

    func testShellQuotingHandlesSingleQuotes() {
        let c = ArchiveKind.extractCommand(archivePath: "/path/to/O'Brien.tar.gz", into: "/root")!
        XCTAssertTrue(c.contains("'\"'\"'"))
        XCTAssertFalse(c.contains("O'Brien"))
    }

    func testUnsafeArchiveMembers() {
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember(""))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember("."))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember(".."))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember("/etc/passwd"))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember("\\windows\\system32"))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember("C:/Windows/win.ini"))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember("../.ssh/authorized_keys"))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember("foo/../../etc/shadow"))
        XCTAssertTrue(ArchiveKind.isUnsafeArchiveMember("ok/\n/evil"))
        XCTAssertFalse(ArchiveKind.isUnsafeArchiveMember("src/main.swift"))
        XCTAssertFalse(ArchiveKind.isUnsafeArchiveMember("README"))
        XCTAssertFalse(ArchiveKind.isUnsafeArchiveMember("./keep"))
    }

    func testExtractCommandRejectsUnsafeSingleFileStem() {
        XCTAssertNil(ArchiveKind.extractCommand(archivePath: "/up/..gz", into: "/root"))
    }

    func testGuardedScriptRefusesSymlinkTargetAndBareTarXf() {
        let c = cmd("payload.tar.gz")!
        XCTAssertTrue(c.contains("HARBOR_UNSAFE_ARCHIVE_PATH"))
        XCTAssertTrue(c.contains("refusing to extract into a symbolic link"))
        XCTAssertTrue(c.contains("harbor_check_extracted"))
        XCTAssertTrue(c.contains("harbor_install_extracted"))
        XCTAssertFalse(c.contains("tar xf '/up/payload.tar.gz'"))
    }
}
