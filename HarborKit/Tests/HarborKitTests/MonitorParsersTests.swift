import XCTest
@testable import HarborKit

final class MonitorParsersTests: XCTestCase {

    /// Realistic full payload as produced by the remote script on a small
    /// Debian VPS (one section per command, separated by @@HARBOR@@ lines).
    private let linuxPayload = """
    Linux
    @@HARBOR@@
    35453006.92 280412407.62
    @@HARBOR@@
    0.28 0.31 0.27 2/345 12345
    @@HARBOR@@
    cpu  74608 2520 24433 1117073 6176 0 4054 17 3 0
    cpu0 17977 551 6082 279174 1640 0 1023 4 1 0
    cpu1 18877 689 6112 279312 1521 0 1011 5 1 0
    intr 33124511 122 9 0 0 0 0 3 0 1
    ctxt 23456789
    btime 1700000000
    processes 882711
    procs_running 2
    procs_blocked 0
    @@HARBOR@@
    MemTotal:        3961748 kB
    MemFree:          161236 kB
    MemAvailable:    1123444 kB
    Buffers:          136472 kB
    Cached:          1153500 kB
    SwapCached:         8516 kB
    SwapTotal:       2097148 kB
    SwapFree:        1947388 kB
    Dirty:               296 kB
    @@HARBOR@@
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 12345678   84927    0    0    0     0          0         0 12345678   84927    0    0    0     0       0          0
      eth0: 9876543210 7654321    0    0    0     0          0         0 1234567890 2345678    0    0    0     0       0          0
    br-d2acf1a66c1b:    1024      10    0    0    0     0          0         0     2048      20    0    0    0     0       0          0
    @@HARBOR@@
    Filesystem     1024-blocks      Used Available Capacity Mounted on
    udev               1989608         0   1989608       0% /dev
    tmpfs               396176      1124    395052       1% /run
    /dev/vda1         82043980  24013880  54658188      31% /
    tmpfs              1980872         0   1980872       0% /dev/shm
    /dev/vda15          126678      6004    120674       5% /boot/efi
    overlay           82043980  24013880  54658188      31% /var/lib/docker/overlay2/abc123/merged
    /dev/loop3           63488     63488         0     100% /snap/core20/1974
    tmpfs               396172         0    396172       0% /run/user/1001
    /dev/sdb1        515928320 123456789 366178904      26% /data
    @@HARBOR@@
    PID USER             %CPU   RSS COMMAND
     1234 mysql           12.3 245760 mysqld
     2345 root             3.4  87236 java
     3456 www-data         0.8  14808 nginx
      789 root             0.2   5120 sshd
        1 root             0.1   2048 systemd
       42 root             0.0   1024 kworker/0:1H
    """

    // MARK: - Full payload

    func testFullPayloadParsesEverySection() {
        let snap = MonitorParsers.parseSnapshot(linuxPayload)

        XCTAssertEqual(snap.os, "Linux")
        XCTAssertTrue(snap.isLinux)
        XCTAssertEqual(snap.uptimeSeconds, 35_453_006.92, accuracy: 0.001)
        XCTAssertEqual(snap.load1, 0.28, accuracy: 0.0001)
        XCTAssertEqual(snap.load5, 0.31, accuracy: 0.0001)
        XCTAssertEqual(snap.load15, 0.27, accuracy: 0.0001)

        let ticks = snap.cpuTicks
        XCTAssertEqual(ticks?.user, 74_608)
        XCTAssertEqual(ticks?.nice, 2_520)
        XCTAssertEqual(ticks?.system, 24_433)
        XCTAssertEqual(ticks?.idle, 1_117_073)
        XCTAssertEqual(ticks?.iowait, 6_176)
        XCTAssertEqual(ticks?.irq, 0)
        XCTAssertEqual(ticks?.softirq, 4_054)
        XCTAssertEqual(ticks?.steal, 17)
        // guest columns ignored, not summed into total
        XCTAssertEqual(ticks?.total, 74_608 + 2_520 + 24_433 + 1_117_073 + 6_176 + 0 + 4_054 + 17)

        XCTAssertEqual(snap.memTotalKB, 3_961_748)
        XCTAssertEqual(snap.memAvailableKB, 1_123_444)
        XCTAssertEqual(snap.swapTotalKB, 2_097_148)
        XCTAssertEqual(snap.swapFreeKB, 1_947_388)

        XCTAssertEqual(snap.interfaces.map(\.name), ["lo", "eth0", "br-d2acf1a66c1b"])
        XCTAssertEqual(snap.disks.map(\.mount), ["/", "/boot/efi", "/data"])
        XCTAssertEqual(snap.topProcesses.count, 6)
    }

