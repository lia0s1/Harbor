import XCTest
@testable import HarborKit

final class SystemInfoParserTests: XCTestCase {

    private let sep = SystemInfoParser.sectionSeparator

    /// Realistic full payload from an x86_64 Ubuntu VPS (one section per
    /// command, separated by @@HARBOR-SYS@@ lines).
    private let ubuntuPayload = """
    Linux
    @@HARBOR-SYS@@
    PRETTY_NAME="Ubuntu 22.04.4 LTS"
    NAME="Ubuntu"
    VERSION_ID="22.04"
    ID=ubuntu
    @@HARBOR-SYS@@
    5.15.0-101-generic
    @@HARBOR-SYS@@
    x86_64
    @@HARBOR-SYS@@
    web-prod-01
    @@HARBOR-SYS@@
    processor	: 0
    vendor_id	: GenuineIntel
    model name	: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
    cpu MHz		: 2399.998
    cache size	: 35840 KB
    processor	: 1
    model name	: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
    cpu MHz		: 2399.998
    processor	: 2
    model name	: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
    cpu MHz		: 2399.998
    processor	: 3
    model name	: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
    cpu MHz		: 2399.998
    @@HARBOR-SYS@@
    MemTotal:        8167584 kB
    MemFree:          261236 kB
    MemAvailable:    5123444 kB
    Buffers:          136472 kB
    Cached:          4153500 kB
    SwapTotal:       2097148 kB
    SwapFree:        1947388 kB
    @@HARBOR-SYS@@
    1234567.89 9876543.21
    @@HARBOR-SYS@@
    1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever
    1: lo    inet6 ::1/128 scope host \\       valid_lft forever preferred_lft forever
    2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0\\       valid_lft forever preferred_lft forever
    2: eth0    inet6 fe80::5054:ff:fe12:3456/64 scope link \\       valid_lft forever preferred_lft forever
    3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\\       valid_lft forever preferred_lft forever
    @@HARBOR-SYS@@
    Filesystem     1024-blocks      Used Available Capacity Mounted on
    udev               3989608         0   3989608       0% /dev
    tmpfs               816760      1124    815636       1% /run
    /dev/vda1         82043980  24013880  54658188      31% /
    /dev/vda15          126678      6004    120674       5% /boot/efi
    /dev/loop3           63488     63488         0     100% /snap/core20/1974
    overlay           82043980  24013880  54658188      31% /var/lib/docker/overlay2/abc/merged
    /dev/sdb1        515928320 123456789 366178904      26% /data
    """

    func testFullPayloadParsesEverySection() {
        let info = SystemInfoParser.parse(ubuntuPayload)
        XCTAssertEqual(info.os, "Linux")
        XCTAssertTrue(info.isLinux)
        XCTAssertEqual(info.prettyName, "Ubuntu 22.04.4 LTS")
        XCTAssertEqual(info.kernel, "5.15.0-101-generic")
        XCTAssertEqual(info.arch, "x86_64")
        XCTAssertEqual(info.hostname, "web-prod-01")

        XCTAssertEqual(info.cpuModel, "Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz")
        XCTAssertEqual(info.cpuCores, 4)
        XCTAssertEqual(info.cpuMHz, 2399.998, accuracy: 0.001)

        XCTAssertEqual(info.memTotalKB, 8_167_584)
        XCTAssertEqual(info.memAvailableKB, 5_123_444)
        XCTAssertEqual(info.swapTotalKB, 2_097_148)
        XCTAssertEqual(info.swapFreeKB, 1_947_388)
        XCTAssertEqual(info.memUsedKB, 8_167_584 - 5_123_444)
        XCTAssertEqual(info.swapUsedKB, 2_097_148 - 1_947_388)

        XCTAssertEqual(info.uptimeSeconds, 1_234_567.89, accuracy: 0.001)

        // Loopback dropped because real interfaces exist; each keeps inet+inet6.
        XCTAssertEqual(info.interfaces.map(\.name), ["eth0", "docker0"])
        XCTAssertEqual(info.interfaces[0].addresses, ["10.0.0.5/24", "fe80::5054:ff:fe12:3456/64"])
        XCTAssertEqual(info.interfaces[1].addresses, ["172.17.0.1/16"])

        // Pseudo / loop / overlay / /dev filtered; device column preserved.
        XCTAssertEqual(info.filesystems.map(\.mount), ["/", "/boot/efi", "/data"])
        XCTAssertEqual(info.filesystems.first?.device, "/dev/vda1")
        XCTAssertEqual(info.filesystems.first?.totalKB, 82_043_980)
    }

    // MARK: - PRETTY_NAME edge cases

    func testPrettyNameMissingFileYieldsEmpty() {
        XCTAssertEqual(SystemInfoParser.parsePrettyName(""), "")
        // os-release without PRETTY_NAME
        XCTAssertEqual(SystemInfoParser.parsePrettyName("NAME=Alpine\nVERSION_ID=3.19"), "")
    }

    func testPrettyNameSingleQuotedAndUnquoted() {
        XCTAssertEqual(SystemInfoParser.parsePrettyName("PRETTY_NAME='Debian GNU/Linux 12'"), "Debian GNU/Linux 12")
        XCTAssertEqual(SystemInfoParser.parsePrettyName("PRETTY_NAME=Fedora"), "Fedora")
    }

    // MARK: - CPU edge cases

