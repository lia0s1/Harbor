//
//  ZmodemParser.swift
//  HarborKit
//
//  Incremental byte-stream parser for ZModem frames. Feed arbitrary chunks;
//  get back a list of events. Partial frames stay buffered across calls.
//
//  After a header of type ZFILE / ZDATA / ZSINIT / ZCOMMAND / ZSTDERR the
//  parser automatically switches into data-subpacket mode (the subpacket CRC
//  width follows the header's format, exactly like lrzsz), and returns to
//  header scanning once a frame-end terminator (ZCRCE/ZCRCW) is seen.
//
//  A run of >= 4 consecutive ZDLE (CAN) bytes at header level is reported as
//  `.cancel` — that is what a ZCAN cancel burst looks like on the wire.
//

import Foundation

public final class ZmodemParser {

    public enum Event: Equatable, Sendable {
        case header(ZmodemHeader)
        case dataSubpacket(data: Data, terminator: UInt8, crcValid: Bool)
        /// A frame that looked like a header/subpacket but failed to parse or
        /// failed its CRC. The session uses these for its retry budget.
        case corruptFrame(reason: String)
        /// Peer sent a cancel burst (>= 4 consecutive CAN bytes).
        case cancel
    }

    private enum State: Equatable {
        case scan
        case gotPad
        case gotPadPad
        case binaryLead        // ZPAD ZDLE seen; expect ZBIN / ZBIN32
        case hexLead           // ZPAD ZPAD ZDLE seen; expect ZHEX
        case hexBody
        case binaryBody(format: ZmodemHeader.Format)
        case binaryCRC(format: ZmodemHeader.Format)
        case subpacket(crc32: Bool)
        case subpacketEscape(crc32: Bool)
        case subpacketCRC(crc32: Bool, terminator: UInt8)
        case subpacketCRCEscape(crc32: Bool, terminator: UInt8)
    }

    /// Header types that are immediately followed by a data subpacket.
    private static let subpacketFollows: Set<UInt8> = [
        ZmodemConstants.zfile, ZmodemConstants.zdata, ZmodemConstants.zsinit,
        ZmodemConstants.zcommand, ZmodemConstants.zstderr,
    ]

    /// Guard against a peer that never terminates a subpacket.
    private static let maxSubpacketBytes = 4 * 1024 * 1024

    private var state: State = .scan
    private var hexDigits: [UInt8] = []
    private var body: [UInt8] = []      // unescaped type + position bytes (5)
    private var crcBytes: [UInt8] = []  // unescaped CRC bytes (2 or 4)
    private var bodyEscaped = false     // pending ZDLE inside binaryBody/binaryCRC
    private var payload = Data()
    private var cancelRun = 0

    public init() {}

    public func reset() {
        state = .scan
        hexDigits = []
        body = []
        crcBytes = []
        bodyEscaped = false
        payload = Data()
        cancelRun = 0
    }

    /// Feed a chunk of the byte stream; returns the events it produced.
    public func input<S: Sequence>(_ bytes: S) -> [Event] where S.Element == UInt8 {
        var events: [Event] = []
        for b in bytes {
            if let event = step(b) {
                events.append(event)
            }
        }
        return events
    }

    // MARK: - Byte machine

    private func step(_ b: UInt8) -> Event? {
        let Z = ZmodemConstants.self
        switch state {

        case .scan:
            if b == Z.pad {
                cancelRun = 0
                state = .gotPad
            } else if b == Z.zdle {
                cancelRun += 1
                if cancelRun >= 4 {
                    cancelRun = 0
                    return .cancel
                }
            } else {
                cancelRun = 0
            }
            return nil

        case .gotPad:
            switch b {
            case Z.pad: state = .gotPadPad
            case Z.zdle: state = .binaryLead
            default: state = (b == Z.pad) ? .gotPad : .scan
            }
            return nil

        case .gotPadPad:
            if b == Z.zdle {
                state = .hexLead
            } else if b == Z.pad {
                // tolerate extra pads
            } else {
                state = .scan
            }
            return nil

        case .binaryLead:
            switch b {
            case Z.bin:
                startBinaryBody(.bin16)
            case Z.bin32:
                startBinaryBody(.bin32)
            default:
                state = .scan
            }
            return nil

        case .hexLead:
            if b == Z.hex {
                hexDigits = []
                state = .hexBody
            } else {
                state = .scan
            }
            return nil

        case .hexBody:
            if let nibble = hexNibble(b) {
                hexDigits.append(nibble)
                if hexDigits.count == 14 {
                    state = .scan
                    return finishHexHeader()
                }
            } else {
                state = .scan
                return .corruptFrame(reason: "non-hex byte in hex header")
            }
            return nil

        case .binaryBody(let format):
            if collectEscaped(b, into: &body) {
                let done = body.count == 5
                if done { state = .binaryCRC(format: format) }
            }
            return nil

        case .binaryCRC(let format):
            let want = format == .bin32 ? 4 : 2
            if collectEscaped(b, into: &crcBytes) {
                if crcBytes.count == want {
                    state = .scan
                    return finishBinaryHeader(format)
                }
            }
            return nil

        case .subpacket(let crc32):
            if b == Z.zdle {
                state = .subpacketEscape(crc32: crc32)
            } else {
                payload.append(b)
                if payload.count > ZmodemParser.maxSubpacketBytes {
                    state = .scan
                    payload = Data()
                    return .corruptFrame(reason: "subpacket exceeded size cap")
                }
            }
            return nil

        case .subpacketEscape(let crc32):
            switch b {
            case Z.zdle:
                payload.append(Z.zdle)
                state = .subpacket(crc32: crc32)
            case Z.zcrce, Z.zcrcg, Z.zcrcq, Z.zcrcw:
                crcBytes = []
                bodyEscaped = false
                state = .subpacketCRC(crc32: crc32, terminator: b)
            case Z.zrub0, Z.zrub1:
                // Rubout resync bytes: drop them, keep reading the subpacket.
                state = .subpacket(crc32: crc32)
            default:
                payload.append(b ^ 0x40)
                state = .subpacket(crc32: crc32)
            }
            return nil

        case .subpacketCRC(let crc32, let terminator):
            if b == Z.zdle {
                state = .subpacketCRCEscape(crc32: crc32, terminator: terminator)
                return nil
            }
            crcBytes.append(b)
            return finishSubpacketIfDone(crc32: crc32, terminator: terminator)

        case .subpacketCRCEscape(let crc32, let terminator):
            crcBytes.append(b == Z.zdle ? Z.zdle : b ^ 0x40)
            state = .subpacketCRC(crc32: crc32, terminator: terminator)
            return finishSubpacketIfDone(crc32: crc32, terminator: terminator)
        }
    }

