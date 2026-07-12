import XCTest
@testable import HarborKit

final class RemoteLsParserTests: XCTestCase {
    // MARK: - Fixture parsing

    private func record(
        _ type: String,
        _ permissions: String,
        _ uid: Int,
        _ gid: Int,
        _ size: UInt64,
        _ epoch: String,
        _ name: String,
        _ target: String = ""
    ) -> String {
        [type, permissions, String(uid), String(gid), String(size), epoch, name, target]
            .joined(separator: "\0") + "\0"
    }

    private var fixture: String {
        record("d", "drwxr-xr-x", 1000, 1000, 4096, "1718000000.0000000000", "docs")
            + record("d", "drwxr-xr-x", 1000, 1000, 4096, "1718400000.0000000000", ".config")
            + record("f", "-rw-r--r--", 1000, 1000, 12345, "1718100000.0000000000", "file.txt")
            + record("f", "-rw-r--r--", 0, 0, 0, "1525000000.0000000000", "file with  spaces.log")
            + record("f", "-rwsr-xr-x", 0, 0, 54256, "1650000000.0000000000", "sudo")
            + record("l", "lrwxrwxrwx", 1000, 1000, 6, "1718200000.0000000000", "latest", "docs/v2")
            + record("f", "-rw-r--r--", 1000, 1000, 999, "1718300000.0000000000", "\u{4E2D}\u{6587} \u{6587}\u{4EF6}.txt")
    }

    func testParsesAllRowsAndSkipsTotal() {
        let entries = RemoteLsParser.parse(fixture)
        XCTAssertEqual(entries.count, 7)
    }

    func testDirectoryEntry() {
        let entries = RemoteLsParser.parse(fixture)
        let docs = entries.first { $0.name == "docs" }
        XCTAssertNotNil(docs)
        XCTAssertTrue(docs?.isDirectory ?? false)
        XCTAssertFalse(docs?.isSymlink ?? true)
        XCTAssertEqual(docs?.sizeBytes, 4096)
        XCTAssertEqual(docs?.mtimeEpoch, 1_718_000_000)
        XCTAssertEqual(docs?.uid, 1000)
        XCTAssertEqual(docs?.gid, 1000)
        XCTAssertEqual(docs?.permissions, "drwxr-xr-x")
    }

    func testPlainFileEntry() {
        let entries = RemoteLsParser.parse(fixture)
        let file = entries.first { $0.name == "file.txt" }
        XCTAssertEqual(file?.isDirectory, false)
        XCTAssertEqual(file?.sizeBytes, 12345)
        XCTAssertEqual(file?.uid, 1000)
    }

    func testNameWithSpacesIsPreservedVerbatim() {
        let entries = RemoteLsParser.parse(fixture)
        let spaced = entries.first { $0.name == "file with  spaces.log" }
        XCTAssertNotNil(spaced, "double space inside the name must survive")
        XCTAssertEqual(spaced?.sizeBytes, 0)
        XCTAssertEqual(spaced?.uid, 0)
        XCTAssertEqual(spaced?.gid, 0)
    }

    func testCJKName() {
        let entries = RemoteLsParser.parse(fixture)
        let cjk = entries.first { $0.name == "中文 文件.txt" }
        XCTAssertNotNil(cjk)
        XCTAssertEqual(cjk?.sizeBytes, 999)
    }

    func testSymlinkSplitsNameAndTarget() {
        let entries = RemoteLsParser.parse(fixture)
        let link = entries.first { $0.isSymlink }
        XCTAssertEqual(link?.name, "latest")
        XCTAssertEqual(link?.linkTarget, "docs/v2")
        XCTAssertFalse(link?.isDirectory ?? true)
    }

    func testSetuidPermissionStringIsKeptVerbatim() {
        let entries = RemoteLsParser.parse(fixture)
        let suid = entries.first { $0.name == "sudo" }
        XCTAssertEqual(suid?.permissions, "-rwsr-xr-x")
    }

    func testHiddenFlag() {
        let entries = RemoteLsParser.parse(fixture)
        XCTAssertEqual(entries.first { $0.name == ".config" }?.isHidden, true)
        XCTAssertEqual(entries.first { $0.name == "docs" }?.isHidden, false)
    }