    func testCPUInfoARMWithoutMHzUsesHardwareModel() {
        // Raspberry Pi style cpuinfo: no "model name"/"cpu MHz", but a
        // "Hardware" line and "model" line; 4 processors.
        let text = """
        processor	: 0
        BogoMIPS	: 108.00
        Features	: fp asimd evtstrm
        processor	: 1
        processor	: 2
        processor	: 3
        Hardware	: BCM2835
        model		: Raspberry Pi 4 Model B Rev 1.4
        """
        let cpu = SystemInfoParser.parseCPUInfo(text)
        XCTAssertEqual(cpu.cores, 4)
        XCTAssertEqual(cpu.mhz, 0) // absent → 0, not garbage
        XCTAssertEqual(cpu.model, "BCM2835")
    }

    func testCPUInfoEmptyYieldsZeroCores() {
        let cpu = SystemInfoParser.parseCPUInfo("")
        XCTAssertEqual(cpu.cores, 0)
        XCTAssertEqual(cpu.model, "")
        XCTAssertEqual(cpu.mhz, 0)
    }

    // MARK: - Interface edge cases

    func testInterfacesLoopbackOnlyIsKept() {
        let text = "1: lo    inet 127.0.0.1/8 scope host lo"
        let interfaces = SystemInfoParser.parseInterfaces(text)
        XCTAssertEqual(interfaces.map(\.name), ["lo"])
        XCTAssertEqual(interfaces.first?.addresses, ["127.0.0.1/8"])
    }

    func testInterfacesEmptyWhenIproute2Absent() {
        XCTAssertTrue(SystemInfoParser.parseInterfaces("").isEmpty)
    }

    func testInterfacesGroupMultipleAddressesPreservingOrder() {
        let text = """
        2: eth0    inet 10.0.0.5/24 scope global eth0
        2: eth0    inet 10.0.0.6/24 scope global secondary eth0
        2: eth0    inet6 fe80::1/64 scope link
        """
        let interfaces = SystemInfoParser.parseInterfaces(text)
        XCTAssertEqual(interfaces.count, 1)
        XCTAssertEqual(interfaces[0].name, "eth0")
        XCTAssertEqual(interfaces[0].addresses, ["10.0.0.5/24", "10.0.0.6/24", "fe80::1/64"])
    }

    // MARK: - Filesystem edge cases

    func testFilesystemMountWithSpaces() {
        let text = """
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/sdc1 1000000 400000 600000 40% /mnt/my backup
        """
        let fs = SystemInfoParser.parseFilesystems(text)
        XCTAssertEqual(fs.count, 1)
        XCTAssertEqual(fs.first?.mount, "/mnt/my backup")
        XCTAssertEqual(fs.first?.device, "/dev/sdc1")
        XCTAssertEqual(fs.first?.usedFraction ?? 0, 0.4, accuracy: 0.0001)
    }

    // MARK: - Degraded payloads

    func testNonLinuxPayloadOnlyTrustsOSField() {
        let payload = [
            "Darwin", "", "23.4.0", "arm64", "macbook", "", "", "", "", "",
        ].joined(separator: "\n\(sep)\n")
        let info = SystemInfoParser.parse(payload)
        XCTAssertEqual(info.os, "Darwin")
        XCTAssertFalse(info.isLinux)
        XCTAssertEqual(info.kernel, "23.4.0")
        XCTAssertEqual(info.arch, "arm64")
        XCTAssertEqual(info.cpuCores, 0)
        XCTAssertEqual(info.memTotalKB, 0)
        XCTAssertTrue(info.interfaces.isEmpty)
    }

    func testEmptyAndGarbagePayloadsDoNotCrash() {
        let empty = SystemInfoParser.parse("")
        XCTAssertEqual(empty.os, "")
        XCTAssertFalse(empty.isLinux)
        XCTAssertEqual(empty.cpuCores, 0)

        // Fewer sections than expected → trailing fields default cleanly.
        let truncated = SystemInfoParser.parse("Linux\n\(sep)\nPRETTY_NAME=\"Arch Linux\"")
        XCTAssertEqual(truncated.os, "Linux")
        XCTAssertEqual(truncated.prettyName, "Arch Linux")
        XCTAssertEqual(truncated.kernel, "")
        XCTAssertEqual(truncated.cpuCores, 0)
    }

    func testNoSwapReportsZeroSwap() {
        // Container/minimal host with swap disabled: meminfo omits Swap* lines.
        let meminfo = "MemTotal:        2048000 kB\nMemAvailable:    1500000 kB"
        let payload = [
            "Linux", "", "6.1.0", "x86_64", "ct1", "", meminfo, "100.0 200.0", "", "",
        ].joined(separator: "\n\(sep)\n")
        let info = SystemInfoParser.parse(payload)
        XCTAssertEqual(info.memTotalKB, 2_048_000)
        XCTAssertEqual(info.swapTotalKB, 0)
        XCTAssertEqual(info.swapUsedKB, 0)
        // No net section at all → totals default to 0.
        XCTAssertEqual(info.netRxTotalBytes, 0)
        XCTAssertEqual(info.netTxTotalBytes, 0)
    }

    func testNetTotalsSumNonLoopbackInterfaces() {
        let netdev = """
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 999 1 0 0 0 0 0 0 999 1 0 0 0 0 0 0
          eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0
          eth1: 500 0 0 0 0 0 0 0 700 0 0 0 0 0 0 0
        """
        let payload = [
            "Linux", "", "6.1.0", "x86_64", "h", "", "", "100.0 200.0", "", "", netdev,
        ].joined(separator: "\n\(sep)\n")
        let info = SystemInfoParser.parse(payload)
        // Loopback excluded; eth0 + eth1 summed.
        XCTAssertEqual(info.netRxTotalBytes, 1500)
        XCTAssertEqual(info.netTxTotalBytes, 2700)
    }
}
