//
//  ZmodemFraming.swift
//  HarborKit
//
//  ZDLE escaping plus header/subpacket encoders.
//
//  Wire formats (ZMODEM spec):
//    hex header:    ZPAD ZPAD ZDLE ZHEX  <14 lowercase hex chars> CR LF [XON]
//    binary header: ZPAD ZDLE (ZBIN|ZBIN32) <escaped type + 4 pos bytes + CRC>
//    subpacket:     <escaped payload> ZDLE <ZCRCx terminator> <escaped CRC>
//
//  Position/flag bytes are always least-significant byte first. CRC-16 goes
//  out high byte first; CRC-32 goes out low byte first. A subpacket's CRC
//  covers the payload AND its terminator byte.
//

import Foundation

/// One decoded ZModem header.
public struct ZmodemHeader: Equatable, Sendable {
    public enum Format: String, Equatable, Sendable {
        case hex    // ZHEX, CRC-16, ASCII hex body
        case bin16  // ZBIN, CRC-16
        case bin32  // ZBIN32, CRC-32
    }

    public var type: UInt8
    /// The 4-byte position/flags field, little-endian on the wire.
    /// For ZRINIT the capability bits live in the low byte.
    public var position: UInt32
    public var format: Format

    public init(type: UInt8, position: UInt32, format: Format) {
        self.type = type
        self.position = position
        self.format = format
    }

    public var typeName: String { ZmodemConstants.frameName(type) }
}

/// Byte escaping and frame encoders.
public enum ZmodemFraming {

    // MARK: - ZDLE escaping

    /// Bytes that must ALWAYS be escaped (flow-control chars and their
    /// 8th-bit variants, CR variants, and ZDLE itself).
    private static func mustEscape(_ b: UInt8) -> Bool {
        switch b {
        case 0x10, 0x11, 0x13, 0x90, 0x91, 0x93, 0x0D, 0x8D, ZmodemConstants.zdle:
            return true
        default:
            return false
        }
    }

    /// True when the peer set ESCCTL and this byte is any control character.
    private static func escapesWithEscctl(_ b: UInt8) -> Bool {
        b < 0x20 || b == 0x7F || (b & 0x60) == 0 || (b & 0x7F) == 0x7F
    }

    /// ZDLE-escape a byte stream. ZDLE itself becomes ZDLE ZDLE; everything
    /// else becomes ZDLE followed by (byte ^ 0x40).
    public static func escape(_ bytes: Data, escctl: Bool = false) -> Data {
        var out = Data()
        out.reserveCapacity(bytes.count + 8)
        for b in bytes {
            if b == ZmodemConstants.zdle {
                out.append(ZmodemConstants.zdle)
                out.append(ZmodemConstants.zdle)
            } else if mustEscape(b) || (escctl && escapesWithEscctl(b)) {
                out.append(ZmodemConstants.zdle)
                out.append(b ^ 0x40)
            } else {
                out.append(b)
            }
        }
        return out
    }

    /// Reverse of `escape` for payload data (no subpacket terminators allowed).
    public static func unescape(_ bytes: Data) -> Data {
        var out = Data()
        out.reserveCapacity(bytes.count)
        var pendingZdle = false
        for b in bytes {
            if pendingZdle {
                pendingZdle = false
                if b == ZmodemConstants.zdle {
                    out.append(ZmodemConstants.zdle)
                } else {
                    out.append(b ^ 0x40)
                }
            } else if b == ZmodemConstants.zdle {
                pendingZdle = true
            } else {
                out.append(b)
            }
        }
        return out
    }

    // MARK: - Headers

    /// Encode one header. `escctl` only widens the escape set of binary bodies.
    /// Hex headers end with CR LF plus XON — except ZACK and ZFIN, which per
    /// the spec omit the XON (they arrive in bursts at session teardown).
    public static func encodeHeader(
        type: UInt8,
        position: UInt32,
        format: ZmodemHeader.Format,
        escctl: Bool = false
    ) -> Data {
        let Z = ZmodemConstants.self
        // Body in wire order: type, then position least-significant byte first.
        let body: [UInt8] = [
            type,
            UInt8(position & 0xFF),
            UInt8((position >> 8) & 0xFF),
            UInt8((position >> 16) & 0xFF),
            UInt8((position >> 24) & 0xFF),
        ]

        switch format {
        case .hex:
            let crc = ZmodemCRC16.checksum(body)
            var out = Data([Z.pad, Z.pad, Z.zdle, Z.hex])
            let digits = Array("0123456789abcdef".utf8)
            func appendHex(_ b: UInt8) {
                out.append(digits[Int(b >> 4)])
                out.append(digits[Int(b & 0x0F)])
            }
            for b in body { appendHex(b) }
            appendHex(UInt8(crc >> 8))
            appendHex(UInt8(crc & 0xFF))
            out.append(Z.cr)
            out.append(Z.lf)
            if type != Z.zack && type != Z.zfin {
                out.append(Z.xon)
            }
            return out

        case .bin16:
            let crc = ZmodemCRC16.checksum(body)
            var out = Data([Z.pad, Z.zdle, Z.bin])
            out.append(escape(Data(body), escctl: escctl))
            out.append(escape(Data([UInt8(crc >> 8), UInt8(crc & 0xFF)]), escctl: escctl))
            return out

        case .bin32:
            let crc = ZmodemCRC32.checksum(body)
            var out = Data([Z.pad, Z.zdle, Z.bin32])
            out.append(escape(Data(body), escctl: escctl))
            // CRC-32 goes out least-significant byte first.
            let crcBytes: [UInt8] = [
                UInt8(crc & 0xFF),
                UInt8((crc >> 8) & 0xFF),
                UInt8((crc >> 16) & 0xFF),
                UInt8((crc >> 24) & 0xFF),
            ]
            out.append(escape(Data(crcBytes), escctl: escctl))
            return out
        }
    }

