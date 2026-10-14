//
//  ZmodemRobustnessTests.swift
//  HarborKitTests
//
//  Malformed input, out-of-order frames, cancel handling, and retry budgets.
//  The overarching contract: never crash, never hang, always end in a
//  well-defined phase.
//

import XCTest
@testable import HarborKit

final class ZmodemRobustnessTests: XCTestCase {

    private let Z = ZmodemConstants.self
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmodem-robust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeFile(_ name: String, _ bytes: Data) -> URL {
        let url = tempDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: bytes)
        return url
    }

    private var zrqinit: Data {
        ZmodemFraming.encodeHeader(type: Z.zrqinit, position: 0, format: .hex)
    }

    // MARK: - Parser resilience

    func testTruncatedFrameThenCompletion() {
        let parser = ZmodemParser()
        var events: [ZmodemParser.Event] = []
        // Feed one byte at a time, including a mid-stream split.
        for i in zrqinit.indices {
            events.append(contentsOf: parser.input(Data([zrqinit[i]])))
        }
        XCTAssertEqual(
            events,
            [.header(ZmodemHeader(type: Z.zrqinit, position: 0, format: .hex))]
        )
    }

    func testBadCRCHeaderIsCorruptNotCrash() {
        var frame = ZmodemFraming.encodeHeader(type: Z.zrpos, position: 42, format: .bin16)
        frame[frame.count - 1] ^= 0xFF
        let events = ZmodemParser().input(frame)
        XCTAssertEqual(events.count, 1)
        guard case .corruptFrame = events[0] else {
            return XCTFail("expected corruptFrame, got \(events)")
        }
    }

    func testGarbageNeverProducesHeader() {
        let parser = ZmodemParser()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<10 {
            let garbage = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
            for event in parser.input(garbage) {
                switch event {
                case .header, .dataSubpacket:
                    // Astronomically unlikely; corrupt/cancel are fine.
                    if case .header = event { XCTFail("header from garbage: \(event)") }
                default:
                    break
                }
            }
        }
    }

    func testTextAroundFramesIsIgnored() {
        let parser = ZmodemParser()
        var stream = Data("some terminal noise\r\n$ ".utf8)
        stream.append(zrqinit)
        stream.append(Data("more noise".utf8))
        let events = parser.input(stream)
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - Cancel

    func testCancelBurstTriggersCancelEvent() {
        let events = ZmodemParser().input(Data(repeating: Z.zdle, count: 8))
        XCTAssertTrue(events.contains(.cancel))
    }

    func testPeerCancelEndsSession() {
        let src = makeFile("f.bin", Data(repeating: 0x41, count: 10))
        let sender = ZmodemSession(role: .send(files: [src]))
        var sent = Data()
        sender.onSend = { sent.append($0) }
        sender.input(zrqinit)
        XCTAssertEqual(sender.phase, .negotiating)

        sender.input(Data(repeating: Z.zdle, count: 8))
        XCTAssertEqual(sender.phase, .cancelled)
        XCTAssertEqual(sender.error, .cancelled)
    }

    func testLocalCancelEmitsBurst() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        var sent = Data()
        receiver.onSend = { sent.append($0) }
        receiver.input(zrqinit)
        receiver.cancel()
        XCTAssertEqual(receiver.phase, .cancelled)
        XCTAssertEqual(sent.suffix(16), ZmodemFraming.encodeCancel())
    }

    // MARK: - Out-of-order / unexpected frames

    func testZDATAWithoutZFILEIsIgnored() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        receiver.input(zrqinit)
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zdata, position: 0, format: .bin16))
        receiver.input(ZmodemFraming.encodeDataSubpacket(Data("junk".utf8), terminator: Z.zcrce, crc32: false))
        XCTAssertEqual(receiver.phase, .negotiating)  // unchanged, no crash
    }

    func testZEOFBeforeAnyFileIsIgnored() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        receiver.input(zrqinit)
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zeof, position: 0, format: .bin16))
        XCTAssertEqual(receiver.phase, .negotiating)
    }

    func testSessionIgnoresInputAfterCompletion() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        receiver.input(zrqinit)
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zfin, position: 0, format: .hex))
        XCTAssertEqual(receiver.phase, .completed)
        // Late bytes (the peer's "OO", retransmits) must not disturb it.
        receiver.input(ZmodemFraming.encodeOverAndOut())
        receiver.input(zrqinit)
        XCTAssertEqual(receiver.phase, .completed)
    }

    // MARK: - Challenge / unsupported frames

    func testChallengeIsEchoedBack() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        var sent = Data()
        receiver.onSend = { sent.append($0) }
        receiver.input(zrqinit)
        sent = Data()
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zchallenge, position: 0xDEAD_BEEF, format: .hex))
        let events = ZmodemParser().input(sent)
        XCTAssertEqual(
            events,
            [.header(ZmodemHeader(type: Z.zack, position: 0xDEAD_BEEF, format: .hex))]
        )
    }

    func testCommandFrameIsRefused() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        var sent = Data()
        receiver.onSend = { sent.append($0) }
        receiver.input(zrqinit)
        sent = Data()
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zcommand, position: 0, format: .hex))
        receiver.input(ZmodemFraming.encodeDataSubpacket(Data("rm -rf /".utf8), terminator: Z.zcrce, crc32: false))
        let events = ZmodemParser().input(sent)
        XCTAssertEqual(
            events,
            [.header(ZmodemHeader(type: Z.zcompl, position: 0, format: .hex))]
        )
    }

    // MARK: - Retry budget

    func testPersistentCorruptionFailsAfterBudget() {
        let src = makeFile("victim.bin", Data(repeating: 0x42, count: 2048))
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        var sent = Data()
        receiver.onSend = { sent.append($0) }

        receiver.input(zrqinit)

        // Feed a valid ZFILE so the receiver opens the file, then keep
        // delivering corrupt data frames until the retry budget runs out.
        let info = ZmodemFraming.encodeFileInfo(
            name: "victim.bin", size: 2048, modificationTime: 0, mode: 0o100644, filesRemaining: 1
        )
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zfile, position: 0, format: .bin16))
        receiver.input(ZmodemFraming.encodeDataSubpacket(info, terminator: Z.zcrcw, crc32: false))

        var corruptSubpacket = ZmodemFraming.encodeDataSubpacket(
            Data(repeating: 0x42, count: 100), terminator: Z.zcrce, crc32: false
        )
        corruptSubpacket[corruptSubpacket.count - 1] ^= 0xFF
        let badFrame = ZmodemFraming.encodeHeader(type: Z.zdata, position: 0, format: .bin16)
            + corruptSubpacket

        for _ in 0..<15 where receiver.isActive {
            receiver.input(badFrame)
        }

        XCTAssertEqual(receiver.phase, .failed)
        XCTAssertEqual(receiver.error, .tooManyErrors)
        XCTAssertEqual(sent.suffix(16), ZmodemFraming.encodeCancel())
    }

    // MARK: - Less common sender-side frames

    /// Parses everything a session emits, in order.
    private func parseAll(_ data: Data) -> [ZmodemParser.Event] {
        ZmodemParser().input(data)
    }

    private func headers(_ events: [ZmodemParser.Event]) -> [ZmodemHeader] {
        events.compactMap { if case .header(let h) = $0 { return h }; return nil }
    }

    func testZSKIPAdvancesToNextFile() {
        let f1 = makeFile("skip1.bin", Data(repeating: 0x41, count: 10))
        let f2 = makeFile("skip2.bin", Data(repeating: 0x42, count: 10))
        let sender = ZmodemSession(role: .send(files: [f1, f2]))
        var sent = Data()
        sender.onSend = { sent.append($0) }

        sender.input(zrqinit)
        sent = Data()
        sender.input(ZmodemFraming.encodeHeader(type: Z.zskip, position: 0, format: .bin16))

        // The sender must now offer file #2: a ZFILE header followed by a
        // subpacket naming "skip2.bin".
        let events = parseAll(sent)
        let heads = headers(events)
        XCTAssertEqual(heads.first?.type, Z.zfile)
        guard case .dataSubpacket(let info, _, let valid) = events.last, valid else {
            return XCTFail("expected ZFILE info subpacket, got \(events)")
        }
        XCTAssertEqual(ZmodemFraming.parseFileInfo(info).name, "skip2.bin")
        XCTAssertEqual(sender.phase, .negotiating)
    }

    func testZSKIPOnLastFileSendsZFIN() {
        let f1 = makeFile("only.bin", Data(repeating: 0x41, count: 10))
        let sender = ZmodemSession(role: .send(files: [f1]))
        var sent = Data()
        sender.onSend = { sent.append($0) }

        sender.input(zrqinit)
        sent = Data()
        sender.input(ZmodemFraming.encodeHeader(type: Z.zskip, position: 0, format: .bin16))
        XCTAssertEqual(headers(parseAll(sent)).first?.type, Z.zfin)
        XCTAssertEqual(sender.phase, .finishing)
    }

    func testZCRCQueryAnswersWithFileCRC32() {
        let content = Data((0..<10_000).map { UInt8($0 & 0xFF) })
        let f1 = makeFile("crcme.bin", content)
        let sender = ZmodemSession(role: .send(files: [f1]))
        var sent = Data()
        sender.onSend = { sent.append($0) }

        sender.input(zrqinit)
        sent = Data()
        sender.input(ZmodemFraming.encodeHeader(type: Z.zcrc, position: 0, format: .bin16))
        let heads = headers(parseAll(sent))
        XCTAssertEqual(heads.first?.type, Z.zcrc)
        XCTAssertEqual(heads.first?.position, ZmodemCRC32.checksum(content))
    }

    func testZABORTFailsSession() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        receiver.input(zrqinit)
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zabort, position: 0, format: .hex))
        XCTAssertEqual(receiver.phase, .failed)
        XCTAssertEqual(receiver.error, .abortedByPeer)
    }

    // MARK: - File safety

    func testReceiverRefusesPathTraversalName() {
        let receiver = ZmodemSession(role: .receive(directory: tempDir))
        receiver.input(zrqinit)
        let info = ZmodemFraming.encodeFileInfo(
            name: "../../outside-\(UUID().uuidString).txt",
            size: 5, modificationTime: 0, mode: 0o100644, filesRemaining: 1
        )
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zfile, position: 0, format: .bin16))
        receiver.input(ZmodemFraming.encodeDataSubpacket(info, terminator: Z.zcrcw, crc32: false))
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zdata, position: 0, format: .bin16))
        receiver.input(ZmodemFraming.encodeDataSubpacket(Data("hello".utf8), terminator: Z.zcrce, crc32: false))
        receiver.input(ZmodemFraming.encodeHeader(type: Z.zeof, position: 5, format: .bin16))

        // The file must have landed INSIDE the destination directory under
        // its sanitized bare name.
        let contents = try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents?.count, 1)
        XCTAssertTrue(contents?.first?.hasPrefix("outside-") ?? false)
        XCTAssertEqual(try? Data(contentsOf: tempDir.appendingPathComponent(contents![0])), Data("hello".utf8))
    }
}
