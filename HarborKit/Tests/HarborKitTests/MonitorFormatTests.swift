import XCTest
@testable import HarborKit

final class MonitorFormatTests: XCTestCase {
    // MARK: - sizeShort

    func testSizeShortFromKB() {
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 0), "0K")
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 812), "812K")
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 1024), "1M")
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 113_000), "110M")
        // FinalShell-style memory pair: 2.7G / 3.8G.
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 2_831_155), "2.7G")
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 3_984_588), "3.8G")
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 1_288_490_189), "1.2T")
    }

    func testSizeShortFromBytes() {
        XCTAssertEqual(MonitorFormat.sizeShort(bytes: 0), "0K")
        XCTAssertEqual(MonitorFormat.sizeShort(bytes: 512), "0.5K")
        XCTAssertEqual(MonitorFormat.sizeShort(bytes: 1024 * 1024), "1M")
        XCTAssertEqual(MonitorFormat.sizeShort(bytes: -5), "0K") // never negative
    }

    func testSizeShortDropsTrailingZeroDecimal() {
        // 3 GiB exactly: "3.0G" would be noise — expect "3G".
        XCTAssertEqual(MonitorFormat.sizeShort(kb: 3 * 1024 * 1024), "3G")
    }

    func testSizeShortPromotesUnitAtRoundingBoundary() {
        // A value just below the next unit whose display rounds to 1024 must
        // promote: 1023.5 MiB previously rendered "1024M" instead of "1G".
        let almostOneGiBInBytes = 1023.5 * 1024 * 1024
        XCTAssertEqual(MonitorFormat.sizeShort(bytes: almostOneGiBInBytes), "1G")
        // Just under the rounding boundary still stays in the smaller unit.
        XCTAssertEqual(MonitorFormat.sizeShort(bytes: 1023.4 * 1024 * 1024), "1023M")
    }

    func testSizePair() {
        // FinalShell memory cell: used/total.
        XCTAssertEqual(MonitorFormat.sizePair(2_831_155, 3_984_588), "2.7G/3.8G")
        // Disk row: available/total (>= 10 renders whole numbers, like sizeShort).
        XCTAssertEqual(MonitorFormat.sizePair(4_613_734, 24_431_820), "4.4G/23G")
        XCTAssertEqual(MonitorFormat.sizePair(0, 1024), "0K/1M")
    }

    // MARK: - speed

    func testSpeed() {
        XCTAssertEqual(MonitorFormat.speed(bytesPerSecond: 0), "0 B/s")
        XCTAssertEqual(MonitorFormat.speed(bytesPerSecond: 512), "512 B/s")
        XCTAssertEqual(MonitorFormat.speed(bytesPerSecond: 66_560), "65 KB/s")
        XCTAssertEqual(MonitorFormat.speed(bytesPerSecond: 1_258_291), "1.2 MB/s")
        XCTAssertEqual(MonitorFormat.speed(bytesPerSecond: -1), "0 B/s")
    }

    func testSpeedPromotesUnitAtRoundingBoundary() {
        // 1023.5 KiB/s rounds to "1024" and must promote to "1 MB/s".
        XCTAssertEqual(MonitorFormat.speed(bytesPerSecond: 1023.5 * 1024), "1 MB/s")
    }

    func testSpeedAxisLabel() {
        XCTAssertEqual(MonitorFormat.speedAxisLabel(bytesPerSecond: 0), "0")
        XCTAssertEqual(MonitorFormat.speedAxisLabel(bytesPerSecond: 0.4), "0")
        XCTAssertEqual(MonitorFormat.speedAxisLabel(bytesPerSecond: 500), "500B")
        XCTAssertEqual(MonitorFormat.speedAxisLabel(bytesPerSecond: 66_560), "65K")
        XCTAssertEqual(MonitorFormat.speedAxisLabel(bytesPerSecond: 1_258_291), "1.2M")
    }

    func testSpeedAxisLabelPromotesUnitAtRoundingBoundary() {
        // 1023.5 KiB rounds to "1024" and must promote to "1M", not "1024K".
        XCTAssertEqual(MonitorFormat.speedAxisLabel(bytesPerSecond: 1023.5 * 1024), "1M")
    }

    // MARK: - uptime

    func testUptime() {
        let zh = Locale(identifier: "zh-CN")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 410 * 86_400 + 3 * 3_600, locale: zh), "410 天 3 小时")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 2 * 86_400, locale: zh), "2 天")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 3 * 3_600 + 25 * 60, locale: zh), "3 小时 25 分钟")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 3_600, locale: zh), "1 小时")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 300, locale: zh), "5 分钟")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 45, locale: zh), "45 秒")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 0, locale: zh), "0 秒")
        XCTAssertEqual(MonitorFormat.uptime(seconds: -10, locale: zh), "0 秒")
    }

    func testUptimeEnglish() {
        let en = Locale(identifier: "en-US")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 410 * 86_400 + 3 * 3_600, locale: en), "410 d 3 h")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 3 * 3_600 + 25 * 60, locale: en), "3 h 25 m")
        XCTAssertEqual(MonitorFormat.uptime(seconds: 45, locale: en), "45 s")
    }

    func testUptimeDoesNotCrashOnNonFiniteOrAbsurdValues() {
        // Converting a non-finite or overflowing Double to Int is a hard trap;
        // the panel must degrade gracefully rather than crash the whole app.
        let zh = Locale(identifier: "zh-CN")
        XCTAssertEqual(MonitorFormat.uptime(seconds: .infinity, locale: zh), "0 秒")
        XCTAssertEqual(MonitorFormat.uptime(seconds: .nan, locale: zh), "0 秒")
        XCTAssertEqual(MonitorFormat.uptime(seconds: -.infinity, locale: zh), "0 秒")
        // A finite-but-huge value is clamped (not trapped) and yields a string.
        XCTAssertFalse(MonitorFormat.uptime(seconds: 1e300, locale: zh).isEmpty)
    }

    // MARK: - milliseconds

    func testMilliseconds() {
        XCTAssertEqual(MonitorFormat.milliseconds(254.3), "254 ms")
        XCTAssertEqual(MonitorFormat.milliseconds(9.94), "9.9 ms")
        XCTAssertEqual(MonitorFormat.milliseconds(0.42), "0.4 ms")
        XCTAssertEqual(MonitorFormat.milliseconds(-3), "0.0 ms")
    }

    // MARK: - percent / load

    func testPercent() {
        XCTAssertEqual(MonitorFormat.percent(71.2), "71%")
        XCTAssertEqual(MonitorFormat.percent(0), "0%")
        XCTAssertEqual(MonitorFormat.percent(105), "100%")
        XCTAssertEqual(MonitorFormat.percent(-3), "0%")
    }

    func testLoadAverage() {
        XCTAssertEqual(MonitorFormat.loadAverage(0.28, 0.31, 0.27), "0.28, 0.31, 0.27")
        XCTAssertEqual(MonitorFormat.loadAverage(12, 3.5, 0), "12.00, 3.50, 0.00")
    }

    func testProcessCPU() {
        XCTAssertEqual(MonitorFormat.processCPU(3.27), "3.3")
        XCTAssertEqual(MonitorFormat.processCPU(0), "0")
        XCTAssertEqual(MonitorFormat.processCPU(1.0), "1")
        XCTAssertEqual(MonitorFormat.processCPU(12.4), "12")
        XCTAssertEqual(MonitorFormat.processCPU(-1), "0")
    }
}
