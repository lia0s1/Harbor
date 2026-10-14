//
//  ZmodemCRCTests.swift
//  HarborKitTests
//

import XCTest
@testable import HarborKit

final class ZmodemCRCTests: XCTestCase {

    /// Independent bit-at-a-time references so the table-driven production
    /// code is checked against something other than itself.
    private func refCRC16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    private func refCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: Known vectors

    func testCRC32ClassicVector() {
        // zlib crc32("123456789") is universally 0xCBF43926.
        XCTAssertEqual(ZmodemCRC32.checksum("123456789".utf8), 0xCBF4_3926)
    }

    func testCRC16ZeroVectors() {
        // With init 0 any run of zero bytes keeps the CRC at zero — this is
        // also what makes the real-world ZRQINIT hex frame end in "0000".
        XCTAssertEqual(ZmodemCRC16.checksum([UInt8](repeating: 0, count: 5)), 0)
        XCTAssertEqual(ZmodemCRC16.checksum([UInt8]()), 0)
    }

    func testCRC32Empty() {
        XCTAssertEqual(ZmodemCRC32.checksum([UInt8]()), 0)
    }

    // MARK: Table vs bitwise reference

    func testCRC16MatchesBitwiseReference() {
        var rng = SystemRandomNumberGenerator()
        for len in [1, 2, 5, 17, 255, 1024] {
            let bytes = (0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) }
            XCTAssertEqual(ZmodemCRC16.checksum(bytes), refCRC16(bytes), "length \(len)")
        }
    }

    func testCRC32MatchesBitwiseReference() {
        var rng = SystemRandomNumberGenerator()
        for len in [1, 2, 5, 17, 255, 1024] {
            let bytes = (0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) }
            XCTAssertEqual(ZmodemCRC32.checksum(bytes), refCRC32(bytes), "length \(len)")
        }
    }

    // MARK: Incremental == one-shot

    func testIncrementalUpdatesMatchOneShot() {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<1000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        var c16 = ZmodemCRC16()
        var c32 = ZmodemCRC32()
        for b in bytes {
            c16.update(b)
            c32.update(b)
        }
        XCTAssertEqual(c16.value, ZmodemCRC16.checksum(bytes))
        XCTAssertEqual(c32.value, ZmodemCRC32.checksum(bytes))
    }
}
