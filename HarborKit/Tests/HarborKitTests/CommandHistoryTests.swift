import XCTest
@testable import HarborKit

final class CommandHistoryTests: XCTestCase {

    // MARK: - Autosuggestion

    func testAutosuggestionReturnsNewestPrefixMatch() {
        let history = CommandHistory(entries: ["git status", "git push origin main", "git pull"])
        // Newest-first: "git pull" is the most recent entry extending "git p".
        XCTAssertEqual(history.autosuggestion(forPrefix: "git p"), "git pull")
        XCTAssertEqual(history.autosuggestion(forPrefix: "git "), "git pull")
    }

    func testAutosuggestionIgnoresEmptyPrefix() {
        let history = CommandHistory(entries: ["ls", "pwd"])
        XCTAssertNil(history.autosuggestion(forPrefix: ""))
        XCTAssertNil(history.autosuggestion(forPrefix: "   "))
    }

    func testAutosuggestionRequiresLongerEntry() {
        let history = CommandHistory(entries: ["ls"])
        // Exact match is not a suggestion (nothing to add).
        XCTAssertNil(history.autosuggestion(forPrefix: "ls"))
        XCTAssertEqual(history.autosuggestion(forPrefix: "l"), "ls")
    }

    func testAutosuggestionCaseSensitive() {
        let history = CommandHistory(entries: ["Docker ps"])
        XCTAssertNil(history.autosuggestion(forPrefix: "docker"))
        XCTAssertEqual(history.autosuggestion(forPrefix: "Docker"), "Docker ps")
    }

    func testAutosuggestionNoMatch() {
        let history = CommandHistory(entries: ["ls", "pwd"])
        XCTAssertNil(history.autosuggestion(forPrefix: "xyz"))
    }

    // MARK: - Recording

    func testRecordAppendsNewestLast() {
        var history = CommandHistory()
        history.record("ls")
        history.record("pwd")
        XCTAssertEqual(history.entries, ["ls", "pwd"])
    }

    func testRecordTrimsWhitespaceAndNewlines() {
        var history = CommandHistory()
        history.record("  ls -la \n")
        XCTAssertEqual(history.entries, ["ls -la"])
    }

    func testRecordIgnoresEmptyAndWhitespaceOnly() {
        var history = CommandHistory()
        history.record("")
        history.record("   ")
        history.record("\n\t")
        XCTAssertEqual(history.entries, [])
    }

    func testConsecutiveDuplicatesAreCollapsed() {
        var history = CommandHistory()
        history.record("ls")
        history.record("ls")
        history.record("ls ") // trims to the same command
        XCTAssertEqual(history.entries, ["ls"])
    }

    func testNonConsecutiveDuplicatesAreKept() {
        var history = CommandHistory()
        history.record("ls")
        history.record("pwd")
        history.record("ls")
        XCTAssertEqual(history.entries, ["ls", "pwd", "ls"])
    }

    func testCapDropsOldestEntries() {
        var history = CommandHistory(limit: 3)
        for cmd in ["a", "b", "c", "d"] { history.record(cmd) }
        XCTAssertEqual(history.entries, ["b", "c", "d"])
    }

    func testDefaultLimitIs2000() {
        var history = CommandHistory()
        for i in 0..<2050 { history.record("cmd \(i)") }
        XCTAssertEqual(history.entries.count, 2000)
        XCTAssertEqual(history.entries.first, "cmd 50")
        XCTAssertEqual(history.entries.last, "cmd 2049")
    }

    func testInitTruncatesStoredEntriesToLimit() {
        let history = CommandHistory(entries: ["a", "b", "c", "d"], limit: 2)
        XCTAssertEqual(history.entries, ["c", "d"])
    }

    // MARK: - Recent (history menu)

    func testRecentReturnsNewestFirst() {
        var history = CommandHistory()
        for cmd in ["a", "b", "c"] { history.record(cmd) }
        XCTAssertEqual(history.recent(2), ["c", "b"])
        XCTAssertEqual(history.recent(10), ["c", "b", "a"])
        XCTAssertEqual(history.recent(0), [])
    }

    // MARK: - Navigator (↑/↓ cycling)

    func testOlderOnEmptyHistoryReturnsNil() {
        var nav = CommandHistoryNavigator()
        XCTAssertNil(nav.older(in: CommandHistory(), current: "draft"))
    }