    func testNonLinuxPayloadOnlyTrustsOSField() {
        // macOS host: uname says Darwin, /proc reads fail (empty sections),
        // df works but reports mac volumes; the gate is the os field.
        let payload = """
        Darwin
        @@HARBOR@@
        @@HARBOR@@
        @@HARBOR@@
        @@HARBOR@@
        @@HARBOR@@
        @@HARBOR@@
        Filesystem 1024-blocks      Used Available Capacity  Mounted on
        /dev/disk3s1s1  971350180  10485760 670492672     2%    /
        @@HARBOR@@
        """
        let snap = MonitorParsers.parseSnapshot(payload)
        XCTAssertEqual(snap.os, "Darwin")
        XCTAssertFalse(snap.isLinux)
        XCTAssertNil(snap.cpuTicks)
        XCTAssertEqual(snap.memTotalKB, 0)
    }

    func testGarbageAndEmptyPayloadsDoNotCrash() {
        XCTAssertEqual(MonitorParsers.parseSnapshot("").os, "")
        XCTAssertEqual(MonitorParsers.parseSnapshot("@@HARBOR@@\n@@HARBOR@@").os, "")
        let junk = MonitorParsers.parseSnapshot("!!!\n@@HARBOR@@\nnot numbers at all")
        XCTAssertEqual(junk.os, "!!!")
        XCTAssertEqual(junk.uptimeSeconds, 0)
    }

    func testRemoteScriptHasEightSections() {
        // 7 separators -> 8 sections, matching the parser's section indices.
        let echoCount = MonitorParsers.remoteScript
            .components(separatedBy: "echo @@HARBOR@@").count - 1
        XCTAssertEqual(echoCount, 7)
        XCTAssertTrue(MonitorParsers.remoteScript.hasPrefix("uname -s; "))
        XCTAssertTrue(MonitorParsers.remoteScript.hasSuffix("| head -16"))
    }

    // MARK: - Section parsers

    func testParseUptime() {
        XCTAssertEqual(MonitorParsers.parseUptime("12345.67 99999.99"), 12345.67)
        XCTAssertEqual(MonitorParsers.parseUptime("410.0"), 410.0)
        XCTAssertNil(MonitorParsers.parseUptime(""))
        XCTAssertNil(MonitorParsers.parseUptime("abc"))
    }

    func testParseUptimeRejectsNonFiniteAndNegative() {
        // Double() accepts these; a downstream Int(seconds) would trap on a
        // non-finite value and crash the app from one hostile/corrupt line.
        XCTAssertNil(MonitorParsers.parseUptime("inf"))
        XCTAssertNil(MonitorParsers.parseUptime("nan"))
        XCTAssertNil(MonitorParsers.parseUptime("1e400")) // overflows to +inf
        XCTAssertNil(MonitorParsers.parseUptime("-5"))
    }

    func testParseLoadAvg() {
        let load = MonitorParsers.parseLoadAvg("0.28 0.31 0.27 1/123 4567")
        XCTAssertEqual(load?.0, 0.28)
        XCTAssertEqual(load?.1, 0.31)
        XCTAssertEqual(load?.2, 0.27)
        XCTAssertNil(MonitorParsers.parseLoadAvg("0.28 0.31"))
    }

    func testParseLoadAvgRejectsNonFinite() {
        XCTAssertNil(MonitorParsers.parseLoadAvg("inf nan 0.27"))
        XCTAssertNil(MonitorParsers.parseLoadAvg("1e400 0.31 0.27"))
    }

