import XCTest
@testable import HarborKit

final class ShellQuoteTests: XCTestCase {

    func testPlainStringIsWrappedInSingleQuotes() {
        XCTAssertEqual(sq("simple"), "'simple'")
        XCTAssertEqual(sq("/var/log/syslog"), "'/var/log/syslog'")
    }

    func testEmptyStringBecomesEmptyQuotes() {
        XCTAssertEqual(sq(""), "''")
    }

    func testEmbeddedSingleQuoteUsesCloseQuoteReopenTechnique() {
        // don't -> 'don'"'"'t'
        XCTAssertEqual(sq("don't"), "'don'\"'\"'t'")
    }

    func testLoneSingleQuote() {
        XCTAssertEqual(sq("'"), "''\"'\"''")
    }

    func testShellMetacharactersAreInertInsideSingleQuotes() {
        XCTAssertEqual(sq("a;rm -rf / $(boom) `id` $HOME \\"), "'a;rm -rf / $(boom) `id` $HOME \\'")
        XCTAssertEqual(sq("a && b | c > d"), "'a && b | c > d'")
    }

    func testUnicodeIsPreserved() {
        XCTAssertEqual(sq("路径/含 空格"), "'路径/含 空格'")
    }

    func testRoundTripThroughBinSh() throws {
        // The real correctness check: /bin/sh must echo the value verbatim.
        let nasty = "a b'c\"d$e\\f`g;h|i&j>k<l(m)n*o?p!q '' '\"' 汉字"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + sq(nasty)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), nasty)
    }

    func testNULByteIsStripped() {
        // sq() strips NUL bytes to prevent shell string truncation when
        // a malicious server returns a filename containing NUL.
        XCTAssertEqual(sq("a\u{0000}b"), "'ab'")
        XCTAssertEqual(sq("\u{0000}"), "''")
        XCTAssertEqual(sq("a\u{0000}"), "'a'")
    }

    func testControlCharactersPassThrough() {
        // Non-NUL control characters are not modified by sq() — they are
        // passed through inside single quotes. Callers are responsible for
        // rejecting control characters via SSHCommandBuilder.validate().
        let result = sq("a\u{0007}b") // BEL character
        XCTAssertEqual(result, "'a\u{0007}b'")
    }
}
