//
//  ZmodemFramingTests.swift
//  HarborKitTests
//

import XCTest
@testable import HarborKit

final class ZmodemFramingTests: XCTestCase {

    private let Z = ZmodemConstants.self

    // MARK: - ZDLE escaping

    func testEscapeRoundTripAllBytes() {
        let all = Data(0...255)
        for escctl in [false, true] {
            let escaped = ZmodemFraming.escape(all, escctl: escctl)
            XCTAssertEqual(ZmodemFraming.unescape(escaped), all, "escctl=\(escctl)")
        }
    }

    func testMustEscapeBytesEncoding() {
        let Z = ZmodemConstants.self
        // byte -> expected escaped form
        let cases: [UInt8: [UInt8]] = [
            0x10: [Z.zdle, 0x50],       // DLE -> ZDLE 'P'
            0x11: [Z.zdle, 0x51],       // XON -> ZDLE 'Q'
            0x13: [Z.zdle, 0x53],       // XOFF -> ZDLE 'S'
            0x0D: [Z.zdle, 0x4D],       // CR  -> ZDLE 'M'
            0x90: [Z.zdle, 0xD0],
            0x91: [Z.zdle, 0xD1],
            0x93: [Z.zdle, 0xD3],
            0x8D: [Z.zdle, 0xCD],
            Z.zdle: [Z.zdle, Z.zdle],   // ZDLE doubles
        ]
        for (byte, expected) in cases {
            XCTAssertEqual(
                ZmodemFraming.escape(Data([byte])), Data(expected),
                String(format: "byte 0x%02X", byte)
            )
        }
    }

    func testPlainBytesPassThrough() {
        XCTAssertEqual(ZmodemFraming.escape(Data("hello".utf8)), Data("hello".utf8))
    }

    func testEscctlEscapesAllControlCharacters() {
        // With ESCCTL, e.g. 0x01 and 0x7F must be escaped; without, they pass.
        XCTAssertEqual(ZmodemFraming.escape(Data([0x01])), Data([0x01]))
        XCTAssertEqual(ZmodemFraming.escape(Data([0x01]), escctl: true), Data([Z.zdle, 0x41]))
        XCTAssertEqual(ZmodemFraming.escape(Data([0x7F]), escctl: true), Data([Z.zdle, 0x3F]))
    }

    // MARK: - Header golden vectors

    func testGoldenZRQINITHexHeader() {
        // The exact bytes lrzsz `rz` sprays while waiting: ZPAD ZPAD ZDLE ZHEX,
        // type "00", flags "00000000", CRC16 of five zero bytes = "0000",
        // then CR LF and (not ZACK/ZFIN) XON.
        let frame = ZmodemFraming.encodeHeader(type: Z.zrqinit, position: 0, format: .hex)
        XCTAssertEqual(
            frame,
            Data([Z.pad, Z.pad, Z.zdle, Z.hex])
                + Data("00000000000000".utf8)
                + Data([Z.cr, Z.lf, Z.xon])
        )
    }

    func testHexHeadersXONRule() {
        let fin = ZmodemFraming.encodeHeader(type: Z.zfin, position: 0, format: .hex)
        XCTAssertEqual(fin.suffix(2), Data([Z.cr, Z.lf]))          // no XON after ZFIN
        let ack = ZmodemFraming.encodeHeader(type: Z.zack, position: 7, format: .hex)
        XCTAssertEqual(ack.suffix(2), Data([Z.cr, Z.lf]))          // no XON after ZACK
        let rinit = ZmodemFraming.encodeHeader(type: Z.zrinit, position: 0x27, format: .hex)
        XCTAssertEqual(rinit.last, Z.xon)
    }

    // MARK: - Header round trips through the parser

    private func roundTrip(_ type: UInt8, _ position: UInt32, _ format: ZmodemHeader.Format) {
        let bytes = ZmodemFraming.encodeHeader(type: type, position: position, format: format)
        let parser = ZmodemParser()
        let events = parser.input(bytes)
        XCTAssertEqual(events, [.header(ZmodemHeader(type: type, position: position, format: format))])
    }

    func testHeaderRoundTrips() {
        let positions: [UInt32] = [0, 1, 7, 0x1024, 0x8D13_1018, 0xFFFF_FFFF, 0xDEAD_BEEF]
        let types: [UInt8] = [Z.zrqinit, Z.zrinit, Z.zrpos, Z.zdata, Z.zeof, Z.zfin, Z.zack]
        for format in [ZmodemHeader.Format.hex, .bin16, .bin32] {
            for t in types {
                for p in positions {
                    roundTrip(t, p, format)
                }
            }
        }
    }

