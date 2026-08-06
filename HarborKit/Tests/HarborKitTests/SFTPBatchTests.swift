import XCTest
@testable import HarborKit

final class SFTPBatchTests: XCTestCase {
    // MARK: - Quoting

    func testQuotePlainAndSpaces() throws {
        XCTAssertEqual(try SFTPBatch.quote("/a/b"), "\"/a/b\"")
        XCTAssertEqual(try SFTPBatch.quote("/a/with space"), "\"/a/with space\"")
    }

    func testQuoteEscapesQuotesAndBackslashes() throws {
        XCTAssertEqual(try SFTPBatch.quote("a\"b"), "\"a\\\"b\"")
        // Escape `\` first so a following `"` cannot terminate the token early.
        XCTAssertEqual(try SFTPBatch.quote("a\\b"), "\"a\\\\b\"")
    }

    func testQuoteRejectsControlAndNewlineCharacters() {
        XCTAssertThrowsError(try SFTPBatch.quote("/a/\nb")) { error in
            XCTAssertEqual(error as? SFTPBatchError, .unsafePath("/a/\nb"))
        }
        XCTAssertThrowsError(try SFTPBatch.quote("/a/\rb"))
        XCTAssertThrowsError(try SFTPBatch.quote("/a/\u{0000}b"))
        XCTAssertThrowsError(try SFTPBatch.quote("/a/\u{2028}b"))
        XCTAssertThrowsError(try SFTPBatch.get(remote: "/ok", local: "/tmp/x\ny"))
        XCTAssertThrowsError(try SFTPBatch.put(local: "/tmp/x", remote: "evil\n!rm"))
    }

    func testQuoteGlobbedEscapesGlobCharacters() throws {
        // Tokenizer keeps `\*` literally inside quotes; glob(3) then treats
        // it as a literal star.
        XCTAssertEqual(try SFTPBatch.quoteGlobbed("*.log"), "\"\\\\*.log\"")
        XCTAssertEqual(try SFTPBatch.quoteGlobbed("a?b"), "\"a\\\\?b\"")
        XCTAssertEqual(try SFTPBatch.quoteGlobbed("a[1]"), "\"a\\\\[1]\"")
        // A real backslash is glob-escaped then tokenizer-doubled.
        XCTAssertEqual(try SFTPBatch.quoteGlobbed("a\\b"), "\"a\\\\\\\\b\"")
    }

    // MARK: - Batch lines

    func testGet() throws {
        XCTAssertEqual(
            try SFTPBatch.get(remote: "/srv/f 1.txt", local: "/Users/me/Downloads/f 1.txt"),
            "get -p \"/srv/f 1.txt\" \"/Users/me/Downloads/f 1.txt\""
        )
    }

    func testGetRecursive() throws {
        XCTAssertEqual(
            try SFTPBatch.get(remote: "/srv/dir", local: "/tmp/dir", recursive: true),
            "get -p -R \"/srv/dir\" \"/tmp/dir\""
        )
    }

    func testPut() throws {
        XCTAssertEqual(
            try SFTPBatch.put(local: "/tmp/up.bin", remote: "/srv/up.bin"),
            "put -p \"/tmp/up.bin\" \"/srv/up.bin\""
        )
        XCTAssertEqual(
            try SFTPBatch.put(local: "/tmp/d", remote: "/srv/d", recursive: true),
            "put -p -R \"/tmp/d\" \"/srv/d\""
        )
    }

    func testRenameAndMkdir() throws {
        XCTAssertEqual(
            try SFTPBatch.rename(from: "/a/old name", to: "/a/new name"),
            "rename \"/a/old name\" \"/a/new name\""
        )
        XCTAssertEqual(try SFTPBatch.mkdir("/a/新建文件夹"), "mkdir \"/a/新建文件夹\"")
    }

    // MARK: - sftp argv

    func testSftpBatchCommandDefaultPort() throws {
        XCTAssertEqual(
            try SSHCommandBuilder.sftpBatchCommand(
                controlSocketPath: "/tmp/cm-abc",
                destination: "user@host"
            ),
            [
                "/usr/bin/sftp",
                "-b", "-",
                "-o", "ControlMaster=no",
                "-o", "ControlPath=/tmp/cm-abc",
                "-o", "BatchMode=yes",
                "user@host",
            ]
        )
    }

    func testSftpBatchCommandCustomPort() throws {
        let argv = try SSHCommandBuilder.sftpBatchCommand(
            controlSocketPath: "/tmp/cm-abc",
            destination: "host",
            port: 2222
        )
        XCTAssertEqual(Array(argv.suffix(3)), ["-P", "2222", "host"])
    }

    func testSftpBatchCommandPort22IsOmitted() throws {
        let argv = try SSHCommandBuilder.sftpBatchCommand(
            controlSocketPath: "/tmp/cm-abc",
            destination: "host",
            port: 22
        )
        XCTAssertFalse(argv.contains("-P"))
    }
}
