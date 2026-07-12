import XCTest
@testable import HarborKit

final class SFTPBatchTests: XCTestCase {
    // MARK: - Quoting

    func testQuotePlainAndSpaces() {
        XCTAssertEqual(SFTPBatch.quote("/a/b"), "\"/a/b\"")
        XCTAssertEqual(SFTPBatch.quote("/a/with space"), "\"/a/with space\"")
    }

    func testQuoteEscapesQuotesAndKeepsBackslashesLiteral() {
        XCTAssertEqual(SFTPBatch.quote("a\"b"), "\"a\\\"b\"")
        // sftp's tokenizer keeps a backslash inside double quotes literal
        // (unless it precedes a quote), so no doubling.
        XCTAssertEqual(SFTPBatch.quote("a\\b"), "\"a\\b\"")
    }

    func testQuoteGlobbedEscapesGlobCharacters() {
        // Tokenizer keeps `\*` literally inside quotes; glob(3) then treats
        // it as a literal star.
        XCTAssertEqual(SFTPBatch.quoteGlobbed("*.log"), "\"\\*.log\"")
        XCTAssertEqual(SFTPBatch.quoteGlobbed("a?b"), "\"a\\?b\"")
        XCTAssertEqual(SFTPBatch.quoteGlobbed("a[1]"), "\"a\\[1]\"")
        // A real backslash is doubled for glob; the tokenizer keeps both.
        XCTAssertEqual(SFTPBatch.quoteGlobbed("a\\b"), "\"a\\\\b\"")
    }

    // MARK: - Batch lines

    func testGet() {
        XCTAssertEqual(
            SFTPBatch.get(remote: "/srv/f 1.txt", local: "/Users/me/Downloads/f 1.txt"),
            "get -p \"/srv/f 1.txt\" \"/Users/me/Downloads/f 1.txt\""
        )
    }

    func testGetRecursive() {
        XCTAssertEqual(
            SFTPBatch.get(remote: "/srv/dir", local: "/tmp/dir", recursive: true),
            "get -p -R \"/srv/dir\" \"/tmp/dir\""
        )
    }

    func testPut() {
        XCTAssertEqual(
            SFTPBatch.put(local: "/tmp/up.bin", remote: "/srv/up.bin"),
            "put -p \"/tmp/up.bin\" \"/srv/up.bin\""
        )
        XCTAssertEqual(
            SFTPBatch.put(local: "/tmp/d", remote: "/srv/d", recursive: true),
            "put -p -R \"/tmp/d\" \"/srv/d\""
        )
    }

    func testRenameAndMkdir() {
        XCTAssertEqual(
            SFTPBatch.rename(from: "/a/old name", to: "/a/new name"),
            "rename \"/a/old name\" \"/a/new name\""
        )
        XCTAssertEqual(SFTPBatch.mkdir("/a/新建文件夹"), "mkdir \"/a/新建文件夹\"")
    }

    // MARK: - sftp argv

    func testSftpBatchCommandDefaultPort() {
        XCTAssertEqual(
            SSHCommandBuilder.sftpBatchCommand(
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

    func testSftpBatchCommandCustomPort() {
        let argv = SSHCommandBuilder.sftpBatchCommand(
            controlSocketPath: "/tmp/cm-abc",
            destination: "host",
            port: 2222
        )
        XCTAssertEqual(Array(argv.suffix(3)), ["-P", "2222", "host"])
    }

    func testSftpBatchCommandPort22IsOmitted() {
        let argv = SSHCommandBuilder.sftpBatchCommand(
            controlSocketPath: "/tmp/cm-abc",
            destination: "host",
            port: 22
        )
        XCTAssertFalse(argv.contains("-P"))
    }
}