    // MARK: - Data subpackets

    /// Encode one data subpacket. The CRC covers the payload plus the
    /// terminator byte, and its width must match the format of the header
    /// that introduced this subpacket (that's how lrzsz receivers pick a
    /// width when parsing).
    public static func encodeDataSubpacket(
        _ payload: Data,
        terminator: UInt8,
        crc32: Bool,
        escctl: Bool = false
    ) -> Data {
        let Z = ZmodemConstants.self
        var out = escape(payload, escctl: escctl)
        out.append(Z.zdle)
        out.append(terminator)
        if crc32 {
            var c = ZmodemCRC32()
            c.update(contentsOf: payload)
            c.update(terminator)
            let v = c.value
            out.append(escape(Data([
                UInt8(v & 0xFF),
                UInt8((v >> 8) & 0xFF),
                UInt8((v >> 16) & 0xFF),
                UInt8((v >> 24) & 0xFF),
            ]), escctl: escctl))
        } else {
            var c = ZmodemCRC16()
            c.update(contentsOf: payload)
            c.update(terminator)
            let v = c.value
            out.append(escape(Data([UInt8(v >> 8), UInt8(v & 0xFF)]), escctl: escctl))
        }
        return out
    }

    // MARK: - Session-level byte strings

    /// Cancel burst: 8 CAN characters followed by 8 backspaces so the CANs
    /// don't linger on the peer's display.
    public static func encodeCancel() -> Data {
        Data(repeating: ZmodemConstants.zdle, count: 8)
            + Data(repeating: ZmodemConstants.backspace, count: 8)
    }

    /// "Over and Out" — the last bytes a sender emits after the final ZFIN
    /// handshake.
    public static func encodeOverAndOut() -> Data {
        Data([0x4F, 0x4F]) // "OO"
    }

    /// Build the ZFILE subpacket payload: name NUL, then the info line
    /// "<size> <mtime-octal> <mode-octal> <serial> <files-remaining> <type>"
    /// followed by a second NUL.
    public static func encodeFileInfo(
        name: String,
        size: UInt64,
        modificationTime: UInt64,
        mode: UInt32,
        filesRemaining: Int
    ) -> Data {
        var payload = Data(name.utf8)
        payload.append(0)
        let info = "\(size) \(String(modificationTime, radix: 8)) \(String(mode, radix: 8)) 0 \(filesRemaining) 0"
        payload.append(contentsOf: info.utf8)
        payload.append(0)
        return payload
    }

    /// Parsed contents of a ZFILE subpacket.
    public struct FileInfo: Equatable, Sendable {
        public var name: String
        public var size: UInt64?
        public var modificationTime: UInt64?
        public var mode: UInt32?
    }

    /// Parse a ZFILE subpacket payload. Tolerant: a missing/unparseable info
    /// line yields nil size instead of an error (ZEOF carries the authoritative
    /// size anyway).
    public static func parseFileInfo(_ payload: Data) -> FileInfo {
        let firstNul = payload.firstIndex(of: 0) ?? payload.endIndex
        let name = String(decoding: payload[..<firstNul], as: UTF8.self)
        var info = FileInfo(name: name, size: nil, modificationTime: nil, mode: nil)
        guard firstNul < payload.endIndex else { return info }
        let rest = payload[(firstNul + 1)...]
        let secondNul = rest.firstIndex(of: 0) ?? rest.endIndex
        let line = String(decoding: rest[..<secondNul], as: UTF8.self)
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        if let f0 = fields.first { info.size = UInt64(f0) }
        if fields.count > 1 { info.modificationTime = UInt64(fields[1], radix: 8) }
        if fields.count > 2 { info.mode = UInt32(fields[2], radix: 8) }
        return info
    }

    /// Reduce a remote-supplied file name to a safe bare file name: strips any
    /// directory components (both separators) and rejects dot names. Returns
    /// nil when nothing usable remains.
    public static func sanitizeFileName(_ raw: String) -> String? {
        var name = raw
        if let i = name.lastIndex(of: "/") { name = String(name[name.index(after: i)...]) }
        if let i = name.lastIndex(of: "\\") { name = String(name[name.index(after: i)...]) }
        name = name.trimmingCharacters(in: .controlCharacters)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        if name.utf8.count > 255 { return nil }
        return name
    }
}
