import XCTest
@testable import HarborKit

final class RemoteQuickDeleteTests: XCTestCase {
    // MARK: - Command building

    func testCommandQuotesEachPathIndependently() throws {
        XCTAssertEqual(
            try RemoteQuickDelete.command(paths: ["/a/b", "/a/with space"]),
            "rm -rf -- '/a/b' '/a/with space'"
        )
    }

    func testCommandEscapesSingleQuotes() throws {
        // sq: wrap in single quotes; an embedded ' becomes '"'"'.
        XCTAssertEqual(
            try RemoteQuickDelete.command(paths: ["/a/it's"]),
            "rm -rf -- '/a/it'\"'\"'s'"
        )
    }

    func testCommandKeepsShellMetacharactersInsideQuotes() throws {
        // Substitution, separators, globs and redirections must all remain
        // literal characters of the single-quoted operand.
        let hostile = "/a/$(touch /tmp/pwn);`id`|&*>#{}"
        let command = try RemoteQuickDelete.command(paths: [hostile])
        XCTAssertEqual(command, "rm -rf -- '\(hostile)'")
    }

    func testCommandOptionTerminatorGuardsDashNames() throws {
        // A path whose final component starts with '-' must never be parsed
        // as an rm option.
        let command = try RemoteQuickDelete.command(paths: ["/a/-rf"])
        XCTAssertTrue(command.hasPrefix("rm -rf -- "))
        XCTAssertEqual(command, "rm -rf -- '/a/-rf'")
    }

    func testCommandPreservesUnicodeAndWhitespace() throws {
        XCTAssertEqual(
            try RemoteQuickDelete.command(paths: ["/数据/备份 2026"]),
            "rm -rf -- '/数据/备份 2026'"
        )
    }

    // MARK: - Validation failures

    func testCommandRejectsEmptySelection() {
        XCTAssertThrowsError(try RemoteQuickDelete.command(paths: [])) { error in
            XCTAssertEqual(error as? QuickDeleteError, .emptySelection)
        }
    }

    func testCommandRejectsEmptyPath() {
        XCTAssertThrowsError(try RemoteQuickDelete.command(paths: [""])) { error in
            XCTAssertEqual(error as? QuickDeleteError, .unsafePath(""))
        }
    }

    func testCommandRejectsRelativePaths() {
        for path in ["a/b", "./x", "../x", "~/x"] {
            XCTAssertThrowsError(try RemoteQuickDelete.command(paths: [path])) { error in
                XCTAssertEqual(error as? QuickDeleteError, .notAbsolute(path))
            }
        }
    }

    func testCommandRejectsControlAndNewlineCharacters() {
        for path in ["/a/\nb", "/a/\rb", "/a/\tb", "/a/\u{0}b", "/a/\u{2028}b"] {
            XCTAssertThrowsError(try RemoteQuickDelete.command(paths: [path]), "\(path.debugDescription) must throw") { error in
                XCTAssertEqual(error as? QuickDeleteError, .unsafePath(path))
            }
        }
    }

    func testCommandValidatesEveryPathBeforeQuoting() {
        // One bad apple in a multi-selection poisons the whole command —
        // nothing may be emitted partially.
        XCTAssertThrowsError(try RemoteQuickDelete.command(paths: ["/ok", "/bad\nname", "/also-ok"]))
        XCTAssertThrowsError(try RemoteQuickDelete.command(paths: ["/ok", "relative"]))
    }

    // MARK: - validate(paths:)

    func testValidateAcceptsAbsolutePaths() {
        XCTAssertNoThrow(try RemoteQuickDelete.validate(paths: ["/", "/a", "/a/b c"]))
    }

    func testValidateMatchesCommandFailures() {
        XCTAssertThrowsError(try RemoteQuickDelete.validate(paths: [])) { error in
            XCTAssertEqual(error as? QuickDeleteError, .emptySelection)
        }
        XCTAssertThrowsError(try RemoteQuickDelete.validate(paths: ["/a\nb"])) { error in
            XCTAssertEqual(error as? QuickDeleteError, .unsafePath("/a\nb"))
        }
        XCTAssertThrowsError(try RemoteQuickDelete.validate(paths: ["rel"])) { error in
            XCTAssertEqual(error as? QuickDeleteError, .notAbsolute("rel"))
        }
    }

    // MARK: - Error descriptions

    func testErrorDescriptionsNeverEchoTheHostilePath() {
        let hostile = "/a/\nrm -rf /"
        let error = QuickDeleteError.unsafePath(hostile)
        XCTAssertFalse(error.localizedDescription.contains("rm -rf /"))
        XCTAssertFalse(QuickDeleteError.notAbsolute("x\ny").localizedDescription.contains("\n"))
        XCTAssertFalse(QuickDeleteError.emptySelection.localizedDescription.isEmpty)
    }
}
