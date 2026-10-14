//
//  ZmodemDetectorTests.swift
//  HarborKitTests
//

import XCTest
@testable import HarborKit

final class ZmodemDetectorTests: XCTestCase {

    private let Z = ZmodemConstants.self

    private var zrqinit: Data {
        ZmodemFraming.encodeHeader(type: Z.zrqinit, position: 0, format: .hex)
    }

    func testBareZRQINITTriggersUpload() {
        let detector = ZmodemDetector()
        var stream = Data("rz waiting to receive.".utf8)
        stream.append(zrqinit)
        let result = detector.feed(stream)
        XCTAssertEqual(result?.trigger, .upload)
    }

    func testSzInvocationStringTriggersDownload() {
        let detector = ZmodemDetector()
        var stream = Data("rz\r".utf8)   // sz's auto-invocation string
        stream.append(zrqinit)
        let result = detector.feed(stream)
        XCTAssertEqual(result?.trigger, .download)
    }

    func testShellEchoOfTypedRzIsNotDownload() {
        // Typing `rz<Return>` echoes as "rz\r\n"; the LF between the echo and
        // the frame is what separates it from sz's invocation string.
        let detector = ZmodemDetector()
        var stream = Data("rz\r\n".utf8)
        stream.append(zrqinit)
        let result = detector.feed(stream)
        XCTAssertEqual(result?.trigger, .upload)
    }

    func testByteByByteFeeding() {
        let detector = ZmodemDetector()
        var stream = Data("rz\r".utf8)
        stream.append(zrqinit)
        var result: (trigger: ZmodemTrigger, frame: Data)?
        for i in stream.indices {
            result = detector.feed(Data([stream[i]]))
            if result != nil { break }
        }
        XCTAssertEqual(result?.trigger, .download)
    }

    func testCapturedFrameReplaysIntoParser() {
        let detector = ZmodemDetector()
        let result = detector.feed(zrqinit)
        XCTAssertNotNil(result)
        let events = ZmodemParser().input(result!.frame)
        XCTAssertEqual(
            events,
            [.header(ZmodemHeader(type: Z.zrqinit, position: 0, format: .hex))]
        )
    }

    func testNonZRQINITFramesDoNotTrigger() {
        let detector = ZmodemDetector()
        // ZFIN hex header shares the "**\x18B" prefix but type "08".
        let fin = ZmodemFraming.encodeHeader(type: Z.zfin, position: 0, format: .hex)
        XCTAssertNil(detector.feed(fin))
        // Binary headers start "**"? no — ZPAD ZDLE ZBIN; also must not trigger.
        let bin = ZmodemFraming.encodeHeader(type: Z.zdata, position: 0, format: .bin32)
        XCTAssertNil(detector.feed(bin))
    }

    func testRandomGarbageDoesNotTrigger() {
        let detector = ZmodemDetector()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let garbage = Data((0..<512).map { _ in UInt8.random(in: 0...255, using: &rng) })
            XCTAssertNil(detector.feed(garbage))
        }
    }

    func testFiresOnlyOnce() {
        let detector = ZmodemDetector()
        XCTAssertNotNil(detector.feed(zrqinit))
        XCTAssertNil(detector.feed(zrqinit))
    }

    func testTriggerAfterOtherTerminalOutput() {
        let detector = ZmodemDetector()
        XCTAssertNil(detector.feed(Data("user@host:~$ sz report.txt\r\n".utf8)))
        var stream = Data("rz\r".utf8)
        stream.append(zrqinit)
        XCTAssertEqual(detector.feed(stream)?.trigger, .download)
    }
}