    func testParseCPUTicksWithExactlyEightColumns() {
        let ticks = MonitorParsers.parseCPUTicks("cpu 100 5 50 800 30 2 8 5\ncpu0 1 2 3 4 5 6 7 8")
        XCTAssertEqual(ticks, CPUTicks(user: 100, nice: 5, system: 50, idle: 800,
                                       iowait: 30, irq: 2, softirq: 8, steal: 5))
    }

    func testParseCPUTicksOldKernelWithFourColumnsDefaultsRestToZero() {
        let ticks = MonitorParsers.parseCPUTicks("cpu 10 20 30 40")
        XCTAssertEqual(ticks, CPUTicks(user: 10, nice: 20, system: 30, idle: 40))
        XCTAssertEqual(ticks?.steal, 0)
    }

    func testParseCPUTicksIgnoresPerCoreLinesAndMissingAggregate() {
        XCTAssertNil(MonitorParsers.parseCPUTicks("cpu0 1 2 3 4\nintr 5"))
        XCTAssertNil(MonitorParsers.parseCPUTicks(""))
    }

    func testParseCPUTicksRejectsNonNumericColumns() {
        // A garbled column skips the whole sample instead of becoming 0 (which
        // would silently skew the busy/idle delta and report a bogus CPU%).
        XCTAssertNil(MonitorParsers.parseCPUTicks("cpu x y z 800 30 2 8 5"))
        XCTAssertNil(MonitorParsers.parseCPUTicks("cpu 100 5 50 -800 30"))
        XCTAssertNil(MonitorParsers.parseCPUTicks("cpu")) // bare keyword, no columns
    }

    func testParsePerCoreCPUTicks() {
        let cores = MonitorParsers.parsePerCoreCPUTicks("""
        cpu  100 5 50 800 30 2 8 5
        cpu0 10 1 5 80 3 0 1 0
        cpu1 20 2 10 90 4 1 2 1
        intr 99999
        """)
        XCTAssertEqual(cores.count, 2)
        XCTAssertEqual(cores[0], CPUTicks(user: 10, nice: 1, system: 5, idle: 80, iowait: 3, irq: 0, softirq: 1, steal: 0))
        XCTAssertEqual(cores[1].user, 20)
    }

    func testParsePerCoreCPUTicksExcludesAggregateAndGarbage() {
        // The aggregate "cpu" line is not a core; a garbled core is skipped.
        let cores = MonitorParsers.parsePerCoreCPUTicks("cpu 1 2 3 4\ncpu0 1 2 3 4\ncpu1 x y z\ncpu2 9 9 9 9")
        XCTAssertEqual(cores.count, 2) // cpu0 and cpu2; cpu1 skipped, aggregate excluded
        XCTAssertEqual(cores.first?.user, 1)
        XCTAssertEqual(cores.last?.user, 9)
        XCTAssertTrue(MonitorParsers.parsePerCoreCPUTicks("cpu 1 2 3 4").isEmpty)
    }

    func testCPUBreakdownSharesSumToTotal() {
        let prev = CPUTicks(user: 100, nice: 0, system: 50, idle: 800, iowait: 10)
        let curr = CPUTicks(user: 150, nice: 0, system: 70, idle: 880, iowait: 20)
        // total delta = 50+20+80+10 = 160
        let bd = MonitorParsers.cpuBreakdown(previous: prev, current: curr)
        XCTAssertNotNil(bd)
        XCTAssertEqual(bd!.user, 50.0 / 160.0 * 100, accuracy: 0.001)
        XCTAssertEqual(bd!.system, 20.0 / 160.0 * 100, accuracy: 0.001)
        XCTAssertEqual(bd!.idle, 80.0 / 160.0 * 100, accuracy: 0.001)
        XCTAssertEqual(bd!.iowait, 10.0 / 160.0 * 100, accuracy: 0.001)
        let sum = bd!.user + bd!.system + bd!.nice + bd!.iowait + bd!.irq + bd!.softirq + bd!.steal + bd!.idle
        XCTAssertEqual(sum, 100, accuracy: 0.001)
    }