    // MARK: - Frame finishers

    private func startBinaryBody(_ format: ZmodemHeader.Format) {
        body = []
        crcBytes = []
        bodyEscaped = false
        state = .binaryBody(format: format)
    }

    /// Appends one possibly-escaped byte to `buffer`. Returns false when the
    /// byte was a ZDLE introducer (nothing appended yet).
    private func collectEscaped(_ b: UInt8, into buffer: inout [UInt8]) -> Bool {
        let Z = ZmodemConstants.self
        if bodyEscaped {
            buffer.append(b == Z.zdle ? Z.zdle : b ^ 0x40)
            bodyEscaped = false
            return true
        }
        if b == Z.zdle {
            bodyEscaped = true
            return false
        }
        buffer.append(b)
        return true
    }

    private func finishHexHeader() -> Event {
        var bytes = [UInt8](repeating: 0, count: 7)
        for i in 0..<7 {
            bytes[i] = (hexDigits[i * 2] << 4) | hexDigits[i * 2 + 1]
        }
        let bodyBytes = Array(bytes[0..<5])
        let expected = (UInt16(bytes[5]) << 8) | UInt16(bytes[6])
        let actual = ZmodemCRC16.checksum(bodyBytes)
        guard actual == expected else {
            return .corruptFrame(reason: "hex header CRC mismatch")
        }
        return headerEvent(type: bytes[0], body: bodyBytes, format: .hex)
    }

    private func finishBinaryHeader(_ format: ZmodemHeader.Format) -> Event {
        let actual16 = ZmodemCRC16.checksum(body)
        switch format {
        case .bin16:
            let expected = (UInt16(crcBytes[0]) << 8) | UInt16(crcBytes[1])
            guard actual16 == expected else {
                return .corruptFrame(reason: "binary header CRC mismatch")
            }
        case .bin32:
            let expected = UInt32(crcBytes[0])
                | (UInt32(crcBytes[1]) << 8)
                | (UInt32(crcBytes[2]) << 16)
                | (UInt32(crcBytes[3]) << 24)
            guard ZmodemCRC32.checksum(body) == expected else {
                return .corruptFrame(reason: "binary32 header CRC mismatch")
            }
        case .hex:
            preconditionFailure("hex headers never reach binaryCRC")
        }
        return headerEvent(type: body[0], body: body, format: format)
    }

    private func headerEvent(type: UInt8, body: [UInt8], format: ZmodemHeader.Format) -> Event {
        let position = UInt32(body[1])
            | (UInt32(body[2]) << 8)
            | (UInt32(body[3]) << 16)
            | (UInt32(body[4]) << 24)
        if ZmodemParser.subpacketFollows.contains(type) {
            payload = Data()
            state = .subpacket(crc32: format == .bin32)
        }
        return .header(ZmodemHeader(type: type, position: position, format: format))
    }

    private func finishSubpacketIfDone(crc32: Bool, terminator: UInt8) -> Event? {
        let want = crc32 ? 4 : 2
        guard crcBytes.count == want else { return nil }

        let valid: Bool
        if crc32 {
            var c = ZmodemCRC32()
            c.update(contentsOf: payload)
            c.update(terminator)
            let expected = UInt32(crcBytes[0])
                | (UInt32(crcBytes[1]) << 8)
                | (UInt32(crcBytes[2]) << 16)
                | (UInt32(crcBytes[3]) << 24)
            valid = c.value == expected
        } else {
            var c = ZmodemCRC16()
            c.update(contentsOf: payload)
            c.update(terminator)
            let expected = (UInt16(crcBytes[0]) << 8) | UInt16(crcBytes[1])
            valid = c.value == expected
        }

        let event = Event.dataSubpacket(data: payload, terminator: terminator, crcValid: valid)
        payload = Data()
        // ZCRCE / ZCRCW end the frame: a header follows. ZCRCG / ZCRCQ keep
        // the frame open with another subpacket.
        state = (terminator == ZmodemConstants.zcrce || terminator == ZmodemConstants.zcrcw)
            ? .scan
            : .subpacket(crc32: crc32)
        return event
    }

    private func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
