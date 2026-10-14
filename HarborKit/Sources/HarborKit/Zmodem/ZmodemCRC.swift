//
//  ZmodemCRC.swift
//  HarborKit
//
//  The two checksums ZModem uses:
//  - CRC-16: poly 0x1021, MSB-first, init 0x0000, no reflection, no final XOR
//    (lrzsz `updcrc`). Transmitted high byte first.
//  - CRC-32: the same CRC as zlib/PKZIP (poly 0xEDB88320, reflected,
//    init/xorout 0xFFFFFFFF). Transmitted low byte first.
//

import Foundation

/// ZModem 16-bit CRC (CCITT polynomial, zero initial value).
public struct ZmodemCRC16: Sendable {
    private var crc: UInt16 = 0

    public init() {}

    private static let table: [UInt16] = (0..<256).map { seed -> UInt16 in
        var c = UInt16(seed) << 8
        for _ in 0..<8 {
            c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1
        }
        return c
    }

    public mutating func update(_ byte: UInt8) {
        crc = ZmodemCRC16.table[Int((crc >> 8) ^ UInt16(byte)) & 0xFF] ^ (crc << 8)
    }

    public mutating func update<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
        for b in bytes { update(b) }
    }

    public var value: UInt16 { crc }

    /// One-shot convenience.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var c = ZmodemCRC16()
        c.update(contentsOf: bytes)
        return c.value
    }
}

/// ZModem 32-bit CRC (identical to zlib's crc32).
public struct ZmodemCRC32: Sendable {
    private var crc: UInt32 = 0xFFFF_FFFF

    public init() {}

    private static let table: [UInt32] = (0..<256).map { seed -> UInt32 in
        var c = UInt32(seed)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1
        }
        return c
    }

    public mutating func update(_ byte: UInt8) {
        crc = ZmodemCRC32.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }

    public mutating func update<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
        for b in bytes { update(b) }
    }

    public var value: UInt32 { crc ^ 0xFFFF_FFFF }

    /// One-shot convenience.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c = ZmodemCRC32()
        c.update(contentsOf: bytes)
        return c.value
    }
}