    func testCPUBreakdownNilWhenNotAdvancing() {
        let ticks = CPUTicks(user: 100, idle: 900)
        XCTAssertNil(MonitorParsers.cpuBreakdown(previous: ticks, current: ticks))
    }

    func testParseMemInfoKeepsFreeBuffersCached() {
        let info = MonitorParsers.parseMemInfo("""
        MemTotal:        3961748 kB
        MemFree:          161236 kB
        MemAvailable:    1123444 kB
        Buffers:          136472 kB
        Cached:          1153500 kB
        """)
        XCTAssertEqual(info.freeKB, 161_236)
        XCTAssertEqual(info.buffersKB, 136_472)
        XCTAssertEqual(info.cachedKB, 1_153_500)
        XCTAssertEqual(info.availableKB, 1_123_444)
    }

    func testParseMemInfoPrefersMemAvailable() {
        let info = MonitorParsers.parseMemInfo("""
        MemTotal:        3961748 kB
        MemFree:          161236 kB
        MemAvailable:    1123444 kB
        Buffers:          136472 kB
        Cached:          1153500 kB
        SwapTotal:       2097148 kB
        SwapFree:        1947388 kB
        """)
        XCTAssertEqual(info.totalKB, 3_961_748)
        XCTAssertEqual(info.availableKB, 1_123_444)
        XCTAssertEqual(info.swapTotalKB, 2_097_148)
        XCTAssertEqual(info.swapFreeKB, 1_947_388)
    }

    func testParseMemInfoFallsBackToFreePlusBuffersPlusCached() {
        // Kernels < 3.14 have no MemAvailable.
        let info = MonitorParsers.parseMemInfo("""
        MemTotal:        1020000 kB
        MemFree:          100000 kB
        Buffers:           20000 kB
        Cached:           300000 kB
        SwapTotal:             0 kB
        SwapFree:              0 kB
        """)
        XCTAssertEqual(info.availableKB, 420_000)
        XCTAssertEqual(info.swapTotalKB, 0)
    }

    func testParseNetDevHandlesWeirdNamesAndNoSpaceAfterColon() {
        let text = """
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 100 1 0 0 0 0 0 0 200 2 0 0 0 0 0 0
        eth0:9876543210 7654321 0 0 0 0 0 0 1234567890 2345678 0 0 0 0 0 0
        br-d2acf1a66c1b: 1024 10 0 0 0 0 0 0 2048 20 0 0 0 0 0 0
        veth1a2b.42: 11 1 0 0 0 0 0 0 22 2 0 0 0 0 0 0
        """
        let interfaces = MonitorParsers.parseNetDev(text)
        XCTAssertEqual(interfaces.count, 4)
        XCTAssertEqual(
            interfaces[0],
            NetworkInterfaceCounters(name: "lo", rxBytes: 100, txBytes: 200, rxPackets: 1, txPackets: 2)
        )
        XCTAssertEqual(interfaces[1].name, "eth0")
        XCTAssertEqual(interfaces[1].rxBytes, 9_876_543_210) // > UInt32.max
        XCTAssertEqual(interfaces[1].txBytes, 1_234_567_890)
        XCTAssertEqual(interfaces[1].rxPackets, 7_654_321)
        XCTAssertEqual(interfaces[1].txPackets, 2_345_678)
        XCTAssertEqual(interfaces[2].name, "br-d2acf1a66c1b")
        XCTAssertEqual(interfaces[3].name, "veth1a2b.42")
    }

    func testParseNetDevCapturesPacketsAndErrors() {
        // rx: bytes packets errs drop … (0-7), tx: bytes packets errs drop … (8-15)
        let text = "eth0: 1000 50 2 1 0 0 0 0 2000 80 3 4 0 0 0 0"
        let ifaces = MonitorParsers.parseNetDev(text)
        XCTAssertEqual(ifaces.count, 1)
        XCTAssertEqual(ifaces[0].rxPackets, 50)
        XCTAssertEqual(ifaces[0].txPackets, 80)
        XCTAssertEqual(ifaces[0].rxErrors, 2)
        XCTAssertEqual(ifaces[0].txErrors, 3)
        XCTAssertEqual(ifaces[0].rxDrops, 1)
        XCTAssertEqual(ifaces[0].txDrops, 4)
    }

