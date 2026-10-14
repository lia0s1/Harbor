import XCTest
@testable import HarborKit

final class ProcessFDTests: XCTestCase {
    /// Real `ls -l /proc/<pid>/fd` shape: leading `total` line, mixed link
    /// modes, socket/pipe/anon_inode targets, a deleted file.
    private let fixture = """
    total 0
    lrwx------ 1 root root 64 Oct 13 10:00 0 -> /dev/pts/2
    lrwx------ 1 root root 64 Oct 13 10:00 1 -> /dev/pts/2
    lrwx------ 1 root root 64 Oct 13 10:00 2 -> /dev/pts/2
    lrwx------ 1 root root 64 Oct 13 10:00 3 -> socket:[12345]
    l-wx------ 1 root root 64 Oct 13 10:00 4 -> pipe:[6789]
    lrwx------ 1 root root 64 Oct 13 10:00 5 -> socket:[54321]
    lrwx------ 1 root root 64 Oct 13 10:00 6 -> anon_inode:[eventpoll]
    lrwx------ 1 root root 64 Oct 13 10:00 7 -> /var/log/app.log (deleted)
    """

    func testCountsAllFDsAndSockets() {
        let count = ProcFDParser.parse(fixture)
        XCTAssertEqual(count.total, 8)
        XCTAssertEqual(count.socketCount, 2)
    }

    func testSkipsTotalLine() {
        // "total 0" has no " -> " arrow and must not inflate the fd count.
        let count = ProcFDParser.parse(fixture)
        XCTAssertEqual(count.total, 8)
    }

    func testNoSockets() {
        let onlyFiles = """
        total 0
        lrwx------ 1 u u 64 Oct 13 10:00 0 -> /dev/null
        lrwx------ 1 u u 64 Oct 13 10:00 1 -> /tmp/x
        """
        let count = ProcFDParser.parse(onlyFiles)
        XCTAssertEqual(count.total, 2)
        XCTAssertEqual(count.socketCount, 0)
    }

    func testEmpty() {
        let count = ProcFDParser.parse("")
        XCTAssertEqual(count.total, 0)
        XCTAssertEqual(count.socketCount, 0)
    }

    func testArrowInTargetName() {
        // A hostile/odd filename containing " -> " still counts as one fd; the
        // LAST arrow introduces the link target.
        let tricky = "lrwx------ 1 u u 64 Oct 13 10:00 9 -> /tmp/a -> b\n"
        let count = ProcFDParser.parse(tricky)
        XCTAssertEqual(count.total, 1)
        XCTAssertEqual(count.socketCount, 0)
    }

    func testCommandQuotesNumericPid() {
        XCTAssertEqual(ProcFDParser.command(pid: 1234), "LC_ALL=C ls -l /proc/1234/fd 2>/dev/null")
    }
}
