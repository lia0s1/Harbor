//
//  ZmodemConstants.swift
//  HarborKit
//
//  ZModem wire constants, per Chuck Forsberg's ZMODEM spec and lrzsz's
//  on-the-wire behavior.
//

import Foundation

/// Raw byte/flag constants for the ZModem file-transfer protocol.
public enum ZmodemConstants {
    // MARK: - Frame-control bytes

    /// ZPAD — '*', pads the start of every header.
    public static let pad: UInt8 = 0x2A
    /// ZDLE — CAN, introduces an escape pair or a subpacket terminator.
    public static let zdle: UInt8 = 0x18
    /// ZBIN — 'A', binary header with 16-bit CRC.
    public static let bin: UInt8 = 0x41
    /// ZHEX — 'B', hex header (human readable, for "attention" frames).
    public static let hex: UInt8 = 0x42
    /// ZBIN32 — 'C', binary header with 32-bit CRC.
    public static let bin32: UInt8 = 0x43

    public static let xon: UInt8 = 0x11
    public static let xoff: UInt8 = 0x13
    public static let cr: UInt8 = 0x0D
    public static let lf: UInt8 = 0x0A
    public static let backspace: UInt8 = 0x08

    // MARK: - Frame types

    public static let zrqinit: UInt8 = 0    // receiver requests attention
    public static let zrinit: UInt8 = 1     // receiver advertises capabilities
    public static let zsinit: UInt8 = 2     // sender ships its attention string
    public static let zack: UInt8 = 3
    public static let zfile: UInt8 = 4      // file header follows as a data subpacket
    public static let zskip: UInt8 = 5      // receiver: skip this file
    public static let znak: UInt8 = 6       // last frame was garbled
    public static let zabort: UInt8 = 7
    public static let zfin: UInt8 = 8       // end of session
    public static let zrpos: UInt8 = 9      // receiver: resume from this offset
    public static let zdata: UInt8 = 10     // data subpackets follow
    public static let zeof: UInt8 = 11      // end of file, position = file size
    public static let zferr: UInt8 = 12     // fatal read/write error on peer
    public static let zcrc: UInt8 = 13      // request/answer: 32-bit CRC of whole file
    public static let zchallenge: UInt8 = 14// echo the position field back in a ZACK
    public static let zcompl: UInt8 = 15    // "request complete" / cannot comply
    public static let zcan: UInt8 = 16      // cancel (usually sent as raw CAN burst instead)
    public static let zfreecnt: UInt8 = 17  // sender asks for free disk space
    public static let zcommand: UInt8 = 18  // command from sender (NOT honored)
    public static let zstderr: UInt8 = 19   // stderr data subpacket follows

    // MARK: - Data subpacket terminators (always preceded by ZDLE)

    /// Frame ends here; next thing on the wire is a header. No response.
    public static let zcrce: UInt8 = 0x68
    /// Frame continues with another subpacket. No response (full streaming).
    public static let zcrcg: UInt8 = 0x69
    /// Frame continues; receiver must ZACK with bytes received so far.
    public static let zcrcq: UInt8 = 0x6A
    /// Frame ends; receiver must ZACK.
    public static let zcrcw: UInt8 = 0x6B
    public static let zrub0: UInt8 = 0x6C
    public static let zrub1: UInt8 = 0x6D

    // MARK: - ZRINIT capability flags (carried in the low position byte, ZF0)

    public static let canfdx: UInt32 = 0x01   // full duplex
    public static let canovio: UInt32 = 0x02  // can receive during disk I/O
    public static let canbrk: UInt32 = 0x04   // can send a break signal
    public static let cancry: UInt32 = 0x08   // can decrypt (unused)
    public static let canlzw: UInt32 = 0x10   // can uncompress (unused)
    public static let canfc32: UInt32 = 0x20  // can use 32-bit CRC frames
    public static let escctl: UInt32 = 0x40   // expects ALL control chars escaped
    public static let esc8: UInt32 = 0x80     // expects 8th bit escaped

    /// Capabilities Harbor advertises when acting as the receiver (rz peer).
    public static let harborCaps: UInt32 = canfdx | canovio | canbrk | canfc32

    /// Human-readable frame name, for logs and error messages.
    public static func frameName(_ type: UInt8) -> String {
        switch type {
        case zrqinit: return "ZRQINIT"
        case zrinit: return "ZRINIT"
        case zsinit: return "ZSINIT"
        case zack: return "ZACK"
        case zfile: return "ZFILE"
        case zskip: return "ZSKIP"
        case znak: return "ZNAK"
        case zabort: return "ZABORT"
        case zfin: return "ZFIN"
        case zrpos: return "ZRPOS"
        case zdata: return "ZDATA"
        case zeof: return "ZEOF"
        case zferr: return "ZFERR"
        case zcrc: return "ZCRC"
        case zchallenge: return "ZCHALLENGE"
        case zcompl: return "ZCOMPL"
        case zcan: return "ZCAN"
        case zfreecnt: return "ZFREECNT"
        case zcommand: return "ZCOMMAND"
        case zstderr: return "ZSTDERR"
        default: return "UNKNOWN(\(type))"
        }
    }
}