    func testHexHeaderPositionIsLittleEndian() {
        // ZRPOS offset 1 must appear as "01" then "000000" on the wire.
        let frame = ZmodemFraming.encodeHeader(type: Z.zrpos, position: 1, format: .hex)
        let body = frame.dropFirst(4).prefix(10) // "09" + "01000000"
        XCTAssertEqual(body, Data("0901000000".utf8))
    }

    // MARK: - Subpacket round trips

    func testSubpacketRoundTripBothCRCWidths() {
        for crc32 in [false, true] {
            for terminator in [Z.zcrce, Z.zcrcg, Z.zcrcq, Z.zcrcw] {
                let payload = Data((0..<500).map { UInt8($0 & 0xFF) })
                let header = ZmodemFraming.encodeHeader(
                    type: Z.zdata, position: 0, format: crc32 ? .bin32 : .bin16
                )
                let subpacket = ZmodemFraming.encodeDataSubpacket(
                    payload, terminator: terminator, crc32: crc32
                )
                let parser = ZmodemParser()
                var events = parser.input(header)
                events.append(contentsOf: parser.input(subpacket))
                XCTAssertEqual(events.count, 2)
                guard case .dataSubpacket(let data, let term, let valid) = events[1] else {
                    return XCTFail("expected subpacket event, got \(events[1])")
                }
                XCTAssertEqual(data, payload)
                XCTAssertEqual(term, terminator)
                XCTAssertTrue(valid)
            }
        }
    }

    func testSubpacketCRCDetectsTampering() {
        let payload = Data("attack at dawn".utf8)
        var subpacket = ZmodemFraming.encodeDataSubpacket(
            payload, terminator: Z.zcrce, crc32: false
        )
        // Flip the last byte (inside the CRC) without touching the structure.
        subpacket[subpacket.count - 1] ^= 0xFF

        let header = ZmodemFraming.encodeHeader(type: Z.zdata, position: 0, format: .bin16)
        let parser = ZmodemParser()
        _ = parser.input(header)
        let events = parser.input(subpacket)
        guard case .dataSubpacket(_, _, let valid) = events.first else {
            return XCTFail("expected subpacket event")
        }
        XCTAssertFalse(valid)
    }

    func testEmptySubpacketIsValid() {
        // Empty files are terminated by a zero-length ZCRCE subpacket.
        let header = ZmodemFraming.encodeHeader(type: Z.zdata, position: 0, format: .bin16)
        let subpacket = ZmodemFraming.encodeDataSubpacket(Data(), terminator: Z.zcrce, crc32: false)
        let parser = ZmodemParser()
        _ = parser.input(header)
        let events = parser.input(subpacket)
        XCTAssertEqual(events, [.dataSubpacket(data: Data(), terminator: Z.zcrce, crcValid: true)])
    }

    // MARK: - ZFILE info

    func testFileInfoRoundTrip() {
        let payload = ZmodemFraming.encodeFileInfo(
            name: "报告.tar.gz", size: 12345, modificationTime: 1_700_000_000, mode: 0o100644,
            filesRemaining: 3
        )
        let info = ZmodemFraming.parseFileInfo(payload)
        XCTAssertEqual(info.name, "报告.tar.gz")
        XCTAssertEqual(info.size, 12345)
        XCTAssertEqual(info.modificationTime, 1_700_000_000)
        XCTAssertEqual(info.mode, 0o100644)
    }

    func testFileInfoToleratesMissingInfoLine() {
        let info = ZmodemFraming.parseFileInfo(Data("bare-name".utf8))
        XCTAssertEqual(info.name, "bare-name")
        XCTAssertNil(info.size)
    }

    // MARK: - File name sanitizing

    func testSanitizeFileName() {
        XCTAssertEqual(ZmodemFraming.sanitizeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(ZmodemFraming.sanitizeFileName("/abs/path/file.txt"), "file.txt")
        XCTAssertEqual(ZmodemFraming.sanitizeFileName("C:\\fake\\file.txt"), "file.txt")
        XCTAssertEqual(ZmodemFraming.sanitizeFileName("plain.txt"), "plain.txt")
        XCTAssertNil(ZmodemFraming.sanitizeFileName(".."))
        XCTAssertNil(ZmodemFraming.sanitizeFileName(""))
        XCTAssertNil(ZmodemFraming.sanitizeFileName("/"))
        XCTAssertNil(ZmodemFraming.sanitizeFileName(String(repeating: "x", count: 300)))
    }

    // MARK: - Cancel burst

    func testCancelBurstShape() {
        let burst = ZmodemFraming.encodeCancel()
        XCTAssertEqual(burst.prefix(8), Data(repeating: Z.zdle, count: 8))
        XCTAssertEqual(burst.suffix(8), Data(repeating: Z.backspace, count: 8))
    }
}