    func testParseNetDevSkipsMalformedLines() {
        XCTAssertTrue(MonitorParsers.parseNetDev("eth0: 1 2 3").isEmpty) // too few columns
        XCTAssertTrue(MonitorParsers.parseNetDev("no colon here").isEmpty)
    }

    func testParseDFFiltersPseudoFilesystems() {
        let disks = MonitorParsers.parseDF("""
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        udev               1989608         0   1989608       0% /dev
        tmpfs               396176      1124    395052       1% /run
        /dev/vda1         82043980  24013880  54658188      31% /
        tmpfs              1980872         0   1980872       0% /dev/shm
        overlay           82043980  24013880  54658188      31% /var/lib/docker/overlay2/x/merged
        /dev/loop3           63488     63488         0     100% /snap/core20/1974
        /dev/sdb1        515928320 123456789 366178904      26% /data
        """)
        XCTAssertEqual(disks.map(\.mount), ["/", "/data"])
        XCTAssertEqual(disks[0].totalKB, 82_043_980)
        XCTAssertEqual(disks[0].availableKB, 54_658_188)
        XCTAssertEqual(disks[1].totalKB, 515_928_320)
    }

    func testParseDFKeepsMountPointsWithSpaces() {
        let disks = MonitorParsers.parseDF("""
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/sdc1 1000 100 900 10% /mnt/my disk
        """)
        XCTAssertEqual(disks, [DiskUsage(mount: "/mnt/my disk", totalKB: 1000, availableKB: 900)])
    }

    func testParseDFDedupesByMountPoint() {
        let disks = MonitorParsers.parseDF("""
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/sda1 1000 100 900 10% /
        /dev/sda1 1000 100 900 10% /
        """)
        XCTAssertEqual(disks.count, 1)
    }