    // MARK: - Edge cases

    func testEmptyOutput() {
        XCTAssertEqual(RemoteLsParser.parse(""), [])
        XCTAssertEqual(RemoteLsParser.parse("not a NUL-framed listing"), [])
    }

    func testGarbageLinesAreSkipped() {
        let output = record("d", "drwxr-xr-x", 0, 0, 4096, "1718000000.0000000000", "ok")
            + record("x", "-rw-r--r--", 0, 0, 1, "1718000000.0000000000", "bad")
            + record("f", "-rw-", 0, 0, 1, "1718000000.0000000000", "also-bad")
        XCTAssertEqual(RemoteLsParser.parse(output).map(\.name), ["ok"])
    }

    func testDeviceNodeWithMajorMinor() {
        let entry = RemoteLsParser.parse(record(
            "b", "brw-rw----", 0, 6, 0, "1718000000.0000000000", "sda"
        )).first
        XCTAssertEqual(entry?.name, "sda")
        XCTAssertEqual(entry?.sizeBytes, 0)
        XCTAssertEqual(entry?.mtimeEpoch, 1_718_000_000)
        XCTAssertEqual(entry?.gid, 6)
    }

    func testSELinuxContextSuffixInPermissions() {
        let entry = RemoteLsParser.parse(record(
            "f", "-rw-r--r--.", 0, 0, 42, "1718000000.0000000000", "selinux.txt"
        )).first
        XCTAssertEqual(entry?.name, "selinux.txt")
        XCTAssertEqual(entry?.permissions, "-rw-r--r--.")
    }

    func testListScriptQuotesThePathAndUsesNULFraming() {
        XCTAssertEqual(
            RemoteLsParser.listScript(path: "/tmp/a b"),
            "cd '/tmp/a b' && LC_ALL=C find . -mindepth 1 -maxdepth 1 -printf '%y\\0%M\\0%U\\0%G\\0%s\\0%T@\\0%f\\0%l\\0'"
        )
        XCTAssertEqual(
            RemoteLsParser.listScript(path: "/it's"),
            "cd '/it'\"'\"'s' && LC_ALL=C find . -mindepth 1 -maxdepth 1 -printf '%y\\0%M\\0%U\\0%G\\0%s\\0%T@\\0%f\\0%l\\0'"
        )
    }

    func testNewlineFilenameCannotCreateSyntheticEntry() {
        let name = "safe-prefix\n-rw-r--r-- 1 1000 1000 1 1718000000 protected-target"
        let entries = RemoteLsParser.parse(record(
            "f", "-rw-r--r--", 1000, 1000, 1, "1718000000.0000000000", name
        ))
        XCTAssertEqual(entries.map(\.name), [name])
    }

    func testOutOfRangeMtimeIsSkippedWithoutTrapping() {
        let entries = RemoteLsParser.parse(record(
            "f", "-rw-r--r--", 1000, 1000, 1, "1e300", "impossible-time"
        ))
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - RemotePath

    func testNormalize() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("  /a/b/  "), "/a/b")
        XCTAssertEqual(RemotePath.normalize("//a///b"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("/"), "/")
    }

    func testParent() {
        XCTAssertEqual(RemotePath.parent(of: "/a/b"), "/a")
        XCTAssertEqual(RemotePath.parent(of: "/a"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/a/b/"), "/a")
    }

    func testJoin() {
        XCTAssertEqual(RemotePath.join("/", "x"), "/x")
        XCTAssertEqual(RemotePath.join("/a", "x y"), "/a/x y")
        XCTAssertEqual(RemotePath.join("/a/", "x"), "/a/x")
    }

    func testLastComponent() {
        XCTAssertEqual(RemotePath.lastComponent(of: "/"), "/")
        XCTAssertEqual(RemotePath.lastComponent(of: "/a"), "a")
        XCTAssertEqual(RemotePath.lastComponent(of: "/a/b/c"), "c")
        XCTAssertEqual(RemotePath.lastComponent(of: "/a/b c/d e"), "d e")
        XCTAssertEqual(RemotePath.lastComponent(of: "/a/b/"), "b")
        XCTAssertEqual(RemotePath.lastComponent(of: "//var//log"), "log")
    }
}