    func testOlderWalksFromNewestToOldestAndStops() {
        var history = CommandHistory()
        for cmd in ["a", "b", "c"] { history.record(cmd) }
        var nav = CommandHistoryNavigator()
        XCTAssertEqual(nav.older(in: history, current: ""), "c")
        XCTAssertEqual(nav.older(in: history, current: "c"), "b")
        XCTAssertEqual(nav.older(in: history, current: "b"), "a")
        XCTAssertNil(nav.older(in: history, current: "a")) // already oldest
    }

    func testNewerRestoresDraftPastTheNewestEntry() {
        var history = CommandHistory()
        for cmd in ["a", "b"] { history.record(cmd) }
        var nav = CommandHistoryNavigator()
        XCTAssertEqual(nav.older(in: history, current: "half-typed"), "b")
        XCTAssertEqual(nav.older(in: history, current: "b"), "a")
        XCTAssertEqual(nav.newer(in: history), "b")
        XCTAssertEqual(nav.newer(in: history), "half-typed") // draft restored
        XCTAssertNil(nav.newer(in: history)) // already on the draft
    }

    func testNewerWithoutOlderReturnsNil() {
        var history = CommandHistory()
        history.record("ls")
        var nav = CommandHistoryNavigator()
        XCTAssertNil(nav.newer(in: history))
    }

    func testResetForgetsPositionAndDraft() {
        var history = CommandHistory()
        history.record("ls")
        var nav = CommandHistoryNavigator()
        _ = nav.older(in: history, current: "draft")
        nav.reset()
        // Back on the (now empty) draft: older starts from the newest again.
        XCTAssertEqual(nav.older(in: history, current: "x"), "ls")
        XCTAssertEqual(nav.newer(in: history), "x")
    }

    func testOlderClampsWhenHistoryShrankWhileNavigating() {
        var history = CommandHistory()
        for cmd in ["a", "b", "c"] { history.record(cmd) }
        var nav = CommandHistoryNavigator()
        _ = nav.older(in: history, current: "") // at "c" (index 2)
        let shrunk = CommandHistory(entries: ["x"])
        // Index 2 is out of range for the shrunk history; must not crash and
        // must land on a valid entry.
        XCTAssertEqual(nav.older(in: shrunk, current: ""), "x")
    }
}

final class PathHistoryTests: XCTestCase {

    func testRecordAppendsNewestLast() {
        var history = PathHistory()
        history.record("/etc")
        history.record("/var/log")
        XCTAssertEqual(history.entries, ["/etc", "/var/log"])
    }

    func testRecordTrimsWhitespaceAndNewlines() {
        var history = PathHistory()
        history.record("  /etc/nginx \n")
        XCTAssertEqual(history.entries, ["/etc/nginx"])
    }

    func testRecordIgnoresEmptyAndWhitespaceOnly() {
        var history = PathHistory()
        history.record("")
        history.record("   ")
        XCTAssertEqual(history.entries, [])
    }

    func testConsecutiveDuplicatesAreCollapsed() {
        var history = PathHistory()
        history.record("/etc")
        history.record("/etc")
        XCTAssertEqual(history.entries, ["/etc"])
    }

    func testNonConsecutiveDuplicatesAreKept() {
        var history = PathHistory()
        history.record("/etc")
        history.record("/var")
        history.record("/etc")
        XCTAssertEqual(history.entries, ["/etc", "/var", "/etc"])
    }

    func testCapDropsOldestEntries() {
        var history = PathHistory(limit: 3)
        for path in ["/a", "/b", "/c", "/d"] { history.record(path) }
        XCTAssertEqual(history.entries, ["/b", "/c", "/d"])
    }

    func testDefaultLimitIs2000() {
        var history = PathHistory()
        for i in 0..<2050 { history.record("/p\(i)") }
        XCTAssertEqual(history.entries.count, 2000)
        XCTAssertEqual(history.entries.first, "/p50")
        XCTAssertEqual(history.entries.last, "/p2049")
    }

    func testInitTruncatesStoredEntriesToLimit() {
        let history = PathHistory(entries: ["/a", "/b", "/c", "/d"], limit: 2)
        XCTAssertEqual(history.entries, ["/c", "/d"])
    }

    func testRecentReturnsNewestFirst() {
        var history = PathHistory()
        for path in ["/a", "/b", "/c"] { history.record(path) }
        XCTAssertEqual(history.recent(2), ["/c", "/b"])
        XCTAssertEqual(history.recent(10), ["/c", "/b", "/a"])
        XCTAssertEqual(history.recent(0), [])
    }
}