    func testDiskUsageDerivedValues() {
        let disk = DiskUsage(mount: "/", totalKB: 1000, availableKB: 250)
        XCTAssertEqual(disk.usedKB, 750)
        XCTAssertEqual(disk.usedFraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(DiskUsage(mount: "/", totalKB: 0, availableKB: 0).usedFraction, 0)
    }

    func testParseTopProcessesSkipsHeaderAndKeepsCommandSpaces() {
        // New layout: pid user pcpu rss comm…
        let rows = MonitorParsers.parseTopProcesses("""
        PID USER             %CPU   RSS COMMAND
         1234 mysql           12.3 245760 mysqld
          678 root             0.5   2048 VBoxClient --clipboard
           42 root             0.0   1024 kworker/0:1H
        garbage line
        """)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], TopProcess(
            cpuPercent: 12.3, rssKB: 245_760, command: "mysqld", pid: 1234, user: "mysql"
        ))
        XCTAssertEqual(rows[0].pid, 1234)
        XCTAssertEqual(rows[0].user, "mysql")
        XCTAssertEqual(rows[1].command, "VBoxClient --clipboard")
        XCTAssertEqual(rows[1].pid, 678)
        XCTAssertEqual(rows[2].command, "kworker/0:1H")
    }

    func testParseTopProcessesRequiresFullFiveColumnLayout() {
        // The remote script always emits the five-column layout; a short
        // (e.g. 3-column "pcpu rss comm") line has no pid/user and is dropped.
        let rows = MonitorParsers.parseTopProcesses("""
        12.3 245760 mysqld
         1234 mysql           12.3 245760 mysqld
        """)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].pid, 1234)
        XCTAssertEqual(rows[0].command, "mysqld")
    }

    // MARK: - Delta helpers

    func testCPUPercentBetweenSamples() {
        let prev = CPUTicks(user: 100, nice: 0, system: 50, idle: 850)
        let curr = CPUTicks(user: 150, nice: 0, system: 70, idle: 880)
        // busy delta 70 over total delta 100 -> 70%
        let pct = MonitorParsers.cpuPercent(previous: prev, current: curr)
        XCTAssertEqual(pct ?? -1, 70.0, accuracy: 0.0001)
    }

    func testCPUPercentCountsIowaitAsIdle() {
        let prev = CPUTicks(user: 100, idle: 800, iowait: 100)
        let curr = CPUTicks(user: 120, idle: 850, iowait: 130)
        // busy 20 / total 100 -> 20%
        XCTAssertEqual(MonitorParsers.cpuPercent(previous: prev, current: curr) ?? -1, 20.0, accuracy: 0.0001)
    }

    func testCPUPercentNilWhenCountersDidNotAdvanceOrWentBackwards() {
        let ticks = CPUTicks(user: 100, idle: 900)
        XCTAssertNil(MonitorParsers.cpuPercent(previous: ticks, current: ticks))
        let earlier = CPUTicks(user: 50, idle: 400)
        XCTAssertNil(MonitorParsers.cpuPercent(previous: ticks, current: earlier))
    }

    func testCPUTicksTotalSaturatesInsteadOfTrapping() {
        // A hostile/corrupt /proc/stat can emit columns near UInt64.max. A plain
        // `+` would TRAP (crashing the whole app on a single monitoring sample);
        // saturating addition must pin at UInt64.max instead.
        let ticks = CPUTicks(
            user: .max, nice: .max, system: 0, idle: 0,
            iowait: 0, irq: 0, softirq: 0, steal: 0
        )
        XCTAssertEqual(ticks.total, .max)
        XCTAssertEqual(ticks.idleAll, 0)

        let idleOverflow = CPUTicks(idle: .max, iowait: .max)
        XCTAssertEqual(idleOverflow.idleAll, .max)
    }

    func testCPUPercentDoesNotCrashOnOverflowingColumns() {
        // The end-to-end path: a cpu line with multiple UInt64.max columns must
        // parse and feed cpuPercent without trapping.
        let current = MonitorParsers.parseCPUTicks(
            "cpu 18446744073709551615 18446744073709551615 0 0 0 0 0 0"
        )
        let previous = CPUTicks(user: 1, idle: 1)
        XCTAssertNotNil(current)
        // No crash; total saturated so the busy fraction stays within [0, 100].
        if let current {
            let pct = MonitorParsers.cpuPercent(previous: previous, current: current)
            if let pct { XCTAssertTrue(pct >= 0 && pct <= 100) }
        }
    }

    func testNetSpeed() {
        XCTAssertEqual(MonitorParsers.netSpeed(previousBytes: 1000, currentBytes: 3000, seconds: 2), 1000)
        XCTAssertEqual(MonitorParsers.netSpeed(previousBytes: 0, currentBytes: 0, seconds: 2), 0)
    }

    func testNetSpeedCounterResetReportsZero() {
        XCTAssertEqual(MonitorParsers.netSpeed(previousBytes: 5000, currentBytes: 100, seconds: 2), 0)
        XCTAssertEqual(MonitorParsers.netSpeed(previousBytes: 100, currentBytes: 200, seconds: 0), 0)
    }

    // MARK: - Ping

    func testPingLatencyParsesReplyLines() {
        XCTAssertEqual(
            MonitorParsers.pingLatency(line: "64 bytes from 93.184.216.34: icmp_seq=0 ttl=56 time=12.345 ms"),
            12.345
        )
        XCTAssertEqual(
            MonitorParsers.pingLatency(line: "64 bytes from 10.0.0.1: icmp_seq=3 ttl=64 time=0.061 ms"),
            0.061
        )
        XCTAssertEqual(
            MonitorParsers.pingLatency(line: "64 bytes from h: icmp_seq=1 ttl=64 time=42 ms"),
            42
        )
    }

    func testPingLatencyIgnoresNonReplyLines() {
        XCTAssertNil(MonitorParsers.pingLatency(line: "Request timeout for icmp_seq 0"))
        XCTAssertNil(MonitorParsers.pingLatency(line: "PING example.com (93.184.216.34): 56 data bytes"))
        XCTAssertNil(MonitorParsers.pingLatency(line: ""))
    }

    // MARK: - Snapshot derived values

    func testSnapshotMemoryAndSwapFractions() {
        var snap = SystemSnapshot()
        snap.memTotalKB = 4000
        snap.memAvailableKB = 1000
        snap.swapTotalKB = 2000
        snap.swapFreeKB = 1500
        XCTAssertEqual(snap.memUsedKB, 3000)
        XCTAssertEqual(snap.memUsedFraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(snap.swapUsedKB, 500)
        XCTAssertEqual(snap.swapUsedFraction, 0.25, accuracy: 0.0001)
        // No swap configured -> 0, not NaN.
        snap.swapTotalKB = 0
        XCTAssertEqual(snap.swapUsedFraction, 0)
    }

    // MARK: - parseProcessDetail

    func testParseProcessDetail() {
        // 1. Complete valid payload: all three sections present.
        // Scalar line columns: pid ppid user stat nice pri pcpu pmem rss vsz nlwp etimes
        let completePayload = """
        5678 1 deploy Ssl 0 20 3.7 1.2 102400 204800 4 3661
        @@HARBOR@@
        Mon Jun  9 12:34:56 2025
        @@HARBOR@@
        /usr/bin/python3 /opt/app/server.py --port 8080
        """
        let detail = MonitorParsers.parseProcessDetail(completePayload)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.pid, 5678)
        XCTAssertEqual(detail?.ppid, 1)
        XCTAssertEqual(detail?.user, "deploy")
        XCTAssertEqual(detail?.state, "Ssl")
        XCTAssertEqual(detail?.nice, 0)
        XCTAssertEqual(detail?.priority, 20)
        XCTAssertEqual(try XCTUnwrap(detail?.cpuPercent), 3.7, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(detail?.memPercent), 1.2, accuracy: 0.0001)
        XCTAssertEqual(detail?.rssKB, 102_400)
        XCTAssertEqual(detail?.vszKB, 204_800)
        XCTAssertEqual(detail?.threads, 4)
        XCTAssertEqual(detail?.elapsedSeconds, 3661)
        XCTAssertEqual(detail?.startTime, "Mon Jun  9 12:34:56 2025")
        XCTAssertEqual(detail?.command, "/usr/bin/python3 /opt/app/server.py --port 8080")

        // 2. Missing middle section: only two sections (scalar + lstart, no args).
        // The parser degrades gracefully: pid is readable so it returns non-nil with an empty command.
        let twoSectionPayload = """
        1234 0 root R 0 19 0.5 0.1 4096 8192 1 120
        @@HARBOR@@
        Fri Jan  1 00:00:00 2021
        """
        let partial = MonitorParsers.parseProcessDetail(twoSectionPayload)
        XCTAssertNotNil(partial)
        XCTAssertEqual(partial?.pid, 1234)
        XCTAssertEqual(partial?.startTime, "Fri Jan  1 00:00:00 2021")
        XCTAssertEqual(partial?.command, "")

        // 3. Non-numeric PID: "abc" in the first field — must return nil.
        let badPidPayload = """
        abc 1 root S 0 20 0.0 0.0 1024 2048 1 0
        @@HARBOR@@

        @@HARBOR@@
        some command
        """
        XCTAssertNil(MonitorParsers.parseProcessDetail(badPidPayload))

        // 4. Empty payload string — must return nil.
        XCTAssertNil(MonitorParsers.parseProcessDetail(""))

        // 5. Extra whitespace around PID: leading spaces on the scalar line are
        // consumed by token splitting, so the pid is still parsed correctly.
        let paddedPayload = """
          9999 2 syslog S 0 20 0.0 0.0 512 1024 1 7200
        @@HARBOR@@
        Thu Jun 26 08:00:00 2025
        @@HARBOR@@
        syslogd -n
        """
        let padded = MonitorParsers.parseProcessDetail(paddedPayload)
        XCTAssertNotNil(padded)
        XCTAssertEqual(padded?.pid, 9999)
        XCTAssertEqual(padded?.user, "syslog")
        XCTAssertEqual(padded?.command, "syslogd -n")
    }
}
